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

	"github.com/alexec/agents/Go/internal/agentsd/diskjson"
	"github.com/alexec/agents/Go/wire"
)

// Ports EventLogTests, EventStoreTests and what EventSourceTests hold of a server: the
// one funnel, the file a restart reads back, and the events an agent's life raises.

// logged is the log newest first, without the disk's events: the machine a test runs on
// may well be low on space, and say so as the host starts.
func logged(d *Daemon) []wire.Event {
	var out []wire.Event
	for _, e := range d.eventsPage(wire.EventsListRequest{}).Events {
		if !strings.HasPrefix(e.Name, "machine.") {
			out = append(out, e)
		}
	}
	return out
}

// names is the log's names oldest first, without the disk's.
func names(d *Daemon) []string {
	var out []string
	for _, e := range logged(d) {
		out = append([]string{e.Name}, out...)
	}
	return out
}

func TestEventsAreKeptAndReadBack(t *testing.T) {
	root := t.TempDir()
	d, c := start(t, root)
	dir := t.TempDir()
	base := d.eventHead()
	first := d.raise(wire.EventDraft{Name: "server.online", At: now(), Scope: macScope(), Sentence: "ci came back.", Details: map[string]string{"server": "ci"}})
	again := d.raise(wire.EventDraft{Name: "server.online", At: now(), Scope: macScope(), Sentence: "ci came back.", Details: map[string]string{"server": "ci"}})
	other := d.raise(wire.EventDraft{Name: "branch.moved", At: now(), Scope: folderScope(dir), Sentence: "moved", Details: map[string]string{"branch": "x"}})
	if first.Position != base+1 || again.Position != base+1 || again.Count != 2 || again.LastAt == nil || other.Position != base+2 {
		t.Fatalf("%+v %+v %+v", first, again, other)
	}
	d.addConsequence(wire.Consequence{Woke: &wire.ConsequenceWoke{AgentID: "A", Title: "Fix"}}, base+2)

	var page wire.EventsPage
	json.Unmarshal(c.call(t, 1, "events/list", map[string]any{"limit": 1}), &page)
	if len(page.Events) != 1 || page.Events[0].Position != base+2 || !page.HasMore || len(page.Events[0].Consequences) != 1 || page.Waiting == nil {
		t.Fatalf("%+v", page)
	}
	page = wire.EventsPage{}
	json.Unmarshal(c.call(t, 2, "events/list", map[string]any{"limit": 200, "groups": []string{"mac"}}), &page)
	if page.Events[0].Name != "server.online" {
		t.Fatalf("%+v", page)
	}
	page = wire.EventsPage{}
	json.Unmarshal(c.call(t, 3, "events/list", map[string]any{"limit": 200, "scope": map[string]any{"folder": map[string]any{"_0": "file://" + dir}}}), &page)
	if len(page.Events) != 1 || page.Events[0].Name != "branch.moved" {
		t.Fatalf("%+v", page)
	}

	// The file: a line an event, a consequence, a repeat; the state a block ahead.
	b, _ := os.ReadFile(filepath.Join(root, "events.jsonl"))
	lines := strings.Split(strings.TrimSpace(string(b)), "\n")
	lines = lines[int(base):]
	if len(lines) != 4 || !strings.HasPrefix(lines[0], `{"event":{`) || !strings.HasPrefix(lines[1], `{"at":`) ||
		!strings.Contains(lines[1], fmt.Sprintf(`"repeat":%d`, base+1)) || !strings.HasPrefix(lines[3], `{"consequence":{"woke":`) {
		t.Fatalf("%s", b)
	}
	var state eventState
	s, _ := os.ReadFile(filepath.Join(root, "events-state.json"))
	diskjson.Unmarshal(s, &state)
	if state.NextPosition != 2+eventPositionBlock {
		t.Fatalf("%s", s)
	}
	d.Shutdown()

	// A restart reads it back, and a torn last line is skipped; positions go on from the block.
	f, _ := os.OpenFile(filepath.Join(root, "events.jsonl"), os.O_APPEND|os.O_WRONLY, 0o644)
	f.WriteString(`{"event":{"posi`)
	f.Close()
	d2, err := New(context.Background(), root)
	if err != nil {
		t.Fatal(err)
	}
	defer d2.Shutdown()
	got := d2.eventsPage(wire.EventsListRequest{}).Events
	if len(got) != int(base)+2 || got[1].Count != 2 || len(got[0].Consequences) != 1 {
		t.Fatalf("%+v", got)
	}
	if e := d2.raise(wire.EventDraft{Name: "server.offline", At: now(), Scope: macScope(), Sentence: "ci went offline."}); e.Position != 2+eventPositionBlock {
		t.Fatalf("%+v", e)
	}
	b, _ = os.ReadFile(filepath.Join(root, "events.jsonl"))
	if !strings.Contains(string(b), "{\"event\":{\"posi\n{\"event\":") {
		t.Fatalf("the torn line swallowed the next: %s", b)
	}
}

func TestOldEventsGo(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	d.raise(wire.EventDraft{Name: "server.online", At: wire.DateOf(time.Now().Add(-8 * 24 * time.Hour)), Scope: macScope(), Sentence: "old"})
	d.raise(wire.EventDraft{Name: "server.offline", At: now(), Scope: macScope(), Sentence: "new"})
	d.eventMu.Lock()
	d.pruneEventsLocked()
	d.eventMu.Unlock()
	if n := names(d); len(n) != 1 || n[0] != "server.offline" {
		t.Fatal(n)
	}
}

func TestRaisingByHandAndAServersChange(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	draft := map[string]any{"name": "branch.moved", "at": now(), "scope": map[string]any{"mac": map[string]any{}},
		"sentence": "moved.", "details": map[string]any{}, "chainDepth": 0}
	if e := c.callError(t, 1, "events/raise", map[string]any{"draft": draft}); e.Code != wire.FailureEventRefused {
		t.Fatalf("%+v", e)
	}
	d.RaiseByHand = true
	draft["name"] = "Bad Name"
	if e := c.callError(t, 2, "events/raise", map[string]any{"draft": draft}); !strings.Contains(e.Message, "is not an event name") {
		t.Fatal(e.Message)
	}
	draft["name"] = "branch.moved"
	var e wire.Event
	json.Unmarshal(c.call(t, 3, "events/raise", map[string]any{"draft": draft,
		"consequences": []any{map[string]any{"woke": map[string]any{"agentID": "A", "title": "Fix"}}}}), &e)
	if e.Name != "branch.moved" || len(e.Consequences) != 1 {
		t.Fatalf("%+v", e)
	}
	if e := c.callError(t, 4, "events/server", map[string]any{"server": " ", "online": true}); e.Message != "A server change needs the server's name." {
		t.Fatal(e.Message)
	}
	json.Unmarshal(c.call(t, 5, "events/server", map[string]any{"server": "ci", "online": false}), &e)
	if e.Name != "server.offline" || e.Sentence != "ci went offline." || e.Details["server"] != "ci" {
		t.Fatalf("%+v", e)
	}
}

func TestAnAgentsLifeIsOnTheLog(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := t.TempDir()
	id := startAgent(t, c, 1, dir, "Write it")
	waitFor(t, "it finished", func() bool { a := d.Store.Agent(id); return a.State == wire.AgentStateFinished })
	waitFor(t, "the finish on the log", func() bool { n := names(d); return len(n) > 0 && n[len(n)-1] == "agent.finished" })
	fin := logged(d)[0]
	if fin.Details["agent"] != string(id) || fin.Details["afterwards"] != "stay" || fin.Details["outcome"] != string(d.Store.Agent(id).Report.Outcome) ||
		fin.Details["started_by"] != "person" || fin.Details["runtime"] != "claude" || !strings.Contains(fin.Sentence, "finished: ") ||
		fin.Scope.Folder == nil {
		t.Fatalf("%+v", fin)
	}
	if n := names(d); n[0] != "agent.started" {
		t.Fatal(n)
	}
	c.call(t, 2, "agents/archive", map[string]any{"agentID": id})
	c.call(t, 3, "agents/delete", map[string]any{"agentID": id})
	n := names(d)
	if n[len(n)-2] != "agent.archived" || n[len(n)-1] != "agent.deleted" {
		t.Fatal(n)
	}
	if e := logged(d)[0]; e.Details["because"] != "person" || e.Details["agent_title"] == "" {
		t.Fatalf("%+v", e)
	}
}

func TestEndingsSayStoppedOrFailed(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	a := seeded(t, d, t.TempDir(), nil)
	d.raiseAgentEnding(a.ID, wire.AgentStateStopped, reason(wire.EndedReasonCancelled))
	d.raiseAgentEnding(a.ID, wire.AgentStateStopped, reason(wire.EndedReasonAllowanceSpent))
	es := logged(d)
	if es[1].Name != "agent.stopped" || es[1].Details["by"] != "you" ||
		es[0].Name != "agent.failed" || es[0].Details["reason"] != "allowance_spent" || !strings.HasSuffix(es[0].Sentence, "ended in an error: its allowance ran out.") {
		t.Fatalf("%+v", es)
	}
}

func TestADiskCrossingIsSaidOnce(t *testing.T) {
	root := t.TempDir()
	d, _ := start(t, root)
	// As low as can be: every disk is under a line of everything it holds.
	d.raiseDiskLow(wire.DiskAlarm{Reading: wire.DiskReading{Volume: "This server’s disk", FreeBytes: 1_500_000_000, TotalBytes: 100e9},
		Level: wire.DiskLevelLow, Threshold: 20e9}, nil)
	e := d.eventsPage(wire.EventsListRequest{}).Events[0]
	if e.Sentence != "This server’s disk is running low: 1.5 GB free." || e.Details["free_percent"] != "1" || e.Details["level"] != "low" {
		t.Fatalf("%+v", e)
	}
	// The levels of the first look are kept for the next run.
	var state eventState
	s, _ := os.ReadFile(filepath.Join(root, "events-state.json"))
	diskjson.Unmarshal(s, &state)
	if len(state.DiskLevels) == 0 {
		t.Fatalf("%s", s)
	}
	d.Shutdown()
}
