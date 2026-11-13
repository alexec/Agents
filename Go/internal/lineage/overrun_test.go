package lineage

import (
	"testing"

	"github.com/agentloops-dev/agents/Go/wire"
)

// #4529: an open epic's spend is its own and its children's, with their PRs, against the
// estimate kept on its node; Passed is the highest threshold reached.
func TestOverrunOfAnEpic(t *testing.T) {
	epic := wire.LineageNode{Kind: KindIssue, Ref: "github:issue:o/r#1"}
	child := wire.LineageNode{Kind: KindIssue, Ref: "github:issue:o/r#2"}
	pr := wire.LineageNode{Kind: KindPR, Ref: "github:o/r!3"}
	usd := func(v float64) wire.LineageCost { return wire.LineageCost{Cost: map[string]float64{"USD": v}} }
	epicLevel, parent := "epic", epic.Ref
	nodes := []wire.LineageCostNode{
		{Node: epic, Level: &epicLevel, Banked: usd(10), Estimate: &wire.LineageEstimateKept{Cost: map[string]float64{"USD": 50}}},
		{Node: child, Parent: &parent, Banked: usd(20)},
		{Node: pr, Fixes: []string{child.Ref}, Banked: usd(75)},
		{Node: wire.LineageNode{Kind: KindIssue, Ref: "github:issue:o/r#9"}, Banked: usd(500)},
	}
	o, ok := OverrunOf(nodes, epic)
	if !ok || o.Spent != 105 || o.Estimate != 50 || o.Passed != 2 || o.Currency != "USD" {
		t.Fatalf("%+v %v", o, ok)
	}
	nodes[2].Banked = usd(150)
	if o, _ := OverrunOf(nodes, epic); o.Passed != 3 {
		t.Fatalf("%+v", o)
	}
	nodes[2].Banked = usd(5)
	if o, _ := OverrunOf(nodes, epic); o.Passed != 0 {
		t.Fatalf("%+v", o)
	}

	byKey := map[wire.LineageNode]wire.LineageCostNode{}
	for _, n := range nodes {
		byKey[n.Node] = n
	}
	for _, n := range []wire.LineageNode{epic, child, pr} {
		if got := EpicsOf(byKey, n); len(got) != 1 || got[0] != epic {
			t.Fatalf("%v: %v", n, got)
		}
	}

	// Closed, or with an issue's estimate (it had no children yet), it says nothing.
	closed := "closed"
	nodes[0].Resolved = &wire.LineageResolved{State: &closed}
	if _, ok := OverrunOf(nodes, epic); ok {
		t.Fatal("a closed epic")
	}
	nodes[0].Resolved = nil
	nodes[0].Estimate.MatchedBy = new("type")
	if _, ok := OverrunOf(nodes, epic); ok {
		t.Fatal("an issue's estimate")
	}
}
