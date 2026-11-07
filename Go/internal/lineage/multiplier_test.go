package lineage

import (
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
)

func multiplierNodes(now time.Time, merged, reverted int) []wire.LineageCostNode {
	var nodes []wire.LineageCostNode
	at := wire.DateOf(now.Add(-time.Hour))
	add := func(ref, outcome string) {
		o := outcome
		nodes = append(nodes, wire.LineageCostNode{Node: wire.LineageNode{Kind: KindPR, Ref: ref}, Outcome: &o, EndedAt: &at,
			Sessions: []string{"s1"}})
	}
	for i := range merged {
		add("github:o/r#"+string(rune('a'+i)), OutcomeMerged)
	}
	for i := range reverted {
		add("github:o/r#rev"+string(rune('a'+i)), OutcomeReverted)
	}
	return nodes
}

func TestMultiplierOf(t *testing.T) {
	now := time.Date(2026, 11, 7, 12, 0, 0, 0, time.UTC)
	since := MultiplierSince(now)
	for _, c := range []struct {
		name              string
		merged, reverted  int
		prs               int64
		multiplier, hours float64
	}{
		{"seven merged", 7, 0, 7, 5.0, 200},
		{"seven merged, one revert", 7, 1, 6, 4.3, 171},
		{"more reverts than merges", 1, 3, 0, 0, 0},
		{"nothing merged", 0, 0, 0, 0, 0},
	} {
		t.Run(c.name, func(t *testing.T) {
			got := MultiplierOf(Merges(multiplierNodes(now, c.merged, c.reverted), since), now)
			if got.PrsMerged != c.prs || got.Reverts != int64(c.reverted) {
				t.Fatalf("prs %d reverts %d, want %d %d", got.PrsMerged, got.Reverts, c.prs, c.reverted)
			}
			if c.prs == 0 {
				// No figure, not 0×: the page shows — ×.
				if got.Multiplier != nil || got.EngineerHours != nil {
					t.Fatalf("a figure for nothing counted: %v %v", *got.Multiplier, *got.EngineerHours)
				}
				return
			}
			if got.Multiplier == nil || *got.Multiplier != c.multiplier || got.EngineerHours == nil || *got.EngineerHours != c.hours {
				t.Fatalf("got %v× %v h, want %v× %v h", got.Multiplier, got.EngineerHours, c.multiplier, c.hours)
			}
			if got.Baseline.PrsPerWeek != 1.4 || got.Baseline.HoursPerWeek != 40 || got.Baseline.Source != "DX 2025" {
				t.Fatalf("baseline %+v", got.Baseline)
			}
		})
	}
}

// Only a PR an agent worked on, that ended in the range, counts.
func TestMergesLeavesOut(t *testing.T) {
	now := time.Date(2026, 11, 7, 12, 0, 0, 0, time.UTC)
	since := MultiplierSince(now)
	merged, closed := OutcomeMerged, OutcomeClosed
	old, recent := wire.DateOf(now.Add(-8*24*time.Hour)), wire.DateOf(now.Add(-time.Hour))
	pr := func(ref string) wire.LineageNode { return wire.LineageNode{Kind: KindPR, Ref: ref} }
	nodes := []wire.LineageCostNode{
		{Node: pr("github:o/r#1"), Outcome: &merged, EndedAt: &recent, Sessions: []string{"s"}},
		{Node: pr("github:o/r#2"), Outcome: &merged, EndedAt: &recent},
		{Node: pr("github:o/r#3"), Outcome: &merged, EndedAt: &old, Sessions: []string{"s"}},
		{Node: pr("github:o/r#4"), Outcome: &closed, EndedAt: &recent, Sessions: []string{"s"}},
		{Node: pr("github:o/r#5"), Sessions: []string{"s"}},
		{Node: wire.LineageNode{Kind: KindIssue, Ref: "github:o/r#6"}, Outcome: &merged, EndedAt: &recent, Sessions: []string{"s"}},
	}
	got := Merges(nodes, since)
	if len(got) != 1 || got[pr("github:o/r#1")] != (Merge{At: recent}) {
		t.Fatalf("merges %v", got)
	}
	// A merge kept goes out of the range as time goes on.
	if m := MultiplierOf(got, now.Add(7*24*time.Hour)); m.PrsMerged != 0 {
		t.Fatalf("a week later %d", m.PrsMerged)
	}
}
