package agentsd

import (
	"time"

	"github.com/alexec/agents/Go/wire"
)

// A session's turn as its Live Activity says it (#1744): the control plane hears each move
// (attention/turn) and updates the activity on a device by APNs, while the Remote is not
// running. The phase and when it ended, never the words.

// turnWindow is how far back a session's last change can be and still have a Live
// Activity to update: one lives at most twelve hours.
const turnWindow = 12 * time.Hour

// pausingReasons are TurnActivityContent.pausingReasons: the endings the sidebars show as
// Paused.
var pausingReasons = map[wire.EndedReason]bool{
	wire.EndedReasonCancelled:      true,
	wire.EndedReasonStoppedByAgent: true,
	wire.EndedReasonStoppedByAdmin: true,
	wire.EndedReasonAllowanceSpent: true,
}

// turnPhase is TurnActivityContent.make's phase (AgentsKitCore/Widget): what waits on the
// person first, the newest of it, then the session's state.
func turnPhase(a wire.Agent, needs []wire.Need) wire.AttentionTurn {
	turn := wire.AttentionTurn{AgentID: a.ID}
	var newest *wire.Need
	for i, n := range needs {
		if n.AgentID != nil && *n.AgentID == a.ID && n.Kind != wire.NeedKindReport &&
			(newest == nil || n.RaisedAt > newest.RaisedAt) {
			newest = &needs[i]
		}
	}
	switch {
	case a.State == wire.AgentStateArchived:
		turn.Phase = wire.TurnPhaseGone
	case newest != nil && newest.Kind == wire.NeedKindElicitation:
		turn.Phase = wire.TurnPhaseQuestion
	case newest != nil:
		turn.Phase = wire.TurnPhaseApproval
	case a.State == wire.AgentStateWaitingOnUser:
		turn.Phase = wire.TurnPhaseQuestion
	case a.State == wire.AgentStateFinished || a.State == wire.AgentStateStopped:
		turn.Phase = wire.TurnPhaseDone
		// Any ending but a clean end of turn says why (EndedReason.summary): Paused for the
		// sidebars' three (a stop someone chose, a spent allowance), else a failure (#1869).
		if a.EndedReason != nil && *a.EndedReason != wire.EndedReasonEndTurn || a.State == wire.AgentStateStopped {
			turn.Phase = wire.TurnPhaseFailed
			if a.EndedReason != nil && pausingReasons[*a.EndedReason] {
				turn.Phase = wire.TurnPhasePaused
			}
		} else if Group(&a) == "needsAttention" {
			// A clean end that still wants the person, as the sidebars say (#1861).
			turn.Phase = wire.TurnPhaseNeedsYou
		}
		ended := a.LastActivityAt
		turn.EndedAt = &ended
	default:
		turn.Phase = wire.TurnPhaseWorking
	}
	return turn
}

// turnsMoved is each recent session whose phase moved since the control plane was last
// told, and gone for one that was told and is no longer here. Called with attentionMu held.
func (d *Daemon) turnsMoved(needs []wire.Need, at time.Time) []wire.AttentionTurn {
	if d.toldTurns == nil {
		d.toldTurns = map[wire.UUID]wire.TurnPhase{}
	}
	since := wire.DateOf(at.Add(-turnWindow))
	var moved []wire.AttentionTurn
	here := map[wire.UUID]bool{}
	for _, a := range d.Store.Agents() {
		here[a.ID] = true
		if a.LastActivityAt < since {
			delete(d.toldTurns, a.ID)
			continue
		}
		turn := turnPhase(a, needs)
		if told, ok := d.toldTurns[a.ID]; ok && told == turn.Phase {
			continue
		}
		d.toldTurns[a.ID] = turn.Phase
		moved = append(moved, turn)
	}
	for id := range d.toldTurns {
		if !here[id] {
			delete(d.toldTurns, id)
			moved = append(moved, wire.AttentionTurn{AgentID: id, Phase: wire.TurnPhaseGone})
		}
	}
	return moved
}
