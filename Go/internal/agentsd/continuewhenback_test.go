package agentsd

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// A chat paused by a spent allowance carries on when it is back (#1859): it waits for the
// provider's reset, goes on as soon as the runtime is back, and stops waiting when asked.

func TestAPausedChatContinuesWhenItsAllowanceIsBack(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	var id wire.UUID
	json.Unmarshal(c.call(t, 1, "agents/start", map[string]any{"runtimeID": "claude", "cwd": "file://" + t.TempDir(), "prompt": "typed limit"}), &id)
	c.until(t, "stopped", ended(id, wire.AgentStateStopped))
	var a wire.Agent
	json.Unmarshal(c.call(t, 2, "agents/continueWhenBack", map[string]any{"agentID": id}), &a)
	w := a.ContinueWhenBack
	if w == nil || !w.At.Time().After(time.Now()) {
		t.Fatalf("not waiting for a time ahead: %+v", w)
	}
	if !w.ResetKnown {
		t.Fatalf("the provider's reset time not taken: %+v", w)
	}
	// The person marks the runtime available: the chat goes on at once, in the same chat.
	c.call(t, 3, "runtimes/markAvailable", map[string]any{"credentialKey": "claude:sign-in"})
	waitFor(t, "continued", func() bool {
		users, _ := saidIn(d, id)
		return strings.Contains(strings.Join(users, "\n"), continueWhenBackWords)
	})
	if got := d.Store.Agent(id); got.ContinueWhenBack != nil {
		t.Fatalf("still waiting after it went on: %+v", got.ContinueWhenBack)
	}
}

func TestAWaitThatIsDueGoesAndCancelStopsOne(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	cwd := t.TempDir()
	paused := func(a *wire.Agent) { a.State, a.EndedReason = wire.AgentStateStopped, reason(wire.EndedReasonAllowanceSpent) }
	// Not paused by an allowance: refused.
	done := seeded(t, d, cwd, nil)
	if e := c.callError(t, 1, "agents/continueWhenBack", map[string]any{"agentID": done.ID}); e == nil {
		t.Fatal("a finished chat was made to wait")
	}
	// Cancelled: no longer waits, and nothing is sent.
	waiting := seeded(t, d, cwd, paused)
	d.allowMu.Lock()
	until := wire.DateOf(time.Now().Add(time.Hour))
	s := availableState(ownKey("claude"))
	s.Status = wire.AllowanceStateStatus{Out: &wire.AllowanceStateStatusOut{Until: &until, Why: wire.AllowanceStateOutReasonAllowanceSpent}}
	d.allowancesLocked()[ownKey("claude")] = s
	d.allowMu.Unlock()
	var a wire.Agent
	json.Unmarshal(c.call(t, 2, "agents/continueWhenBack", map[string]any{"agentID": waiting.ID}), &a)
	if a.ContinueWhenBack == nil || a.ContinueWhenBack.At != until {
		t.Fatalf("%+v", a.ContinueWhenBack)
	}
	a = wire.Agent{}
	json.Unmarshal(c.call(t, 3, "agents/cancelContinue", map[string]any{"agentID": waiting.ID}), &a)
	if a.ContinueWhenBack != nil {
		t.Fatalf("still waiting after Cancel: %+v", a.ContinueWhenBack)
	}
	// One kept over a restart that is already due goes as soon as it is armed.
	due := seeded(t, d, cwd, func(a *wire.Agent) {
		paused(a)
		a.ContinueWhenBack = &wire.ContinueWhenBack{At: wire.DateOf(time.Now().Add(-time.Minute))}
	})
	d.resumeContinues()
	waitFor(t, "due continued", func() bool {
		users, _ := saidIn(d, due.ID)
		return strings.Contains(strings.Join(users, "\n"), continueWhenBackWords)
	})
	if users, _ := saidIn(d, waiting.ID); len(users) != 0 {
		t.Fatalf("a cancelled wait sent %v", users)
	}
}
