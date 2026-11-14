package agentsd

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// The event envelope (#4728, spec 4724-event-bus, "An event").

func envStr(p *string) string {
	if p == nil {
		return "<nil>"
	}
	return *p
}

func TestTheAppsOwnEventsHaveAnEnvelope(t *testing.T) {
	root := t.TempDir()
	d, c := start(t, root)
	folder := t.TempDir()
	if err := os.MkdirAll(filepath.Join(folder, ".agents"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(folder, ".agents", "folder.json"), []byte(`{"project":"P-Agents"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	machine := d.envelopeMachine()

	e := d.raise(wire.EventDraft{Name: "agent.finished", At: now(), Scope: folderScope(folder), Sentence: "done",
		Details: map[string]string{"agent": "7F3C", "outcome": "done"}})
	subject := "agents:session:p-agents#7F3C"
	if envStr(e.Specversion) != "1.0" || envStr(e.Type) != "agent.finished" || envStr(e.Provider) != "agents" || envStr(e.Topic) != "p-agents" ||
		e.Subject == nil || e.Subject.String() != subject || envStr(e.ID) != fmt.Sprintf("%s@agent.finished/%d", subject, e.Position) ||
		envStr(e.Source) != "agents:p-agents" || envStr(e.Producer) != "agents:machine:#"+machine || envStr(e.Time) == "<nil>" {
		t.Fatalf("%+v", e)
	}
	var data map[string]string
	if json.Unmarshal(e.Data, &data) != nil || data["outcome"] != "done" {
		t.Fatalf("data %s", e.Data)
	}

	m := d.raise(wire.EventDraft{Name: "server.online", At: now(), Scope: macScope(), Sentence: "ci came back.",
		Details: map[string]string{"server": "ci"}})
	if envStr(m.Topic) != machine || m.Subject == nil || m.Subject.String() != "agents:server:"+machine+"#ci" {
		t.Fatalf("%+v", m)
	}
	w := d.raise(wire.EventDraft{Name: "mac.wake", At: now(), Scope: macScope(), Sentence: "woke"})
	if w.Subject == nil || w.Subject.String() != "agents:machine:#"+machine {
		t.Fatalf("%+v", w)
	}

	// events/list returns it, and events.jsonl keeps it across a restart.
	var page wire.EventsPage
	if err := json.Unmarshal(c.call(t, 1, "events/list", map[string]any{"limit": 200}), &page); err != nil {
		t.Fatal(err)
	}
	found := false
	for _, got := range page.Events {
		found = found || envStr(got.ID) == envStr(e.ID)
	}
	if !found {
		t.Fatalf("events/list has no %s", envStr(e.ID))
	}
	d.Shutdown()
	d2, err := New(context.Background(), root)
	if err != nil {
		t.Fatal(err)
	}
	defer d2.Shutdown()
	if got := d2.event(e.Position); got == nil || envStr(got.ID) != envStr(e.ID) || envStr(got.Producer) != envStr(e.Producer) {
		t.Fatalf("%+v", got)
	}
}

func TestAServersEventTakesTheSubjectItSays(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	folder := t.TempDir()
	id, subject, key := "pr.commented:alexec/agents:2457", "github:pr:alexec/agents#4702", "2457"
	details := map[string]string{"server": "github", "event": "pr.commented", "subscription": "k", "mcp_event_id": id,
		"time": "2026-11-11T17:02:11Z", "payload": `{"number":4702}`}
	e := d.raiseEnveloped(wire.EventDraft{Name: "pr.commented", At: now(), Scope: folderScope(folder), Sentence: "x", Details: details},
		nil, polledEnvelope(mcpPolled{EventID: &id, Subject: &subject, Key: &key}, "github"))
	if envStr(e.ID) != subject+"@pr.commented/2457" || envStr(e.Provider) != "github" || envStr(e.Topic) != "alexec/agents" ||
		envStr(e.Source) != "github:alexec/agents" || envStr(e.Time) != "2026-11-11T17:02:11Z" || string(e.Data) != `{"number":4702}` {
		t.Fatalf("%+v", e)
	}

	// A server that says no subject, or one that is not a ref: provider server:<name>.
	bad := "not a ref"
	id2 := "evt-9"
	details2 := map[string]string{"server": "ci", "event": "build.done", "subscription": "k", "mcp_event_id": id2, "payload": "null"}
	f := d.raiseEnveloped(wire.EventDraft{Name: "build.done", At: now(), Scope: folderScope(folder), Sentence: "y", Details: details2},
		nil, polledEnvelope(mcpPolled{EventID: &id2, Subject: &bad}, "ci"))
	if envStr(f.ID) != "server:ci@build.done/evt-9" || envStr(f.Provider) != "server:ci" || f.Subject != nil || envStr(f.Topic) != "" {
		t.Fatalf("%+v", f)
	}
}

func TestAnOldLogLineGetsItsEnvelope(t *testing.T) {
	root := t.TempDir()
	line := `{"event":{"position":1,"name":"pr.merged","at":` + fmt.Sprint(float64(now())) + `,"count":1,"scope":{"mac":{}},"sentence":"github reported pr.merged",` +
		`"details":{"server":"github","event":"pr.merged","subscription":"k","mcp_event_id":"pr.merged:a/b:1","payload":"{}"},"chainDepth":0,"consequences":[]}}` + "\n"
	if err := os.WriteFile(filepath.Join(root, "events.jsonl"), []byte(line), 0o644); err != nil {
		t.Fatal(err)
	}
	d, _ := start(t, root)
	defer d.Shutdown()
	e := d.event(1)
	if e == nil || envStr(e.ID) != "server:github@pr.merged/pr.merged:a/b:1" || envStr(e.Type) != "pr.merged" || e.Details["mcp_event_id"] == "" {
		t.Fatalf("%+v", e)
	}
}
