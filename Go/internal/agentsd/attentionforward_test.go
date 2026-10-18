package agentsd

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// Ports AttentionTests' forwarding cases (#1367): a host of a control plane offers a need
// it shows nowhere, withdraws it once it is looked at, and withdraws what a Swift host
// offered and never took back, so a phone's widget does not keep it.

type toldControl struct {
	mu   sync.Mutex
	sent []wire.AttentionNeed
}

func (c *toldControl) tell(method string, params any) {
	if method != wire.CallAttentionNeed.Name {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	c.sent = append(c.sent, params.(wire.AttentionNeed))
}

func (c *toldControl) find(ok func(wire.AttentionNeed) bool) *wire.AttentionNeed {
	c.mu.Lock()
	defer c.mu.Unlock()
	for i := range c.sent {
		if ok(c.sent[i]) {
			return &c.sent[i]
		}
	}
	return nil
}

func TestAHostOfAControlPlaneOffersAndWithdrawsNeeds(t *testing.T) {
	shortPause(t)
	root := t.TempDir()
	// A Swift host offered a change in a worktree since removed, and never withdrew it.
	gone := `{"guardedChange":{"folder":"file:///nowhere/worktrees/gone","path":".agents/pins.json"}}`
	os.WriteFile(filepath.Join(root, "attention.json"), []byte(`{"raised":[],"deliveries":[],"withdrawing":[],"forwarded":[`+gone+`]}`), 0o644)
	d, c := start(t, root)
	defer d.Shutdown()
	report := seeded(t, d, t.TempDir(), func(a *wire.Agent) {
		title := "Fix login"
		a.Title = &title
		a.Report = &wire.WorkReport{Outcome: wire.WorkOutcomeNeedsAnswer, Message: "Which branch?", At: now()}
	})
	control := &toldControl{}
	d.SetControl(control.tell)

	withdrawn := control.find(func(m wire.AttentionNeed) bool {
		return m.Withdraw != nil && m.Withdraw.GuardedChange != nil && strings.HasSuffix(string(m.Withdraw.GuardedChange.Folder), "/gone")
	})
	if withdrawn == nil || withdrawn.Waiting == nil {
		t.Fatalf("the Swift host's offer was not withdrawn: %+v", control.sent)
	}
	// No window: the report goes to the control plane, to buzz, with the count.
	offered := control.find(func(m wire.AttentionNeed) bool {
		return m.Need != nil && m.Need.ID.Report != nil && m.Need.ID.Report.AgentID == report.ID
	})
	if offered == nil || offered.Buzz == nil || !*offered.Buzz || offered.Headline == nil || offered.Headline.H2 != "Fix login" ||
		offered.Waiting == nil || *offered.Waiting != 1 {
		t.Fatalf("not offered: %+v", control.sent)
	}
	// Offered once, however often it is looked at again.
	d.reconsider()
	offers := 0
	control.mu.Lock()
	for _, m := range control.sent {
		if m.Need != nil {
			offers++
		}
	}
	control.mu.Unlock()
	if offers != 1 {
		t.Fatalf("%d offers", offers)
	}
	// Watched at the window: withdrawn from the control plane.
	c.call(t, 1, "presence/report", map[string]any{"active": true, "watching": report.ID})
	waitFor(t, "withdrawn", func() bool {
		return control.find(func(m wire.AttentionNeed) bool { return m.Withdraw != nil && m.Withdraw.Report != nil }) != nil
	})
	// What was forwarded and withdrawn is not kept.
	d.Shutdown()
	b, _ := os.ReadFile(filepath.Join(root, "attention.json"))
	if !strings.Contains(string(b), `"forwarded":[]`) {
		t.Fatalf("%s", b)
	}
}
