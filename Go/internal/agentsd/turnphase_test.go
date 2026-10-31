package agentsd

import (
	"encoding/json"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// The phase is TurnActivityContent.make's (#1744): what waits on the person first, then
// the state; a clean end is done, or needs you as the sidebars say, any other ending failed.
func TestATurnsPhaseIsWhatItsActivitySays(t *testing.T) {
	id := wire.UUID("A0000000-0000-4000-8000-000000000001")
	agent := func(s wire.AgentState, r *wire.EndedReason) wire.Agent {
		return wire.Agent{ID: id, State: s, EndedReason: r, LastActivityAt: 800000300}
	}
	// A clean end with a report, and one asked how it went that never said (#1861).
	asked := true
	reported := func(o wire.WorkOutcome, b *wire.Block) wire.Agent {
		a := agent(wire.AgentStateFinished, reason(wire.EndedReasonEndTurn))
		a.OutcomeAsked, a.Report = &asked, &wire.WorkReport{Outcome: o, Message: "The rest is yours.", Block: b}
		return a
	}
	unknown := agent(wire.AgentStateFinished, reason(wire.EndedReasonEndTurn))
	unknown.OutcomeAsked = &asked
	elicitation, permission := wire.UUID("E0000000-0000-4000-8000-000000000001"), wire.UUID("E0000000-0000-4000-8000-000000000002")
	asks := []wire.Need{
		{ID: wire.NeedID{Permission: &permission}, AgentID: &id, Kind: wire.NeedKindPermission, RaisedAt: 1},
		{ID: wire.NeedID{Elicitation: &elicitation}, AgentID: &id, Kind: wire.NeedKindElicitation, RaisedAt: 2},
	}
	for _, c := range []struct {
		agent wire.Agent
		needs []wire.Need
		want  wire.TurnPhase
	}{
		{agent(wire.AgentStateRunning, nil), nil, wire.TurnPhaseWorking},
		{agent(wire.AgentStateQueued, nil), nil, wire.TurnPhaseWorking},
		{agent(wire.AgentStateWaitingOnUser, nil), asks, wire.TurnPhaseQuestion},
		{agent(wire.AgentStateWaitingOnUser, nil), asks[:1], wire.TurnPhaseApproval},
		{agent(wire.AgentStateWaitingOnUser, nil), nil, wire.TurnPhaseQuestion},
		{agent(wire.AgentStateFinished, reason(wire.EndedReasonEndTurn)), nil, wire.TurnPhaseDone},
		{agent(wire.AgentStateFinished, reason(wire.EndedReasonProcessDied)), nil, wire.TurnPhaseFailed},
		{reported(wire.WorkOutcomeDone, nil), nil, wire.TurnPhaseDone},
		// Only a question needs the person (#1916): a block with nothing to wait on is done.
		{reported(wire.WorkOutcomeWaiting, &wire.Block{}), nil, wire.TurnPhaseDone},
		{reported(wire.WorkOutcomeNeedsAnswer, nil), nil, wire.TurnPhaseNeedsYou},
		{unknown, nil, wire.TurnPhaseNeedsYou},
		{agent(wire.AgentStateStopped, nil), nil, wire.TurnPhaseFailed},
		{agent(wire.AgentStateStopped, reason(wire.EndedReasonCancelled)), nil, wire.TurnPhasePaused},
		{agent(wire.AgentStateStopped, reason(wire.EndedReasonStoppedByAgent)), nil, wire.TurnPhasePaused},
		{agent(wire.AgentStateStopped, reason(wire.EndedReasonAllowanceSpent)), nil, wire.TurnPhasePaused},
		{agent(wire.AgentStateStopped, reason(wire.EndedReasonRateLimited)), nil, wire.TurnPhaseFailed},
		{agent(wire.AgentStateArchived, nil), asks, wire.TurnPhaseGone},
	} {
		turn := turnPhase(c.agent, c.needs)
		if turn.Phase != c.want {
			t.Errorf("%s with %d needs: %s, not %s", c.agent.State, len(c.needs), turn.Phase, c.want)
		}
		if ended := turn.EndedAt != nil; ended != (c.want == wire.TurnPhaseDone || c.want == wire.TurnPhaseNeedsYou || c.want == wire.TurnPhasePaused ||
			c.want == wire.TurnPhaseFailed) {
			t.Errorf("%s: endedAt %v", c.want, turn.EndedAt)
		}
	}
}

type toldTurns struct {
	mu    sync.Mutex
	turns []wire.AttentionTurn
}

func (c *toldTurns) tell(method string, params any) {
	if method != wire.CallAttentionTurn.Name {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	c.turns = append(c.turns, params.(wire.AttentionTurn))
}

func (c *toldTurns) of(id wire.UUID) []wire.TurnPhase {
	c.mu.Lock()
	defer c.mu.Unlock()
	var out []wire.TurnPhase
	for _, t := range c.turns {
		if t.AgentID == id {
			out = append(out, t.Phase)
		}
	}
	return out
}

// A host tells its control plane each move of a recent turn, once; not one long idle; and
// gone for one deleted.
func TestAHostTellsItsControlPlaneEachMoveOfATurn(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	recent := seeded(t, d, t.TempDir(), nil)
	old := seeded(t, d, t.TempDir(), func(a *wire.Agent) { a.LastActivityAt = wire.DateOf(time.Now().Add(-13 * time.Hour)) })
	control := &toldTurns{}
	d.SetControl(control.tell)
	waitFor(t, "the recent turn told", func() bool { return len(control.of(recent.ID)) == 1 })
	if got := control.of(recent.ID); got[0] != wire.TurnPhaseDone {
		t.Fatal(got)
	}
	d.setState(recent.ID, wire.AgentStateRunning)
	waitFor(t, "working told", func() bool { return len(control.of(recent.ID)) == 2 })
	d.reconsider()
	if got := control.of(recent.ID); len(got) != 2 || got[1] != wire.TurnPhaseWorking {
		t.Fatal(got)
	}
	if got := control.of(old.ID); len(got) != 0 {
		t.Fatal("an old turn told:", got)
	}
	if err := d.Store.Delete(recent.ID); err != nil {
		t.Fatal(err)
	}
	d.reconsider()
	if got := control.of(recent.ID); len(got) != 3 || got[2] != wire.TurnPhaseGone {
		t.Fatal(got)
	}
}

// #1916: an old record's stuck or partly_done (finish_turn's) reads as done, so it shows as
// Complete, not Needs you. #2981: so does an old blocked, through the x-fallback.
func TestAnOldStuckOrPartlyDoneReadsAsDone(t *testing.T) {
	for _, old := range []string{"stuck", "partly_done", "blocked"} {
		var a wire.Agent
		b := []byte(`{"id":"A","runtimeID":"claude","cwd":"file:///w/","state":"finished","report":{"outcome":"` + old + `","message":"m","at":1}}`)
		if err := json.Unmarshal(b, &a); err != nil {
			t.Fatal(err)
		}
		if a.Report == nil || a.Report.Outcome != wire.WorkOutcomeDone || Group(&a) == "needsAttention" {
			t.Fatalf("%s: %+v", old, a.Report)
		}
	}
}
