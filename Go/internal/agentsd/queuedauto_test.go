package agentsd

import (
	"strings"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// A session on Auto that waits in the queue picks its runtime when it leaves the queue, as
// one started at once does (#4380).
func TestAQueuedAutoSessionPicksItsRuntimeWhenItStarts(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	d.SettingsDir = t.TempDir()
	dir := folder(t, c, 1)
	c.call(t, 2, "policy/setFolder", map[string]any{"folder": "file://" + dir + "/", "rules": map[string]any{"helpers": map[string]any{"mostRunning": 1}}})
	title := "Lead"
	level := wire.PermissionLevelApproveForMe
	lead := seeded(t, d, dir, func(a *wire.Agent) { a.Title = &title; a.Levels = &wire.Levels{Permission: &level} })
	m := appClient(t, d, lead.ID)
	m.post("initialize", map[string]any{}, 1)
	text, isErr := m.tool(3, "start_session", map[string]any{"prompt": "wait for me", "runtime": "auto"})
	if isErr || !strings.HasPrefix(text, "Started ") {
		t.Fatal(text)
	}
	first := helperID(text)
	waitFor(t, "the first working", func() bool { return d.Store.Agent(first).State == wire.AgentStateRunning })
	text, isErr = m.tool(4, "start_session", map[string]any{"prompt": "Write it", "runtime": "auto"})
	if isErr || !strings.HasPrefix(text, "Queued ") {
		t.Fatal(text)
	}
	second := helperID(text)
	// The day rolls over (drainHeld) and anything else kicks its turns: it stays queued,
	// with nothing said, where before it stopped with "The runtime reported an error".
	d.drainHeld()
	d.live(second).run()
	if a := d.Store.Agent(second); a.State != wire.AgentStateQueued || len(notices(d, second)) > 0 {
		t.Fatalf("%s %+v %q", a.State, a.EndedReason, notices(d, second))
	}
	if text, _ := m.tool(5, "stop_session", map[string]any{"id": string(first)}); !strings.HasPrefix(text, "Stopped ") {
		t.Fatal(text)
	}
	waitFor(t, "the second out of the queue", func() bool {
		s := d.Store.Agent(second).State
		return s != wire.AgentStateQueued && s != wire.AgentStateStarting
	})
	a := d.Store.Agent(second)
	if a.State == wire.AgentStateStopped || a.Auto == nil || a.RuntimeID == autoRuntimeID {
		t.Fatalf("%s %s %+v %q", a.State, a.RuntimeID, a.EndedReason, runtimeNotes(d, second))
	}
	if u := userMessages(d, second); len(u) != 1 || u[0] != "Write it" {
		t.Fatalf("%q", u)
	}
}

// A session whose runtime is not there says so when it does not start (#4380).
func TestASessionWithNoRuntimeSaysWhyItDidNotStart(t *testing.T) {
	fakeRuntimes(t)
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	a := seeded(t, d, t.TempDir(), func(a *wire.Agent) { a.RuntimeID = autoRuntimeID; a.State = wire.AgentStateFinished })
	if err := d.enqueue(a.ID, wire.QueuedPrompt{ID: "11111111-1111-1111-1111-111111111111", Text: "go", From: wire.PromptOriginPerson}, false); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "it stopped", func() bool { return d.Store.Agent(a.ID).State == wire.AgentStateStopped })
	if n := notices(d, a.ID); len(n) != 1 || n[0] != "It did not start" {
		t.Fatalf("%q", n)
	}
}
