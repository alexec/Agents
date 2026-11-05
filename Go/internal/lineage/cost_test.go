package lineage

import (
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// #2350: the shares add up to the whole, tokens too.
func TestSplitAddsUp(t *testing.T) {
	limit := int64(10)
	c := wire.LineageCost{Cost: map[string]float64{"USD": 1}, InputTokens: 7, OutputTokens: 2, LimitTokens: &limit, Turns: 1, WorkingSeconds: 3}
	sum := wire.LineageCost{}
	for _, s := range Split(c, 3) {
		AddCost(&sum, s)
	}
	if sum.InputTokens != 7 || sum.OutputTokens != 2 || *sum.LimitTokens != 10 || sum.Turns < 0.999 || sum.Cost["USD"] < 0.999 || sum.WorkingSeconds < 2.999 {
		t.Fatalf("%+v", sum)
	}
}

func TestRepoOf(t *testing.T) {
	for n, want := range map[wire.LineageNode]string{
		{Kind: KindIssue, Ref: "github:alexec/agents#12"}: "github:alexec/agents",
		{Kind: KindPR, Ref: "gitlab:group/sub/repo!4"}:    "gitlab:group/sub/repo",
		{Kind: KindIssue, Ref: "linear:ENG-4"}:            "linear",
		{Kind: KindSession, Ref: "session:x"}:             "",
	} {
		if got := RepoOf(n); got != want {
			t.Errorf("%v: %q, want %q", n, got, want)
		}
	}
}

// #2350: a repo adds up every node in it once; a merged revert is waste.
func TestRollupOfARepo(t *testing.T) {
	cost := func(v float64) wire.LineageCost { return wire.LineageCost{Cost: map[string]float64{"USD": v}} }
	p, other := "github:o/r", "github:o/other"
	reverted, merged := OutcomeReverted, OutcomeMerged
	nodes := []wire.LineageCostNode{
		{Node: wire.LineageNode{Kind: KindIssue, Ref: "github:o/r#1"}, Repo: &p, Banked: cost(1), LastAt: 1},
		{Node: wire.LineageNode{Kind: KindPR, Ref: "github:o/r#2"}, Repo: &p, Banked: cost(2), Fixes: []string{"github:o/r#1"}, Outcome: &merged, LastAt: 2},
		{Node: wire.LineageNode{Kind: KindPR, Ref: "github:o/r#3"}, Repo: &p, Banked: cost(4), Outcome: &reverted, LastAt: 3},
		{Node: wire.LineageNode{Kind: KindSession, Ref: "session:a"}, Repo: &p, Banked: cost(8), LastAt: 4},
		{Node: wire.LineageNode{Kind: KindIssue, Ref: "github:o/other#1"}, Repo: &other, Banked: cost(16), LastAt: 5},
	}
	r := Rollup(nodes, wire.LineageNode{Kind: KindRepo, Ref: p})
	if r.Total.Cost["USD"] != 15 || r.Waste.Cost["USD"] != 4 || r.Unlinked.Cost["USD"] != 8 || r.PrsMerged != 2 || r.PrsReverted != 1 ||
		len(r.Parts) != 4 || r.Parts[0].Node.Ref != "session:a" {
		t.Fatalf("%+v", r)
	}
	if got := Rollup(nodes, wire.LineageNode{Kind: KindIssue, Ref: "github:o/r#1"}); got.Own.Cost["USD"] != 1 || got.Total.Cost["USD"] != 3 {
		t.Fatalf("%+v", got)
	}
}

// #3562: a hierarchy level wins over bug; a label's value in any case.
func TestLevelOfAndLabelValue(t *testing.T) {
	for _, c := range []struct {
		labels []string
		want   string
	}{
		{[]string{"bug", "Task"}, "task"},
		{[]string{"bug"}, "bug"},
		{[]string{"enhancement", "epic"}, "epic"},
		{[]string{"enhancement"}, ""},
		{nil, ""},
	} {
		if got := LevelOf(c.labels); got != c.want {
			t.Errorf("LevelOf(%v) = %q, want %q", c.labels, got, c.want)
		}
	}
	labels := []string{"area:", "Feature: estimates ", "area:lineage"}
	if got := LabelValue(labels, "feature:"); got != "estimates" {
		t.Errorf("feature %q", got)
	}
	if got := LabelValue(labels, "area:"); got != "lineage" {
		t.Errorf("area %q", got)
	}
}
