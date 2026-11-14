package agentsd

import (
	"strings"
	"testing"

	"github.com/agentloops-dev/agents/Go/wire"
)

// Start now (#5156): the person starts a queued session past the running limit, never past
// the total, and the rest of the queue keeps its order and waits.
func TestStartNowGoesPastTheRunningLimitButNotTheTotal(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	d.SettingsDir = t.TempDir()
	dir := folder(t, c, 1)
	c.call(t, 2, "policy/setFolder", map[string]any{"folder": "file://" + dir + "/",
		"rules": map[string]any{"helpers": map[string]any{"mostRunning": 1, "mostNotArchived": 2}}})
	title := "Lead"
	level := wire.PermissionLevelApproveForMe
	lead := seeded(t, d, dir, func(a *wire.Agent) { a.Title = &title; a.Levels = &wire.Levels{Permission: &level} })
	m := appClient(t, d, lead.ID)
	m.post("initialize", map[string]any{}, 1)
	text, isErr := m.tool(3, "start_session", map[string]any{"prompt": "wait for me"})
	if isErr || !strings.HasPrefix(text, "Started ") {
		t.Fatal(text)
	}
	first := helperID(text)
	waitFor(t, "the first working", func() bool { return d.Store.Agent(first).State == wire.AgentStateRunning })
	var queued []wire.UUID
	for i, prompt := range []string{"second", "third"} {
		text, isErr = m.tool(4+i, "start_session", map[string]any{"prompt": prompt})
		if isErr || !strings.HasPrefix(text, "Queued ") {
			t.Fatal(text)
		}
		queued = append(queued, helperID(text))
	}
	// The third, past the queue's oldest: running goes to 2 of 1.
	c.call(t, 10, "agents/startNow", map[string]any{"agentID": queued[1]})
	waitFor(t, "the third out of the queue", func() bool { return d.Store.Agent(queued[1]).State != wire.AgentStateQueued })
	if a := d.Store.Agent(queued[1]); a.State == wire.AgentStateStopped {
		t.Fatalf("%+v %q", a.EndedReason, runtimeNotes(d, queued[1]))
	}
	if a := d.Store.Agent(queued[0]); a.State != wire.AgentStateQueued {
		t.Fatalf("the second left the queue too: %s", a.State)
	}
	// Two of two not archived: the second may not go past the total.
	e := c.callError(t, 11, "agents/startNow", map[string]any{"agentID": queued[0]})
	if e == nil || e.Code != wire.FailureNotAllowed || !strings.Contains(e.Message, "2 of 2 sessions not archived") {
		t.Fatalf("%+v", e)
	}
	if a := d.Store.Agent(queued[0]); a.State != wire.AgentStateQueued {
		t.Fatalf("%s", a.State)
	}
}

// An agent's connection cannot start one now: only a person's click goes past the limit.
func TestAnAgentCannotStartNow(t *testing.T) {
	if RoleAgent.Allows("agents/startNow") {
		t.Fatal("the agent role may call agents/startNow")
	}
	if !RoleControl.Allows("agents/startNow") || !RoleDevice.Allows("agents/startNow") {
		t.Fatal("a window or a device may not call agents/startNow")
	}
}
