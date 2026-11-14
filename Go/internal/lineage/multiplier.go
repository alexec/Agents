package lineage

import (
	"math"
	"time"

	"github.com/agentloops-dev/agents/Go/wire"
)

// The Multiplier (#3901, #3903; specs/3901-multiplier/spec.md): the PRs the person's
// agents merged in the last 7 days, less the merged reverts, never below 0, against the
// PRs an average engineer merged in a week in 2025, or the person's own figure (#3991). The
// host and the control plane count the same way, and the clients keep no copy of the baseline.

const (
	// MultiplierRange is the rolling range, by the PR's endedAt.
	MultiplierRange = 7 * 24 * time.Hour
	// BaselinePRsPerWeek is DX's median for an engineer with no AI, Q4 2025.
	BaselinePRsPerWeek = 1.4
	// BaselineHoursPerWeek is that engineer's week.
	BaselineHoursPerWeek = 40.0
	// BaselineSource is said under the figure.
	BaselineSource = "DX 2025"
	// LeastPRsPerWeek and MostPRsPerWeek bound the person's own baseline (#3991).
	LeastPRsPerWeek = 0.1
	MostPRsPerWeek  = 100.0
)

// BaselineOf is the baseline with the person's PRs a week, rounded to one decimal and kept
// from 0.1 to 100, and their line; 0 is the default, 1.4, and "" is the default line.
func BaselineOf(prsPerWeek float64, line string) wire.MultiplierBaseline {
	b := wire.MultiplierBaseline{PrsPerWeek: BaselinePRsPerWeek, HoursPerWeek: BaselineHoursPerWeek, Source: BaselineSource}
	if prsPerWeek > 0 && !math.IsInf(prsPerWeek, 0) {
		b.PrsPerWeek = min(max(math.Round(prsPerWeek*10)/10, LeastPRsPerWeek), MostPRsPerWeek)
	}
	if line != "" {
		b.Line = &line
	}
	return b
}

// Merge is one counted PR's end: a merge, or a merged revert.
type Merge struct {
	At       wire.Date
	Reverted bool
}

// Merges is the counted PRs of nodes that ended at or after since, by node, as the
// Multiplier counts them: a PR that merged or a merged revert, that a session worked on.
// A PR no session worked on (a person's own, or another's in the same repo) is not the
// agents' work. A PR an agent only reviewed counts too: a review session's P#n label is a
// works-on link, so lineage cannot tell it apart.
func Merges(nodes []wire.LineageCostNode, since wire.Date) map[wire.LineageNode]Merge {
	out := map[wire.LineageNode]Merge{}
	for _, n := range nodes {
		if n.Node.Kind != KindPR || n.Outcome == nil || n.EndedAt == nil || *n.EndedAt < since || len(n.Sessions) == 0 {
			continue
		}
		switch *n.Outcome {
		case OutcomeMerged:
			out[n.Node] = Merge{At: *n.EndedAt}
		case OutcomeReverted:
			out[n.Node] = Merge{At: *n.EndedAt, Reverted: true}
		}
	}
	return out
}

// MultiplierSince is the start of the range that ends at now.
func MultiplierSince(now time.Time) wire.Date { return wire.DateOf(now.Add(-MultiplierRange)) }

// MultiplierOf is the figure for merges in the range that ends at now, against b. Nothing
// counted is no figure, not 0×.
func MultiplierOf(merges map[wire.LineageNode]Merge, now time.Time, b wire.MultiplierBaseline) wire.Multiplier {
	since := MultiplierSince(now)
	out := wire.Multiplier{Since: since, Baseline: b}
	var merged int64
	for _, m := range merges {
		if m.At < since {
			continue
		}
		if m.Reverted {
			out.Reverts++
		} else {
			merged++
		}
	}
	// A revert is not a PR of work, and takes one away: it undoes the PR it reverts.
	out.PrsMerged = max(merged-out.Reverts, 0)
	if out.PrsMerged > 0 {
		x := math.Round(float64(out.PrsMerged)/b.PrsPerWeek*10) / 10
		h := math.Round(float64(out.PrsMerged) * b.HoursPerWeek / b.PrsPerWeek)
		out.Multiplier, out.EngineerHours = &x, &h
	}
	return out
}

// AllMerges is the time to keep merges from for the best week: all of them. A merge is at
// most a few a day, so a person's every merge is a few thousand.
var AllMerges = wire.Date(math.Inf(-1))

// FirstMergeOf is when the first of merges happened (#4250): a merge or a merged revert, so
// the page can tell a person whose agents never merged a PR from one with none this week.
// Nil when there is none. merges is all of them (AllMerges), as for the best week.
func FirstMergeOf(merges map[wire.LineageNode]Merge) *wire.Date {
	var first *wire.Date
	for _, m := range merges {
		if first == nil || m.At < *first {
			at := m.At
			first = &at
		}
	}
	return first
}

// BestWeekOf is the highest Multiplier of a calendar week (#3988), Monday to Sunday in loc,
// this week too, counted as MultiplierOf counts: the week's merges less its reverts. It is
// nil until the first merge is 7 days old (before that "best week" means nothing), and
// when no week has a figure.
func BestWeekOf(merges map[wire.LineageNode]Merge, now time.Time, loc *time.Location, b wire.MultiplierBaseline) *float64 {
	first := wire.DateOf(now)
	net := map[time.Time]int64{}
	for _, m := range merges {
		first = min(first, m.At)
		if m.Reverted {
			net[weekOf(m.At.Time(), loc)]--
		} else {
			net[weekOf(m.At.Time(), loc)]++
		}
	}
	if first > MultiplierSince(now) {
		return nil
	}
	var best int64
	for _, n := range net {
		best = max(best, n)
	}
	if best == 0 {
		return nil
	}
	x := math.Round(float64(best)/b.PrsPerWeek*10) / 10
	return &x
}

// weekOf is the Monday, at midnight in loc, that starts t's week.
func weekOf(t time.Time, loc *time.Location) time.Time {
	l := t.In(loc)
	back := (int(l.Weekday()) + 6) % 7
	return time.Date(l.Year(), l.Month(), l.Day()-back, 0, 0, 0, 0, loc)
}
