package lineage

import (
	"math"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// The Multiplier (#3901, #3903; specs/3901-multiplier/spec.md): the PRs the person's
// agents merged in the last 7 days, less the merged reverts, never below 0, against the
// PRs an average engineer merged in a week in 2025. The host and the control plane count
// the same way, and the clients keep no copy of the baseline.

const (
	// MultiplierRange is the rolling range, by the PR's endedAt.
	MultiplierRange = 7 * 24 * time.Hour
	// BaselinePRsPerWeek is DX's median for an engineer with no AI, Q4 2025.
	BaselinePRsPerWeek = 1.4
	// BaselineHoursPerWeek is that engineer's week.
	BaselineHoursPerWeek = 40.0
	// BaselineSource is said under the figure.
	BaselineSource = "DX 2025"
)

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

// MultiplierOf is the figure for merges in the range that ends at now. Nothing counted is
// no figure, not 0×.
func MultiplierOf(merges map[wire.LineageNode]Merge, now time.Time) wire.Multiplier {
	since := MultiplierSince(now)
	out := wire.Multiplier{Since: since, Baseline: wire.MultiplierBaseline{PrsPerWeek: BaselinePRsPerWeek,
		HoursPerWeek: BaselineHoursPerWeek, Source: BaselineSource}}
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
		x := math.Round(float64(out.PrsMerged)/BaselinePRsPerWeek*10) / 10
		h := math.Round(float64(out.PrsMerged) * BaselineHoursPerWeek / BaselinePRsPerWeek)
		out.Multiplier, out.EngineerHours = &x, &h
	}
	return out
}
