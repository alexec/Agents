package controlplane

import (
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
	story.Level, story.Area, story.Parent = str("story"), str("lineage"), str(epic.Node.Ref)
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
		s.Level == nil || *s.Level != "story" || s.Area == nil || *s.Area != "lineage" {
		t.Fatalf("story row %+v", s)
	}
	if e.CycleTimeSeconds == nil || *e.CycleTimeSeconds != hours(8) || e.StartedAt == nil || *e.StartedAt != *story.StartedAt ||
		e.Feature == nil || *e.Feature != "estimates" {
		t.Fatalf("epic row %+v", e)
	}
}
