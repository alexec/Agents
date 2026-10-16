package agentsd

import (
	"encoding/json"
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
