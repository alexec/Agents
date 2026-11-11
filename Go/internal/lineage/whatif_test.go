package lineage

import (
	"math"
	"strconv"
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// #4531: an hour with four issues in flight keeps half of its landings at two lanes, and all
// of them at four or more.
func TestLaneKeepClipsBusyHours(t *testing.T) {
	inFlight := []int{0, 1, 2, 4}
	if mean, peak := LanesOf(inFlight); peak != 4 || math.Abs(mean-7.0/3) > 1e-9 {
		t.Fatalf("%v %v", mean, peak)
	}
	keep := LaneKeep(inFlight, 2)
	if keep[0] != 1 || keep[1] != 1 || keep[2] != 1 || keep[3] != 0.5 {
		t.Fatalf("%v", keep)
	}
	if LaneKeep(inFlight, 0) != nil {
		t.Fatal("no limit keeps them all")
	}
	// Two landings in each of the last two hours: half of the busy hour's go.
	if p := Pace([]int{0, 0, 2, 2}, keep); p != 0.75 {
		t.Fatalf("%v", p)
	}
	if p := Pace([]int{0, 0, 2, 2}, LaneKeep(inFlight, 4)); p != 1 {
		t.Fatalf("%v", p)
	}
}

// #4531: each landing is in flight from its first work to its landing; an open issue to its
// last work; a closed issue with no landing and an epic never.
func TestInFlightCountsOpenWork(t *testing.T) {
	now := time.Date(2026, 11, 10, 12, 0, 0, 0, time.UTC)
	nodes := landedNodes(landed{n: 1, level: "task", at: now.Add(-time.Hour), cycle: 3 * 3600})
	start, last := wire.DateOf(now.Add(-2*time.Hour)), wire.DateOf(now.Add(-time.Hour))
	open, closed := "open", "closed"
	issue := func(n int, state *string, level string) wire.LineageCostNode {
		return wire.LineageCostNode{Node: wire.LineageNode{Kind: KindIssue, Ref: "github:o/r#" + strconv.Itoa(n)}, Repo: new("github:o/r"),
			Banked: blankCost(), StartedAt: &start, LastAt: last, Level: &level, Resolved: &wire.LineageResolved{State: state}}
	}
	nodes = append(nodes, issue(2, &open, "task"), issue(3, &closed, "task"), issue(4, &open, "epic"))
	bins := InFlight(nodes, Landings(nodes), "github:o/r", now)
	n := len(bins)
	// #1 from 4 hours ago to 1 hour ago; #2 from 2 hours ago to 1 hour ago.
	if bins[n-5] != 0 || bins[n-4] != 1 || bins[n-3] != 1 || bins[n-2] != 2 || bins[n-1] != 2 {
		t.Fatalf("%v", bins[n-6:])
	}
	if other := InFlight(nodes, nil, "github:o/other", now); other[n-2] != 0 {
		t.Fatalf("%v", other[n-6:])
	}
}

// #4531: a runtime's share is its part of the working hours, and its rate its cost an hour; a
// mix scales the dollars by its cost an hour over the window's.
func TestMixScalesTheDollars(t *testing.T) {
	r := RuntimesOf(map[string]float64{"claude": 30, "codex": 10, "idle": 0},
		map[string]map[string]float64{"claude": {"USD": 300}, "codex": {"USD": 20}})
	if len(r) != 2 || r[0].Runtime != "claude" || r[0].Share != 0.75 || r[0].Rate["USD"] != 10 || r[1].Rate["USD"] != 2 {
		t.Fatalf("%+v", r)
	}
	// The window's mix: $8 an hour. Half and half: $6 an hour.
	scaled, cost, ok := Mix(r, map[string]float64{"claude": 1, "codex": 1, "grok": 5})
	if !ok || scaled["claude"] != 0.5 || scaled["codex"] != 0.5 || len(scaled) != 2 || cost["USD"] != 0.75 {
		t.Fatalf("%v %v %v", scaled, cost, ok)
	}
	if _, _, ok := Mix(r, map[string]float64{"grok": 1}); ok {
		t.Fatal("a mix of none of the window's runtimes is no mix")
	}
}

// #4531: fewer lanes than were in flight move the epic's dates out and the spend down; as
// many as the most in flight move nothing; a mix moves the dollars and not the dates.
func TestForecastOfAWhatIf(t *testing.T) {
	now := time.Date(2026, 11, 10, 12, 0, 0, 0, time.UTC)
	var ls []landed
	n := 1
	// Two landings an hour for 20 days, each two hours in flight: four in flight an hour.
	for h := 1; h <= 20*24; h++ {
		for range 2 {
			ls = append(ls, landed{n: n, level: "task", at: now.Add(-time.Duration(h) * time.Hour), usd: 1, cycle: 2 * 3600})
			n++
		}
	}
	var extra []wire.LineageCostNode
	closed := "closed"
	for e := range 5 {
		ep := wire.LineageCostNode{Node: wire.LineageNode{Kind: KindIssue, Ref: "github:o/r#" + strconv.Itoa(9000+e)}, Repo: new("github:o/r"),
			Banked: blankCost(), Resolved: &wire.LineageResolved{Title: "epic", State: &closed, Labels: []string{"epic"}}}
		extra = append(extra, ep)
		for k := range 4 {
			ls = append(ls, landed{n: n, parent: ep.Node.Ref, level: "story", at: now.Add(-time.Duration(48*(e+1)+k) * time.Hour).Add(time.Minute), usd: 2, cycle: 3600})
			n++
		}
	}
	nodes := append(landedNodes(ls...), extra...)
	asked := wire.LineageNode{Kind: KindIssue, Ref: "github:o/r#9999"}
	var children []EpicChild
	for c := range 6 {
		children = append(children, EpicChild{Node: wire.LineageNode{Kind: KindIssue, Ref: "github:o/r#" + strconv.Itoa(9900+c)}, Step: 1, Open: true})
	}
	runtimes := RuntimesOf(map[string]float64{"claude": 30, "codex": 10}, map[string]map[string]float64{"claude": {"USD": 300}, "codex": {"USD": 20}})
	as := ForecastOf(nodes, &asked, true, children, now, WhatIf{Runtimes: runtimes})
	if as.Lands == nil || as.WhatIf != nil || as.Assumes == nil || as.Assumes.PeakLanes < 4 || len(as.Assumes.Runtimes) != 2 {
		t.Fatalf("%+v %+v", as, as.Assumes)
	}
	one := ForecastOf(nodes, &asked, true, children, now, WhatIf{Lanes: 1, Runtimes: runtimes})
	if one.WhatIf == nil || *one.WhatIf.Lanes != 1 || one.WhatIf.Pace >= 0.5 || one.WhatIf.Cost != 1 || one.Lands.P50 <= as.Lands.P50 ||
		one.Lands.P85 <= as.Lands.P85 || one.Spend.Week["USD"].Median >= as.Spend.Week["USD"].Median {
		t.Fatalf("%+v %+v, then %+v", as.Lands, as.Spend, one)
	}
	if KeepForecast(as) == nil {
		t.Fatal("the forecast as it ran is kept")
	}
	all := ForecastOf(nodes, &asked, true, children, now, WhatIf{Lanes: int(as.Assumes.PeakLanes), Runtimes: runtimes})
	if all.WhatIf.Pace != 1 || *all.Lands != *as.Lands {
		t.Fatalf("%+v, then %+v", as.Lands, all.Lands)
	}
	mixed := ForecastOf(nodes, &asked, true, children, now, WhatIf{Mix: map[string]float64{"claude": 1, "codex": 1}, Runtimes: runtimes})
	if mixed.WhatIf.Cost != 0.75 || mixed.WhatIf.Lanes != nil || *mixed.Lands != *as.Lands ||
		math.Abs(mixed.Spend.Week["USD"].Median-0.75*as.Spend.Week["USD"].Median) > 1e-9 {
		t.Fatalf("%+v %+v, then %+v", as.Spend, as.Lands, mixed)
	}
	if BurnPace(as, "claude") != 1 || math.Abs(BurnPace(mixed, "claude")-0.5/0.75) > 1e-9 || BurnPace(one, "codex") != one.WhatIf.Pace {
		t.Fatalf("%v %v", BurnPace(mixed, "claude"), BurnPace(one, "codex"))
	}
}
