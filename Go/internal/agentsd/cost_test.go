package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// Ports SpendLedgerTests, LimitStoreTests and UsageLedgerTests: a session's running cost
// banked by what it rose, a turn's tokens on the day and the charts, limits set, kept and
// taken away, and a limits file that cannot be read failing closed.

func TestCostIsBankedAndLimitsKept(t *testing.T) {
	root := t.TempDir()
	d, c := start(t, root)
	defer d.Shutdown()
	d.SettingsDir = t.TempDir()
	a := seeded(t, d, t.TempDir(), nil)
	d.bankSessionCost(a.ID, wire.Cost{Amount: 0.25, Currency: "USD"})
	d.bankSessionCost(a.ID, wire.Cost{Amount: 0.75, Currency: "USD"}) // the session's total: 0.5 more
	read := int64(100)
	d.bankTurnUsage(a.ID, wire.TurnUsage{TotalTokens: 1300, InputTokens: 1000, OutputTokens: 300, CachedReadTokens: &read})
	var st wire.CostState
	json.Unmarshal(c.call(t, 1, "cost/state", nil), &st)
	if st.Today["USD"] != 0.75 || st.TokensToday != 1200 || st.Day != time.Now().Format("2006-01-02") {
		t.Fatalf("%+v", st)
	}
	got := d.Store.Agent(a.ID)
	if got.CostToDate["USD"] != 0.75 || *got.TokensToDate != 1200 || got.LastTurnUsage.InputTokens != 1000 {
		t.Fatalf("%+v", got)
	}
	b, _ := os.ReadFile(filepath.Join(root, "spend.json"))
	if !strings.Contains(string(b), `"days":{"`+st.Day+`":{"USD":0.75}}`) {
		t.Fatalf("%s", b)
	}
	var h wire.UsageHistory
	json.Unmarshal(c.call(t, 2, "usage/history", nil), &h)
	day := h.Days[st.Day]["claude"]
	if day.Cost["USD"] != 0.75 || day.InputTokens != 1000 || day.Turns != 1 || h.Now == "" {
		t.Fatalf("%+v", h)
	}
	// Limits: set, a key left alone when absent, taken away with null.
	json.Unmarshal(c.call(t, 3, "cost/setLimits", map[string]any{"daily": map[string]any{"amount": 5, "currency": "USD"}, "perAgentTokens": 100000}), &st)
	if st.Limits.Daily == nil || st.Limits.Daily.Amount != 5 || *st.Limits.PerAgentTokens != 100000 {
		t.Fatalf("%+v", st.Limits)
	}
	st = wire.CostState{}
	json.Unmarshal(c.call(t, 4, "cost/setLimits", map[string]any{"daily": nil}), &st)
	if st.Limits.Daily != nil || st.Limits.PerAgentTokens == nil {
		t.Fatalf("%+v", st.Limits)
	}
	// A file that cannot be read fails closed, and says so.
	os.WriteFile(filepath.Join(d.SettingsDir, "limits.json"), []byte("{not json"), 0o644)
	future := time.Now().Add(time.Second)
	os.Chtimes(filepath.Join(d.SettingsDir, "limits.json"), future, future)
	st = wire.CostState{}
	json.Unmarshal(c.call(t, 5, "cost/state", nil), &st)
	if st.Note == nil || !strings.Contains(*st.Note, "Nothing new starts until the limits are set again here.") {
		t.Fatalf("%+v", st)
	}
	var m wire.Milestones
	json.Unmarshal(c.call(t, 6, "milestones/state", nil), &m)
	var th wire.TimeHistory
	json.Unmarshal(c.call(t, 7, "time/history", nil), &th)
	if m.Earned == nil || th.Hours == nil || th.Now == "" {
		t.Fatalf("%+v %+v", m, th)
	}
}
