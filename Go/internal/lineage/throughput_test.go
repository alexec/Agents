package lineage

import (
	"math"
	"slices"
	"strconv"
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// landed is an issue of github:o/r that landed at with a merged PR costing usd, under parent
// (none for ""), with level and a cycle time of cycle.
type landed struct {
	n          int
	parent     string
	level      string
	at         time.Time
	usd, cycle float64
}

func landedNodes(ls ...landed) []wire.LineageCostNode {
	closed, merged := "closed", OutcomeMerged
	var out []wire.LineageCostNode
	for _, l := range ls {
		ref := "github:o/r#" + strconv.Itoa(l.n)
		start, end := wire.DateOf(l.at.Add(-time.Duration(l.cycle*float64(time.Second)))), wire.DateOf(l.at)
		level := l.level
		c := wire.LineageCostNode{Node: wire.LineageNode{Kind: KindIssue, Ref: ref}, Repo: new("github:o/r"), Banked: blankCost(),
			StartedAt: &start, Level: &level, Resolved: &wire.LineageResolved{Title: ref, State: &closed, Labels: []string{"enhancement", level}}}
		if l.parent != "" {
			p := l.parent
			c.Parent = &p
		}
		pr := wire.LineageCostNode{Node: wire.LineageNode{Kind: KindPR, Ref: "github:o/r#" + strconv.Itoa(100000+l.n)}, Repo: new("github:o/r"),
			Banked: wire.LineageCost{Cost: map[string]float64{"USD": l.usd}}, Fixes: []string{ref}, Outcome: &merged, EndedAt: &end}
		out = append(out, c, pr)
	}
	return out
}

// #4526: with one landing an hour, all of them the epic's, six open children take six hours.
func TestLandsInCountsHours(t *testing.T) {
	bins := make([]int, 24)
	for i := range bins {
		bins[i] = 1
	}
	p50, p85, ok := LandsIn(bins, nil, 1, 6, Rng("x"))
	if !ok || p50 != 6 || p85 != 6 {
		t.Fatalf("%v %v %v", p50, p85, ok)
	}
	// Half of them: about twelve hours, later at P85.
	p50, p85, ok = LandsIn(bins, nil, 0.5, 6, Rng("x"))
	if !ok || p50 < 9 || p50 > 15 || p85 < p50 {
		t.Fatalf("%v %v %v", p50, p85, ok)
	}
	if _, _, ok = LandsIn(make([]int, 24), nil, 1, 1, Rng("x")); ok {
		t.Fatal("no landings should never finish")
	}
}

// #4526: an epic's landing date is method H on the repo's last 14 days, with the share of the
// closed epics; without enough of them, or of history, it says why.
func TestForecastOfAnEpic(t *testing.T) {
	now := time.Date(2026, 11, 10, 12, 0, 0, 0, time.UTC)
	var ls []landed
	n := 1
	// One landing an hour for 20 days, no epic's.
	for h := 1; h <= 20*24; h++ {
		ls = append(ls, landed{n: n, level: "task", at: now.Add(-time.Duration(h) * time.Hour), usd: 1, cycle: 3600})
		n++
	}
	// Five closed epics, four children each, landed in their own four hours.
	epicNode := func(e int) wire.LineageCostNode {
		closed := "closed"
		return wire.LineageCostNode{Node: wire.LineageNode{Kind: KindIssue, Ref: "github:o/r#" + strconv.Itoa(9000+e)}, Repo: new("github:o/r"),
			Banked: blankCost(), Resolved: &wire.LineageResolved{Title: "epic", State: &closed, Labels: []string{"epic"}}}
	}
	var extra []wire.LineageCostNode
	for e := range 5 {
		ep := epicNode(e)
		extra = append(extra, ep)
		for k := range 4 {
			ls = append(ls, landed{n: n, parent: ep.Node.Ref, level: "story", at: now.Add(-time.Duration(48*(e+1)+k) * time.Hour).Add(time.Minute), usd: 2, cycle: 7200})
			n++
		}
	}
	nodes := append(landedNodes(ls...), extra...)
	asked := wire.LineageNode{Kind: KindIssue, Ref: "github:o/r#9999"}
	children := []EpicChild{
		{Node: wire.LineageNode{Kind: KindIssue, Ref: "github:o/r#9990"}, Step: 1, Open: true},
		{Node: wire.LineageNode{Kind: KindIssue, Ref: "github:o/r#9991"}, Step: 2, Open: true},
		{Node: wire.LineageNode{Kind: KindIssue, Ref: "github:o/r#9992"}, Step: 2, Open: true},
	}
	f := ForecastOf(nodes, &asked, true, children, now, WhatIf{})
	if f.NoForecast != nil || f.Lands == nil {
		t.Fatalf("%+v", f)
	}
	l := f.Lands
	// Each epic's four of the nine landings in its hours.
	if l.Groups != 5 || l.Share < 0.3 || l.Share > 0.5 || l.Open != 3 || l.Closed != 0 || l.StepsLeft != 2 || l.P50 > l.P85 ||
		l.P50 <= f.At || f.WindowDays != 14 || f.Landings < 14*24 {
		t.Fatalf("%+v %+v", f, l)
	}
	if k := KeepForecast(f); k == nil || k.P50 != l.P50 || k.Open != 3 || k.Share != l.Share {
		t.Fatalf("%+v", k)
	}
	// The same history gives the same dates.
	if g := ForecastOf(nodes, &asked, true, children, now, WhatIf{}); *g.Lands != *l {
		t.Fatalf("%+v, then %+v", l, g.Lands)
	}
	// The service levels: tasks took an hour, stories two.
	if len(f.ServiceLevels) != 2 || f.ServiceLevels[0].Level != "story" || f.ServiceLevels[0].P85Seconds != 7200 ||
		f.ServiceLevels[1].Level != "task" || f.ServiceLevels[1].P50Seconds != 3600 {
		t.Fatalf("%+v", f.ServiceLevels)
	}
	// Four closed epics are too few: the last is open again.
	reopened := slices.Clone(nodes)
	open := "open"
	last := reopened[len(reopened)-1]
	last.Resolved = &wire.LineageResolved{Title: "epic", State: &open}
	reopened[len(reopened)-1] = last
	if g := ForecastOf(reopened, &asked, true, children, now, WhatIf{}); g.Lands != nil || *g.NoForecast != NoForecastGroups {
		t.Fatalf("%+v", g)
	}
	// Six days of history are too little.
	if g := ForecastOf(nodes, &asked, true, children, now.Add(-15*24*time.Hour), WhatIf{}); g.Lands != nil || *g.NoForecast != NoForecastHistory {
		t.Fatalf("%+v", g)
	}
	for _, c := range []struct {
		isEpic   bool
		children []EpicChild
		why      string
	}{{false, nil, NoForecastNotEpic}, {true, []EpicChild{{Node: children[0].Node}}, NoForecastNothing}} {
		if g := ForecastOf(nodes, &asked, c.isEpic, c.children, now, WhatIf{}); g.Lands != nil || *g.NoForecast != c.why {
			t.Fatalf("%+v", g)
		}
	}
	// No node: the spend and the service levels only.
	if g := ForecastOf(nodes, nil, false, nil, now, WhatIf{}); g.Lands != nil || g.NoForecast != nil || g.Spend == nil || len(g.ServiceLevels) != 2 {
		t.Fatalf("%+v", g)
	}
}

// #4526: a week and a month at the window's pace: $1 a day is $7 and $30.
func TestSpendDrawsDays(t *testing.T) {
	now := time.Date(2026, 11, 10, 12, 0, 0, 0, time.UTC)
	var ls []landed
	for d := range 20 {
		ls = append(ls, landed{n: d + 1, level: "task", at: now.Add(-time.Duration(d)*24*time.Hour - time.Hour), usd: 1})
	}
	s := Spend(Landings(landedNodes(ls...)), now, nil)
	if s == nil || s.Week["USD"].Median != 7 || s.Week["USD"].P90 != 7 || s.Month["USD"].Median != 30 {
		t.Fatalf("%+v", s)
	}
}

// #4526: the closed children's actual over their kept estimate scales the open ones, and the
// lead's share of the closed children's cost is added.
func TestToCompleteScalesTheOpenChildren(t *testing.T) {
	epic := wire.LineageNode{Kind: KindIssue, Ref: "github:o/r#500"}
	now := time.Now()
	var ls []landed
	for i := 1; i <= 5; i++ {
		ls = append(ls, landed{n: i, level: "task", at: now, usd: 1})
	}
	// Three closed children: $2 estimated each, $4 spent.
	for i := 10; i < 13; i++ {
		ls = append(ls, landed{n: i, parent: epic.Ref, level: "task", at: now, usd: 4})
	}
	nodes := landedNodes(ls...)
	for i := range nodes {
		if n := nodes[i]; n.Parent != nil {
			nodes[i].Estimate = &wire.LineageEstimateKept{Cost: map[string]float64{"USD": 2}}
		}
	}
	// The lead spent $6 of its own: half the children's $12.
	nodes = append(nodes, wire.LineageCostNode{Node: epic, Banked: wire.LineageCost{Cost: map[string]float64{"USD": 6}}})
	children := []EpicChild{{Node: wire.LineageNode{Kind: KindIssue, Ref: "github:o/r#20"}, Labels: []string{"enhancement", "task"}, Open: true}}
	for i := 10; i < 13; i++ {
		children = append(children, EpicChild{Node: wire.LineageNode{Kind: KindIssue, Ref: "github:o/r#" + strconv.Itoa(i)}})
	}
	history := History(nodes)
	tc := ToComplete(history, nodes, epic, children)
	// The open child is like the $1 tasks (and the $4 ones): its draws are scaled by 2, then by 1.5.
	near := func(a, b float64) bool { return math.Abs(a-b) < 1e-9 }
	if tc == nil || !near(tc.Ratio, 2) || tc.Closed != 3 || tc.LeadRatio != 0.5 || !near(tc.Cost["USD"].P10, 3) || !near(tc.Cost["USD"].P90, 12) {
		t.Fatalf("%+v", tc)
	}
	// Two closed children are too few.
	if tc := ToComplete(history, nodes, epic, children[:3]); tc != nil {
		t.Fatalf("%+v", tc)
	}
}
