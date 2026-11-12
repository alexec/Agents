package lineage

import (
	"math"
	"regexp"
	"slices"
	"sort"
	"strings"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// The delivery figures (#4552, epic #4551): the four DORA keys, DORA 2025's rework rate and
// flow efficiency, for a repo, from the cost ledger's nodes and its releases' tag times.
//
//   - Lead time for changes: from the first work on an issue (its own start or its PRs') to
//     the first release tag that carries a merged PR that fixes it. Median and P90.
//   - Deployment frequency: release tags a week (#3023).
//   - Change failure rate: failures over merged PRs. A failure is a merged revert (a PR whose
//     title starts with Revert), or a merged PR that fixes a priority:high bug filed within
//     FailureAfterRelease after a release tag.
//   - Failed deployment recovery time: a revert's merge less the merge of the PR it reverts,
//     or a bug's first merged fix less the bug's filing. Median.
//   - Rework rate: the share of merged PRs, of those with their files known, that change a
//     file another PR merged in the ReworkRange before changed.
//   - Flow efficiency: a closed issue's agents' working time (its own and its PRs') over its
//     cycle time (#3562), at most 1. Median.
//
// Each is over the DeliveryWindow before now, with a series of its weeks, 7 days each back
// from now. The band is DORA 2024's cluster, as a reference: those clusters are teams of
// people, and agents merge many small PRs.
//
// Decided (#4552): a PR fixes a bug by any lineage link (the PR body's or a session's), not
// only "Fixes #n" in its body, because every PR an agent opens has one. A bug's filing is
// when the forge says it was made, else when this machine first noted it.

const (
	// DeliveryWindow is the delivery figures' window: 4 weeks.
	DeliveryWindow = 4 * deliveryWeek
	deliveryWeek   = 7 * 24 * time.Hour
	// FailureAfterRelease is how long after a release a priority:high bug filed counts against it.
	FailureAfterRelease = 7 * 24 * time.Hour
	// ReworkRange is how far back a merged PR's files count as recent work.
	ReworkRange = 21 * 24 * time.Hour
	// FilesKept bounds a PR's files on its node; FilesKeep is how long after its merge they
	// are kept: the window and the rework range, with room.
	FilesKept = 100
	FilesKeep = 60 * 24 * time.Hour
)

// The DORA 2024 clusters.
const (
	BandElite  = "elite"
	BandHigh   = "high"
	BandMedium = "medium"
	BandLow    = "low"
)

// revertTitle is the title GitHub's Revert button gives: Revert "<the PR's title>".
var revertTitle = regexp.MustCompile(`^Revert "(.+)"$`)

// RevertsIn is the PR a revert's body says it reverts: "Reverts owner/repo#12", or "Reverts
// #12" in repo (github:owner/repo). "" when it names none.
func RevertsIn(repo, body string) string {
	m := revertsBody.FindStringSubmatch(body)
	if m == nil {
		return ""
	}
	if m[1] == "" {
		return repo + "#" + m[2]
	}
	scheme, _, _ := strings.Cut(repo, ":")
	return scheme + ":" + m[1] + "#" + m[2]
}

var revertsBody = regexp.MustCompile(`(?i)\breverts\s+([\w.-]+/[\w.-]+)?#([0-9]{1,9})\b`)

// sample is one figure's value at a time.
type sample struct {
	at wire.Date
	v  float64
}

// DeliveryOf is repo's delivery figures from nodes, which hold each node once, and the
// release tags' times by ref, at now.
func DeliveryOf(nodes []wire.LineageCostNode, repo string, releases map[string]wire.Date, now time.Time) wire.LineageDelivery {
	at := wire.DateOf(now)
	since := wire.DateOf(now.Add(-DeliveryWindow))
	var mine []wire.LineageCostNode
	for _, n := range nodes {
		if n.Repo != nil && *n.Repo == repo {
			mine = append(mine, n)
		}
	}
	var tags []wire.Date
	for ref, t := range releases {
		if RepoOf(wire.LineageNode{Kind: KindRelease, Ref: ref}) == repo {
			tags = append(tags, t)
		}
	}
	slices.Sort(tags)

	byRef := map[string]wire.LineageCostNode{}
	fixers := map[string][]wire.LineageCostNode{}
	var merged []wire.LineageCostNode
	for _, n := range mine {
		byRef[n.Node.Ref] = n
		if n.Node.Kind != KindPR || !mergedPR(n) {
			continue
		}
		merged = append(merged, n)
		for _, f := range n.Fixes {
			fixers[f] = append(fixers[f], n)
		}
	}

	out := wire.LineageDelivery{Since: since, At: at, WindowDays: int64(DeliveryWindow / (24 * time.Hour))}

	// Lead time for changes, by the tag's time.
	var lead []sample
	for _, n := range mine {
		if n.Node.Kind != KindIssue || (n.Level != nil && *n.Level == "epic") {
			continue
		}
		start := StartOf(n)
		var shipped *wire.Date
		for _, pr := range fixers[n.Node.Ref] {
			if s := StartOf(pr); s != nil && (start == nil || *s < *start) {
				start = s
			}
			for _, ref := range pr.PartOf {
				if t, ok := releases[ref]; ok && (shipped == nil || t < *shipped) {
					shipped = &t
				}
			}
		}
		if start != nil && shipped != nil && *shipped >= *start {
			lead = append(lead, sample{*shipped, float64(*shipped - *start)})
		}
	}
	out.LeadTime = figureOf(lead, since, at, median)
	if v := valuesIn(lead, since, at+1); len(v) > 0 {
		p := percentile(v, 0.9)
		out.LeadTime.P90 = &p
	}
	out.LeadTime.Band = band(out.LeadTime.Value, leadBand)

	// Deployment frequency: tags a week, 0 for none.
	var deploys []sample
	for _, t := range tags {
		deploys = append(deploys, sample{t, 1})
	}
	out.DeploymentFrequency = figureOf(deploys, since, at, func(v []float64) float64 { return float64(len(v)) })
	weeks := float64(len(out.DeploymentFrequency.Weeks))
	perWeek := float64(out.DeploymentFrequency.Count) / weeks
	out.DeploymentFrequency.Value = &perWeek
	for i, w := range out.DeploymentFrequency.Weeks {
		v := float64(w.Count)
		out.DeploymentFrequency.Weeks[i].Value = &v
	}
	out.DeploymentFrequency.Band = band(&perWeek, frequencyBand)

	// Change failure rate and recovery time.
	filed := func(issue wire.LineageCostNode) *wire.Date {
		if issue.Resolved != nil && issue.Resolved.CreatedAt != nil {
			return issue.Resolved.CreatedAt
		}
		return issue.FirstAt
	}
	afterRelease := func(t wire.Date) bool {
		i := sort.Search(len(tags), func(i int) bool { return tags[i] > t })
		return i > 0 && float64(t-tags[i-1]) <= FailureAfterRelease.Seconds()
	}
	// failureBug says an issue is a priority:high bug filed within a week after a release.
	failureBug := map[string]wire.Date{}
	for _, n := range mine {
		if n.Node.Kind != KindIssue || n.Resolved == nil || !isHighBug(n) {
			continue
		}
		if f := filed(n); f != nil && afterRelease(*f) {
			failureBug[n.Node.Ref] = *f
		}
	}
	byTitle := map[string]wire.LineageCostNode{}
	for _, n := range merged {
		if n.Resolved != nil && n.Resolved.Title != "" {
			byTitle[n.Resolved.Title] = n
		}
	}
	var failures, recovery []sample
	for _, n := range merged {
		failed := n.Outcome != nil && *n.Outcome == OutcomeReverted
		if failed {
			if r, ok := revertedBy(n, byRef, byTitle); ok && r.EndedAt != nil && *n.EndedAt >= *r.EndedAt {
				recovery = append(recovery, sample{*n.EndedAt, float64(*n.EndedAt - *r.EndedAt)})
			}
		}
		for _, f := range n.Fixes {
			if _, ok := failureBug[f]; ok {
				failed = true
			}
		}
		v := 0.0
		if failed {
			v = 1
		}
		failures = append(failures, sample{*n.EndedAt, v})
	}
	for ref, at := range failureBug {
		var first *wire.Date
		for _, pr := range fixers[ref] {
			if first == nil || *pr.EndedAt < *first {
				first = pr.EndedAt
			}
		}
		if first != nil && *first >= at {
			recovery = append(recovery, sample{*first, float64(*first - at)})
		}
	}
	out.ChangeFailureRate = figureOf(failures, since, at, mean)
	out.ChangeFailureRate.Band = band(out.ChangeFailureRate.Value, failureBand)
	out.RecoveryTime = figureOf(recovery, since, at, median)
	out.RecoveryTime.Band = band(out.RecoveryTime.Value, recoveryBand)

	// Rework rate.
	var withFiles []wire.LineageCostNode
	for _, n := range merged {
		if len(n.Files) > 0 {
			withFiles = append(withFiles, n)
		}
	}
	var rework []sample
	for _, n := range withFiles {
		if *n.EndedAt < since {
			continue
		}
		from := *n.EndedAt - wire.Date(ReworkRange.Seconds())
		recent := map[string]bool{}
		for _, o := range withFiles {
			if o.Node != n.Node && *o.EndedAt >= from && *o.EndedAt < *n.EndedAt {
				for _, f := range o.Files {
					recent[f] = true
				}
			}
		}
		v := 0.0
		for _, f := range n.Files {
			if recent[f] {
				v = 1
				break
			}
		}
		rework = append(rework, sample{*n.EndedAt, v})
	}
	out.ReworkRate = figureOf(rework, since, at, mean)

	// Flow efficiency, by the last merge.
	var flow []sample
	for _, p := range History(mine) {
		if p.Cycle != nil && *p.Cycle > 0 {
			flow = append(flow, sample{p.Merged, min(p.Cost.WorkingSeconds / *p.Cycle, 1)})
		}
	}
	out.FlowEfficiency = figureOf(flow, since, at, median)
	return out
}

// mergedPR says a PR merged: a merge, or a merged revert.
func mergedPR(n wire.LineageCostNode) bool {
	return n.Outcome != nil && n.EndedAt != nil && (*n.Outcome == OutcomeMerged || *n.Outcome == OutcomeReverted)
}

// isHighBug says an issue is a bug labelled priority:high.
func isHighBug(n wire.LineageCostNode) bool {
	bug := n.Level != nil && *n.Level == "bug" || TypeOf(n.Resolved.Labels) == "bug"
	return bug && slices.ContainsFunc(n.Resolved.Labels, func(l string) bool {
		return strings.EqualFold(strings.TrimSpace(l), "priority:high")
	})
}

// revertedBy is the merged PR a revert reverts: the one its body names, else the one whose
// title its own title quotes.
func revertedBy(revert wire.LineageCostNode, byRef, byTitle map[string]wire.LineageCostNode) (wire.LineageCostNode, bool) {
	if revert.Reverts != nil {
		if r, ok := byRef[*revert.Reverts]; ok && mergedPR(r) {
			return r, true
		}
	}
	if revert.Resolved == nil {
		return wire.LineageCostNode{}, false
	}
	m := revertTitle.FindStringSubmatch(revert.Resolved.Title)
	if m == nil {
		return wire.LineageCostNode{}, false
	}
	r, ok := byTitle[m[1]]
	return r, ok && r.Node != revert.Node
}

// figureOf is samples' figure over [since, at], and over each of its weeks, by agg.
func figureOf(samples []sample, since, at wire.Date, agg func([]float64) float64) wire.LineageDeliveryFigure {
	week := wire.Date(deliveryWeek.Seconds())
	n := int(math.Round(float64(at-since) / float64(week)))
	f := wire.LineageDeliveryFigure{Weeks: make([]wire.LineageDeliveryWeek, 0, n)}
	// The last week takes at itself.
	all := valuesIn(samples, since, at+1)
	f.Count = int64(len(all))
	if len(all) > 0 {
		v := agg(all)
		f.Value = &v
	}
	for i := range n {
		from := since + wire.Date(i)*week
		to := from + week
		if i == n-1 {
			to = at + 1
		}
		w := wire.LineageDeliveryWeek{Since: from}
		if v := valuesIn(samples, from, to); len(v) > 0 {
			w.Count = int64(len(v))
			x := agg(v)
			w.Value = &x
		}
		f.Weeks = append(f.Weeks, w)
	}
	return f
}

// valuesIn is the values of the samples at from or later and before to, sorted.
func valuesIn(samples []sample, from, to wire.Date) []float64 {
	var v []float64
	for _, s := range samples {
		if s.at >= from && s.at < to {
			v = append(v, s.v)
		}
	}
	sort.Float64s(v)
	return v
}

func mean(v []float64) float64 {
	var sum float64
	for _, x := range v {
		sum += x
	}
	return sum / float64(len(v))
}

// band is v's DORA 2024 cluster by of; nil for no value.
func band(v *float64, of func(float64) string) *string {
	if v == nil {
		return nil
	}
	b := of(*v)
	return &b
}

// leadBand: elite under a day, high to a week, medium to a month, else low.
func leadBand(secs float64) string {
	switch day := 24 * time.Hour.Seconds(); {
	case secs < day:
		return BandElite
	case secs <= 7*day:
		return BandHigh
	case secs <= 30*day:
		return BandMedium
	}
	return BandLow
}

// frequencyBand, in tags a week: elite more than daily, high daily to weekly, medium weekly
// to monthly, else low.
func frequencyBand(perWeek float64) string {
	switch {
	case perWeek > 7:
		return BandElite
	case perWeek >= 1:
		return BandHigh
	case perWeek >= 12.0/52:
		return BandMedium
	}
	return BandLow
}

// failureBand is the cluster whose 2024 figure is nearest: elite 5%, medium 10%, high 20%,
// low 40%. DORA 2024 put medium below high on this key.
func failureBand(rate float64) string {
	clusters := []struct {
		band string
		at   float64
	}{{BandElite, 0.05}, {BandMedium, 0.10}, {BandHigh, 0.20}, {BandLow, 0.40}}
	best := clusters[0]
	for _, c := range clusters[1:] {
		if math.Abs(rate-c.at) < math.Abs(rate-best.at) {
			best = c
		}
	}
	return best.band
}

// recoveryBand: elite under an hour, high under a day, medium under a week, else low. DORA
// 2024 put high and medium both under a day, and low from a week to a month.
func recoveryBand(secs float64) string {
	switch hour := time.Hour.Seconds(); {
	case secs < hour:
		return BandElite
	case secs < 24*hour:
		return BandHigh
	case secs < 7*24*hour:
		return BandMedium
	}
	return BandLow
}
