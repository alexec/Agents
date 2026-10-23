package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// Ports LeaseCallTests: an agent's lease, refused or waited for in line, its place a wait
// on its own lease.granted (#2361).

func (m *mcpClient) tool(id int, name string, args map[string]any) (string, bool) {
	m.t.Helper()
	_, r := m.post("tools/call", map[string]any{"name": "mcp__agents__" + name, "arguments": args}, id)
	var res struct {
		Content []struct{ Text string } `json:"content"`
		IsError bool                    `json:"isError"`
	}
	json.Unmarshal(r["result"], &res)
	if len(res.Content) == 0 {
		m.t.Fatalf("%s: %s", name, r["error"])
	}
	return res.Content[0].Text, res.IsError
}

func TestAgentsTakeTurnsWithAResource(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := t.TempDir()
	titled := func(title string) func(*wire.Agent) {
		return func(a *wire.Agent) { a.Title = &title }
	}
	first := appClient(t, d, seeded(t, d, dir, titled("Build it")).ID)
	secondAgent := seeded(t, d, dir, titled("Test it"))
	second := appClient(t, d, secondAgent.ID)
	first.post("initialize", map[string]any{}, 1)
	second.post("initialize", map[string]any{}, 1)

	if text, _ := first.tool(2, "lease_resource", map[string]any{"name": "Build", "minutes": 10}); !strings.HasPrefix(text, "You hold Build until ") ||
		!strings.Contains(text, "(10 minutes)") {
		t.Fatal(text)
	}
	if text, _ := first.tool(3, "lease_resource", map[string]any{"name": "build", "minutes": "20"}); !strings.HasPrefix(text, "You still hold Build, now until ") {
		t.Fatal(text)
	}
	if text, _ := second.tool(2, "lease_resource", map[string]any{"name": "build", "wait": false}); !strings.HasPrefix(text, "Build is held by “Build it” until ") ||
		!strings.HasSuffix(text, ". You are not in line.") {
		t.Fatal(text)
	}
	// Held: answered at once, and the place in line is a wait on its own grant (#2361).
	if text, _ := second.tool(3, "lease_resource", map[string]any{"name": "build"}); !strings.HasPrefix(text, "Build is held by “Build it” until ") ||
		!strings.HasSuffix(text, ". You are 1st in line. You will get a lease.granted event when it is yours. End your turn, and you will be started again with it.") {
		t.Fatal(text)
	}
	w := d.Store.Agent(secondAgent.ID).EventWait
	if name, ok := lineWaitResource(w, secondAgent.ID); !ok || name != "build" || w.Deadline == nil {
		t.Fatalf("%+v", w)
	}
	var snap wire.LeaseSnapshot
	json.Unmarshal(c.call(t, 1, "resources/snapshot", nil), &snap)
	for _, r := range snap.Resources {
		if r.Name == "build" && (len(r.Line) != 1 || !r.Line[0].IsCallOpen) {
			t.Fatalf("%+v", r)
		}
	}
	if s := d.waitStatus(d.Store.Agent(secondAgent.ID)); s == nil || !strings.HasPrefix(s.Line, "◷ Waiting for your turn with build · since ") {
		t.Fatalf("%+v", s)
	}
	// The release hands it on, and lease.granted wakes the one in line.
	if text, _ := first.tool(4, "release_resource", map[string]any{"name": "Build"}); text != "Released Build. It has gone to “Test it”." {
		t.Fatal(text)
	}
	waitFor(t, "the wake in its chat", func() bool {
		for _, u := range userMessages(d, secondAgent.ID) {
			if strings.HasPrefix(u, "The event you were waiting for happened.\n\nlease.granted at ") && strings.Contains(u, "\nresource: build") {
				return true
			}
		}
		return false
	})
	if w := d.Store.Agent(secondAgent.ID).EventWait; w == nil || w.Ending == nil || w.Ending.Matched == nil {
		t.Fatalf("%+v", w)
	}
	waitFor(t, "its turn over", func() bool { return d.Store.Agent(secondAgent.ID).State == wire.AgentStateFinished })
	// Its turn gave it a new token: a new client.
	second = appClient(t, d, secondAgent.ID)
	second.post("initialize", map[string]any{}, 1)
	text, _ := second.tool(4, "list_resources", nil)
	if !strings.HasPrefix(text, "Yours:\n- Holding Build (build) until ") || !strings.Contains(text, "On this Mac:\n- screen — Screen, mouse and keyboard: free.") ||
		!strings.Contains(text, "- Build (named by an agent): held by you until ") {
		t.Fatal(text)
	}
	// In line again: release_resource leaves the line, and its wait goes with it.
	if text, _ := first.tool(5, "lease_resource", map[string]any{"name": "build"}); !strings.HasSuffix(text, "You are 1st in line. You will get a lease.granted event when it is yours. End your turn, and you will be started again with it.") {
		t.Fatal(text)
	}
	if text, _ := first.tool(6, "release_resource", map[string]any{"name": "build"}); text != "You left the line for Build." {
		t.Fatal(text)
	}
	if text, isErr := first.tool(7, "release_resource", map[string]any{}); !isErr || text != "Nothing was released: say which resource, in `name`." {
		t.Fatal(text)
	}
}

// Stop Waiting, and cancel_wait, take an agent out of the line; a wait that replaces its
// place keeps it, and its turn starts it again all the same (#2361).
func TestAPlaceInLineIsAWait(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := t.TempDir()
	holder := appClient(t, d, seeded(t, d, dir, nil).ID)
	a := seeded(t, d, dir, nil)
	m := appClient(t, d, a.ID)
	holder.post("initialize", map[string]any{}, 1)
	m.post("initialize", map[string]any{}, 1)
	holder.tool(2, "lease_resource", map[string]any{"name": "screen"})
	inLine := func() bool {
		d.leaseMu.Lock()
		defer d.leaseMu.Unlock()
		e := d.book.Entries["screen"]
		return e != nil && lineIndex(e, a.ID) >= 0
	}
	m.tool(2, "lease_resource", map[string]any{"name": "screen"})
	c.call(t, 1, "events/cancelWait", map[string]any{"agentID": a.ID})
	if inLine() || d.Store.Agent(a.ID).EventWait != nil {
		t.Fatal("Stop Waiting kept the place")
	}
	m.tool(3, "lease_resource", map[string]any{"name": "screen"})
	if text, _ := m.tool(4, "cancel_wait", nil); text != "Stopped waiting for your turn with screen." || inLine() {
		t.Fatal(text)
	}
	// A wait on something else replaces the line's wait and keeps the place.
	m.tool(5, "lease_resource", map[string]any{"name": "screen"})
	answered := make(chan string, 1)
	go func() {
		text, _ := m.tool(6, "wait_for_event", map[string]any{"events": "lease.released", "where": map[string]any{}, "until_minutes": 10})
		answered <- text
	}()
	waitFor(t, "the other wait", func() bool {
		w := d.Store.Agent(a.ID).EventWait
		return w != nil && w.Patterns[0].Name == "lease.released"
	})
	if !inLine() {
		t.Fatal("the place went with its wait")
	}
	d.endWait(a.ID, "agent", true)
	<-answered
	holder.tool(3, "release_resource", map[string]any{"name": "screen"})
	waitFor(t, "started with the event", func() bool {
		for _, u := range userMessages(d, a.ID) {
			if strings.HasPrefix(u, "The event you were waiting for happened.\n\nlease.granted at ") && strings.Contains(u, "You hold Screen, mouse and keyboard until ") {
				return true
			}
		}
		return false
	})
	waitFor(t, "its turn over", func() bool { return d.Store.Agent(a.ID).State == wire.AgentStateFinished })
}

// The line and the waits outlive a restart and agree after it: a place whose wait was lost
// is still started when its turn comes, and a wait whose place was lost ends, the agent
// started again and told why (#2361). The Linux agentsd is this one.
func TestALineOutlivesARestart(t *testing.T) {
	fakeRuntimes(t)
	root := t.TempDir()
	dir := t.TempDir()
	at := time.Now().UTC()
	deadline := wire.DateOf(at.Add(time.Hour))
	holder := leftWorking(t, root, wire.AgentStateFinished, "", func(a *wire.Agent) {
		a.Cwd = store.FolderURL(dir)
		a.EndedReason = reason(wire.EndedReasonEndTurn)
	})
	placed := leftWorking(t, root, wire.AgentStateFinished, "", func(a *wire.Agent) {
		a.Cwd = store.FolderURL(dir)
		a.EndedReason = reason(wire.EndedReasonEndTurn)
	})
	var orphan wire.UUID
	orphan = leftWorking(t, root, wire.AgentStateFinished, "", func(a *wire.Agent) {
		a.Cwd = store.FolderURL(dir)
		a.EndedReason = reason(wire.EndedReasonEndTurn)
		a.EventWait = &wire.EventWait{ID: store.NewUUID(), Patterns: []wire.EventPattern{linePattern(a.ID, "build").wire()},
			Deadline: &deadline, Since: now()}
	})
	stamp := at.Format("2006-01-02T15:04:05.000Z")
	book := map[string]any{"entries": map[string]any{"build": map[string]any{
		"kind": "named", "displayName": "build", "rules": map[string]any{"holders": 1},
		"leases": []any{map[string]any{"resource": "build", "displayName": "build", "holder": holder,
			"grantedAt": stamp, "expiresAt": at.Add(20 * time.Minute).Format("2006-01-02T15:04:05.000Z"), "warned": false}},
		"line": []any{map[string]any{"agentID": placed, "askedAt": stamp}}}}, "notices": map[string]any{}}
	b, _ := json.Marshal(book)
	os.WriteFile(filepath.Join(root, "leases.json"), b, 0o644)

	d, c := start(t, root)
	defer d.Shutdown()
	waitFor(t, "the wait without its place told", func() bool {
		for _, u := range userMessages(d, orphan) {
			if u == lostPlaceWords("build") {
				return true
			}
		}
		return false
	})
	if w := d.Store.Agent(orphan).EventWait; w == nil || w.Ending == nil || w.Ending.Cancelled == nil {
		t.Fatalf("%+v", w)
	}
	c.call(t, 1, "resources/end", map[string]any{"name": "build"})
	waitFor(t, "the place without its wait started", func() bool {
		for _, u := range userMessages(d, placed) {
			if strings.HasPrefix(u, "The event you were waiting for happened.\n\nlease.granted at ") {
				return true
			}
		}
		return false
	})
	waitFor(t, "its turn over", func() bool { return d.Store.Agent(placed).State == wire.AgentStateFinished })
	waitFor(t, "the other's turn over", func() bool { return d.Store.Agent(orphan).State == wire.AgentStateFinished })
}

func TestOrdinals(t *testing.T) {
	for n, want := range map[int]string{1: "1st", 2: "2nd", 3: "3rd", 4: "4th", 11: "11th", 12: "12th", 13: "13th", 21: "21st", 112: "112th"} {
		if ordinal(n) != want {
			t.Errorf("%d: %s", n, ordinal(n))
		}
	}
}
