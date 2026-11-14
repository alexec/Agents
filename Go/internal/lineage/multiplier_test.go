package lineage

import (
	"math"
	"testing"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/wire"
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
		add("github:issue:o/r#"+string(rune('a'+i)), OutcomeMerged)
	}
	for i := range reverted {
		add("github:issue:o/r#rev"+string(rune('a'+i)), OutcomeReverted)
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
			got := MultiplierOf(Merges(multiplierNodes(now, c.merged, c.reverted), since), now, BaselineOf(0, ""))
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

// The person's own baseline (#3991): one decimal, from 0.1 to 100, and their line; the
// figure, the engineer-hours and the best week count against it.
func TestBaselineOf(t *testing.T) {
	for _, c := range []struct {
		in, want float64
	}{{0, 1.4}, {-3, 1.4}, {2.34, 2.3}, {0.01, 0.1}, {500, 100}, {math.Inf(1), 1.4}} {
		if got := BaselineOf(c.in, "").PrsPerWeek; got != c.want {
			t.Errorf("BaselineOf(%v) = %v, want %v", c.in, got, c.want)
		}
	}
	if b := BaselineOf(0, ""); b.Line != nil || b.HoursPerWeek != 40 || b.Source != "DX 2025" {
		t.Fatalf("default %+v", b)
	}
	b := BaselineOf(2, "My team merged 2 a week")
	if b.Line == nil || *b.Line != "My team merged 2 a week" {
		t.Fatalf("line %v", b.Line)
	}
	now := time.Date(2026, 11, 7, 12, 0, 0, 0, time.UTC)
	got := MultiplierOf(Merges(multiplierNodes(now, 7, 0), MultiplierSince(now)), now, b)
	if *got.Multiplier != 3.5 || *got.EngineerHours != 140 || got.Baseline != b {
		t.Fatalf("got %v× %v h %+v", *got.Multiplier, *got.EngineerHours, got.Baseline)
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
		{Node: pr("github:issue:o/r#1"), Outcome: &merged, EndedAt: &recent, Sessions: []string{"s"}},
		{Node: pr("github:issue:o/r#2"), Outcome: &merged, EndedAt: &recent},
		{Node: pr("github:issue:o/r#3"), Outcome: &merged, EndedAt: &old, Sessions: []string{"s"}},
		{Node: pr("github:issue:o/r#4"), Outcome: &closed, EndedAt: &recent, Sessions: []string{"s"}},
		{Node: pr("github:issue:o/r#5"), Sessions: []string{"s"}},
		{Node: wire.LineageNode{Kind: KindIssue, Ref: "github:issue:o/r#6"}, Outcome: &merged, EndedAt: &recent, Sessions: []string{"s"}},
	}
	got := Merges(nodes, since)
	if len(got) != 1 || got[pr("github:issue:o/r#1")] != (Merge{At: recent}) {
		t.Fatalf("merges %v", got)
	}
	// A merge kept goes out of the range as time goes on.
	if m := MultiplierOf(got, now.Add(7*24*time.Hour), BaselineOf(0, "")); m.PrsMerged != 0 {
		t.Fatalf("a week later %d", m.PrsMerged)
	}
}

// The best week (#3988): the highest calendar week, Monday to Sunday in the zone given,
// less its reverts; none until the first merge is 7 days old.
func TestBestWeekOf(t *testing.T) {
	london, err := time.LoadLocation("Europe/London")
	if err != nil {
		t.Skip("no zoneinfo:", err)
	}
	dx := BaselineOf(0, "")
	// Saturday 7 November 2026, noon in London.
	now := time.Date(2026, 11, 7, 12, 0, 0, 0, london)
	n := 0
	merges := map[wire.LineageNode]Merge{}
	add := func(at time.Time, reverted bool) {
		n++
		merges[wire.LineageNode{Kind: KindPR, Ref: "github:pr:o/r#" + string(rune('a'+n))}] = Merge{At: wire.DateOf(at), Reverted: reverted}
	}
	// This week: 2 merged.
	add(time.Date(2026, 11, 2, 0, 30, 0, 0, london), false)
	add(time.Date(2026, 11, 6, 9, 0, 0, 0, london), false)
	if got := BestWeekOf(merges, now, london, dx); got != nil {
		t.Fatalf("a best week before 7 days of lineage: %v", *got)
	}
	// Last week: 7 merged, one reverted, the last of them late on Sunday.
	for d := range 6 {
		add(time.Date(2026, 10, 26+d, 10, 0, 0, 0, london), false)
	}
	add(time.Date(2026, 11, 1, 23, 30, 0, 0, london), false)
	add(time.Date(2026, 10, 28, 11, 0, 0, 0, london), true)
	got := BestWeekOf(merges, now, london, dx)
	if got == nil || *got != 4.3 {
		t.Fatalf("best week %v, want 4.3 (6 PRs)", got)
	}
	// In New York, this week's Monday 00:30 merge in London is last week's Sunday evening.
	ny, _ := time.LoadLocation("America/New_York")
	if got := BestWeekOf(merges, now, ny, dx); got == nil || *got != 5 {
		t.Fatalf("New York's best week %v, want 5.0 (7 PRs)", got)
	}
	// This week passes it: a new best.
	for d := range 6 {
		add(time.Date(2026, 11, 3, 10+d, 0, 0, 0, london), false)
	}
	if got := BestWeekOf(merges, now, london, dx); got == nil || *got != 5.7 {
		t.Fatalf("best week %v, want 5.7 (8 PRs)", got)
	}
	// Only reverts: no figure.
	only := map[wire.LineageNode]Merge{{Kind: KindPR, Ref: "x"}: {At: wire.DateOf(now.Add(-10 * 24 * time.Hour)), Reverted: true}}
	if got := BestWeekOf(only, now, london, dx); got != nil {
		t.Fatalf("a best week of reverts: %v", *got)
	}
}

// The first merge (#4250): none with no merges; the earliest, a revert too, else.
func TestFirstMergeOf(t *testing.T) {
	if got := FirstMergeOf(nil); got != nil {
		t.Fatalf("a first merge of none: %v", *got)
	}
	now := time.Date(2026, 11, 7, 12, 0, 0, 0, time.UTC)
	old := wire.DateOf(now.Add(-30 * 24 * time.Hour))
	merges := map[wire.LineageNode]Merge{
		{Kind: KindPR, Ref: "a"}: {At: wire.DateOf(now.Add(-time.Hour))},
		{Kind: KindPR, Ref: "b"}: {At: old, Reverted: true},
	}
	if got := FirstMergeOf(merges); got == nil || *got != old {
		t.Fatalf("first merge %v, want %v", got, old)
	}
}
