package agentsd

import (
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// The goal on a session_info_update (#2742): Codex's snapshot and Claude's, a cleared
// goal, and the shapes that say nothing, which leave the goal as it was.
func TestTheGoalOnASessionInfoUpdate(t *testing.T) {
	air := func(goal any) map[string]any {
		return map[string]any{"jetbrains": map[string]any{"air": map[string]any{"version": 1.0, "goal": goal}}}
	}
	at := now()

	codex, said := goalIn(air(map[string]any{"objective": " Ship the change ", "status": "limited", "tokenBudget": 1000.0,
		"tokensUsed": 42.0, "timeUsedSeconds": 12.5, "createdAt": 1.71e12, "controlMethod": "_session/goal"}), at)
	if !said || codex == nil || codex.Objective != "Ship the change" || codex.Status != wire.GoalStatusLimited ||
		*codex.TokenBudget != 1000 || *codex.TokensUsed != 42 || *codex.TimeUsedSeconds != 12.5 || codex.At != at {
		t.Fatal(codex)
	}

	claude, said := goalIn(air(map[string]any{"objective": "Tests pass", "status": "active", "iterations": 3.0,
		"lastReason": "Tests still need work", "createdAt": 1.71e12}), at)
	if !said || claude == nil || *claude.Iterations != 3 || *claude.Reason != "Tests still need work" || claude.TokenBudget != nil {
		t.Fatal(claude)
	}

	if g, said := goalIn(air(nil), at); !said || g != nil {
		t.Fatal("goal: null clears the goal", g, said)
	}
	for name, meta := range map[string]map[string]any{
		"no meta":        nil,
		"no goal key":    {"jetbrains": map[string]any{"air": map[string]any{"version": 1.0}}},
		"unknown status": air(map[string]any{"objective": "x", "status": "dreaming"}),
		"no objective":   air(map[string]any{"objective": "  ", "status": "active"}),
		"not an object":  air("x"),
	} {
		if g, said := goalIn(meta, at); said || g != nil {
			t.Fatal(name, g)
		}
	}
	// A budget of nothing is no budget.
	if g, _ := goalIn(air(map[string]any{"objective": "x", "status": "active", "tokenBudget": 0.0}), at); g.TokenBudget != nil {
		t.Fatal(g)
	}
}
