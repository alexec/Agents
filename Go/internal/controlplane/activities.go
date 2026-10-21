package controlplane

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/apns"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/wire"
)

// Live Activities by push (#1744). A device that shows a turn as a Live Activity gives the
// activity's push token (clients/setActivityToken); its host says when the turn moves
// (attention/turn); this copy, the one that heard the host, sends the activity its new
// state through APNs, so the Lock Screen keeps up while the Remote is not running.
//
// A Live Activity's state is not sealed: no extension opens it, and Apple reads it. So it
// carries the phase and the times, never the session's title or a line
// (public-security.md §5); the activity keeps the title it was started with.

// turnActivityState is TurnActivityContent (AgentsKitCore/Widget) as a push writes it:
// no title and no line.
type turnActivityState struct {
	Phase     string     `json:"phase"`
	StartedAt wire.Date  `json:"startedAt"`
	EndedAt   *wire.Date `json:"endedAt,omitempty"`
}

// keptAfterEnd is how long an ended activity stays on the Lock Screen: as the Remote's own.
const keptAfterEnd = 15 * time.Minute

// turnMoved sends the turn's phase to every Live Activity that shows its session. An end
// ends the activity, and its token is forgotten.
func (s *Service) turnMoved(turn wire.AttentionTurn) {
	agent := strings.ToUpper(string(turn.AgentID))
	for _, c := range s.records.Clients() {
		for _, t := range c.ActivityTokens {
			if t.Agent != agent {
				continue
			}
			if s.pushes == nil {
				s.log("live activity: no APNs key, so no update for " + agent)
				return
			}
			push := activityPush(turn, t, time.Now())
			s.pushes.queueActivity(push, c.ID)
			if push.Activity.End {
				s.forgetActivityToken(c.ID, t.Token)
			}
		}
	}
}

// activityPush is the turn's phase as one activity's push.
func activityPush(turn wire.AttentionTurn, t records.ActivityToken, now time.Time) apns.Push {
	state := turnActivityState{Phase: string(turn.Phase), StartedAt: t.StartedAt}
	a := apns.Activity{Timestamp: now, Urgent: turn.Phase != wire.TurnPhaseWorking}
	switch turn.Phase {
	case wire.TurnPhaseDone, wire.TurnPhaseNeedsYou, wire.TurnPhaseFailed, wire.TurnPhaseGone:
		ended := wire.DateOf(now)
		if turn.EndedAt != nil {
			ended = *turn.EndedAt
		}
		ended = max(ended, t.StartedAt)
		state.EndedAt = &ended
		a.End, a.Dismiss = true, now.Add(keptAfterEnd)
		if turn.Phase == wire.TurnPhaseGone {
			// Archived or deleted: it goes at once, as the Remote's own does.
			state.Phase, a.Dismiss = string(wire.TurnPhaseDone), now
		}
	case wire.TurnPhaseWorking, wire.TurnPhaseQuestion, wire.TurnPhaseApproval:
	default:
		// A phase this build does not know: working, which the stale line covers.
		state.Phase = string(wire.TurnPhaseWorking)
	}
	a.State, _ = json.Marshal(state)
	return apns.Push{Token: t.Token, Environment: wire.PushEnvironment(t.Environment), Activity: &a}
}

// forgetActivityToken takes a Live Activity's token off a device's record: its activity
// ended, or Apple says it is gone.
func (s *Service) forgetActivityToken(client, token string) {
	has := func(c *records.ClientRecord) bool {
		for _, t := range c.ActivityTokens {
			if t.Token == token {
				return true
			}
		}
		return false
	}
	if c := s.records.Client(client); c == nil || !has(c) {
		return
	}
	err := s.records.ChangeClient(context.Background(), client, func(c *records.ClientRecord) bool {
		if !has(c) {
			return false
		}
		var kept []records.ActivityToken
		for _, t := range c.ActivityTokens {
			if t.Token != token {
				kept = append(kept, t)
			}
		}
		c.ActivityTokens = kept
		return true
	})
	if err != nil {
		s.log(fmt.Sprintf("live activity: could not forget a token of %s: %v", client, err))
	}
}
