package agentsd

import (
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// A wait only the connected person can settle (#3051) shows as needing them, as a
// question does, where an ordinary wait on events only shows as Waiting.
func TestAWaitForThePersonNeedsAttention(t *testing.T) {
	id := wire.UUID("A0000000-0000-4000-8000-000000000001")
	yes := true
	personWait := &wire.EventWait{ID: wire.UUID("B0000000-0000-4000-8000-000000000001"),
		Patterns: []wire.EventPattern{{Name: "review.requested"}}, ForPerson: &yes}
	otherWait := &wire.EventWait{ID: wire.UUID("B0000000-0000-4000-8000-000000000002"),
		Patterns: []wire.EventPattern{{Name: "pr.merged"}}}
	for _, c := range []struct {
		name  string
		agent wire.Agent
		want  string
	}{
		{"finished, waiting for the person", wire.Agent{ID: id, State: wire.AgentStateFinished, EndedReason: reason(wire.EndedReasonEndTurn), EventWait: personWait}, "needsAttention"},
		{"finished, waiting on an ordinary event", wire.Agent{ID: id, State: wire.AgentStateFinished, EndedReason: reason(wire.EndedReasonEndTurn), EventWait: otherWait}, "waiting"},
		{"finished, a wait for the person already ended", wire.Agent{ID: id, State: wire.AgentStateFinished, EndedReason: reason(wire.EndedReasonEndTurn),
			EventWait: &wire.EventWait{ID: personWait.ID, Patterns: personWait.Patterns, ForPerson: &yes, Ending: &wire.EventWaitEnding{TimedOut: &struct{}{}}}}, "finished"},
	} {
		if got := Group(&c.agent); got != c.want {
			t.Errorf("%s: Group() = %s, want %s", c.name, got, c.want)
		}
	}
}

func TestIsForPersonEvent(t *testing.T) {
	for _, c := range []struct {
		name string
		want bool
	}{
		{"review.requested", true},
		{"issue.assigned", true},
		{"pr.merged", false},
		{"issue.commented", false},
	} {
		if got := isForPersonEvent(c.name); got != c.want {
			t.Errorf("isForPersonEvent(%q) = %v, want %v", c.name, got, c.want)
		}
	}
}
