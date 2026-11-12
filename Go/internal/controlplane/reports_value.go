package controlplane

import (
	"context"
	"encoding/json"
	"math"
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
	// The overhead over the 14 days to now, whatever the range (#4524).
	overhead := lineage.Overhead(nodes, now)
	out.Overhead = &overhead
	// The delivery figures over the 4 weeks to now, whatever the range (#4555).
	if out.Delivery, err = s.keptDelivery(ctx, keep, nodes, now); err != nil {
		return wire.ReportValue{}, err
	}
	return out, nil
}

// scopeLineage is the nodes of the machines whose people keep says, each node once, its
// machines' copies added up.
func (s *Service) scopeLineage(ctx context.Context, keep func(person string) bool) ([]wire.LineageCostNode, error) {
	keys, read, err := s.scopeLineageKeys(ctx, keep)
	if err != nil {
		return nil, err
	}
	return s.readLineage(ctx, keys, read)
}

// scopeLineageKeys is the listing of the machines' lineage objects, and those of it whose
// people keep says.
func (s *Service) scopeLineageKeys(ctx context.Context, keep func(person string) bool) (keys, read []store.Key, err error) {
	keys, err = s.cfg.Store.List(ctx, lineagePrefix)
	if err != nil {
		return nil, nil, fail(storeUnavailable, "The reports could not be read: %v", err)
	}
	known := map[string]string{}
	for _, h := range s.records.Hosts() {
		known[strings.ToLower(h.ID)] = h.ID
	}
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
	return keys, read, nil
}

// readLineage is the nodes of the objects read, of the listing keys, each node once, its
// machines' copies added up.
func (s *Service) readLineage(ctx context.Context, keys, read []store.Key) ([]wire.LineageCostNode, error) {
	// By entity tag and storeReadsAtOnce at a time (#2975), not one machine after another.
	objects, err := s.storeReads.read(ctx, s.cfg.Store, lineagePrefix, keys, read)
	if err != nil {
		return nil, fail(storeUnavailable, "The reports could not be read: %v", err)
	}
	byNode := map[wire.LineageNode]*wire.LineageCostNode{}
	var names lineage.Names
	for _, data := range objects {
		var kept storedLineage
		if data == nil || json.Unmarshal(data, &kept) != nil {
			continue
		}
		for _, n := range kept.Nodes {
			// A copy from a release before #4800 holds the old ref form.
			n = lineage.FullCostNode(n, nil)
			n.Node = names.Name(n.Node)
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
	// The first start any machine saw, and the level, feature, epic and milestone (#4620) of
	// the copy that knows them, the newest first (#3562).
	if n.StartedAt != nil && (have.StartedAt == nil || *n.StartedAt < *have.StartedAt) {
		have.StartedAt = n.StartedAt
	}
	newer := n.LastAt > have.LastAt
	for _, f := range []struct{ have, n **string }{{&have.Level, &n.Level}, {&have.Feature, &n.Feature},
		{&have.Parent, &n.Parent}, {&have.Milestone, &n.Milestone}} {
		if *f.n != nil && (*f.have == nil || newer) {
			*f.have = *f.n
		}
	}
	// The estimate made for the earliest start (#3561).
	if n.Estimate != nil && (have.Estimate == nil || n.Estimate.At < have.Estimate.At) {
		have.Estimate = n.Estimate
	}
	// The first landing forecast any machine kept (#4528), as each keeps its first.
	if n.Forecast != nil && (have.Forecast == nil || n.Forecast.At < have.Forecast.At) {
		have.Forecast = n.Forecast
	}
	if n.LastAt > have.LastAt {
		have.LastAt = n.LastAt
	}
}

// valueOf adds up the nodes that changed since: the totals over each node once, and a row
// for each issue and release with a part that changed since.
func valueOf(nodes []wire.LineageCostNode, since wire.Date) wire.ReportValue {
	blank := func() wire.LineageCost { return wire.LineageCost{Cost: map[string]float64{}} }
	out := wire.ReportValue{Total: blank(), Waste: blank(), Unlinked: blank(), PerMergedPR: map[string]float64{},
		Issues: []wire.ReportValueRow{}, Releases: []wire.ReportValueRow{}}
	byRef := map[string]wire.LineageCostNode{}
	// A release's own node (#4524): what a release session banked on it.
	ownRelease := map[string]wire.LineageCostNode{}
	fixers := map[string][]wire.LineageCostNode{}
	members := map[string][]wire.LineageCostNode{}
	var issues, releases []string
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
		case lineage.KindRelease:
			if _, ok := members[n.Node.Ref]; !ok {
				releases = append(releases, n.Node.Ref)
				members[n.Node.Ref] = nil
			}
			ownRelease[n.Node.Ref] = n
		}
		for _, m := range n.PartOf {
			if !lineage.IsReleaseRef(m) {
				continue
			}
			if _, ok := members[m]; !ok {
				releases = append(releases, m)
			}
			members[m] = append(members[m], n)
		}
		if n.LastAt < since {
			continue
		}
		switch n.Node.Kind {
		case lineage.KindIssue, lineage.KindPR, lineage.KindRelease:
			lineage.AddCost(&out.Total, n.Banked)
		case lineage.KindSession:
			lineage.AddCost(&out.Unlinked, n.Banked)
		}
		if lineage.Wasted(n) {
			lineage.AddCost(&out.Waste, n.Banked)
		}
		countPR(n, &out.PrsMerged, &out.PrsClosed, &out.PrsReverted, &out.FailedChecks)
	}
	// All in (#4524): the work, and the turns that went on no work.
	loaded := wire.LineageCost{Cost: map[string]float64{}}
	lineage.AddCost(&loaded, out.Total)
	lineage.AddCost(&loaded, out.Unlinked)
	out.Loaded = &loaded
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
	for _, ref := range releases {
		// Its PRs, and the issues those PRs fix, each once (#3023; the same shape as
		// lineage.Rollup's KindRelease case): only PRs are ever part-of a release.
		var own []wire.LineageCostNode
		if n, ok := ownRelease[ref]; ok {
			own = append(own, n)
		}
		parts := dedupParts(append(own, members[ref]...), func(n wire.LineageCostNode) []wire.LineageCostNode {
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
	out.ForecastScore = forecastScore(byRef, issueParts, children, since)
	out.OpenEpics = openEpics(nodes, children)
	limited := false
	out.Issues, limited = mostCostly(out.Issues)
	var more bool
	out.Releases, more = mostCostly(out.Releases)
	if limited || more {
		t := true
		out.Limited = &t
	}
	return out
}

// secondsPerDay converts a span of wire.Date (seconds) to days.
const secondsPerDay = 24 * 60 * 60

// estimateError is how far the estimates kept at the start of work were from what the issues
// took (#3561), over the issues closed in the range: those with a merged PR that ended since,
// that are not open and not an epic. None when no issue had an estimate. coverage (#4525) is
// how often the kept P10-P90 dollar range held the actual, over the issues whose kept estimate
// has one; landsAtErrorDays is the median of how many days the kept landing date was off by,
// over the issues whose kept estimate has one.
func estimateError(issues []string, byRef map[string]wire.LineageCostNode, issueParts func(string) []wire.LineageCostNode,
	children map[string][]string, since wire.Date) *wire.ReportEstimateError {
	var costs, works, landsAtDays []float64
	var n, checked, covered int64
	for _, ref := range issues {
		node, ok := byRef[ref]
		if !ok || node.Estimate == nil || len(children[ref]) > 0 || (node.Level != nil && *node.Level == "epic") ||
			(node.Resolved != nil && node.Resolved.State != nil && *node.Resolved.State == "open") {
			continue
		}
		actual := wire.LineageCost{Cost: map[string]float64{}}
		var merged *wire.Date
		for _, p := range issueParts(ref) {
			lineage.AddCost(&actual, p.Banked)
			if p.Node.Kind == lineage.KindPR && p.Outcome != nil && *p.Outcome == lineage.OutcomeMerged && p.EndedAt != nil &&
				(merged == nil || *p.EndedAt > *merged) {
				merged = p.EndedAt
			}
		}
		if merged == nil || *merged < since {
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
		if p10, ok := node.Estimate.CostP10["USD"]; ok {
			if p90, ok := node.Estimate.CostP90["USD"]; ok {
				if a, ok := actual.Cost["USD"]; ok {
					checked++
					if a >= p10 && a <= p90 {
						covered++
					}
				}
			}
		}
		if node.Estimate.LandsAt != nil {
			landsAtDays = append(landsAtDays, math.Abs(float64(*merged-node.Estimate.LandsAt.Median))/secondsPerDay)
		}
	}
	if n == 0 {
		return nil
	}
	out := &wire.ReportEstimateError{Issues: n, Cost: median(costs), WorkingSeconds: median(works), LandsAtErrorDays: median(landsAtDays)}
	if checked > 0 {
		c := float64(covered) / float64(checked)
		out.Coverage = &c
	}
	return out
}

// mostOpenEpics bounds reports/value's openEpics.
const mostOpenEpics = 20

// isEpic says an issue is an epic: its level says so, or it has children.
func isEpic(n wire.LineageCostNode, children map[string][]string) bool {
	return len(children[n.Node.Ref]) > 0 || (n.Level != nil && *n.Level == "epic")
}

// isOpen says a node's connector last said it is open.
func isOpen(n wire.LineageCostNode) bool {
	return n.Resolved != nil && n.Resolved.State != nil && *n.Resolved.State == "open"
}

// forecastScore is how the kept landing forecasts of the epics that landed since scored
// (#4528): an epic lands when the last PR of it or its children merges. None when no epic
// that landed since had a forecast kept.
func forecastScore(byRef map[string]wire.LineageCostNode, issueParts func(string) []wire.LineageCostNode,
	children map[string][]string, since wire.Date) *wire.ReportForecastScore {
	refs := make([]string, 0, len(byRef))
	for ref := range byRef {
		refs = append(refs, ref)
	}
	sort.Strings(refs)
	out := wire.ReportForecastScore{}
	var off []float64
	for _, ref := range refs {
		n := byRef[ref]
		if n.Forecast == nil || !isEpic(n, children) || isOpen(n) {
			continue
		}
		var landed *wire.Date
		for _, p := range epicParts(ref, children[ref], issueParts) {
			if p.Node.Kind == lineage.KindPR && p.Outcome != nil && *p.Outcome == lineage.OutcomeMerged && p.EndedAt != nil &&
				(landed == nil || *p.EndedAt > *landed) {
				landed = p.EndedAt
			}
		}
		if landed == nil || *landed < since {
			continue
		}
		out.Epics++
		if *landed <= n.Forecast.P50 {
			out.P50Held++
		}
		if *landed <= n.Forecast.P85 {
			out.P85Held++
		}
		off = append(off, math.Abs(float64(*landed-n.Forecast.P50))/secondsPerDay)
	}
	if out.Epics == 0 {
		return nil
	}
	out.ErrorDays = median(off)
	return &out
}

// openEpics is the epics whose connector says they are open, the most recently changed
// first, at most mostOpenEpics (#4528).
func openEpics(nodes []wire.LineageCostNode, children map[string][]string) []wire.LineageNode {
	var open []wire.LineageCostNode
	for _, n := range nodes {
		if n.Node.Kind == lineage.KindIssue && isEpic(n, children) && isOpen(n) {
			open = append(open, n)
		}
	}
	sort.SliceStable(open, func(i, j int) bool { return open[i].LastAt > open[j].LastAt })
	out := []wire.LineageNode{}
	for i, n := range open {
		if i == mostOpenEpics {
			break
		}
		out = append(out, n.Node)
	}
	return out
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
