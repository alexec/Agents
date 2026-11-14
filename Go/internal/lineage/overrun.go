package lineage

import (
	"sort"

	"github.com/agentloops-dev/agents/Go/wire"
)

// An epic's overrun (#4529): what an open epic has spent so far against the estimate kept on
// its node when its work started (#3561). It passes OverrunThresholds one at a time, and the
// person gets one notice for each, while there is still a choice to stop, trim or go on.

// OverrunThresholds are the multiples of its estimate an epic's spend is said at.
var OverrunThresholds = []int64{2, 3}

// Overrun is an epic's spend against its kept estimate, in one currency.
type Overrun struct {
	Epic     wire.LineageNode
	Currency string
	Spent    float64
	Estimate float64
	// Passed is the highest of OverrunThresholds that Spent is at or above, 0 for none.
	Passed int64
}

// EpicsOf is the epics a node's cost counts towards: an epic's own node (its lead), an issue's
// parent, and the parents of the issues a PR fixes.
func EpicsOf(byKey map[wire.LineageNode]wire.LineageCostNode, n wire.LineageNode) []wire.LineageNode {
	c, ok := byKey[n]
	if !ok {
		return nil
	}
	seen := map[wire.LineageNode]bool{}
	var out []wire.LineageNode
	add := func(ref string) {
		e := wire.LineageNode{Kind: KindIssue, Ref: ref}
		if !seen[e] {
			seen[e] = true
			out = append(out, e)
		}
	}
	switch n.Kind {
	case KindIssue:
		if c.Level != nil && *c.Level == "epic" {
			add(n.Ref)
		}
		if c.Parent != nil {
			add(*c.Parent)
		}
	case KindPR:
		for _, f := range c.Fixes {
			if i, ok := byKey[wire.LineageNode{Kind: KindIssue, Ref: f}]; ok && i.Parent != nil {
				add(*i.Parent)
			}
		}
	}
	return out
}

// OverrunOf is epic's overrun from nodes: its own cost and each child's (the issues whose parent
// it is, with their PRs), against the estimate kept on its node, in USD when it has one, else in
// the first currency by name. False when the epic is closed, has no epic's kept estimate (an
// issue's has a matchedBy), or nothing is spent in its currency.
func OverrunOf(nodes []wire.LineageCostNode, epic wire.LineageNode) (Overrun, bool) {
	var own *wire.LineageCostNode
	for i := range nodes {
		if nodes[i].Node == epic {
			own = &nodes[i]
			break
		}
	}
	if own == nil || own.Estimate == nil || own.Estimate.MatchedBy != nil {
		return Overrun{}, false
	}
	if r := own.Resolved; r != nil && r.State != nil && *r.State == "closed" {
		return Overrun{}, false
	}
	currencies := make([]string, 0, len(own.Estimate.Cost))
	for c, v := range own.Estimate.Cost {
		if v > 0 {
			currencies = append(currencies, c)
		}
	}
	if len(currencies) == 0 {
		return Overrun{}, false
	}
	sort.Slice(currencies, func(i, j int) bool {
		if (currencies[i] == "USD") != (currencies[j] == "USD") {
			return currencies[i] == "USD"
		}
		return currencies[i] < currencies[j]
	})
	currency := currencies[0]
	spent := Rollup(nodes, epic).Total.Cost[currency]
	for _, n := range nodes {
		if n.Node.Kind == KindIssue && n.Parent != nil && *n.Parent == epic.Ref && n.Node != epic {
			spent += Rollup(nodes, n.Node).Total.Cost[currency]
		}
	}
	if spent <= 0 {
		return Overrun{}, false
	}
	o := Overrun{Epic: epic, Currency: currency, Spent: spent, Estimate: own.Estimate.Cost[currency]}
	for _, t := range OverrunThresholds {
		if spent >= float64(t)*o.Estimate {
			o.Passed = t
		}
	}
	return o, true
}
