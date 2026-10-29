package agentsd

import (
	"strings"

	"github.com/alexec/agents/Go/wire"
)

// goalIn is the session's goal in a session_info_update's _meta (#2742): JetBrains' AIR
// extension, which Codex's and Claude's adapters send to a client that declares AIR, as
// this host does for typed failures. said is true and goal nil when it cleared the goal
// (`goal: null`); said is false when the update says nothing of one, or a shape not
// understood, which leaves the goal as it was.
func goalIn(meta map[string]any, at wire.Date) (goal *wire.Goal, said bool) {
	jb, _ := meta["jetbrains"].(map[string]any)
	air, _ := jb["air"].(map[string]any)
	v, said := air["goal"]
	if !said {
		return nil, false
	}
	if v == nil {
		return nil, true
	}
	m, _ := v.(map[string]any)
	objective := strings.TrimSpace(goalText(m, "objective"))
	status := wire.GoalStatus(goalText(m, "status"))
	switch status {
	case wire.GoalStatusActive, wire.GoalStatusPaused, wire.GoalStatusBlocked, wire.GoalStatusLimited, wire.GoalStatusComplete:
	default:
		return nil, false
	}
	if objective == "" {
		return nil, false
	}
	g := &wire.Goal{Objective: objective, Status: status, At: at}
	whole := func(k string) *int64 {
		if n, ok := m[k].(float64); ok && n >= 0 {
			i := int64(n)
			return &i
		}
		return nil
	}
	g.Iterations, g.TokensUsed = whole("iterations"), whole("tokensUsed")
	if b := whole("tokenBudget"); b != nil && *b > 0 {
		g.TokenBudget = b
	}
	if n, ok := m["timeUsedSeconds"].(float64); ok && n >= 0 {
		g.TimeUsedSeconds = &n
	}
	if r := strings.TrimSpace(goalText(m, "lastReason")); r != "" {
		g.Reason = &r
	}
	return g, true
}

func goalText(m map[string]any, k string) string { s, _ := m[k].(string); return s }
