package agentsd

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/agentloops-dev/agents/Go/internal/lineage"
	"github.com/agentloops-dev/agents/Go/wire"
)

// #4526: a weekly allowance at its reading's pace: half used two days into the week runs out
// two days later; a tenth used lasts to the reset; a past week or another window says nothing.
func TestBurnOfAWeeklyAllowance(t *testing.T) {
	now := time.Date(2026, 11, 10, 12, 0, 0, 0, time.UTC)
	reading := func(window string, used float64, at, resets time.Time) wire.AllowanceReading {
		return wire.AllowanceReading{Window: &window, Used: &used, At: wire.DateOf(at), ResetsAt: new(wire.DateOf(resets))}
	}
	resets := now.Add(5 * 24 * time.Hour)
	b, ok := burnOf("claude:sign-in", wire.AllowanceState{Reading: new(reading("seven_day", 0.5, now, resets))}, now, 1)
	if !ok || b.Lasts || b.RunsOutAt == nil || b.RunsOutAt.Time().Sub(now).Round(time.Minute) != 48*time.Hour || b.Used != 0.5 {
		t.Fatalf("%+v %v", b, ok)
	}
	b, ok = burnOf("k", wire.AllowanceState{Weeks: []wire.AllowanceReading{reading("weekly", 0.1, now, resets)}}, now, 1)
	if !ok || !b.Lasts || b.RunsOutAt != nil {
		t.Fatalf("%+v %v", b, ok)
	}
	for _, s := range []wire.AllowanceState{
		{Reading: new(reading("five_hour", 0.5, now, now.Add(time.Hour)))},
		{Weeks: []wire.AllowanceReading{reading("seven_day", 0.9, now.Add(-8*24*time.Hour), now.Add(-time.Hour))}},
	} {
		if b, ok := burnOf("k", s, now, 1); ok {
			t.Fatalf("%+v", b)
		}
	}
}

// #4526: lineage/forecast reads the epic's plan and says why it has no date with too little
// history; it always says the burn, and keeps a forecast on the epic's node only once.
func TestLineageForecastOfAnEpic(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	epic := wire.LineageNode{Kind: "issue", Ref: "github:issue:alexec/agents#10"}
	key, _ := json.Marshal([]any{"forge/plan", epic.Ref})
	d.forgeRemember(string(key), forgeAnswer{plan: &forgePlanAnswer{
		epic:     wire.ForgeItem{Node: epic, State: "open", Labels: []wire.ForgeLabel{{Name: "epic"}}},
		children: []planChild{{item: wire.ForgeItem{Node: wire.LineageNode{Kind: "issue", Ref: "github:issue:alexec/agents#11"}, State: "open"}}}}})
	var f wire.LineageForecast
	if err := json.Unmarshal(c.call(t, 1, "lineage/forecast", wire.LineageForecastRequest{Node: &epic}), &f); err != nil {
		t.Fatal(err)
	}
	if f.Lands != nil || f.NoForecast == nil || *f.NoForecast != lineage.NoForecastHistory || f.Burn == nil || f.WindowDays != 14 {
		t.Fatalf("%+v", f)
	}

	d.workMu.Lock()
	d.costLedgerLocked().Nodes[costKey(epic)] = wire.LineageCostNode{Node: epic, Banked: wire.LineageCost{Cost: map[string]float64{}}}
	d.workMu.Unlock()
	first := &wire.LineageForecastKept{P50: 1, P85: 2, WindowDays: 14, Share: 0.1, Open: 3}
	if got := d.keepForecast(costKey(epic), first); got == nil || *got != *first {
		t.Fatalf("%+v", got)
	}
	if got := d.keepForecast(costKey(epic), &wire.LineageForecastKept{P50: 5, P85: 6}); got == nil || *got != *first {
		t.Fatalf("kept again: %+v", got)
	}
	if got := d.keepForecast(costKey(wire.LineageNode{Kind: "issue", Ref: "github:issue:alexec/agents#12"}), first); got != nil {
		t.Fatalf("%+v", got)
	}
}

// #4620: lineage/forecast for a milestone reads the store's issues in it, in the folder's repo;
// a node and a milestone together are refused.
func TestLineageForecastOfAMilestone(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	folder := t.TempDir()
	d.repos = map[string]forgeRepo{folder: {"github", "alexec/agents"}}
	issue := wire.LineageNode{Kind: "issue", Ref: "github:issue:alexec/agents#11"}
	open := "open"
	d.workMu.Lock()
	d.costLedgerLocked().Nodes[costKey(issue)] = wire.LineageCostNode{Node: issue, Repo: new("github:repo:#alexec/agents"), Milestone: new("Planning"),
		Level: new("task"), Banked: wire.LineageCost{Cost: map[string]float64{}}, Resolved: &wire.LineageResolved{State: &open}}
	d.workMu.Unlock()
	var f wire.LineageForecast
	if err := json.Unmarshal(c.call(t, 1, "lineage/forecast", wire.LineageForecastRequest{Milestone: new("Planning"), Folder: &folder}), &f); err != nil {
		t.Fatal(err)
	}
	if f.Lands != nil || f.NoForecast == nil || *f.NoForecast != lineage.NoForecastHistory || f.Milestone == nil || f.Burn == nil {
		t.Fatalf("%+v", f)
	}
	if err := json.Unmarshal(c.call(t, 2, "lineage/forecast", wire.LineageForecastRequest{Milestone: new("Later"), Folder: &folder}), &f); err != nil {
		t.Fatal(err)
	}
	if f.NoForecast == nil || *f.NoForecast != lineage.NoForecastNoItems {
		t.Fatalf("%+v", f)
	}
	if _, err := d.lineageForecast(t.Context(), wire.LineageForecastRequest{Node: &issue, Milestone: new("Planning")}); err == nil {
		t.Fatal("a node and a milestone together")
	}
}
