package daemon

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"testing"
	"time"

	acp "github.com/coder/acp-go-sdk"

	"github.com/alexec/agents/agentsd-go/internal/wire"
)

// What this host writes, by hand, must be what the schema says (stage 3): every agent
// record and transcript entry decodes strictly into the generated types.
func strict[T any](t *testing.T, what string, v any) {
	t.Helper()
	b, _ := json.Marshal(v)
	d := json.NewDecoder(bytes.NewReader(b))
	d.DisallowUnknownFields()
	var out T
	if err := d.Decode(&out); err != nil {
		t.Errorf("%s does not fit the schema: %v\n%s", what, err, b)
	}
}

func TestHostRecordsFitTheSchema(t *testing.T) {
	root := t.TempDir()
	os.Setenv("HOME", t.TempDir()) // no toolset, no sign-in: the start fails, as recorded
	os.Setenv("PATH", "/nonexistent")
	d, err := New(context.Background(), root)
	if err != nil {
		t.Fatal(err)
	}
	folder := t.TempDir()
	id, err := d.Start("claude", folderURL(folder), "Say hello.", nil)
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 50 && d.store.Agent(id).State != "stopped"; i++ {
		time.Sleep(20 * time.Millisecond)
	}
	l := d.live(id)
	for _, u := range []string{
		`{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hello."},"messageId":"m1"}}`,
		`{"sessionId":"s","update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"hmm"}}}`,
		`{"sessionId":"s","update":{"sessionUpdate":"tool_call","toolCallId":"t1","title":"ls","kind":"execute","status":"pending","rawInput":{"command":"ls"}}}`,
		`{"sessionId":"s","update":{"sessionUpdate":"tool_call_update","toolCallId":"t1","status":"completed","content":[{"type":"content","content":{"type":"text","text":"a"}}]}}`,
		`{"sessionId":"s","update":{"sessionUpdate":"plan","entries":[{"content":"Read","priority":"high","status":"in_progress"}]}}`,
		`{"sessionId":"s","update":{"sessionUpdate":"current_mode_update","currentModeId":"plan"}}`,
	} {
		var n acp.SessionNotification
		if err := json.Unmarshal([]byte(u), &n); err != nil {
			t.Fatal(err)
		}
		l.Update(n)
	}
	var req acp.RequestPermissionRequest
	json.Unmarshal([]byte(`{"sessionId":"s","toolCall":{"toolCallId":"t2","title":"rm x","kind":"delete"},
		"options":[{"optionId":"allow","name":"Allow","kind":"allow_once"},{"optionId":"deny","name":"Deny","kind":"reject_once"}]}`), &req)
	go func() {
		time.Sleep(50 * time.Millisecond)
		for _, p := range l.pending {
			l.answer(p.req.ID, "allow")
		}
	}()
	if got := l.Permission(context.Background(), req); got != "allow" {
		t.Fatalf("answer %q", got)
	}
	d.end(id, "finished", "endTurn", "Hello. Done.")

	strict[wire.Agent](t, "the agent", d.store.Agent(id))
	kinds := map[string]bool{}
	for _, e := range d.store.Transcript(id) {
		for k := range e.Kind {
			kinds[k] = true
		}
		strict[wire.TranscriptEntry](t, "an entry", e)
	}
	t.Logf("checked kinds: %v", kinds)
	p := d.store.AddProject(folderURL(folder))
	strict[wire.ProjectSummary](t, "the project", d.summary(p))
	for _, r := range d.runtimesList() {
		strict[wire.RuntimeStatus](t, "a runtime", r)
	}
}
