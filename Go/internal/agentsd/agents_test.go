package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/diskjson"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// Ports what DaemonCore's tests hold of the rest of a chat's life: the queue (QueueTests),
// rename (RenameTests), labels (SessionLabelTests), unarchive and delete (DeletionTests),
// options, touched paths and the continue successor.

// seeded is a finished agent in cwd, saved, with edit applied first.
func seeded(t *testing.T, d *Daemon, cwd string, edit func(a *wire.Agent)) wire.Agent {
	t.Helper()
	a := wire.Agent{ID: store.NewUUID(), RuntimeID: "claude", Cwd: store.FolderURL(cwd), State: wire.AgentStateFinished,
		EndedReason: reason(wire.EndedReasonEndTurn), AdvertisedOptions: []wire.ConfigOption{}, AvailableCommands: []wire.SlashCommand{},
		StartOptions: wire.StartOptions{Values: map[string]wire.JSONValue{}, ExtraArguments: []string{}}, CreatedAt: now(), LastActivityAt: now()}
	if edit != nil {
		edit(&a)
	}
	if err := d.Store.Save(a); err != nil {
		t.Fatal(err)
	}
	return a
}

func userMessages(d *Daemon, id wire.UUID) []string {
	entries, _, _ := d.Store.Transcript(id, 0)
	var out []string
	for _, e := range entries {
		if e.Kind.UserMessage != nil {
			out = append(out, e.Kind.UserMessage.Value)
		}
	}
	return out
}

func startAgent(t *testing.T, c *conn, n int, cwd, prompt string) wire.UUID {
	t.Helper()
	var id wire.UUID
	json.Unmarshal(c.call(t, n, "agents/start", map[string]any{"runtimeID": "claude", "cwd": "file://" + cwd, "prompt": prompt}), &id)
	return id
}

// The queue is the daemon's: kept in agent.json while a turn runs, left where it is by a
// stop, and the person's prompts go together as the next turn.
func TestTheQueueOutlivesATurnAndGoesTogether(t *testing.T) {
	fakeRuntimes(t)
	root := t.TempDir()
	d, c := start(t, root)
	defer d.Shutdown()
	id := startAgent(t, c, 1, t.TempDir(), "wait for me")
	c.until(t, "running", ended(id, wire.AgentStateRunning))
	c.call(t, 2, "agents/prompt", map[string]any{"agentID": id, "text": "first", "from": "person"})
	c.call(t, 3, "agents/prompt", map[string]any{"agentID": id, "text": "second", "from": "person"})
	c.call(t, 4, "agents/prompt", map[string]any{"agentID": id, "text": "dropped", "from": "person"})
	a := d.Store.Agent(id)
	if len(a.QueuedPrompts) != 3 {
		t.Fatalf("queued %+v", a.QueuedPrompts)
	}
	b, _ := os.ReadFile(filepath.Join(root, "agents", string(id), "agent.json"))
	var onDisk wire.Agent
	if diskjson.Unmarshal(b, &onDisk); len(onDisk.QueuedPrompts) != 3 || onDisk.QueuedPrompts[1].Text != "second" {
		t.Fatalf("on disk %s", b)
	}
	c.call(t, 5, "agents/unqueue", map[string]any{"agentID": id, "promptID": a.QueuedPrompts[2].ID})
	c.call(t, 6, "agents/stop", map[string]any{"agentID": id})
	waitFor(t, "stopped", func() bool { return d.Store.Agent(id).State == wire.AgentStateStopped })
	time.Sleep(200 * time.Millisecond)
	if q := d.Store.Agent(id).QueuedPrompts; len(q) != 2 {
		t.Fatalf("a stop took the queue: %+v", q)
	}
	// The next prompt sends all of it, as one turn.
	c.call(t, 7, "agents/prompt", map[string]any{"agentID": id, "text": "third", "from": "person"})
	waitFor(t, "finished", func() bool { return d.Store.Agent(id).State == wire.AgentStateFinished })
	if got := userMessages(d, id); len(got) != 2 || got[1] != "first\n\nsecond\n\nthird" {
		t.Fatalf("%q", got)
	}
	if q := d.Store.Agent(id).QueuedPrompts; len(q) != 0 {
		t.Fatalf("left %+v", q)
	}
}

// editQueued (#1552): the person's waiting prompt takes new words in its place; one not
// waiting any more, or another agent's, says edited false and is left as it was.
func TestEditQueued(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	id := startAgent(t, c, 1, t.TempDir(), "wait for me")
	c.until(t, "running", ended(id, wire.AgentStateRunning))
	c.call(t, 2, "agents/prompt", map[string]any{"agentID": id, "text": "first", "from": "person"})
	c.call(t, 3, "agents/prompt", map[string]any{"agentID": id, "text": "second", "from": "person"})
	c.call(t, 4, "agents/prompt", map[string]any{"agentID": id, "text": "from a helper", "from": "agent"})
	q := d.Store.Agent(id).QueuedPrompts
	edit := func(n int, promptID wire.UUID, text string) bool {
		var r wire.EditQueuedResult
		json.Unmarshal(c.call(t, n, "agents/editQueued", map[string]any{"agentID": id, "promptID": promptID, "text": text}), &r)
		return r.Edited
	}
	if !edit(5, q[0].ID, "first, changed") {
		t.Fatal("a waiting prompt was not edited")
	}
	if edit(6, q[2].ID, "not mine") {
		t.Fatal("another agent's prompt was edited")
	}
	c.call(t, 7, "agents/unqueue", map[string]any{"agentID": id, "promptID": q[1].ID})
	if edit(8, q[1].ID, "too late") {
		t.Fatal("a prompt taken back was edited")
	}
	got := d.Store.Agent(id).QueuedPrompts
	if len(got) != 2 || got[0].ID != q[0].ID || got[0].Text != "first, changed" || got[1].Text != "from a helper" {
		t.Fatalf("queue %+v", got)
	}
}

// sendNow with no turn running sends it first; mid-turn, a runtime that cannot steer says so.
func TestSendNow(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	id := startAgent(t, c, 1, t.TempDir(), "wait for me")
	c.until(t, "running", ended(id, wire.AgentStateRunning))
	c.call(t, 2, "agents/prompt", map[string]any{"agentID": id, "text": "now please", "from": "person"})
	q := d.Store.Agent(id).QueuedPrompts[0]
	if e := c.callError(t, 3, "agents/sendNow", map[string]any{"agentID": id, "promptID": q.ID}); e.Code != wire.FailureNotSupported {
		t.Fatalf("%+v", e)
	}
	c.call(t, 4, "agents/stop", map[string]any{"agentID": id})
	waitFor(t, "stopped", func() bool { return d.Store.Agent(id).State == wire.AgentStateStopped })
	// The state says stopped a moment before the turn has ended.
	waitFor(t, "its turn over", func() bool {
		l := d.live(id)
		l.mu.Lock()
		defer l.mu.Unlock()
		return !l.inTurn && !l.running
	})
	c.call(t, 5, "agents/sendNow", map[string]any{"agentID": id, "promptID": q.ID})
	waitFor(t, "finished", func() bool { return d.Store.Agent(id).State == wire.AgentStateFinished })
	if got := userMessages(d, id); got[len(got)-1] != "now please" {
		t.Fatalf("%q", got)
	}
	// One that has gone already is nothing.
	c.call(t, 6, "agents/sendNow", map[string]any{"agentID": id, "promptID": q.ID})
}

func TestRenameAndHandBack(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	runtimeTitle := "From the runtime"
	a := seeded(t, d, t.TempDir(), func(a *wire.Agent) { a.Title = &runtimeTitle })
	var got wire.Agent
	json.Unmarshal(c.call(t, 1, "agents/rename", map[string]any{"agentID": a.ID, "title": "  My   name\nhere "}), &got)
	if *got.Title != "My name here" || got.TitleIsPersons == nil || !*got.TitleIsPersons || *got.RuntimeTitle != runtimeTitle {
		t.Fatalf("%+v", got)
	}
	json.Unmarshal(c.call(t, 2, "agents/rename", map[string]any{"agentID": a.ID, "title": strings.Repeat("x", 90)}), &got)
	if len([]rune(*got.Title)) != 80 || *got.RuntimeTitle != runtimeTitle {
		t.Fatalf("%q", *got.Title)
	}
	got = wire.Agent{}
	json.Unmarshal(c.call(t, 3, "agents/rename", map[string]any{"agentID": a.ID, "title": " "}), &got)
	if *got.Title != runtimeTitle || got.TitleIsPersons != nil || got.RuntimeTitle != nil {
		t.Fatalf("handed back %+v", got)
	}
}

func TestLabels(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	folder := t.TempDir()
	mk := func(labels ...string) wire.UUID {
		return seeded(t, d, folder, func(a *wire.Agent) {
			for _, l := range labels {
				a.Labels = append(a.Labels, wire.SessionLabel{Value: l, Owner: wire.SessionLabelOwnerAgent, AddedAt: now()})
			}
		}).ID
	}
	mk("Release")
	id := mk("bug")
	var got wire.Agent
	json.Unmarshal(c.call(t, 1, "agents/setLabels", map[string]any{"agentID": id, "add": []string{"release", " BUG "}, "remove": []string{}}), &got)
	if len(got.Labels) != 2 || got.Labels[0].Owner != wire.SessionLabelOwnerPerson || got.Labels[1].Value != "Release" {
		t.Fatalf("%+v", got.Labels)
	}
	if e := c.callError(t, 2, "agents/setLabels", map[string]any{"agentID": id, "add": []string{"x"}, "remove": []string{"X"}}); e.Message != "The label X cannot be added and removed in the same change." {
		t.Fatal(e.Message)
	}
	if e := c.callError(t, 3, "agents/setLabels", map[string]any{"agentID": id, "add": []string{strings.Repeat("a", 25)}}); e.Message != "A label can be at most 24 characters." {
		t.Fatal(e.Message)
	}
	if e := c.callError(t, 4, "agents/setLabels", map[string]any{"agentID": id, "add": []string{"a", "b", "c", "d"}}); e.Message != "A session can have at most five labels." {
		t.Fatal(e.Message)
	}
	var words []string
	json.Unmarshal(c.call(t, 5, "agents/labelVocabulary", map[string]any{"folder": store.FolderURL(folder)}), &words)
	if strings.Join(words, ",") != "Release,bug" {
		t.Fatal(words)
	}
}

func TestUnarchiveAndDelete(t *testing.T) {
	fakeRuntimes(t)
	root := t.TempDir()
	d, c := start(t, root)
	defer d.Shutdown()
	id := startAgent(t, c, 1, t.TempDir(), "hello")
	waitFor(t, "finished", func() bool { return d.Store.Agent(id).State == wire.AgentStateFinished })
	if e := c.callError(t, 2, "agents/delete", map[string]any{"agentID": id}); e.Code != wire.FailureDeleteRefused {
		t.Fatalf("%+v", e)
	}
	c.call(t, 3, "agents/archive", map[string]any{"agentID": id})
	c.call(t, 4, "agents/unarchive", map[string]any{"agentID": id})
	if a := d.Store.Agent(id); a.State != wire.AgentStateFinished || a.ArchivedAt != nil || a.ArchivedReason != nil {
		t.Fatalf("%+v", a)
	}
	c.call(t, 5, "agents/archive", map[string]any{"agentID": id})
	c.in <- `{"jsonrpc":"2.0","id":6,"method":"agents/delete","params":{"agentID":"` + string(id) + `"}}`
	c.until(t, "agent/removed", func(method string, p json.RawMessage) bool {
		return method == "agent/removed" && strings.Contains(string(p), string(id))
	})
	if d.Store.Agent(id) != nil {
		t.Fatal("still listed")
	}
	if _, err := os.Stat(filepath.Join(root, "agents", string(id))); !os.IsNotExist(err) {
		t.Fatalf("folder left: %v", err)
	}
	// A delete cut off after its folder was set aside is finished at the next start.
	aside := filepath.Join(root, "agents", ".deleting-"+string(store.NewUUID()))
	os.MkdirAll(aside, 0o755)
	if _, err := store.Open(root); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(aside); !os.IsNotExist(err) {
		t.Fatal("a set-aside folder was left")
	}
}

func TestAnOptionWithNoSessionIsAStartOption(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	a := seeded(t, d, t.TempDir(), nil)
	c.call(t, 1, "agents/setOption", map[string]any{"agentID": a.ID, "optionID": "model", "value": "opus"})
	if v := d.Store.Agent(a.ID).StartOptions.Values["model"]; string(v) != `"opus"` {
		t.Fatalf("%s", v)
	}
	if k := kinds(d, a.ID); len(k) != 1 || k[0] != "optionChanged" {
		t.Fatal(k)
	}
}

func TestTouchedPaths(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := t.TempDir()
	real, _ := filepath.EvalSymlinks(dir)
	id := seeded(t, d, dir, nil).ID
	diff := filepath.Join(dir, "b.go")
	d.Store.Append(id, wire.TranscriptEntry{ID: store.NewUUID(), At: now(), Kind: wire.TranscriptEntryKind{ToolCall: &wire.TranscriptEntryKindToolCall{
		Value: wire.ToolCall{Title: "Edit", Content: []wire.ToolCallContent{{Type: "diff", Path: &diff}},
			Locations: []wire.ToolCallLocation{{Path: filepath.Join(dir, "a.go")}}}}}})
	var paths []string
	json.Unmarshal(c.call(t, 1, "agents/touchedPaths", map[string]any{"agentID": id}), &paths)
	if strings.Join(paths, " ") != filepath.Join(real, "a.go")+" "+filepath.Join(real, "b.go") &&
		strings.Join(paths, " ") != filepath.Join(dir, "a.go")+" "+filepath.Join(dir, "b.go") {
		t.Fatal(paths)
	}
}

// A successor in the folder carries on the work of one whose folder went, and the
// same start sent again is the agent it made.
func TestContinueInFolder(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	folder := t.TempDir()
	title := "Old work"
	old := seeded(t, d, filepath.Join(folder, "gone"), func(a *wire.Agent) {
		a.Title = &title
		a.Labels = []wire.SessionLabel{{Value: "mine", Owner: wire.SessionLabelOwnerPerson, AddedAt: now()},
			{Value: "its", Owner: wire.SessionLabelOwnerAgent, AddedAt: now()}}
		a.Worktree = &wire.AgentWorktree{Folder: store.FolderURL(folder)}
	})
	request := store.NewUUID()
	var id wire.UUID
	json.Unmarshal(c.call(t, 1, "agents/continueInFolder", map[string]any{"agentID": old.ID, "text": "and the tests", "requestID": request}), &id)
	waitFor(t, "finished", func() bool { return d.Store.Agent(id).State == wire.AgentStateFinished })
	a := d.Store.Agent(id)
	if store.FolderPath(a.Cwd) != folder || *a.Title != title || len(a.Labels) != 1 || a.Labels[0].Value != "mine" {
		t.Fatalf("%+v", a)
	}
	said := userMessages(d, id)
	if len(said) != 1 || !strings.HasPrefix(said[0], "Continue the work of the session “Old work” ("+string(old.ID)+").") ||
		!strings.HasSuffix(said[0], "then carry on.\n\nand the tests") {
		t.Fatalf("%q", said)
	}
	var again wire.UUID
	json.Unmarshal(c.call(t, 2, "agents/continueInFolder", map[string]any{"agentID": old.ID, "requestID": request}), &again)
	if again != id {
		t.Fatalf("a second agent %s", again)
	}
}

// TestArchivedListIsNewestArchivedFirst: an archived-only page is in order of when each was
// archived, not of last activity (#2153), and goes on from its cursor in that order.
func TestArchivedListIsNewestArchivedFirst(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	hour := wire.Date(3600)
	archived := func(active, archivedAt wire.Date) func(a *wire.Agent) {
		return func(a *wire.Agent) {
			r := wire.AgentArchivedReasonByUser
			a.State, a.ArchivedReason, a.LastActivityAt = wire.AgentStateArchived, &r, active
			if archivedAt != 0 {
				a.ArchivedAt = &archivedAt
			}
		}
	}
	t0 := now()
	// A was active yesterday and archived now; B active an hour ago and archived yesterday;
	// old has no archivedAt, and goes by its activity two days ago.
	a := seeded(t, d, t.TempDir(), archived(t0-24*hour, t0))
	b := seeded(t, d, t.TempDir(), archived(t0-hour, t0-24*hour))
	old := seeded(t, d, t.TempDir(), archived(t0-48*hour, 0))
	var list []wire.Agent
	json.Unmarshal(c.call(t, 1, "agents/list", map[string]any{"archivedOnly": true, "includeArchived": true, "lean": true}), &list)
	if len(list) != 3 || list[0].ID != a.ID || list[1].ID != b.ID || list[2].ID != old.ID {
		t.Fatalf("not newest archived first: %+v", list)
	}
	list = nil
	after := map[string]any{"lastActivityAt": a.LastActivityAt, "id": a.ID, "archivedAt": *a.ArchivedAt}
	json.Unmarshal(c.call(t, 2, "agents/list", map[string]any{"archivedOnly": true, "includeArchived": true, "lean": true, "after": after}), &list)
	if len(list) != 2 || list[0].ID != b.ID || list[1].ID != old.ID {
		t.Fatalf("the next page: %+v", list)
	}
}
