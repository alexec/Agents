package controlplane

import (
	"context"
	"encoding/json"
	"fmt"
	"slices"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/apns"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/wire"
)

// Live Activities by push (#1744). A device shows the turns sent from it as one Live
// Activity (#2991), and gives the activity's push token once for each session it speaks
// for (clients/setActivityToken); a host says when a session's turn moves (attention/turn);
// this copy, the one that heard the host, keeps the phase on the token and sends the
// activity its new summary through APNs, so the Lock Screen keeps up while the Remote is not
// running.
//
// A Live Activity's state is not sealed: no extension opens it, and Apple reads it. So it
// carries the phase, the session's id, the counts and the times, never a title, a place or
// a line (public-security.md §5).

// turnActivityState is TurnActivityContent (AgentsKitCore/Widget) as a push writes it:
// no title, no place and no line.
type turnActivityState struct {
	Phase         string     `json:"phase"`
	AgentID       string     `json:"agentID,omitempty"`
	StartedAt     wire.Date  `json:"startedAt"`
	EndedAt       *wire.Date `json:"endedAt,omitempty"`
	OthersAsking  int        `json:"othersAsking,omitempty"`
	OthersWorking int        `json:"othersWorking,omitempty"`
}

// keptAfterEnd is how long an ended activity stays on the Lock Screen: as the Remote's own.
const keptAfterEnd = 15 * time.Minute

// turnMoved keeps the turn's phase on each activity token for its session, and sends each
// of those activities its new summary. A session whose turn ended leaves its activity; the
// last one to end ends it, and its tokens are forgotten.
func (s *Service) turnMoved(turn wire.AttentionTurn) {
	agent := strings.ToUpper(string(turn.AgentID))
	for _, c := range s.records.Clients() {
		var tokens []string
		for _, t := range c.ActivityTokens {
			if t.Agent == agent && !slices.Contains(tokens, t.Token) {
				tokens = append(tokens, t.Token)
			}
		}
		if len(tokens) == 0 {
			continue
		}
		if s.pushes == nil {
			s.log("live activity: no APNs key, so no update for " + agent)
			return
		}
		var pushes []apns.Push
		err := s.records.ChangeClient(context.Background(), c.ID, func(c *records.ClientRecord) bool {
			pushes = nil
			list := c.ActivityTokens
			for _, token := range tokens {
				var push *apns.Push
				list, push = activitySummary(list, token, agent, turn, time.Now())
				if push != nil {
					pushes = append(pushes, *push)
				}
			}
			if slices.Equal(list, c.ActivityTokens) {
				return false
			}
			c.ActivityTokens = list
			return true
		})
		if err != nil {
			s.log(fmt.Sprintf("live activity: could not keep a phase for %s: %v", c.ID, err))
		}
		for _, push := range pushes {
			s.pushes.queueActivity(push, c.ID)
		}
	}
}

// turnIsOver says whether a phase ends a session's turn.
func turnIsOver(phase wire.TurnPhase) bool {
	switch phase {
	case wire.TurnPhaseDone, wire.TurnPhaseNeedsYou, wire.TurnPhasePaused, wire.TurnPhaseFailed, wire.TurnPhaseGone:
		return true
	}
	return false
}

// turnAsks says whether a phase waits on the person.
func turnAsks(phase wire.TurnPhase) bool {
	return phase == wire.TurnPhaseQuestion || phase == wire.TurnPhaseApproval
}

// activitySummary is the list with the session's phase kept on the activity's token, and
// the push that says the activity's new summary, as TurnActivityContent.summary in the
// Remote picks it: the session that asks, else the newest working one, a count of the
// others still running, and the timer from the oldest. A session that ended leaves; when
// none runs, the push ends the activity with this turn's end, and the token goes. Nil when
// the token is not this session's.
func activitySummary(list []records.ActivityToken, token, agent string, turn wire.AttentionTurn,
	now time.Time) ([]records.ActivityToken, *apns.Push) {
	phase := turn.Phase
	if !turnIsOver(phase) && !turnAsks(phase) && phase != wire.TurnPhaseWorking {
		// A phase this build does not know: working, which the stale line covers.
		phase = wire.TurnPhaseWorking
	}
	var this *records.ActivityToken
	var running []records.ActivityToken
	var out []records.ActivityToken
	for _, t := range list {
		if t.Token != token {
			out = append(out, t)
			continue
		}
		if t.Agent == agent {
			t.Phase = string(phase)
			this = &t
		}
		if turnIsOver(wire.TurnPhase(t.Phase)) {
			continue
		}
		running = append(running, t)
		out = append(out, t)
	}
	if this == nil {
		return list, nil
	}
	a := apns.Activity{Timestamp: now}
	push := &apns.Push{Token: this.Token, Environment: wire.PushEnvironment(this.Environment), Activity: &a}
	if len(running) == 0 {
		// The last turn ended: the activity ends with it, and every token goes.
		state := turnActivityState{Phase: string(phase), AgentID: agent, StartedAt: this.StartedAt}
		ended := wire.DateOf(now)
		if turn.EndedAt != nil {
			ended = *turn.EndedAt
		}
		ended = max(ended, this.StartedAt)
		state.EndedAt = &ended
		a.End, a.Dismiss, a.Urgent = true, now.Add(keptAfterEnd), true
		if phase == wire.TurnPhaseGone {
			// Archived or deleted: it goes at once, as the Remote's own does.
			state.Phase, a.Dismiss = string(wire.TurnPhaseDone), now
		}
		a.State, _ = json.Marshal(state)
		return out, push
	}
	shown := running[0]
	for _, t := range running[1:] {
		asks, shownAsks := turnAsks(wire.TurnPhase(t.Phase)), turnAsks(wire.TurnPhase(shown.Phase))
		if asks != shownAsks {
			if asks {
				shown = t
			}
			continue
		}
		if t.StartedAt > shown.StartedAt {
			shown = t
		}
	}
	shownPhase := wire.TurnPhase(shown.Phase)
	if shownPhase == "" {
		shownPhase = wire.TurnPhaseWorking
	}
	state := turnActivityState{Phase: string(shownPhase), AgentID: shown.Agent, StartedAt: shown.StartedAt}
	for _, t := range running {
		state.StartedAt = min(state.StartedAt, t.StartedAt)
		switch {
		case t.Agent == shown.Agent:
		case turnAsks(wire.TurnPhase(t.Phase)):
			state.OthersAsking++
		default:
			state.OthersWorking++
		}
	}
	a.Urgent = shownPhase != wire.TurnPhaseWorking
	a.State, _ = json.Marshal(state)
	return out, push
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
