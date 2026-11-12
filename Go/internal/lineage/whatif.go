package lineage

import (
	"sort"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// What-if (#4531): the same forecast with another lane limit or runtime mix.
//
//   - Lanes: method H draws hours of the window, and an hour's landings came from the issues
//     in flight in it. With a limit of L lanes, an hour that had a in flight keeps min(a, L) / a
//     of its landings, in the dates' draws and in the spend. A limit at or above the most that
//     were ever in flight moves nothing: no hour shows what more lanes would do.
//   - Runtime mix: each runtime's cost per working hour over the window, weighted by the mix,
//     over the same weighted by the mix the window ran. It scales the dollars (the spend and the
//     estimate to complete) and each allowance's pace by its runtime's share. Landings do not
//     say their runtime, so the mix does not move the dates.

// InFlight is how many issues were in flight in each hour of the window before now, oldest
// first: each landing from its first work (its lead time before it, else its cycle time) to
// its landing, and each other issue that is not closed and not an epic from its start to its
// last work.
func InFlight(nodes []wire.LineageCostNode, landings []Landing, repo string, now time.Time) []int {
	since := now.Add(-ThroughputWindow)
	bins := make([]int, int(ThroughputWindow/time.Hour))
	add := func(start, end time.Time) {
		start, end = laterOf(start, since).Truncate(time.Hour), minTime(end, now)
		for t := start; !t.After(end); t = t.Add(time.Hour) {
			if i := int(t.Sub(since) / time.Hour); i >= 0 && i < len(bins) {
				bins[i]++
			}
		}
	}
	landed := map[string]bool{}
	for _, l := range landings {
		landed[l.Ref] = true
		start := l.At
		if took := l.Lead; took != nil || l.Cycle != nil {
			if took == nil {
				took = l.Cycle
			}
			start = l.At.Add(-time.Duration(*took * float64(time.Second)))
		}
		if !l.At.Before(since) {
			add(start, l.At)
		}
	}
	parents := map[string]bool{}
	for _, n := range nodes {
		if n.Parent != nil {
			parents[*n.Parent] = true
		}
	}
	for _, n := range nodes {
		if n.Node.Kind != KindIssue || landed[n.Node.Ref] || parents[n.Node.Ref] || deref(n.Level) == "epic" {
			continue
		}
		if repo != "" && !SameRepo(deref(n.Repo), repo) {
			continue
		}
		if n.Resolved != nil && n.Resolved.State != nil && *n.Resolved.State == "closed" {
			continue
		}
		if s := StartOf(n); s != nil && !n.LastAt.Time().Before(since) {
			add(s.Time(), n.LastAt.Time())
		}
	}
	return bins
}

// LanesOf is the lanes a window ran with: the issues in flight in an average hour that had
// one, and the most in any hour.
func LanesOf(inFlight []int) (mean float64, peak int) {
	hours, sum := 0, 0
	for _, a := range inFlight {
		if a > 0 {
			hours++
			sum += a
		}
		peak = max(peak, a)
	}
	if hours > 0 {
		mean = float64(sum) / float64(hours)
	}
	return mean, peak
}

// LaneKeep is each hour's part of its landings that a limit of lanes keeps: min(in flight,
// lanes) / in flight. Nil (keep them all) when lanes is below 1.
func LaneKeep(inFlight []int, lanes int) []float64 {
	if lanes < 1 {
		return nil
	}
	keep := make([]float64, len(inFlight))
	for i, a := range inFlight {
		keep[i] = 1
		if a > lanes {
			keep[i] = float64(lanes) / float64(a)
		}
	}
	return keep
}

// Pace is the landings that keep keeps, over all of bins' landings: 1 with none.
func Pace(bins []int, keep []float64) float64 {
	all, kept := 0, 0.0
	for i, n := range bins {
		all += n
		kept += float64(n) * keepAt(keep, i)
	}
	if all == 0 || keep == nil {
		return 1
	}
	return kept / float64(all)
}

func keepAt(keep []float64, i int) float64 {
	if keep == nil || i < 0 || i >= len(keep) {
		return 1
	}
	return keep[i]
}

// RuntimesOf is the runtime mix of a window: each runtime's working hours and cost by
// currency, as its share of the hours and its cost per hour, the most hours first. A runtime
// with no working hours is left out.
func RuntimesOf(hours map[string]float64, cost map[string]map[string]float64) []wire.LineageForecastRuntime {
	all := 0.0
	for _, h := range hours {
		if h > 0 {
			all += h
		}
	}
	out := []wire.LineageForecastRuntime{}
	for runtime, h := range hours {
		if h <= 0 {
			continue
		}
		r := wire.LineageForecastRuntime{Runtime: runtime, Share: h / all, Hours: h, Rate: map[string]float64{}}
		for currency, v := range cost[runtime] {
			r.Rate[currency] = v / h
		}
		out = append(out, r)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Hours != out[j].Hours {
			return out[i].Hours > out[j].Hours
		}
		return out[i].Runtime < out[j].Runtime
	})
	return out
}

// Mix is a runtime mix against the window's: the mix's shares of the window's runtimes,
// scaled to add up to 1 (others left out), and its cost per working hour over the window's by
// currency. ok is false when the mix names none of the window's runtimes.
func Mix(runtimes []wire.LineageForecastRuntime, mix map[string]float64) (scaled, cost map[string]float64, ok bool) {
	sum := 0.0
	for _, r := range runtimes {
		sum += max(mix[r.Runtime], 0)
	}
	if sum <= 0 {
		return nil, nil, false
	}
	scaled = map[string]float64{}
	was, will := map[string]float64{}, map[string]float64{}
	for _, r := range runtimes {
		m := max(mix[r.Runtime], 0) / sum
		scaled[r.Runtime] = m
		for currency, rate := range r.Rate {
			was[currency] += r.Share * rate
			will[currency] += m * rate
		}
	}
	cost = map[string]float64{}
	for currency, w := range was {
		if w > 0 {
			cost[currency] = will[currency] / w
		}
	}
	return scaled, cost, true
}

// costFactor is cost's factor for the effect: USD's, else the first currency's, else 1.
func costFactor(cost map[string]float64) float64 {
	if v, ok := cost["USD"]; ok {
		return v
	}
	keys := make([]string, 0, len(cost))
	for k := range cost {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	if len(keys) == 0 {
		return 1
	}
	return cost[keys[0]]
}

// scaleRanges is m with each currency's range times by[currency] (1 when it has none).
func scaleRanges(m map[string]wire.LineageEstimateRange, by map[string]float64) map[string]wire.LineageEstimateRange {
	out := make(map[string]wire.LineageEstimateRange, len(m))
	for currency, r := range m {
		f, ok := by[currency]
		if !ok {
			f = 1
		}
		out[currency] = wire.LineageEstimateRange{Median: r.Median * f, P10: r.P10 * f, P90: r.P90 * f}
	}
	return out
}

// WhatIf is a what-if's inputs to ForecastOf: the request's, and the window's runtime mix
// from the machine's usage and time histories.
type WhatIf struct {
	Lanes    int
	Mix      map[string]float64
	Runtimes []wire.LineageForecastRuntime
}

// Asked says whether w asks for anything other than the window as it ran.
func (w WhatIf) Asked() bool { return w.Lanes >= 1 || len(w.Mix) > 0 }

// BurnPace is how much faster than its last reading an allowance of runtime burns under f's
// what-if: the lanes' pace times the runtime's share over the window's. 1 without a what-if.
func BurnPace(f wire.LineageForecast, runtime string) float64 {
	if f.WhatIf == nil {
		return 1
	}
	k := f.WhatIf.Pace
	if f.WhatIf.Mix != nil && f.Assumes != nil {
		for _, r := range f.Assumes.Runtimes {
			if r.Runtime == runtime && r.Share > 0 {
				k *= f.WhatIf.Mix[runtime] / r.Share
			}
		}
	}
	return k
}
