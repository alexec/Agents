package agentsd

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	sdk "github.com/coder/acp-go-sdk"

	"github.com/alexec/agents/Go/internal/agentsd/diskjson"
	"github.com/alexec/agents/Go/wire"
)

// The test binary is also a fake ACP runtime: with AGENTS_FAKE_ACP=1 it serves one on its
// stdin and stdout. A prompt with "ask" in it asks for permission before it answers; one
// with "wait for me" waits to be cancelled.
func TestMain(m *testing.M) {
	if os.Getenv("AGENTS_FAKE_ACP") == "1" {
		f := &fakeRuntime{ready: make(chan struct{})}
		f.conn = sdk.NewAgentSideConnection(f, os.Stdout, os.Stdin)
		close(f.ready)
		<-f.conn.Done()
		return
	}
	os.Exit(m.Run())
}

type fakeRuntime struct {
	sdk.Agent // what it does not answer
	conn      *sdk.AgentSideConnection
	// ready is closed once conn is set: the SDK serves before it returns the connection.
	ready chan struct{}
	// sandboxOff is whether session/new's _meta turned Claude's sandbox off.
	sandboxOff bool
}

func (f *fakeRuntime) Initialize(context.Context, sdk.InitializeRequest) (sdk.InitializeResponse, error) {
	return sdk.InitializeResponse{ProtocolVersion: sdk.ProtocolVersionNumber,
		AgentCapabilities: sdk.AgentCapabilities{SessionCapabilities: sdk.SessionCapabilities{Resume: &sdk.SessionResumeCapabilities{},
			Fork: &sdk.SessionForkCapabilities{}}}}, nil
}

func (f *fakeRuntime) UnstableForkSession(_ context.Context, r sdk.UnstableForkSessionRequest) (sdk.UnstableForkSessionResponse, error) {
	return sdk.UnstableForkSessionResponse{SessionId: "forked-" + r.SessionId}, nil
}

// ResumeSession has its own conversation, and no other.
func (f *fakeRuntime) ResumeSession(_ context.Context, r sdk.ResumeSessionRequest) (sdk.ResumeSessionResponse, error) {
	if r.SessionId != "fake-session" {
		return sdk.ResumeSessionResponse{}, fmt.Errorf("no session %s", r.SessionId)
	}
	b, _ := json.Marshal(r.Meta)
	f.sandboxOff = strings.Contains(string(b), `"sandbox":{"enabled":false}`)
	return sdk.ResumeSessionResponse{}, nil
}

// NewSession in a folder called offers offers a model, and a command a moment after.
func (f *fakeRuntime) NewSession(_ context.Context, r sdk.NewSessionRequest) (sdk.NewSessionResponse, error) {
	var out sdk.NewSessionResponse
	b, _ := json.Marshal(r.Meta)
	f.sandboxOff = strings.Contains(string(b), `"sandbox":{"enabled":false}`)
	if filepath.Base(r.Cwd) != "offers" {
		return sdk.NewSessionResponse{SessionId: "fake-session"}, nil
	}
	json.Unmarshal([]byte(`{"sessionId":"fake-session","configOptions":[{"type":"select","id":"model","name":"Model",
		"currentValue":"opus","options":[{"value":"opus","name":"Opus"},{"value":"sonnet","name":"Sonnet"}]}]}`), &out)
	go func() {
		<-f.ready
		time.Sleep(50 * time.Millisecond)
		var u sdk.SessionUpdate
		json.Unmarshal([]byte(`{"sessionUpdate":"available_commands_update","availableCommands":[{"name":"review","description":"Review the change"}]}`), &u)
		f.conn.SessionUpdate(context.Background(), sdk.SessionNotification{SessionId: "fake-session", Update: u})
	}()
	return out, nil
}
func (f *fakeRuntime) Cancel(context.Context, sdk.CancelNotification) error { return nil }
func (f *fakeRuntime) SetSessionConfigOption(context.Context, sdk.SetSessionConfigOptionRequest) (sdk.SetSessionConfigOptionResponse, error) {
	return sdk.SetSessionConfigOptionResponse{}, nil
}

func (f *fakeRuntime) Prompt(ctx context.Context, p sdk.PromptRequest) (sdk.PromptResponse, error) {
	<-f.ready
	text := ""
	if len(p.Prompt) > 0 && p.Prompt[0].Text != nil {
		text = p.Prompt[0].Text.Text
	}
	say := func(s string) {
		f.conn.SessionUpdate(ctx, sdk.SessionNotification{SessionId: p.SessionId, Update: sdk.UpdateAgentMessageText(s)})
	}
	if strings.Contains(text, "wait for me") {
		<-ctx.Done()
		return sdk.PromptResponse{StopReason: sdk.StopReasonCancelled}, nil
	}
	if strings.Contains(text, "spend it all") {
		return sdk.PromptResponse{}, &sdk.RequestError{Code: -32603, Message: "Internal error", Data: map[string]any{"message": "Your credit balance is too low to access the API."}}
	}
	if strings.Contains(text, "sandbox fails") && !f.sandboxOff {
		// A command whose sandbox could not be set up, as Claude's Bash says it.
		f.conn.SessionUpdate(ctx, sdk.SessionNotification{SessionId: p.SessionId, Update: sdk.StartToolCall("call_s", "Run make",
			sdk.WithStartKind(sdk.ToolKindExecute), sdk.WithStartStatus(sdk.ToolCallStatusCompleted),
			sdk.WithStartContent([]sdk.ToolCallContent{sdk.ToolContent(sdk.TextBlock("sandbox_apply: Operation not permitted"))}))})
		say("The command could not run.")
		return sdk.PromptResponse{StopReason: sdk.StopReasonEndTurn}, nil
	}
	if strings.Contains(text, "a form") {
		return f.form(ctx, p.SessionId, strings.Contains(text, "withdraw"), say)
	}
	f.conn.SessionUpdate(ctx, sdk.SessionNotification{SessionId: p.SessionId, Update: sdk.StartToolCall("call_1", "Write hi.txt",
		sdk.WithStartKind(sdk.ToolKindEdit), sdk.WithStartStatus(sdk.ToolCallStatusPending))})
	if strings.Contains(text, "Please ask") {
		r, _ := f.conn.RequestPermission(ctx, sdk.RequestPermissionRequest{SessionId: p.SessionId,
			ToolCall: sdk.ToolCallUpdate{ToolCallId: "call_1", Title: sdk.Ptr("Write hi.txt")},
			Options: []sdk.PermissionOption{{Kind: sdk.PermissionOptionKindAllowOnce, Name: "Allow", OptionId: "allow"},
				{Kind: sdk.PermissionOptionKindRejectOnce, Name: "Reject", OptionId: "reject"}}})
		if r.Outcome.Selected == nil || r.Outcome.Selected.OptionId != "allow" {
			say("You said no.")
			return sdk.PromptResponse{StopReason: sdk.StopReasonEndTurn}, nil
		}
	}
	f.conn.SessionUpdate(ctx, sdk.SessionNotification{SessionId: p.SessionId, Update: sdk.UpdateToolCall("call_1",
		sdk.WithUpdateStatus(sdk.ToolCallStatusCompleted))})
	say("I wrote hi.txt. ")
	say("Anything else?")
	return sdk.PromptResponse{StopReason: sdk.StopReasonEndTurn}, nil
}

// form asks which colour, and says what it heard; with withdraw, it asks for a page by
// its own id and takes the question down itself.
func (f *fakeRuntime) form(ctx context.Context, session sdk.SessionId, withdraw bool, say func(string)) (sdk.PromptResponse, error) {
	req := sdk.UnstableCreateElicitationRequest{Form: &sdk.UnstableCreateElicitationForm{Mode: "form", Message: "Which colour?",
		RequestedSchema: sdk.UnstableElicitationSchema{Type: "object", Required: []string{"colour"},
			Properties: map[string]any{"colour": map[string]any{"type": "string", "enum": []string{"red", "blue"}}}}}}
	if withdraw {
		req = sdk.UnstableCreateElicitationRequest{Url: &sdk.UnstableCreateElicitationUrl{Mode: "url", Message: "Sign in",
			ElicitationId: "e1", Url: "https://example.com/sign-in"}}
		go func() {
			time.Sleep(300 * time.Millisecond)
			f.conn.UnstableCompleteElicitation(ctx, sdk.UnstableCompleteElicitationNotification{ElicitationId: "e1"})
		}()
	}
	r, err := f.conn.UnstableCreateElicitation(ctx, req)
	switch {
	case ctx.Err() != nil: // session/cancel came first
		return sdk.PromptResponse{StopReason: sdk.StopReasonCancelled}, nil
	case err != nil:
		say("No form: " + err.Error())
	case r.Accept != nil:
		say(fmt.Sprintf("You chose %v.", r.Accept.Content["colour"]))
	case r.Decline != nil:
		say("You would not say.")
	default:
		// Cancelled by a stop: session/cancel follows the answer.
		select {
		case <-ctx.Done():
			return sdk.PromptResponse{StopReason: sdk.StopReasonCancelled}, nil
		case <-time.After(300 * time.Millisecond):
		}
		say("The form was closed.")
	}
	return sdk.PromptResponse{StopReason: sdk.StopReasonEndTurn}, nil
}

func fakeRuntimes(t *testing.T) {
	self, _ := os.Executable()
	t.Setenv("AGENTS_FAKE_ACP", "1")
	old := locateFor
	locateFor = func(*runtimeDef) (string, []string, []string) { return self, nil, nil }
	t.Cleanup(func() { locateFor = old })
}

// notes collects the notifications a client hears.
func (c *conn) until(t *testing.T, what string, ok func(method string, params json.RawMessage) bool) {
	t.Helper()
	deadline := time.After(20 * time.Second)
	for {
		select {
		case line := <-c.out:
			var m message
			json.Unmarshal([]byte(line), &m)
			if m.Method != "" && ok(m.Method, m.Params) {
				return
			}
		case <-deadline:
			t.Fatalf("never heard %s", what)
		}
	}
}

func ended(id wire.UUID, state wire.AgentState) func(string, json.RawMessage) bool {
	return func(method string, p json.RawMessage) bool {
		if method != "agent/changed" {
			return false
		}
		var a wire.Agent
		json.Unmarshal(p, &a)
		return a.ID == id && a.State == state
	}
}

// A whole turn: the agent starts, the runtime asks, the card is answered, the turn ends
// finished with a report from its last words, and the records on disk are today's.
func TestATurnWithACard(t *testing.T) {
	fakeRuntimes(t)
	root := t.TempDir()
	work := t.TempDir()
	d, c := start(t, root)
	defer d.Shutdown()
	var id wire.UUID
	json.Unmarshal(c.call(t, 1, "agents/start", map[string]any{"runtimeID": "claude", "cwd": "file://" + work,
		"prompt": "Please ask, then write hi.txt", "startOptions": map[string]any{"values": map[string]any{}, "extraArguments": []string{}}}), &id)
	var permission wire.PermissionRequest
	c.until(t, "a card", func(method string, p json.RawMessage) bool {
		var n wire.PermissionNotification
		if method == "agent/permission" && json.Unmarshal(p, &n) == nil && n.Request != nil {
			permission = *n.Request
			return true
		}
		return false
	})
	if got := d.pendingPermissions(); len(got) != 1 || got[0].ID != permission.ID {
		t.Fatalf("pending %v", got)
	}
	if a := d.Store.Agent(id); a.State != wire.AgentStateWaitingOnUser {
		t.Fatalf("state %s while asking", a.State)
	}
	c.call(t, 2, "permissions/answer", map[string]any{"permissionID": permission.ID, "optionID": "allow"})
	c.until(t, "the end", ended(id, wire.AgentStateFinished))
	a := d.Store.Agent(id)
	if a.Report == nil || a.Report.Outcome != wire.WorkOutcomeNeedsAnswer || a.Report.Message != "I wrote hi.txt." {
		t.Fatalf("report %+v", a.Report)
	}
	if a.RuntimeSessionID == nil || *a.RuntimeSessionID != "fake-session" || a.EndedReason == nil || *a.EndedReason != wire.EndedReasonEndTurn {
		t.Fatalf("%+v", a)
	}
	// The record's last line follows the agent/changed that says it ended.
	waitFor(t, "the ending recorded", func() bool { k := kinds(d, id); return len(k) > 0 && k[len(k)-1] == "stateChanged" })
	entries, _, _ := d.Store.Transcript(id, 0)
	var kinds []string
	for _, e := range entries {
		b, _ := json.Marshal(e.Kind)
		var k map[string]any
		json.Unmarshal(b, &k)
		for name := range k {
			kinds = append(kinds, name)
		}
	}
	want := "runtimeNote userMessage stateChanged toolCall permissionAsked stateChanged permissionAnswered stateChanged toolCallUpdate agentMessage agentMessage stateChanged"
	if got := strings.Join(kinds, " "); got != want {
		t.Fatalf("transcript\n got %s\nwant %s", got, want)
	}
	// The record on disk is the Swift store's: ISO dates.
	b, _ := os.ReadFile(filepath.Join(root, "agents", string(id), "agent.json"))
	var back wire.Agent
	if err := diskjson.Unmarshal(b, &back); err != nil || !strings.Contains(string(b), `"createdAt":"20`) {
		t.Fatalf("agent.json %s: %v", b, err)
	}
}

func TestStopEndsTheTurnCancelled(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	var id wire.UUID
	json.Unmarshal(c.call(t, 1, "agents/start", map[string]any{"runtimeID": "claude", "cwd": "file://" + t.TempDir(),
		"prompt": "wait for me"}), &id)
	c.until(t, "running", ended(id, wire.AgentStateRunning))
	time.Sleep(200 * time.Millisecond)
	c.call(t, 2, "agents/stop", map[string]any{"agentID": id})
	c.until(t, "stopped", ended(id, wire.AgentStateStopped))
	if a := d.Store.Agent(id); *a.EndedReason != wire.EndedReasonCancelled {
		t.Fatalf("ended %s", *a.EndedReason)
	}
	c.call(t, 3, "agents/archive", map[string]any{"agentID": id})
	if a := d.Store.Agent(id); a.State != wire.AgentStateArchived || a.ArchivedAt == nil {
		t.Fatalf("archived %+v", a.State)
	}
}

func TestAStartInAFolderThatIsNotThere(t *testing.T) {
	_, c := start(t, t.TempDir())
	c.in <- `{"jsonrpc":"2.0","id":1,"method":"agents/start","params":{"runtimeID":"claude","cwd":"file:///no/such","prompt":"x"}}`
	for line := range c.out {
		if strings.Contains(line, `"id":1`) {
			if !strings.Contains(line, "-32004") {
				t.Fatal(line)
			}
			return
		}
	}
}

func TestRuntimesList(t *testing.T) {
	_, c := start(t, t.TempDir())
	var rs []wire.RuntimeStatus
	json.Unmarshal(c.call(t, 1, "runtimes/list", nil), &rs)
	if len(rs) != 8 || rs[0].Runtime.ID != "antigravity" {
		t.Fatalf("%d runtimes, first %v", len(rs), rs)
	}
	for _, r := range rs {
		if r.Availability.Available == nil && r.Availability.Missing == nil {
			t.Fatalf("%s has no availability", r.Runtime.ID)
		}
	}
}

func TestAToolCallIsRecordedAsSwiftRecordsIt(t *testing.T) {
	tc := toolCall(sdk.SessionToolCallUpdate{ToolCallId: "c1", Status: sdk.Ptr(sdk.ToolCallStatusCompleted),
		RawOutput: map[string]any{"ok": true}, Meta: map[string]any{"x": 1}})
	if tc.Title != "Tool call" || *tc.ToolCallID != "c1" || *tc.Status != "completed" || string(tc.RawOutput) != `{"ok":true}` {
		t.Fatalf("%+v", tc)
	}
	if strings.Contains(string(tc.Raw), "rawOutput") || strings.Contains(string(tc.Raw), "_meta") || !strings.Contains(string(tc.Raw), "toolCallId") {
		t.Fatalf("raw %s", tc.Raw)
	}
	kind := toolCall(sdk.SessionToolCallUpdate{ToolCallId: "c2", Kind: sdk.Ptr(sdk.ToolKindEdit)})
	if kind.Title != "edit" {
		t.Fatalf("title %q", kind.Title)
	}
}
