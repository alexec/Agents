package controlplane

import (
	"context"
	"encoding/json"
	"slices"
	"sort"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/wire"
)

// Reports ▸ Value (#2351): what the work in a scope cost and what it delivered, read from
// the lineage nodes each machine sends (lineagecost.go). The machines' copies of one node
// add up, as each banked its own turns. A node is in the range when it last changed in it,
// with its whole cost: a node's total is not kept by the day.

// mostValueRows bounds each list of the answer.
const mostValueRows = 100

// valueSince is the start of a range.
func valueSince(r wire.ReportRange, now time.Time) (time.Time, bool) {
	switch r {
	case wire.ReportRangeDay:
		return now.Add(-24 * time.Hour), true
	case wire.ReportRangeWeek:
		return now.AddDate(0, 0, -7), true
	case wire.ReportRangeMonth:
		return now.AddDate(0, 0, -30), true
	case wire.ReportRangeThreeMonths:
		return now.AddDate(0, 0, -90), true
	}
	return time.Time{}, false
}

// valueReport is reports/value for the scope the caller asks for.
func (s *Service) valueReport(ctx context.Context, r wire.ReportRange, scope *wire.ReportScope, user string, now time.Time) (wire.ReportValue, error) {
	since, ok := valueSince(r, now)
	if !ok {
		return wire.ReportValue{}, fail(invalidParams, "Say a range: day, week, month or threeMonths.")
	}
	scope, keep, _, err := s.reportScope(ctx, scope, user, s.isAdmin(user))
	if err != nil {
		return wire.ReportValue{}, err
	}
	nodes, err := s.scopeLineage(ctx, keep)
	if err != nil {
		return wire.ReportValue{}, err
	}
	out := valueOf(nodes, wire.DateOf(since))
	out.Range, out.Scope = r, *scope
	return out, nil
}

// scopeLineage is the nodes of the machines whose people keep says, each node once, its
// machines' copies added up.
func (s *Service) scopeLineage(ctx context.Context, keep func(person string) bool) ([]wire.LineageCostNode, error) {
	keys, err := s.cfg.Store.List(ctx, lineagePrefix)
	if err != nil {
		return nil, fail(storeUnavailable, "The reports could not be read: %v", err)
	}
	known := map[string]string{}
	for _, h := range s.records.Hosts() {
		known[strings.ToLower(h.ID)] = h.ID
	}
	var read []store.Key
	for _, k := range keys {
		host := strings.TrimSuffix(strings.TrimPrefix(k.Key, lineagePrefix), ".json")
		// A machine removed since: its person is not known, so only an admin sees it.
		person := ""
		if id, ok := known[host]; ok {
			person = s.ownerOf(id)
		}
		if keep(person) {
			read = append(read, k)
		}
	}
	// By entity tag and storeReadsAtOnce at a time (#2975), not one machine after another.
	objects, err := s.storeReads.read(ctx, s.cfg.Store, lineagePrefix, keys, read)
	if err != nil {
		return nil, fail(storeUnavailable, "The reports could not be read: %v", err)
	}
	byNode := map[wire.LineageNode]*wire.LineageCostNode{}
	for _, data := range objects {
		var kept storedLineage
		if data == nil || json.Unmarshal(data, &kept) != nil {
			continue
		}
		for _, n := range kept.Nodes {
			if have := byNode[n.Node]; have != nil {
				mergeNode(have, n)
				continue
			}
			c := n
			c.Banked = wire.LineageCost{Cost: map[string]float64{}}
			lineage.AddCost(&c.Banked, n.Banked)
			c.Fixes, c.PartOf, c.Sessions = slices.Clone(n.Fixes), slices.Clone(n.PartOf), slices.Clone(n.Sessions)
			byNode[n.Node] = &c
		}
	}
	out := make([]wire.LineageCostNode, 0, len(byNode))
	for _, n := range byNode {
		out = append(out, *n)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Node.Kind != out[j].Node.Kind {
			return out[i].Node.Kind < out[j].Node.Kind
		}
		return out[i].Node.Ref < out[j].Node.Ref
	})
	return out, nil
}

// mergeNode adds another machine's copy of a node to have: the cost adds up, the links and
// sessions join, and the newest copy says how a PR ended and its title, state and labels. Failed checks are the most any machine
// heard, as each machine that listens hears the same rounds.
func mergeNode(have *wire.LineageCostNode, n wire.LineageCostNode) {
	lineage.AddCost(&have.Banked, n.Banked)
	for _, f := range n.Fixes {
		if !slices.Contains(have.Fixes, f) {
			have.Fixes = append(have.Fixes, f)
		}
	}
	for _, p := range n.PartOf {
		if !slices.Contains(have.PartOf, p) {
			have.PartOf = append(have.PartOf, p)
		}
	}
	for _, id := range n.Sessions {
		if !slices.Contains(have.Sessions, id) {
			have.Sessions = append(have.Sessions, id)
		}
	}
	if have.Repo == nil {
		have.Repo = n.Repo
	}
	// The newest title, state and labels any machine resolved (#3118).
	if n.Resolved != nil && (have.Resolved == nil || n.LastAt > have.LastAt) {
		have.Resolved = n.Resolved
	}
	if n.Outcome != nil && (have.Outcome == nil || n.LastAt > have.LastAt) {
		have.Outcome = n.Outcome
	}
	if n.FailedChecks != nil && (have.FailedChecks == nil || *n.FailedChecks > *have.FailedChecks) {
		have.FailedChecks = n.FailedChecks
	}
	if n.FirstAt != nil && (have.FirstAt == nil || *n.FirstAt < *have.FirstAt) {
		have.FirstAt = n.FirstAt
	}
	if n.EndedAt != nil && (have.EndedAt == nil || *n.EndedAt > *have.EndedAt) {
		have.EndedAt = n.EndedAt
	}
	// The first start any machine saw, and the level, feature, area and epic of the copy
	// that knows them, the newest first (#3562).
	if n.StartedAt != nil && (have.StartedAt == nil || *n.StartedAt < *have.StartedAt) {
		have.StartedAt = n.StartedAt
	}
	newer := n.LastAt > have.LastAt
	for _, f := range []struct{ have, n **string }{{&have.Level, &n.Level}, {&have.Feature, &n.Feature},
		{&have.Area, &n.Area}, {&have.Parent, &n.Parent}} {
		if *f.n != nil && (*f.have == nil || newer) {
			*f.have = *f.n
		}
	}
	// The estimate made for the earliest start (#3561).
	if n.Estimate != nil && (have.Estimate == nil || n.Estimate.At < have.Estimate.At) {
		have.Estimate = n.Estimate
	}
	if n.LastAt > have.LastAt {
		have.LastAt = n.LastAt
	}
}

// valueOf adds up the nodes that changed since: the totals over each node once, and a row
// for each issue, milestone and release with a part that changed since.
func valueOf(nodes []wire.LineageCostNode, since wire.Date) wire.ReportValue {
	blank := func() wire.LineageCost { return wire.LineageCost{Cost: map[string]float64{}} }
	out := wire.ReportValue{Total: blank(), Waste: blank(), Unlinked: blank(), PerMergedPR: map[string]float64{},
		Issues: []wire.ReportValueRow{}, Milestones: []wire.ReportValueRow{}, Releases: []wire.ReportValueRow{}}
	byRef := map[string]wire.LineageCostNode{}
	fixers := map[string][]wire.LineageCostNode{}
	members := map[string][]wire.LineageCostNode{}
	var issues, milestones, releases []string
	seen := map[string]bool{}
	addIssue := func(ref string) {
		if !seen[ref] {
			seen[ref] = true
			issues = append(issues, ref)
		}
	}
	for _, n := range nodes {
		switch n.Node.Kind {
		case lineage.KindIssue:
			byRef[n.Node.Ref] = n
			addIssue(n.Node.Ref)
		case lineage.KindPR:
			for _, f := range n.Fixes {
				fixers[f] = append(fixers[f], n)
				addIssue(f)
			}
		}
		for _, m := range n.PartOf {
			if _, ok := members[m]; !ok {
				if lineage.PartOfKind(m) == lineage.KindRelease {
					releases = append(releases, m)
				} else {
					milestones = append(milestones, m)
				}
			}
			members[m] = append(members[m], n)
		}
		if n.LastAt < since {
			continue
		}
		switch n.Node.Kind {
		case lineage.KindIssue, lineage.KindPR:
			lineage.AddCost(&out.Total, n.Banked)
		case lineage.KindSession:
			lineage.AddCost(&out.Unlinked, n.Banked)
		}
		if lineage.Wasted(n) {
			lineage.AddCost(&out.Waste, n.Banked)
		}
		countPR(n, &out.PrsMerged, &out.PrsClosed, &out.PrsReverted, &out.FailedChecks)
	}
	if out.PrsMerged > 0 {
		for currency, v := range out.Total.Cost {
			out.PerMergedPR[currency] = v / float64(out.PrsMerged)
		}
	}
	issueParts := func(ref string) []wire.LineageCostNode {
		var parts []wire.LineageCostNode
		if n, ok := byRef[ref]; ok {
			parts = append(parts, n)
		}
		return append(parts, fixers[ref]...)
	}
	children := childrenOf(nodes)
	var leads, cycles []float64
	for _, ref := range issues {
		row, ok := valueRow(wire.LineageNode{Kind: lineage.KindIssue, Ref: ref}, issueParts(ref), since)
		if !ok {
			continue
		}
		if n, ok := byRef[ref]; ok {
			row.Level = n.Level
		}
		if kids := children[ref]; len(kids) > 0 {
			_, row.CycleTimeSeconds = cycleOf(epicParts(ref, kids, issueParts))
		}
		if row.LeadTimeSeconds != nil {
			leads = append(leads, *row.LeadTimeSeconds)
		}
		if row.CycleTimeSeconds != nil {
			cycles = append(cycles, *row.CycleTimeSeconds)
		}
		out.Issues = append(out.Issues, row)
	}
	for _, ref := range milestones {
		// Its issues and PRs, and the PRs that fix those issues, each once.
		parts := dedupParts(members[ref], func(n wire.LineageCostNode) []wire.LineageCostNode {
			if n.Node.Kind != lineage.KindIssue {
				return nil
			}
			return fixers[n.Node.Ref]
		})
		if row, ok := valueRow(wire.LineageNode{Kind: lineage.KindMilestone, Ref: ref}, parts, since); ok {
			out.Milestones = append(out.Milestones, row)
		}
	}
	for _, ref := range releases {
		// Its PRs, and the issues those PRs fix, each once (#3023; the same shape as
		// lineage.Rollup's KindRelease case): only PRs are ever part-of a release.
		parts := dedupParts(members[ref], func(n wire.LineageCostNode) []wire.LineageCostNode {
			var fixed []wire.LineageCostNode
			for _, f := range n.Fixes {
				if issue, ok := byRef[f]; ok {
					fixed = append(fixed, issue)
				}
			}
			return fixed
		})
		if row, ok := valueRow(wire.LineageNode{Kind: lineage.KindRelease, Ref: ref}, parts, since); ok {
			out.Releases = append(out.Releases, row)
		}
	}
	out.LeadTimeSeconds, out.CycleTimeSeconds = median(leads), median(cycles)
	out.EstimateError = estimateError(issues, byRef, issueParts, children, since)
	limited := false
	out.Issues, limited = mostCostly(out.Issues)
	var more bool
	out.Milestones, more = mostCostly(out.Milestones)
	limited = limited || more
	out.Releases, more = mostCostly(out.Releases)
	if limited || more {
		t := true
		out.Limited = &t
	}
	return out
}

// estimateError is how far the estimates kept at the start of work were from what the issues
// took (#3561), over the issues closed in the range: those with a merged PR that ended since,
// that are not open and not an epic. None when no issue had an estimate.
func estimateError(issues []string, byRef map[string]wire.LineageCostNode, issueParts func(string) []wire.LineageCostNode,
	children map[string][]string, since wire.Date) *wire.ReportEstimateError {
	var costs, works []float64
	var n int64
	for _, ref := range issues {
		node, ok := byRef[ref]
		if !ok || node.Estimate == nil || len(children[ref]) > 0 || (node.Level != nil && *node.Level == "epic") ||
			(node.Resolved != nil && node.Resolved.State != nil && *node.Resolved.State == "open") {
			continue
		}
		actual := wire.LineageCost{Cost: map[string]float64{}}
		closed := false
		for _, p := range issueParts(ref) {
			lineage.AddCost(&actual, p.Banked)
			if p.Node.Kind == lineage.KindPR && p.Outcome != nil && *p.Outcome == lineage.OutcomeMerged && p.EndedAt != nil &&
				*p.EndedAt >= since {
				closed = true
			}
		}
		if !closed {
			continue
		}
		n++
		if v, ok := lineage.ErrorOf(node.Estimate.Cost["USD"], actual.Cost["USD"]); ok {
			costs = append(costs, v)
		}
		if w := node.Estimate.WorkingSeconds; w != nil {
			if v, ok := lineage.ErrorOf(*w, actual.WorkingSeconds); ok {
				works = append(works, v)
			}
		}
	}
	if n == 0 {
		return nil
	}
	return &wire.ReportEstimateError{Issues: n, Cost: median(costs), WorkingSeconds: median(works)}
}

// median is the middle of values, or none when there are none.
func median(values []float64) *float64 {
	if len(values) == 0 {
		return nil
	}
	sort.Float64s(values)
	m := values[len(values)/2]
	if len(values)%2 == 0 {
		m = (values[len(values)/2-1] + m) / 2
	}
	return &m
}

// childrenOf is each epic's children, by ref, as their issues' parent says (#3562).
func childrenOf(nodes []wire.LineageCostNode) map[string][]string {
	out := map[string][]string{}
	for _, n := range nodes {
		if n.Node.Kind == lineage.KindIssue && n.Parent != nil && *n.Parent != n.Node.Ref {
			out[*n.Parent] = append(out[*n.Parent], n.Node.Ref)
		}
	}
	return out
}

// epicParts is an epic's parts for its cycle time (#3562): its own and its children's, so its
// start is its first child's start and its end its children's last PR merged.
func epicParts(ref string, kids []string, issueParts func(string) []wire.LineageCostNode) []wire.LineageCostNode {
	parts := issueParts(ref)
	for _, k := range kids {
		parts = append(parts, issueParts(k)...)
	}
	return parts
}

// cycleOf is the first start of work on any of parts, and the time from it to the last of
// their PRs merged (#3562); none before a merge or with no start.
func cycleOf(parts []wire.LineageCostNode) (*wire.Date, *float64) {
	var start, merged *wire.Date
	for _, n := range parts {
		if n.StartedAt != nil && (start == nil || *n.StartedAt < *start) {
			start = n.StartedAt
		}
		if n.Node.Kind == lineage.KindPR && n.Outcome != nil && *n.Outcome == lineage.OutcomeMerged && n.EndedAt != nil &&
			(merged == nil || *n.EndedAt > *merged) {
			merged = n.EndedAt
		}
	}
	if start == nil || merged == nil || *merged < *start {
		return start, nil
	}
	cycle := float64(*merged - *start)
	return start, &cycle
}

// dedupParts is base's nodes, each once, plus each one's related nodes (also each once),
// in base's order.
func dedupParts(base []wire.LineageCostNode, related func(wire.LineageCostNode) []wire.LineageCostNode) []wire.LineageCostNode {
	var parts []wire.LineageCostNode
	in := map[wire.LineageNode]bool{}
	add := func(n wire.LineageCostNode) {
		if !in[n.Node] {
			in[n.Node] = true
			parts = append(parts, n)
		}
	}
	for _, n := range base {
		add(n)
		for _, r := range related(n) {
			add(r)
		}
	}
	return parts
}

// valueRow adds up of's parts, or says no when none of them changed since. Its lead time
// is from the first work on any part to the last of its PRs merged, and its cycle time from
// the first start of work on any part (#3562).
func valueRow(of wire.LineageNode, parts []wire.LineageCostNode, since wire.Date) (wire.ReportValueRow, bool) {
	row := wire.ReportValueRow{Node: of, Total: wire.LineageCost{Cost: map[string]float64{}},
		Waste: wire.LineageCost{Cost: map[string]float64{}}}
	recent := false
	var first, merged *wire.Date
	for _, n := range parts {
		recent = recent || n.LastAt >= since
		lineage.AddCost(&row.Total, n.Banked)
		if lineage.Wasted(n) {
			lineage.AddCost(&row.Waste, n.Banked)
		}
		countPR(n, &row.PrsMerged, &row.PrsClosed, &row.PrsReverted, &row.FailedChecks)
		if n.FirstAt != nil && (first == nil || *n.FirstAt < *first) {
			first = n.FirstAt
		}
		if n.Node.Kind == lineage.KindPR && n.Outcome != nil && *n.Outcome == lineage.OutcomeMerged && n.EndedAt != nil &&
			(merged == nil || *n.EndedAt > *merged) {
			merged = n.EndedAt
		}
	}
	if first != nil && merged != nil && *merged >= *first {
		lead := float64(*merged - *first)
		row.LeadTimeSeconds = &lead
	}
	_, row.CycleTimeSeconds = cycleOf(parts)
	return row, recent
}

// countPR counts how a PR ended, as lineage.Rollup does: a reverted PR was merged too.
func countPR(n wire.LineageCostNode, merged, closed, reverted, failed *int64) {
	if n.Node.Kind != lineage.KindPR {
		return
	}
	if n.Outcome != nil {
		switch *n.Outcome {
		case lineage.OutcomeMerged:
			*merged++
		case lineage.OutcomeClosed:
			*closed++
		case lineage.OutcomeReverted:
			*merged++
			*reverted++
		}
	}
	if n.FailedChecks != nil {
		*failed += *n.FailedChecks
	}
}

// mostCostly is the rows by cost, the most first (US dollars, then the tokens,
// then the ref), at most mostValueRows, and whether there were more.
func mostCostly(rows []wire.ReportValueRow) ([]wire.ReportValueRow, bool) {
	tokens := func(c wire.LineageCost) int64 { return c.InputTokens + c.OutputTokens }
	sort.SliceStable(rows, func(i, j int) bool {
		a, b := rows[i].Total, rows[j].Total
		if a.Cost["USD"] != b.Cost["USD"] {
			return a.Cost["USD"] > b.Cost["USD"]
		}
		if tokens(a) != tokens(b) {
			return tokens(a) > tokens(b)
		}
		return rows[i].Node.Ref < rows[j].Node.Ref
	})
	if len(rows) > mostValueRows {
		return rows[:mostValueRows], true
	}
	return rows, false
}
