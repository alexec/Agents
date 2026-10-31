package controlplane

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/store"
)

// #2243: at the plan's limit, agents/start and the other ways to begin another running
// agent are refused with the gate's own words; a call that starts no new agent is not.
func TestAgentsRunningGateRefusesAtThePlanLimit(t *testing.T) {
	t.Parallel()
	refusal := errors.New("Your Free plan allows 3 agents running at once. Wait for one to finish, or upgrade at https://hosted.test/account.")
	p := startPlaneWith(t, store.NewMemory(), controllink.NewPrivateKey(), func(cfg *Config) {
		cfg.AgentsRunningGate = func(running int) error { return refusal }
	})
	_, window := p.client("Alex's Mac")
	host := p.host("MACHINE-2").member.Host
	for _, method := range []string{"agents/start", "agents/fork", "agents/branchFrom", "agents/continueInFolder", "agents/continueInNew"} {
		if e := callError(t, window, host, method, map[string]any{}); !strings.Contains(e, refusal.Error()) {
			t.Fatalf("%s: %s", method, e)
		}
	}
	// Reading, and a call that starts no new agent, are not this gate's to refuse: a
	// fakeHost answers daemon/ping, and answers agents/prompt method-not-found, never
	// with this gate's words.
	call(t, window, host, "daemon/ping", nil)
	if e := callError(t, window, host, "agents/prompt", map[string]any{}); strings.Contains(e, refusal.Error()) {
		t.Fatal("agents/prompt was refused by the agents-running gate")
	}
}

// #2243: runningAgents counts the live-state agents of every host's cached list, across
// more than one host, as console/live's board does (TestConsoleLiveIsEveryRunningAgent).
func TestRunningAgentsCountsEveryHostsLiveStates(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	a := p.host("MACHINE-A")
	b := p.host("MACHINE-B")
	p.s.copies.take(a.member.Host, "agents/list", `{"result":[{"id":"A1","state":"running"},{"id":"A2","state":"finished"}]}`)
	p.s.copies.take(b.member.Host, "agents/list", `{"result":[{"id":"B1","state":"waitingOnUser"},{"id":"B2","state":"starting"}]}`)
	if n := p.s.runningAgents(context.Background()); n != 3 {
		t.Fatalf("got %d", n)
	}
}

// #2243: with no AgentsRunningGate configured (self-hosted, or hosted with no plan
// change yet), a call that would otherwise be gated reaches the host as usual.
func TestAgentsRunningGateDoesNothingWithNoneConfigured(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	_, window := p.client("Alex's Mac")
	host := p.host("MACHINE-2").member.Host
	// Not refused by a limit: a fakeHost answers method-not-found for agents/start, which
	// it does not serve, but never this gate's words.
	if e := callError(t, window, host, "agents/start", map[string]any{}); strings.Contains(e, "allows") {
		t.Fatal("agents/start was refused by a limit with none configured:", e)
	}
}
