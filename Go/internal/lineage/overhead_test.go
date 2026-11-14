package lineage

import (
	"math"
	"testing"
	"time"

	"github.com/agentloops-dev/agents/Go/wire"
)

// #4524: the unlinked ratio is the sessions' cost over the linked cost in the window; the epic
// ratio is the epics' own cost over their children's and their PRs'; a node changed before the
// window is left out; the loaded figure is the direct one times both.
func TestOverheadAndLoad(t *testing.T) {
	now := time.Date(2026, 11, 10, 12, 0, 0, 0, time.UTC)
	in, old := wire.DateOf(now.Add(-time.Hour)), wire.DateOf(now.Add(-15*24*time.Hour))
	cost := func(v float64) wire.LineageCost { return wire.LineageCost{Cost: map[string]float64{"USD": v}} }
	epic, level := "github:issue:o/r#1", "epic"
	nodes := []wire.LineageCostNode{
		{Node: wire.LineageNode{Kind: KindIssue, Ref: epic}, Level: &level, Banked: cost(2), LastAt: in},
		{Node: wire.LineageNode{Kind: KindIssue, Ref: "github:issue:o/r#2"}, Parent: &epic, Banked: cost(3), LastAt: in},
		{Node: wire.LineageNode{Kind: KindPR, Ref: "github:pr:o/r#3"}, Fixes: []string{"github:issue:o/r#2"}, Banked: cost(5), LastAt: in},
		{Node: wire.LineageNode{Kind: KindSession, Ref: "agents:session:#a"}, Banked: cost(6), LastAt: in},
		{Node: wire.LineageNode{Kind: KindSession, Ref: "agents:session:#old"}, Banked: cost(100), LastAt: old},
		{Node: wire.LineageNode{Kind: KindIssue, Ref: "github:issue:o/r#4"}, Banked: cost(100), LastAt: old},
	}
	o := Overhead(nodes, now)
	// Unlinked 6 over linked 2 + 3 + 5; the epic's 2 over its child's 3 and its PR's 5.
	if o.WindowDays != 14 || o.Currency == nil || *o.Currency != "USD" || o.UnlinkedRatio == nil || *o.UnlinkedRatio != 0.6 ||
		o.EpicRatio == nil || *o.EpicRatio != 0.25 || o.Linked.Cost["USD"] != 10 || o.Unlinked.Cost["USD"] != 6 || len(o.Uncounted) != 2 {
		t.Fatalf("%+v", o)
	}
	e := wire.LineageEstimate{Cost: map[string]wire.LineageEstimateRange{"USD": {Median: 100, P10: 10, P90: 200}}}
	Load(&e, o, false)
	if e.Overhead == nil || math.Abs(e.Loaded["USD"].Median-160) > 1e-9 || math.Abs(e.Loaded["USD"].P90-320) > 1e-9 {
		t.Fatalf("issue %+v", e.Loaded)
	}
	Load(&e, o, true)
	if math.Abs(e.Loaded["USD"].Median-200) > 1e-9 {
		t.Fatalf("epic %+v", e.Loaded)
	}
	// Nothing linked: no ratio, so nothing loaded.
	none := Overhead(nodes[3:5], now)
	if none.UnlinkedRatio != nil || none.Currency != nil {
		t.Fatalf("%+v", none)
	}
	e = wire.LineageEstimate{Cost: map[string]wire.LineageEstimateRange{"USD": {Median: 1}}}
	if Load(&e, none, false); e.Loaded != nil || e.Overhead == nil {
		t.Fatalf("%+v", e)
	}
}

// #4524: a release's rollup counts its own node.
func TestRollupOfAReleaseCountsItself(t *testing.T) {
	rel := "github:release:o/r#v1.2.0"
	nodes := []wire.LineageCostNode{
		{Node: wire.LineageNode{Kind: KindRelease, Ref: rel}, Banked: wire.LineageCost{Cost: map[string]float64{"USD": 1}}},
		{Node: wire.LineageNode{Kind: KindPR, Ref: "github:pr:o/r#2"}, PartOf: []string{rel}, Banked: wire.LineageCost{Cost: map[string]float64{"USD": 2}}},
	}
	r := Rollup(nodes, wire.LineageNode{Kind: KindRelease, Ref: rel})
	if r.Own.Cost["USD"] != 1 || r.Total.Cost["USD"] != 3 {
		t.Fatalf("%+v", r)
	}
	if got := RepoOf(wire.LineageNode{Kind: KindRelease, Ref: rel}); got != "github:repo:#o/r" {
		t.Fatalf("%q", got)
	}
}

// #4524: a forecast's estimate to complete and spend are loaded with the unlinked ratio only.
func TestLoadForecast(t *testing.T) {
	r, e := 0.5, 1.0
	o := wire.LineageOverhead{UnlinkedRatio: &r, EpicRatio: &e}
	one := map[string]wire.LineageEstimateRange{"USD": {Median: 10, P10: 2, P90: 20}}
	f := wire.LineageForecast{ToComplete: &wire.LineageForecastToComplete{Cost: one}, Spend: &wire.LineageForecastSpend{Week: one, Month: one}}
	LoadForecast(&f, o)
	if f.Overhead == nil || f.ToComplete.Loaded["USD"].Median != 15 || f.Spend.LoadedWeek["USD"].P90 != 30 ||
		f.Spend.LoadedMonth["USD"].P10 != 3 {
		t.Fatalf("%+v %+v", f.ToComplete, f.Spend)
	}
}
