package lineage

import (
	"reflect"
	"strconv"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

func past(n int, typ, level string, usd, cycle float64) Past {
	return Past{Ref: "github:o/r#" + strconv.Itoa(n), Type: typ, Level: level,
		Cost: wire.LineageCost{Cost: map[string]float64{"USD": usd}, OutputTokens: int64(usd * 1000), WorkingSeconds: usd * 60},
		Cycle: &cycle}
}

// #3559: only issues closed with a merged PR that fixes them count, with that PR's cost; no epic.
func TestHistoryKeepsIssuesClosedByAMergedPR(t *testing.T) {
	cost := func(v float64) wire.LineageCost { return wire.LineageCost{Cost: map[string]float64{"USD": v}} }
	str := func(s string) *string { return &s }
	date := func(d wire.Date) *wire.Date { return &d }
	issue := func(n, state, level string) wire.LineageCostNode {
		c := wire.LineageCostNode{Node: wire.LineageNode{Kind: KindIssue, Ref: "github:o/r#" + n}, Banked: cost(1), FirstAt: date(100),
			StartedAt: date(200), Resolved: &wire.LineageResolved{Title: n, State: str(state), Labels: []string{"bug"}}}
		if level != "" {
			c.Level = str(level)
		}
		return c
	}
	pr := func(n, outcome string, fixes ...string) wire.LineageCostNode {
		return wire.LineageCostNode{Node: wire.LineageNode{Kind: KindPR, Ref: "github:o/r#" + n}, Banked: cost(2), Fixes: fixes,
			Outcome: str(outcome), EndedAt: date(1000)}
	}
	h := History([]wire.LineageCostNode{
		issue("1", "closed", "bug"), pr("2", OutcomeMerged, "github:o/r#1"), pr("3", OutcomeClosed, "github:o/r#1"),
		issue("4", "open", ""), pr("5", OutcomeMerged, "github:o/r#4"),
		issue("6", "closed", "epic"), pr("7", OutcomeMerged, "github:o/r#6"),
		issue("8", "closed", ""), pr("9", OutcomeClosed, "github:o/r#8"),
	})
	if len(h) != 1 {
		t.Fatalf("%+v", h)
	}
	p := h[0]
	if p.Ref != "github:o/r#1" || p.Type != "bug" || p.Level != "bug" || p.Cost.Cost["USD"] != 5 || *p.Lead != 900 || *p.Cycle != 800 {
		t.Fatalf("%+v", p)
	}
}

// #3559: the same type and level, else the same type, else all, with at least 5; none with fewer.
func TestMatchesFallBack(t *testing.T) {
	var h []Past
	for i := range 5 {
		h = append(h, past(i, "enhancement", "story", 1, 1))
	}
	for i := 5; i < 8; i++ {
		h = append(h, past(i, "bug", "bug", 1, 1))
	}
	for _, c := range []struct {
		typ, level, by string
		n          int
	}{
		{"enhancement", "story", MatchedByLevel, 5},
		{"enhancement", "task", MatchedByType, 5},
		{"bug", "bug", MatchedByAll, 8},
	} {
		got, by := Matches(h, c.typ, c.level, "")
		if by != c.by || len(got) != c.n {
			t.Errorf("%s %s: %s %d, want %s %d", c.typ, c.level, by, len(got), c.by, c.n)
		}
	}
	// The issue itself is left out.
	if got, by := Matches(h[:5], "enhancement", "story", h[0].Ref); by != "" || got != nil {
		t.Fatalf("%s %d", by, len(got))
	}
}

// #3559: an issue's figures are the median and P10 to P90 of its matches; it lands at start
// plus its cycle time; too little history gives no figures.
func TestEstimateIssue(t *testing.T) {
	var h []Past
	for i := 1; i <= 10; i++ {
		h = append(h, past(i, "enhancement", "task", float64(i), float64(i*100)))
	}
	node := wire.LineageNode{Kind: KindIssue, Ref: "github:o/r#99"}
	e := EstimateIssue(h, node, []string{"enhancement", "task"}, 1000)
	if e.MatchedBy == nil || *e.MatchedBy != MatchedByLevel || e.Matches != 10 || e.ClosedIssues != 10 || *e.Level != "task" || *e.Type != "enhancement" {
		t.Fatalf("%+v", e)
	}
	if want := (wire.LineageEstimateRange{Median: 5.5, P10: 1.9, P90: 9.1}); !near(e.Cost["USD"], want) {
		t.Fatalf("cost %+v", e.Cost)
	}
	if e.LeadTimeSeconds != nil || e.CycleTimeSeconds == nil || e.LandsAt == nil || e.LandsAt.Median != 1550 {
		t.Fatalf("times %+v %+v", e.CycleTimeSeconds, e.LandsAt)
	}
	few := EstimateIssue(h[:4], node, nil, 0)
	if few.ClosedIssues != 4 || few.MatchedBy != nil || few.Cost != nil || few.WorkingSeconds != nil {
		t.Fatalf("%+v", few)
	}
}

func near(a, b wire.LineageEstimateRange) bool {
	d := func(x, y float64) bool { return x-y < 1e-9 && y-x < 1e-9 }
	return d(a.Median, b.Median) && d(a.P10, b.P10) && d(a.P90, b.P90)
}

// #3559: an epic adds up its open children, takes the longest child per step for its time, says
// what its closed children spent, and gives the same answer each time.
func TestEstimateEpic(t *testing.T) {
	var h []Past
	for i := range 6 {
		h = append(h, past(i, "enhancement", "story", 2, 100))
	}
	closed := wire.LineageNode{Kind: KindIssue, Ref: "github:o/r#50"}
	nodes := []wire.LineageCostNode{{Node: closed, Banked: wire.LineageCost{Cost: map[string]float64{"USD": 7}}}}
	child := func(n string, step int64, open bool) EpicChild {
		return EpicChild{Node: wire.LineageNode{Kind: KindIssue, Ref: "github:o/r#" + n}, Labels: []string{"enhancement", "story"}, Step: step, Open: open}
	}
	epic := wire.LineageNode{Kind: KindIssue, Ref: "github:o/r#40"}
	kids := []EpicChild{child("43", 2, true), child("41", 1, true), child("42", 1, true), {Node: closed, Step: 1}}
	e := EstimateEpic(h, nodes, epic, []string{"epic", "enhancement"}, kids, 0)
	if *e.OpenChildren != 3 || *e.ClosedChildren != 1 || e.Spent.Cost["USD"] != 7 || e.Matches != 6 || e.MatchedBy != nil || *e.Level != "epic" {
		t.Fatalf("%+v", e)
	}
	if e.Cost["USD"].Median != 6 || e.OutputTokens.Median != 6000 {
		t.Fatalf("sum %+v %+v", e.Cost, e.OutputTokens)
	}
	// Two steps of 100 each: the two children of step 1 run at the same time.
	if e.CycleTimeSeconds.Median != 200 || e.LandsAt.Median != 200 {
		t.Fatalf("time %+v", e.CycleTimeSeconds)
	}
	if len(e.Children) != 3 || *e.Children[0].Step != 1 || *e.Children[2].Step != 2 || e.Children[2].Node.Ref != "github:o/r#43" {
		t.Fatalf("children %+v", e.Children)
	}
	// Spread the costs: the fixed seed gives the same estimate again.
	for i := range h {
		h[i].Cost.Cost["USD"] = float64(i)
	}
	a := EstimateEpic(h, nodes, epic, nil, kids, 0)
	b := EstimateEpic(h, nodes, epic, nil, kids, 0)
	if !reflect.DeepEqual(a, b) || a.Cost["USD"].P10 >= a.Cost["USD"].P90 {
		t.Fatalf("%+v %+v", a.Cost, b.Cost)
	}
}
