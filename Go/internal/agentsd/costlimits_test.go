package agentsd

import (
	"strings"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// Ports CostLimitTests: nothing new starts at the day's limit; what is sent to an agent at
// its limit waits, said once; raising the limit lets it go.

func TestLimitsHoldTheWork(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	d.SettingsDir = t.TempDir()
	dir := t.TempDir()
	a := seeded(t, d, dir, nil)
	d.bankSessionCost(a.ID, wire.Cost{Amount: 2, Currency: "USD"})
	c.call(t, 1, "cost/setLimits", map[string]any{"daily": map[string]any{"amount": 1, "currency": "USD"}})
	if e := c.callError(t, 2, "agents/start", map[string]any{"runtimeID": "claude", "cwd": "file://" + dir, "prompt": "hi"}); e.Code != wire.FailureDayLimitReached ||
		!strings.HasPrefix(e.Message, "Today has cost $2.00, which reaches the $1.00 you allowed for a day.") {
		t.Fatalf("%+v", e)
	}
	c.call(t, 3, "agents/prompt", map[string]any{"agentID": a.ID, "text": "go on", "from": "person"})
	waitFor(t, "the hold said", func() bool {
		for _, k := range kinds(d, a.ID) {
			if k == "runtimeNote" {
				return true
			}
		}
		return false
	})
	if q := d.Store.Agent(a.ID).QueuedPrompts; len(q) != 1 {
		t.Fatalf("%+v", q)
	}
	c.call(t, 4, "cost/setLimits", map[string]any{"daily": map[string]any{"amount": 10, "currency": "USD"}})
	waitFor(t, "it went", func() bool { u := userMessages(d, a.ID); return len(u) == 1 && u[0] == "go on" })
	if n := names(d); !strings.Contains(strings.Join(n, " "), "cost.limit_reached") {
		t.Fatal(n)
	}
}
