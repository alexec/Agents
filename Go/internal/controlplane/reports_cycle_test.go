package controlplane

import (
	"math"
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// #3562: an issue's cycle time is from the first start of work on it or its PRs to its last
// PR merged; an epic's starts at its first child's start; the machines' copies keep the first
// start and the level; and reports/value says the median.
func TestCycleTimeFromStartToMerge(t *testing.T) {
	now := time.Now().Truncate(time.Second)
	at := func(ago time.Duration) *wire.Date { d := wire.DateOf(now.Add(-ago)); return &d }
	str := func(s string) *string { return &s }
	node := func(kind, ref string) wire.LineageCostNode {
		return wire.LineageCostNode{Node: wire.LineageNode{Kind: kind, Ref: ref},
			Banked: wire.LineageCost{Cost: map[string]float64{"USD": 1}}, LastAt: wire.DateOf(now)}
	}
	epic := node("issue", "github:o/r#1")
	epic.Level, epic.Feature = str("epic"), str("estimates")
	epic.StartedAt = at(1 * time.Hour)
	story := node("issue", "github:o/r#2")
	story.Level, story.Parent = str("story"), str(epic.Node.Ref)
	story.FirstAt, story.StartedAt = at(20*time.Hour), at(10*time.Hour)
	pr := node("pr", "github:o/r#3")
	pr.Fixes, pr.Outcome, pr.EndedAt, pr.StartedAt = []string{story.Node.Ref}, str("merged"), at(2*time.Hour), at(9*time.Hour)
	bug := node("issue", "github:o/r#4")
	bug.Level, bug.StartedAt = str("bug"), at(3*time.Hour)

	// Another machine's copy: a later start, and no level.
	other := node("issue", story.Node.Ref)
	other.StartedAt = at(5 * time.Hour)
	merged := story
	merged.Banked = wire.LineageCost{Cost: map[string]float64{"USD": 1}}
	mergeNode(&merged, other)
	if *merged.StartedAt != *story.StartedAt || merged.Level == nil || *merged.Level != "story" {
		t.Fatalf("merged %+v", merged)
	}

	nodes := []wire.LineageCostNode{epic, story, pr, bug}
	hours := func(h float64) float64 { return h * 3600 }
	v := valueOf(nodes, wire.Date(0))
	cycles := map[string]*float64{}
	for _, r := range v.Issues {
		cycles[r.Node.Ref] = r.CycleTimeSeconds
		if r.Node.Ref == story.Node.Ref && (r.Level == nil || *r.Level != "story") {
			t.Fatalf("story row %+v", r)
		}
	}
	// The story: 10h ago to 2h ago. The epic: its child's start to its child's merge, though
	// its own start is later. The open bug: no merge, no cycle time.
	if c := cycles[story.Node.Ref]; c == nil || *c != hours(8) {
		t.Fatalf("story %v", c)
	}
	if c := cycles[epic.Node.Ref]; c == nil || *c != hours(8) {
		t.Fatalf("epic %v", c)
	}
	if c := cycles[bug.Node.Ref]; c != nil {
		t.Fatalf("bug %v", *c)
	}
	if v.CycleTimeSeconds == nil || *v.CycleTimeSeconds != hours(8) {
		t.Fatalf("median %v", v.CycleTimeSeconds)
	}
	// The story's lead time is from its first work, 20h ago.
	for _, r := range v.Issues {
		if r.Node.Ref == story.Node.Ref && (r.LeadTimeSeconds == nil || *r.LeadTimeSeconds != hours(18)) {
			t.Fatalf("lead %v", r.LeadTimeSeconds)
		}
	}

	rows := map[string]wire.ReportNode{}
	for _, r := range nodeRows(nodes, "issue") {
		rows[r.Node.Ref] = r
	}
	s, e := rows[story.Node.Ref], rows[epic.Node.Ref]
	if s.CycleTimeSeconds == nil || *s.CycleTimeSeconds != hours(8) || s.StartedAt == nil || *s.StartedAt != *story.StartedAt ||
		s.Level == nil || *s.Level != "story" {
		t.Fatalf("story row %+v", s)
	}
	if e.CycleTimeSeconds == nil || *e.CycleTimeSeconds != hours(8) || e.StartedAt == nil || *e.StartedAt != *story.StartedAt ||
		e.Feature == nil || *e.Feature != "estimates" {
		t.Fatalf("epic row %+v", e)
	}
}

// #3561: Reports ▸ Value says how far the estimates kept at the start of work were from what
// the issues closed in the range took: the median of how many times too high or too low.
// An issue with no estimate, still open, or closed before the range is not counted. #4525:
// it also says how often the kept P10-P90 dollar range held the actual, and the median days
// the kept landing date was off by, over the issues whose kept estimate has those figures.
func TestValueSaysTheEstimateError(t *testing.T) {
	str := func(s string) *string { return &s }
	date := func(d wire.Date) *wire.Date { return &d }
	work := func(v float64) *float64 { return &v }
	issue := func(n string, est, actual float64, kept bool, state string, landsAt *wire.Date, p10, p90 *float64) wire.LineageCostNode {
		c := wire.LineageCostNode{Node: wire.LineageNode{Kind: "issue", Ref: "github:o/r#" + n},
			Banked: wire.LineageCost{Cost: map[string]float64{"USD": actual}, WorkingSeconds: actual * 60}, LastAt: 500,
			Resolved: &wire.LineageResolved{Title: n, State: str(state)}}
		if kept {
			e := &wire.LineageEstimateKept{At: 100, Matches: 5, Cost: map[string]float64{"USD": est}, WorkingSeconds: work(est * 60)}
			if p10 != nil && p90 != nil {
				e.CostP10, e.CostP90 = map[string]float64{"USD": *p10}, map[string]float64{"USD": *p90}
			}
			if landsAt != nil {
				e.LandsAt = &wire.LineageEstimateDates{Median: *landsAt}
			}
			c.Estimate = e
		}
		return c
	}
	pr := func(n, fixes string, ended wire.Date) wire.LineageCostNode {
		return wire.LineageCostNode{Node: wire.LineageNode{Kind: "pr", Ref: "github:o/r#" + n},
			Banked: wire.LineageCost{Cost: map[string]float64{}}, Fixes: []string{"github:o/r#" + fixes},
			Outcome: str("merged"), EndedAt: date(ended), LastAt: ended}
	}
	v := valueOf([]wire.LineageCostNode{
		// Off by x2, 2 days late, out of its $1-$3 range (not covered).
		issue("1", 2, 4, true, "closed", date(500-2*secondsPerDay), f(1), f(3)), pr("11", "1", 500),
		// Off by x1, on time, inside its $2-$5 range (covered).
		issue("2", 3, 3, true, "closed", date(500), f(2), f(5)), pr("12", "2", 500),
		// Off by x3, 1 day late, inside its $1-$10 range (covered).
		issue("3", 6, 2, true, "closed", date(500-secondsPerDay), f(1), f(10)), pr("13", "3", 500),
		issue("4", 1, 50, false, "closed", nil, nil, nil), pr("14", "4", 500),
		issue("5", 1, 50, true, "open", nil, nil, nil), pr("15", "5", 500),
		issue("6", 1, 50, true, "closed", nil, nil, nil), pr("16", "6", 100),
	}, 400)
	e := v.EstimateError
	if e == nil || e.Issues != 3 || *e.Cost != 2 || *e.WorkingSeconds != 2 {
		t.Fatalf("%+v", e)
	}
	// 2 of the 3 held the actual (issue 1 did not).
	if e.Coverage == nil || math.Abs(*e.Coverage-2.0/3.0) > 1e-9 {
		t.Fatalf("coverage %+v", e)
	}
	// Off by 2, 0 and 1 days: the median is 1.
	if e.LandsAtErrorDays == nil || *e.LandsAtErrorDays != 1 {
		t.Fatalf("landsAtErrorDays %+v", e)
	}
	if v := valueOf(nil, 0); v.EstimateError != nil {
		t.Fatalf("%+v", v.EstimateError)
	}
}

func f(v float64) *float64 { return &v }
