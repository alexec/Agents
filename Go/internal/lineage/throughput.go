package lineage

import (
	"math"
	"math/rand/v2"
	"slices"
	"sort"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// lineage/forecast (#4526; the method is the #4523 spike's, specs/4533-forecasting/spec.md):
//
//   - A landing is an issue (not an epic) that landed with a merged PR: History's issues.
//   - When an epic lands is method H: ThroughputDraws draws, each resampling hours of the last
//     ThroughputWindow and keeping each landing in an hour with the chance share, counting hours
//     until the open children are done. P50 and P85, no P10. The share is the median of the
//     closed epics' shares: a group's landings over all of its repo's landings from its start
//     to its last landing. No step floor and no growth: the open children as filed.
//   - The estimate to complete scales each open child's drawn cost by one lognormal factor per
//     draw, from the closed children's actual over their kept estimates, and adds the lead's term.
//   - A week's and a month's spend resample the window's days; service levels are each level's
//     P50 and P85 cycle time in the window.

const (
	// ThroughputWindow is how far back the throughput, the spend and the service levels look.
	ThroughputWindow = 14 * 24 * time.Hour
	// ThroughputMinHistory is the least history a forecast is made from.
	ThroughputMinHistory = 7 * 24 * time.Hour
	// ThroughputMinGroups is the fewest closed epics a share is made from.
	ThroughputMinGroups = 5
	// ThroughputDraws is each simulation's draws.
	ThroughputDraws = 1000
	// ToCompleteMinClosed is the fewest closed children with a kept estimate that scale the open ones.
	ToCompleteMinClosed = 3
	// ServiceLevelMin is the fewest issues of a level that make its service level.
	ServiceLevelMin = 5
	// throughputMaxHours stops a draw that would never finish: a year.
	throughputMaxHours = 365 * 24
)

// Why there is no landing date.
const (
	NoForecastNotEpic   = "not an epic"
	NoForecastNothing   = "no open children"
	NoForecastHistory   = "less than 7 days of landings"
	NoForecastGroups    = "fewer than 5 closed epics"
	NoForecastNoLanding = "no landings in the window"
	NoForecastTooSlow   = "more than a year at this pace"
)

// Landing is an issue that landed: History's, with its repo, epic, milestone and level.
type Landing struct {
	Past
	Repo, Parent, Milestone string
	At                      time.Time
}

// Landings is the issues in nodes that landed with a merged PR, no epic (labelled one, or
// another issue's parent), oldest first.
func Landings(nodes []wire.LineageCostNode) []Landing {
	byRef := map[string]wire.LineageCostNode{}
	parents := map[string]bool{}
	for _, n := range nodes {
		byRef[n.Node.Ref] = n
		if n.Parent != nil {
			parents[*n.Parent] = true
		}
	}
	var out []Landing
	for _, p := range History(nodes) {
		if parents[p.Ref] {
			continue
		}
		n := byRef[p.Ref]
		l := Landing{Past: p, Repo: deref(n.Repo), At: p.Merged.Time()}
		if n.Parent != nil {
			l.Parent = *n.Parent
		}
		l.Milestone = deref(n.Milestone)
		out = append(out, l)
	}
	slices.SortStableFunc(out, func(a, b Landing) int { return a.At.Compare(b.At) })
	return out
}

// inRepo is the landings in repo; all of them for "".
func inRepo(landings []Landing, repo string) []Landing {
	if repo == "" {
		return landings
	}
	var out []Landing
	for _, l := range landings {
		if SameRepo(l.Repo, repo) {
			out = append(out, l)
		}
	}
	return out
}

// EpicShares is the share of the closed epics in nodes (not not): each one's landings over all
// of its repo's landings from its start (the first work on it or a child, else its first
// landing) to its last landing, by the hour.
func EpicShares(nodes []wire.LineageCostNode, landings []Landing, not string) []float64 {
	byRef := map[string]wire.LineageCostNode{}
	kids := map[string][]wire.LineageCostNode{}
	for _, n := range nodes {
		byRef[n.Node.Ref] = n
		if n.Parent != nil {
			kids[*n.Parent] = append(kids[*n.Parent], n)
		}
	}
	items := map[string][]Landing{}
	for _, l := range landings {
		if l.Parent != "" {
			items[l.Parent] = append(items[l.Parent], l)
		}
	}
	closed := func(n wire.LineageCostNode) bool {
		return n.Resolved != nil && n.Resolved.State != nil && *n.Resolved.State == "closed"
	}
	refs := make([]string, 0, len(kids))
	for ref := range kids {
		refs = append(refs, ref)
	}
	sort.Strings(refs)
	var shares []float64
	for _, ref := range refs {
		mine := items[ref]
		if ref == not || len(mine) == 0 {
			continue
		}
		epic, have := byRef[ref]
		if have && !closed(epic) {
			continue
		}
		if !have && slices.ContainsFunc(kids[ref], func(n wire.LineageCostNode) bool { return !closed(n) }) {
			continue
		}
		starts := kids[ref]
		if have {
			starts = append(slices.Clone(starts), epic)
		}
		if share, ok := groupShare(mine, starts, landings); ok {
			shares = append(shares, share)
		}
	}
	return shares
}

// groupShare is a group's landings, mine, over all of its repo's landings from its start (the
// first work on one of starts, else its first landing) to its last landing, by the hour.
func groupShare(mine []Landing, starts []wire.LineageCostNode, landings []Landing) (float64, bool) {
	start, end := mine[0].At, mine[0].At
	for _, l := range mine {
		start, end = minTime(start, l.At), laterOf(end, l.At)
	}
	for _, n := range starts {
		if s := StartOf(n); s != nil {
			start = minTime(start, s.Time())
		}
	}
	start, end = start.Truncate(time.Hour), end.Truncate(time.Hour).Add(time.Hour)
	all := 0
	for _, l := range inRepo(landings, mine[0].Repo) {
		if !l.At.Before(start) && l.At.Before(end) {
			all++
		}
	}
	if all == 0 {
		return 0, false
	}
	return float64(len(mine)) / float64(all), true
}

func minTime(a, b time.Time) time.Time {
	if b.Before(a) {
		return b
	}
	return a
}

func laterOf(a, b time.Time) time.Time {
	if b.After(a) {
		return b
	}
	return a
}

func deref(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

// HourBins is the landings in each hour of the ThroughputWindow before now, oldest first. ok is
// false with less than ThroughputMinHistory of landings before now.
func HourBins(landings []Landing, now time.Time) ([]int, bool) {
	since := now.Add(-ThroughputWindow)
	bins := make([]int, int(ThroughputWindow/time.Hour))
	first := now
	for _, l := range landings {
		if !l.At.Before(now) {
			continue
		}
		first = minTime(first, l.At)
		if !l.At.Before(since) {
			bins[int(l.At.Sub(since)/time.Hour)]++
		}
	}
	return bins, now.Sub(first) >= ThroughputMinHistory
}

// LandsIn is how many hours from now open items take, P50 and P85, by method H: each draw
// resamples hours of bins and keeps each landing in one with the chance share, times keep's
// for the hour (a what-if's lanes, #4531; nil keeps them all). ok is false when P85 is past
// throughputMaxHours.
func LandsIn(bins []int, keep []float64, share float64, open int, rng *rand.Rand) (p50, p85 float64, ok bool) {
	hours := make([]float64, ThroughputDraws)
	for i := range hours {
		done, h := 0, 0
		for done < open && h < throughputMaxHours {
			b := rng.IntN(len(bins))
			chance := share * keepAt(keep, b)
			for range bins[b] {
				if rng.Float64() < chance {
					done++
				}
			}
			h++
		}
		hours[i] = float64(h)
	}
	slices.Sort(hours)
	p50, p85 = hours[ThroughputDraws/2], hours[ThroughputDraws*85/100]
	return p50, p85, p85 < throughputMaxHours
}

// ForecastOf is lineage/forecast from nodes at now: for an epic (with its plan's children), when
// it lands and its estimate to complete; always the spend, the service levels and what the
// window assumes. With a what-if (#4531), its lanes move the dates and the spend, and its mix
// the dollars. The burn is the allowances', not the store's: the daemon adds it.
func ForecastOf(nodes []wire.LineageCostNode, epic *wire.LineageNode, isEpic bool, children []EpicChild, now time.Time, w WhatIf) wire.LineageForecast {
	all := Landings(nodes)
	repo := ""
	if epic != nil {
		repo = repoOf(nodes, *epic, children)
	}
	f, bins, enough, wi := forecastIn(nodes, inRepo(all, repo), repo, now, w)
	f.Node = epic
	if epic == nil {
		return f
	}
	no := func(why string) wire.LineageForecast {
		f.NoForecast = &why
		return f
	}
	if !isEpic {
		return no(NoForecastNotEpic)
	}
	f.ToComplete = ToComplete(History(nodes), nodes, *epic, children)
	if f.ToComplete != nil && wi.cost != nil {
		f.ToComplete.Cost = scaleRanges(f.ToComplete.Cost, wi.cost)
	}
	var open, closed int64
	steps := map[int64]bool{}
	for _, c := range children {
		if c.Open {
			open++
			steps[c.Step] = true
		} else {
			closed++
		}
	}
	shares := EpicShares(nodes, all, epic.Ref)
	switch {
	case open == 0:
		return no(NoForecastNothing)
	case !enough:
		return no(NoForecastHistory)
	case len(shares) < ThroughputMinGroups:
		return no(NoForecastGroups)
	case f.Landings == 0:
		return no(NoForecastNoLanding)
	}
	share := median(shares)
	p50, p85, ok := LandsIn(bins, wi.keep, share, int(open), Rng("lands:"+epic.Ref))
	if !ok {
		return no(NoForecastTooSlow)
	}
	at := func(h float64) wire.Date { return wire.DateOf(now.Add(time.Duration(h * float64(time.Hour)))) }
	f.Lands = &wire.LineageForecastLands{P50: at(p50), P85: at(p85), Open: open, Closed: closed,
		StepsLeft: int64(len(steps)), Share: share, Groups: int64(len(shares))}
	return f
}

// forecastIn is what every forecast says from landings (of nodes, in repo) at now: the
// window's landings, the service levels, what the window assumes (#4531) and, with enough
// history, the spend; and the window's hours. With a what-if, the spend is the what-if's, and
// wi is what the dates and the estimate to complete take from it.
func forecastIn(nodes []wire.LineageCostNode, landings []Landing, repo string, now time.Time, w WhatIf) (f wire.LineageForecast, bins []int, enough bool, wi whatIfIn) {
	f = wire.LineageForecast{At: wire.DateOf(now), WindowDays: int64(ThroughputWindow / (24 * time.Hour)),
		Burn: []wire.LineageForecastBurn{}, ServiceLevels: ServiceLevels(landings, now)}
	bins, enough = HourBins(landings, now)
	for _, n := range bins {
		f.Landings += int64(n)
	}
	inFlight := InFlight(nodes, landings, repo, now)
	lanes, peak := LanesOf(inFlight)
	f.Assumes = &wire.LineageForecastAssumes{Lanes: lanes, PeakLanes: int64(peak), Runtimes: w.Runtimes}
	if f.Assumes.Runtimes == nil {
		f.Assumes.Runtimes = []wire.LineageForecastRuntime{}
	}
	if w.Asked() {
		wi.keep = LaneKeep(inFlight, w.Lanes)
		f.WhatIf = &wire.LineageForecastWhatIfEffect{Pace: Pace(bins, wi.keep), Cost: 1}
		if wi.keep != nil {
			lanes := int64(w.Lanes)
			f.WhatIf.Lanes = &lanes
		}
		if mix, c, ok := Mix(w.Runtimes, w.Mix); ok {
			f.WhatIf.Mix, wi.cost, f.WhatIf.Cost = mix, c, costFactor(c)
		}
	}
	if enough {
		f.Spend = Spend(landings, now, wi.keep)
		if f.Spend != nil && wi.cost != nil {
			f.Spend.Week, f.Spend.Month = scaleRanges(f.Spend.Week, wi.cost), scaleRanges(f.Spend.Month, wi.cost)
		}
	}
	return f, bins, enough, wi
}

// whatIfIn is what a what-if gives the dates and the dollars: each hour's landings kept, and
// the cost by currency; nil for as the window ran.
type whatIfIn struct {
	keep []float64
	cost map[string]float64
}

// repoOf is the repo of an epic: its node's, else a child's; "" when the store has neither.
func repoOf(nodes []wire.LineageCostNode, epic wire.LineageNode, children []EpicChild) string {
	in := map[wire.LineageNode]bool{}
	for _, c := range children {
		in[c.Node] = true
	}
	repo := ""
	for _, n := range nodes {
		r := deref(n.Repo)
		if r == "" {
			continue
		}
		if n.Node == epic {
			return r
		}
		if in[n.Node] && repo == "" {
			repo = r
		}
	}
	return repo
}

// KeepForecast is f's landing dates as kept on the epic's node; nil without them.
func KeepForecast(f wire.LineageForecast) *wire.LineageForecastKept {
	if f.Lands == nil {
		return nil
	}
	return &wire.LineageForecastKept{At: f.At, P50: f.Lands.P50, P85: f.Lands.P85, WindowDays: f.WindowDays,
		Share: f.Lands.Share, Open: f.Lands.Open}
}

// ToComplete is an epic's estimate to complete, by currency: nil with fewer than
// ToCompleteMinClosed closed children whose kept estimate and actual cost are known in a
// currency, or no open child.
func ToComplete(history []Past, nodes []wire.LineageCostNode, epic wire.LineageNode, children []EpicChild) *wire.LineageForecastToComplete {
	byNode := map[wire.LineageNode]wire.LineageCostNode{}
	for _, n := range nodes {
		byNode[n.Node] = n
	}
	logs := map[string][]float64{}
	actuals := map[string]float64{}
	var open [][]Past
	for _, c := range children {
		if c.Open {
			_, matches := issueEstimate(history, c.Node, c.Labels)
			open = append(open, matches)
			continue
		}
		n, ok := byNode[c.Node]
		if !ok || n.Estimate == nil {
			continue
		}
		actual := Rollup(nodes, c.Node).Total.Cost
		for currency, kept := range n.Estimate.Cost {
			if a := actual[currency]; kept > 0 && a > 0 {
				logs[currency] = append(logs[currency], math.Log(a/kept))
				actuals[currency] += a
			}
		}
	}
	if len(open) == 0 {
		return nil
	}
	currencies := make([]string, 0, len(logs))
	for currency, l := range logs {
		if len(l) >= ToCompleteMinClosed {
			currencies = append(currencies, currency)
		}
	}
	sort.Strings(currencies)
	if len(currencies) == 0 {
		return nil
	}
	t := &wire.LineageForecastToComplete{Cost: map[string]wire.LineageEstimateRange{}}
	own := byNode[epic].Banked.Cost
	for _, currency := range currencies {
		costs := make([][]float64, 0, len(open))
		for _, matches := range open {
			var v []float64
			for _, m := range matches {
				if c, ok := m.Cost.Cost[currency]; ok {
					v = append(v, c)
				}
			}
			if len(v) < EstimateMinMatches {
				costs = nil
				break
			}
			costs = append(costs, v)
		}
		if costs == nil {
			continue
		}
		mu, sigma := meanSD(logs[currency])
		lead := own[currency] / actuals[currency]
		rng := Rng("complete:" + currency + ":" + epic.Ref)
		sums := make([]float64, ThroughputDraws)
		for i := range sums {
			factor := math.Exp(mu + sigma*rng.NormFloat64())
			for _, v := range costs {
				sums[i] += v[rng.IntN(len(v))] * factor
			}
			sums[i] *= 1 + lead
		}
		t.Cost[currency] = *rangeOf(sums)
		if t.Closed == 0 || currency == "USD" {
			t.Ratio, t.Closed, t.LeadRatio = math.Exp(mu), int64(len(logs[currency])), lead
		}
	}
	if len(t.Cost) == 0 {
		return nil
	}
	return t
}

// meanSD is the mean and the sample standard deviation of v.
func meanSD(v []float64) (float64, float64) {
	mean := 0.0
	for _, x := range v {
		mean += x
	}
	mean /= float64(len(v))
	if len(v) < 2 {
		return mean, 0
	}
	ss := 0.0
	for _, x := range v {
		ss += (x - mean) * (x - mean)
	}
	return mean, math.Sqrt(ss / float64(len(v)-1))
}

// Spend is what 7 and 30 of the window's days cost, drawn ThroughputDraws times: a day's cost is
// what the issues that landed on it took, each times keep's for its hour (a what-if's lanes,
// #4531; nil keeps them all). Nil when no landing in the window had a cost.
func Spend(landings []Landing, now time.Time, keep []float64) *wire.LineageForecastSpend {
	since := now.Add(-ThroughputWindow)
	days := int(ThroughputWindow / (24 * time.Hour))
	byDay := map[string][]float64{}
	for _, l := range landings {
		if l.At.Before(since) || !l.At.Before(now) {
			continue
		}
		for currency, v := range l.Cost.Cost {
			if byDay[currency] == nil {
				byDay[currency] = make([]float64, days)
			}
			byDay[currency][int(l.At.Sub(since)/(24*time.Hour))] += v * keepAt(keep, int(l.At.Sub(since)/time.Hour))
		}
	}
	if len(byDay) == 0 {
		return nil
	}
	s := &wire.LineageForecastSpend{Week: map[string]wire.LineageEstimateRange{}, Month: map[string]wire.LineageEstimateRange{}}
	for currency, perDay := range byDay {
		draw := func(n int, into map[string]wire.LineageEstimateRange) {
			rng := Rng("spend:" + currency)
			sums := make([]float64, ThroughputDraws)
			for i := range sums {
				for range n {
					sums[i] += perDay[rng.IntN(len(perDay))]
				}
			}
			into[currency] = *rangeOf(sums)
		}
		draw(7, s.Week)
		draw(30, s.Month)
	}
	return s
}

// ServiceLevels is each level's P50 and P85 cycle time over its landings in the window, for each
// level with ServiceLevelMin of them, by level.
func ServiceLevels(landings []Landing, now time.Time) []wire.LineageForecastServiceLevel {
	since := now.Add(-ThroughputWindow)
	byLevel := map[string][]float64{}
	for _, l := range landings {
		if l.Level != "" && l.Cycle != nil && !l.At.Before(since) && l.At.Before(now) {
			byLevel[l.Level] = append(byLevel[l.Level], *l.Cycle)
		}
	}
	out := []wire.LineageForecastServiceLevel{}
	for level, v := range byLevel {
		if len(v) < ServiceLevelMin {
			continue
		}
		sort.Float64s(v)
		out = append(out, wire.LineageForecastServiceLevel{Level: level, Closed: int64(len(v)),
			P50Seconds: percentile(v, 0.5), P85Seconds: percentile(v, 0.85)})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Level < out[j].Level })
	return out
}
