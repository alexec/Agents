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
// banked by what it rose, a turn's tokens on the day and the charts, and limits set, kept
// and taken away. cost/setLimits now writes your layer, not limits.json (#2957, FR-012):
// limits.json is not read for enforcement any more, so a corrupt copy of it no longer
// fails anything closed (policy_test.go covers your layer's own signature checks instead).

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
	if day.Cost["USD"] != 0.75 || day.InputTokens != 1000 || day.Turns != 1 || h.Now == "" || !sameZone(h.TimeZone) {
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
	var m wire.Milestones
	json.Unmarshal(c.call(t, 5, "milestones/state", nil), &m)
	var th wire.TimeHistory
	json.Unmarshal(c.call(t, 6, "time/history", nil), &th)
	if m.Earned == nil || th.Hours == nil || th.Now == "" || !sameZone(th.TimeZone) {
		t.Fatalf("%+v %+v", m, th)
	}
}

func sameZone(z *string) bool {
	want := zoneName()
	return (z == nil) == (want == nil) && (z == nil || *z == *want)
}

// The histories say the zone their stamps are in, so a viewer elsewhere can move them into
// its own day (#1267).
func TestNamedZone(t *testing.T) {
	utc := func() time.Time { return time.Date(2026, 10, 17, 2, 41, 0, 0, time.UTC) }
	pdt := func() time.Time { return time.Date(2026, 10, 16, 19, 41, 0, 0, time.FixedZone("PDT", -7*3600)) }
	noLink := func(string) (string, error) { return "", os.ErrNotExist }
	link := func(to string) func(string) (string, error) { return func(string) (string, error) { return to, nil } }
	env := func(tz string, set bool) func(string) (string, bool) {
		return func(string) (string, bool) { return tz, set }
	}
	for _, c := range []struct {
		name     string
		env      func(string) (string, bool)
		readlink func(string) (string, error)
		now      func() time.Time
		want     string
	}{
		{"TZ names a zone", env("America/Los_Angeles", true), noLink, pdt, "America/Los_Angeles"},
		{"TZ with a colon", env(":Europe/London", true), noLink, utc, "Europe/London"},
		{"TZ empty is UTC", env("", true), noLink, utc, "UTC"},
		{"TZ a path", env("/usr/share/zoneinfo/Asia/Kolkata", true), noLink, utc, "Asia/Kolkata"},
		{"macOS link", env("", false), link("/var/db/timezone/zoneinfo/America/Los_Angeles"), pdt, "America/Los_Angeles"},
		{"Linux link", env("", false), link("../usr/share/zoneinfo/Etc/UTC"), utc, "Etc/UTC"},
		{"container with no zone", env("", false), noLink, utc, "UTC"},
		{"nothing to name", env("", false), noLink, pdt, ""},
	} {
		got := namedZone(c.env, c.readlink, c.now)
		if (got == nil) != (c.want == "") || (got != nil && *got != c.want) {
			t.Errorf("%s: %v, want %q", c.name, got, c.want)
		}
	}
}
