package lineage

import (
	"reflect"
	"strconv"
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// #4620: a milestone's landing date is method H on its repo's last 14 days, with the closed
// milestones' share, on its open items in the store; an epic in it is no item; with less than
// half of its items done, it says the scope is still growing.
func TestMilestoneForecastOf(t *testing.T) {
	now := time.Date(2026, 11, 10, 12, 0, 0, 0, time.UTC)
	var ls []landed
	milestones := map[int]string{}
	n := 1
	// One landing an hour for 20 days, in no milestone.
	for h := 1; h <= 20*24; h++ {
		ls = append(ls, landed{n: n, level: "task", at: now.Add(-time.Duration(h) * time.Hour), usd: 1, cycle: 3600})
		n++
	}
	// Five closed milestones, four items each, landed in their own four hours.
	for m := range 5 {
		for k := range 4 {
			ls = append(ls, landed{n: n, level: "story", at: now.Add(-time.Duration(48*(m+1)+k) * time.Hour).Add(time.Minute), usd: 2, cycle: 7200})
			milestones[n] = "Theme " + strconv.Itoa(m)
			n++
		}
	}
	// The milestone asked for: one item landed.
	ls = append(ls, landed{n: n, level: "story", at: now.Add(-time.Hour).Add(time.Minute), usd: 2, cycle: 7200})
	milestones[n] = "Next"
	nodes := landedNodes(ls...)
	for i, c := range nodes {
		if c.Node.Kind != KindIssue {
			continue
		}
		num, _ := strconv.Atoi(c.Node.Ref[len("github:o/r#"):])
		if m, ok := milestones[num]; ok {
			nodes[i].Milestone = new(m)
		}
	}
	open := "open"
	item := func(num int, level string) wire.LineageCostNode {
		ref := "github:o/r#" + strconv.Itoa(num)
		return wire.LineageCostNode{Node: wire.LineageNode{Kind: KindIssue, Ref: ref}, Repo: new("github:o/r"), Banked: blankCost(),
			Level: new(level), Milestone: new("next"), Resolved: &wire.LineageResolved{Title: ref, State: &open, Labels: []string{level}}}
	}
	nodes = append(nodes, item(90001, "task"), item(90002, "task"), item(90003, "story"), item(90004, "epic"))

	f := MilestoneForecastOf(nodes, "Next", "github:o/r", now, WhatIf{})
	if f.NoForecast != nil || f.Lands == nil || f.Milestone == nil || *f.Milestone != "Next" || f.Node != nil {
		t.Fatalf("%+v", f)
	}
	l := f.Lands
	if l.Groups != 5 || l.Share < 0.3 || l.Share > 0.5 || l.Open != 3 || l.Closed != 1 || l.StepsLeft != 0 ||
		l.Growing == nil || !*l.Growing || l.P50 > l.P85 || l.P50 <= f.At {
		t.Fatalf("%+v %+v", f, l)
	}
	// Without a repo it is the repo its items are in: the same dates.
	if g := MilestoneForecastOf(nodes, "next", "", now, WhatIf{}); g.Lands == nil || !reflect.DeepEqual(*g.Lands, *l) {
		t.Fatalf("%+v, then %+v", l, g.Lands)
	}
	// Two of the open items closed: half are done, so the scope is no longer growing.
	done := append([]wire.LineageCostNode{}, nodes...)
	closed := "closed"
	for _, i := range []int{len(done) - 4, len(done) - 3} {
		r := *done[i].Resolved
		r.State = &closed
		done[i].Resolved = &r
	}
	if g := MilestoneForecastOf(done, "Next", "github:o/r", now, WhatIf{}); g.Lands == nil || g.Lands.Open != 1 || g.Lands.Closed != 3 || *g.Lands.Growing {
		t.Fatalf("%+v", g)
	}

	for _, c := range []struct {
		name, repo, why string
		nodes           []wire.LineageCostNode
	}{
		{"Later", "github:o/r", NoForecastNoItems, nodes},
		{"Next", "github:o/other", NoForecastNoItems, nodes},
		{"Theme 0", "github:o/r", NoForecastNoneOpen, nodes},
		// Four closed milestones are too few: one of Theme 4's items is open again.
		{"Next", "github:o/r", NoForecastMilestones, append(append([]wire.LineageCostNode{}, nodes...), func() wire.LineageCostNode {
			c := item(90005, "task")
			c.Milestone = new("Theme 4")
			return c
		}())},
	} {
		if g := MilestoneForecastOf(c.nodes, c.name, c.repo, now, WhatIf{}); g.NoForecast == nil || *g.NoForecast != c.why || g.Lands != nil {
			t.Fatalf("%s in %s: %+v", c.name, c.repo, g)
		}
	}
}
