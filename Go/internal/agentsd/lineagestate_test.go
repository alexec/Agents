package agentsd

import (
	"slices"
	"testing"
	"time"

	"github.com/agentloops-dev/agents/Go/wire"
)

// statesOf is a session's lineage states, oldest first.
func statesOf(d *Daemon, id wire.UUID) []wire.LineageSessionStateName {
	d.lineageSettle(5 * time.Second)
	var out []wire.LineageSessionStateName
	for _, s := range d.lineage().Links(sessionNode(id)).States {
		out = append(out, s.State)
	}
	slices.Reverse(out)
	return out
}

// #4274: each agent state, and the waits the host keeps, read as a lineage state.
func TestSessionStateOfAnAgent(t *testing.T) {
	open := &wire.WorkReport{Outcome: wire.WorkOutcomeWaiting, Block: &wire.Block{Waits: []wire.Wait{}}}
	cleared := wire.DateOf(time.Now())
	for _, c := range []struct {
		a    wire.Agent
		want wire.LineageSessionStateName
	}{
		{wire.Agent{State: wire.AgentStateStarting}, wire.LineageSessionStateNameWorking},
		{wire.Agent{State: wire.AgentStateRunning, EventWait: &wire.EventWait{}}, wire.LineageSessionStateNameWorking},
		{wire.Agent{State: wire.AgentStateWaitingOnUser}, wire.LineageSessionStateNameNeedsYou},
		{wire.Agent{State: wire.AgentStateQueued}, wire.LineageSessionStateNameWaiting},
		{wire.Agent{State: wire.AgentStateFinished, EventWait: &wire.EventWait{}}, wire.LineageSessionStateNameWaiting},
		{wire.Agent{State: wire.AgentStateFinished, Report: open}, wire.LineageSessionStateNameWaiting},
		{wire.Agent{State: wire.AgentStateFinished, Report: &wire.WorkReport{Outcome: wire.WorkOutcomeWaiting,
			Block: &wire.Block{Waits: []wire.Wait{}, ClearedAt: &cleared}}}, wire.LineageSessionStateNameStopped},
		{wire.Agent{State: wire.AgentStateFinished}, wire.LineageSessionStateNameStopped},
		{wire.Agent{State: wire.AgentStateStopped}, wire.LineageSessionStateNameStopped},
		{wire.Agent{State: wire.AgentStateArchived, EventWait: &wire.EventWait{}}, wire.LineageSessionStateNameArchived},
	} {
		if got := sessionState(&c.a); got != c.want {
			t.Errorf("%s (wait %v, report %v): %s, want %s", c.a.State, c.a.EventWait != nil, c.a.Report != nil, got, c.want)
		}
	}
}

// #4274: a session's changes of state are recorded as its record changes, once each, and a
// delete records deleted.
func TestSessionStatesRecorded(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	a := seeded(t, d, t.TempDir(), nil)
	d.noteLineage(nil, a)
	d.change(a.ID, func(a *wire.Agent) { a.State = wire.AgentStateRunning })
	d.change(a.ID, func(a *wire.Agent) { a.Title = new("a title") }) // no change of state
	d.change(a.ID, func(a *wire.Agent) { a.State = wire.AgentStateWaitingOnUser })
	d.change(a.ID, func(a *wire.Agent) { a.State = wire.AgentStateRunning })
	d.change(a.ID, func(a *wire.Agent) { a.State, a.EventWait = wire.AgentStateFinished, &wire.EventWait{} })
	d.change(a.ID, func(a *wire.Agent) { a.EventWait = nil })
	if err := d.archive(a.ID); err != nil {
		t.Fatal(err)
	}
	if err := d.delete(a.ID); err != nil {
		t.Fatal(err)
	}
	want := []wire.LineageSessionStateName{"stopped", "working", "needs-you", "working", "waiting", "stopped", "archived", "deleted"}
	if got := statesOf(d, a.ID); !slices.Equal(got, want) {
		t.Fatalf("states %v, want %v", got, want)
	}

	writer := seeded(t, d, t.TempDir(), func(a *wire.Agent) { a.Purpose = &wire.AgentPurpose{} })
	d.noteLineage(nil, writer)
	if got := statesOf(d, writer.ID); got != nil {
		t.Fatalf("a writer agent has states: %v", got)
	}
}
