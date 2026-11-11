package lineage

import (
	"sort"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// The overhead (#4524): the cost that no issue, PR or release carries (a Scrum Master's turn
// that started nothing, a review, a check), and an epic's own cost (its lead's), measured over
// a rolling window so an estimate can say what the work costs all in: "direct $100, about $165
// all in". People's time and CI minutes are in no figure; Uncounted names them.

// OverheadWindow is the overhead's rolling window.
const OverheadWindow = 14 * 24 * time.Hour

// What no figure counts.
const (
	UncountedPeopleTime = "people-time"
	UncountedCIMinutes  = "ci-minutes"
)

// Overhead is the overhead of nodes that last changed in the OverheadWindow to now: the
// sessions' cost over the issues', PRs' and releases', and the epics' own cost over their
// children's, each child with the PRs that fix it. An epic is an issue labelled epic, or one
// another issue names as its parent. Each ratio is in the currency with the most linked cost,
// and absent when there is nothing to divide by.
func Overhead(nodes []wire.LineageCostNode, now time.Time) wire.LineageOverhead {
	since := wire.DateOf(now.Add(-OverheadWindow))
	o := wire.LineageOverhead{WindowDays: int64(OverheadWindow / (24 * time.Hour)), Linked: blankCost(), Unlinked: blankCost(),
		Uncounted: []string{UncountedPeopleTime, UncountedCIMinutes}}
	fixers := map[string][]wire.LineageCostNode{}
	epics := map[string]bool{}
	lastAt := map[string]wire.Date{}
	for _, n := range nodes {
		switch n.Node.Kind {
		case KindPR:
			for _, f := range n.Fixes {
				fixers[f] = append(fixers[f], n)
			}
		case KindIssue:
			lastAt[n.Node.Ref] = n.LastAt
			if n.Level != nil && *n.Level == "epic" {
				epics[n.Node.Ref] = true
			}
			if n.Parent != nil {
				epics[*n.Parent] = true
			}
		}
	}
	own, children := blankCost(), blankCost()
	for _, n := range nodes {
		if n.LastAt < since {
			continue
		}
		switch n.Node.Kind {
		case KindSession:
			AddCost(&o.Unlinked, n.Banked)
		case KindIssue, KindPR, KindRelease:
			AddCost(&o.Linked, n.Banked)
		}
		if n.Node.Kind == KindIssue && epics[n.Node.Ref] {
			AddCost(&own, n.Banked)
		}
	}
	// Each epic changed in the window, against all its children, whenever they changed.
	for _, n := range nodes {
		if n.Node.Kind != KindIssue || n.Parent == nil || epics[n.Node.Ref] {
			continue
		}
		if at, ok := lastAt[*n.Parent]; !ok || at < since {
			continue
		}
		AddCost(&children, n.Banked)
		for _, pr := range fixers[n.Node.Ref] {
			AddCost(&children, pr.Banked)
		}
	}
	currency := mainCurrency(o.Linked)
	if currency == "" {
		return o
	}
	o.Currency = &currency
	if linked := o.Linked.Cost[currency]; linked > 0 {
		r := o.Unlinked.Cost[currency] / linked
		o.UnlinkedRatio = &r
	}
	if c := children.Cost[currency]; c > 0 {
		r := own.Cost[currency] / c
		o.EpicRatio = &r
	}
	return o
}

// mainCurrency is the currency c has most of; none when it has none.
func mainCurrency(c wire.LineageCost) string {
	keys := make([]string, 0, len(c.Cost))
	for k := range c.Cost {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	best := ""
	for _, k := range keys {
		if c.Cost[k] > 0 && (best == "" || c.Cost[k] > c.Cost[best]) {
			best = k
		}
	}
	return best
}

// LoadFactor is what a direct figure is times all in: 1 + the unlinked ratio, and for an
// epic's plan, which leaves its lead out, times 1 + the epic ratio. Not ok without an
// unlinked ratio.
func LoadFactor(o wire.LineageOverhead, epic bool) (float64, bool) {
	if o.UnlinkedRatio == nil {
		return 0, false
	}
	f := 1 + *o.UnlinkedRatio
	if epic && o.EpicRatio != nil {
		f *= 1 + *o.EpicRatio
	}
	return f, true
}

// Load puts on e its cost loaded with o, and o (#4524). An epic's cost is its open children's
// only, so it is loaded with the epic ratio too.
func Load(e *wire.LineageEstimate, o wire.LineageOverhead, epic bool) {
	e.Overhead = &o
	f, ok := LoadFactor(o, epic)
	if !ok || len(e.Cost) == 0 {
		return
	}
	e.Loaded = map[string]wire.LineageEstimateRange{}
	for k, r := range e.Cost {
		e.Loaded[k] = wire.LineageEstimateRange{Median: r.Median * f, P10: r.P10 * f, P90: r.P90 * f}
	}
}
