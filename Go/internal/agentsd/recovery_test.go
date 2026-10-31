package agentsd

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// Ports DaemonTests' restart cases: an agent found working is said to have stopped and is
// picked back up in its own conversation; one cut off three times is left; one copied in
// from another set-up is never run; a conversation the runtime lost goes on in a new one.

func leftWorking(t *testing.T, root string, state wire.AgentState, session string, edit func(a *wire.Agent)) wire.UUID {
	t.Helper()
	s, err := store.Open(root)
	if err != nil {
		t.Fatal(err)
	}
	a := wire.Agent{ID: store.NewUUID(), RuntimeID: "claude", Cwd: store.FolderURL(t.TempDir()), State: state,
		AdvertisedOptions: []wire.ConfigOption{}, AvailableCommands: []wire.SlashCommand{}, MadeInRoot: &s.RootID,
		StartOptions: wire.StartOptions{Values: map[string]wire.JSONValue{}, ExtraArguments: []string{}}, CreatedAt: now(), LastActivityAt: now()}
	if session != "" {
		a.RuntimeSessionID = &session
	}
	if edit != nil {
		edit(&a)
	}
	if err := s.Save(a); err != nil {
		t.Fatal(err)
	}
	return a.ID
}

func notes(d *Daemon, id wire.UUID) []string {
	entries, _, _ := d.Store.Transcript(id, 0)
	var out []string
	for _, e := range entries {
		if e.Kind.RuntimeNote != nil {
			out = append(out, e.Kind.RuntimeNote.Value)
		}
	}
	return out
}

func TestAnAgentFoundWorkingIsPickedBackUpAndToldWhy(t *testing.T) {
	fakeRuntimes(t)
	root := t.TempDir()
	id := leftWorking(t, root, wire.AgentStateWaitingOnUser, "fake-session", nil)
	d, c := start(t, root)
	defer d.Shutdown()
	a := d.Store.Agent(id)
	if a.State != wire.AgentStateStopped || *a.EndedReason != wire.EndedReasonDaemonGone {
		t.Fatalf("%s", a.State)
	}
	d.PickUpAfterRestart()
	c.until(t, "resuming", func(method string, _ json.RawMessage) bool { return method == "agent/resuming" })
	waitFor(t, "finished", func() bool { return d.Store.Agent(id).State == wire.AgentStateFinished })
	got := strings.Join(notes(d, id), " | ")
	want := questionWentUnanswered + " | This agent was working when the daemon stopped, so it stopped too. | Starting Claude… | Picked the conversation back up."
	if got != want {
		t.Fatalf("notes\n got %s\nwant %s", got, want)
	}
	if m := userMessages(d, id); len(m) != 1 || !strings.HasPrefix(m[0], "(The app restarted while you were waiting for an answer") {
		t.Fatalf("%q", m)
	}
	if a := d.Store.Agent(id); a.RestartPickUps != nil || *a.RuntimeSessionID != "fake-session" {
		t.Fatalf("%+v %v", a.RestartPickUps, *a.RuntimeSessionID)
	}
	waitFor(t, "it left the queue of agents coming back", func() bool { return len(d.resumingNow()) == 0 })
}

// The fresh process a reconnect relaunches hands back its own mode first (here,
// "default"); the daemon re-pushes the agent's saved mode ("plan") right after, and the
// mode pill must show that, not the runtime's own default (#3082).
func TestAReconnectKeepsTheSavedModeNotTheRuntimesOwn(t *testing.T) {
	fakeRuntimes(t)
	root := t.TempDir()
	dir := filepath.Join(t.TempDir(), "reconnecting")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	mode, _ := json.Marshal("plan")
	id := leftWorking(t, root, wire.AgentStateWaitingOnUser, "fake-session", func(a *wire.Agent) {
		a.Cwd = store.FolderURL(dir)
		a.StartOptions.Values["mode"] = mode
	})
	d, _ := start(t, root)
	defer d.Shutdown()
	d.PickUpAfterRestart()
	waitFor(t, "finished", func() bool { return d.Store.Agent(id).State == wire.AgentStateFinished })
	a := d.Store.Agent(id)
	if o := modeOption(a.AdvertisedOptions); o == nil || string(o.CurrentValue) != `"plan"` {
		t.Fatalf("mode after reconnect: %+v", o)
	}
}

func TestAConversationTheRuntimeLostGoesOnInANewOne(t *testing.T) {
	fakeRuntimes(t)
	root := t.TempDir()
	id := leftWorking(t, root, wire.AgentStateRunning, "gone-session", nil)
	d, _ := start(t, root)
	defer d.Shutdown()
	d.PickUpAfterRestart()
	waitFor(t, "finished", func() bool { return d.Store.Agent(id).State == wire.AgentStateFinished })
	if n := strings.Join(notes(d, id), " | "); !strings.Contains(n, "Claude no longer has this conversation. Carrying on in a new one; everything above is kept.") {
		t.Fatal(n)
	}
	if a := d.Store.Agent(id); *a.RuntimeSessionID != "fake-session" {
		t.Fatal(*a.RuntimeSessionID)
	}
}

func TestOneCutOffThreeTimesAndOneCopiedInAreLeft(t *testing.T) {
	root := t.TempDir()
	three := int64(3)
	looping := leftWorking(t, root, wire.AgentStateRunning, "fake-session", func(a *wire.Agent) { a.RestartPickUps = &three })
	other := "another-root"
	copied := leftWorking(t, root, wire.AgentStateRunning, "fake-session", func(a *wire.Agent) { a.MadeInRoot = &other })
	d, _ := start(t, root)
	defer d.Shutdown()
	if n := notes(d, looping); len(n) != 2 || !strings.HasPrefix(n[1], "Not picked back up: the app stopped 3 times in a row") {
		t.Fatalf("%q", n)
	}
	if a := d.Store.Agent(copied); a.State != wire.AgentStateStopped || *a.EndedReason != wire.EndedReasonImported {
		t.Fatalf("%s %v", a.State, a.EndedReason)
	}
	d.resumeMu.Lock()
	n := len(d.interrupted)
	d.resumeMu.Unlock()
	if n != 0 {
		t.Fatalf("%d to pick up", n)
	}
}

// A clean stop (an update) cuts a working agent off: the next start picks it up, as after a
// crash, and the stop is not said to be somebody's (#1605).
func TestAnAgentACleanStopCutOffIsPickedBackUp(t *testing.T) {
	fakeRuntimes(t)
	root := t.TempDir()
	first, c := start(t, root)
	var id wire.UUID
	json.Unmarshal(c.call(t, 1, "agents/start", map[string]any{"runtimeID": "claude", "cwd": "file://" + t.TempDir(),
		"prompt": "wait for me"}), &id)
	c.until(t, "running", ended(id, wire.AgentStateRunning))
	first.Shutdown()
	if a := first.Store.Agent(id); a.State != wire.AgentStateStopped || a.EndedReason == nil || *a.EndedReason != wire.EndedReasonDaemonGone {
		t.Fatalf("%s %v %q", a.State, endedAs(a.EndedReason), notices(first, id))
	}

	d, _ := start(t, root)
	defer d.Shutdown()
	d.PickUpAfterRestart()
	waitFor(t, "finished", func() bool { return d.Store.Agent(id).State == wire.AgentStateFinished })
	if n := strings.Join(notes(d, id), " | "); !strings.Contains(n, "This agent was working when the daemon stopped, so it stopped too.") {
		t.Fatal(n)
	}
	if m := userMessages(d, id); len(m) != 2 || !strings.HasPrefix(m[1], "(The app restarted while you were working") {
		t.Fatalf("%q", m)
	}
	entries, _, _ := d.Store.Transcript(id, 0)
	gone := 0
	for _, e := range entries {
		if c := e.Kind.StateChanged; c != nil && c.Reason != nil && *c.Reason == wire.EndedReasonDaemonGone {
			gone++
		}
	}
	if gone != 1 {
		t.Fatalf("stopped with the daemon %d times, want once", gone)
	}
}

// A SIGTERM ends the daemon's context, and so every turn, before main calls Shutdown
// (#1822): the turn is still the daemon's going, alive.json lists it, and the next start
// picks it back up.
func TestAnAgentASignalCutOffIsPickedBackUp(t *testing.T) {
	fakeRuntimes(t)
	root := t.TempDir()
	ctx, signal := context.WithCancel(context.Background())
	first, c := startWith(t, ctx, root)
	var id wire.UUID
	json.Unmarshal(c.call(t, 1, "agents/start", map[string]any{"runtimeID": "claude", "cwd": "file://" + t.TempDir(),
		"prompt": "wait for me"}), &id)
	c.until(t, "running", ended(id, wire.AgentStateRunning))
	signal()
	// The turn ends on the signal, before Shutdown, as in main.
	waitFor(t, "stopped", func() bool { return first.Store.Agent(id).State == wire.AgentStateStopped })
	first.Shutdown()
	if a := first.Store.Agent(id); a.EndedReason == nil || *a.EndedReason != wire.EndedReasonDaemonGone {
		t.Fatalf("%s %v %q", a.State, endedAs(a.EndedReason), notices(first, id))
	}
	if alive := first.readAlive(); alive == nil || alive.CutOff[id] != wire.AgentStateRunning {
		t.Fatalf("alive.json: %+v", alive)
	}

	d, _ := start(t, root)
	defer d.Shutdown()
	d.PickUpAfterRestart()
	waitFor(t, "finished", func() bool { return d.Store.Agent(id).State == wire.AgentStateFinished })
	if m := userMessages(d, id); len(m) != 2 || !strings.HasPrefix(m[1], "(The app restarted while you were working") {
		t.Fatalf("%q", m)
	}
}

// endedAs is an ending reason for a failure's message, or "none".
func endedAs(r *wire.EndedReason) string {
	if r == nil {
		return "none"
	}
	return string(*r)
}

// notices is the titles of the notices in an agent's record.
func notices(d *Daemon, id wire.UUID) []string {
	entries, _, _ := d.Store.Transcript(id, 0)
	var out []string
	for _, e := range entries {
		if n := e.Kind.Notice; n != nil {
			out = append(out, n.Value.Title)
		}
	}
	return out
}
