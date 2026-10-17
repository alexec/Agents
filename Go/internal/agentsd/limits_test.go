package agentsd

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// Ports LimitRecognitionTests and the pool's refusals: a refusal's words say spent, credit
// gone or rate limited; spent and gone take the runtime out of the pool and stop the agent.

func TestALimitInWords(t *testing.T) {
	c := func(n int) *int { return &n }
	for _, tc := range []struct {
		runtime   string
		code      *int
		msg, said string
		want      limitKind
	}{
		{"claude", c(-32603), "Internal error: You've hit your session limit · resets 5pm", "", limitSpent},
		{"codex", c(-32603), "insufficient_quota", "", limitCreditGone},
		{"gemini", c(429), "Too many requests", "", limitRateLimited},
		{"gemini", c(-32603), "You have exhausted your daily quota", "", limitSpent},
		{"copilot", nil, "", "You have exceeded your monthly quota for premium requests.", limitSpent},
		{"grok", nil, "", "Error: Usage balance exhausted", limitSpent},
		{"claude", nil, "", "You've hit your limit, says the doc I read.", limitNone},
		{"antigravity", nil, "", "Resource has been exhausted (e.g. check quota).", limitRateLimited},
	} {
		if got := classifyLimit(tc.runtime, tc.code, tc.msg, tc.said); got != tc.want {
			t.Errorf("%s %q %q: %v", tc.runtime, tc.msg, tc.said, got)
		}
	}
}

func TestACreditGoneStopsTheAgent(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	var id wire.UUID
	json.Unmarshal(c.call(t, 1, "agents/start", map[string]any{"runtimeID": "claude", "cwd": "file://" + t.TempDir(), "prompt": "spend it all"}), &id)
	c.until(t, "stopped", ended(id, wire.AgentStateStopped))
	if r := d.Store.Agent(id).EndedReason; r == nil || *r != wire.EndedReasonAllowanceSpent {
		t.Fatal(r)
	}
	var allow wire.RuntimeAllowances
	json.Unmarshal(c.call(t, 2, "runtimes/allowances", nil), &allow)
	b, _ := json.Marshal(allow)
	if !strings.Contains(string(b), `"why":"creditUsedUp"`) {
		t.Fatalf("%s", b)
	}
	if n := names(d); !strings.Contains(strings.Join(n, " "), "cost.allowance_out") {
		t.Fatal(n)
	}
}
