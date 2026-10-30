package controlplane

import (
	"context"
	"encoding/json"
	"slices"
	"sort"
	"strings"
	"time"

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
	byNode := map[wire.LineageNode]*wire.LineageCostNode{}
	for _, k := range keys {
		host := strings.TrimSuffix(strings.TrimPrefix(k.Key, lineagePrefix), ".json")
		// A machine removed since: its person is not known, so only an admin sees it.
		person := ""
		if id, ok := known[host]; ok {
			person = s.ownerOf(id)
		}
		if !keep(person) {
			continue
		}
		object, err := s.cfg.Store.Get(ctx, k.Key)
		if err != nil {
			return nil, fail(storeUnavailable, "The reports could not be read: %v", err)
		}
		var kept storedLineage
		if object == nil || json.Unmarshal(object.Data, &kept) != nil {
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
			c.Fixes, c.PartOf = slices.Clone(n.Fixes), slices.Clone(n.PartOf)
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

// mergeNode adds another machine's copy of a node to have: the cost adds up, the links
// join, and the newest copy says how a PR ended. Failed checks are the most any machine
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
	if have.Project == nil {
		have.Project = n.Project
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
	if n.LastAt > have.LastAt {
		have.LastAt = n.LastAt
	}
}

// valueOf adds up the nodes that changed since: the totals over each node once, and a row
// for each issue and milestone with a part that changed since.
func valueOf(nodes []wire.LineageCostNode, since wire.Date) wire.ReportValue {
	blank := func() wire.LineageCost { return wire.LineageCost{Cost: map[string]float64{}} }
	out := wire.ReportValue{Total: blank(), Waste: blank(), Unlinked: blank(), PerMergedPR: map[string]float64{},
		Issues: []wire.ReportValueRow{}, Milestones: []wire.ReportValueRow{}}
	byRef := map[string]wire.LineageCostNode{}
	fixers := map[string][]wire.LineageCostNode{}
	members := map[string][]wire.LineageCostNode{}
	var issues, milestones []string
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
				milestones = append(milestones, m)
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
	var leads []float64
	for _, ref := range issues {
		row, ok := valueRow(wire.LineageNode{Kind: lineage.KindIssue, Ref: ref}, issueParts(ref), since)
		if !ok {
			continue
		}
		if row.LeadTimeSeconds != nil {
			leads = append(leads, *row.LeadTimeSeconds)
		}
		out.Issues = append(out.Issues, row)
	}
	for _, ref := range milestones {
		// Its issues and PRs, and the PRs that fix those issues, each once.
		var parts []wire.LineageCostNode
		in := map[wire.LineageNode]bool{}
		add := func(n wire.LineageCostNode) {
			if !in[n.Node] {
				in[n.Node] = true
				parts = append(parts, n)
			}
		}
		for _, n := range members[ref] {
			add(n)
			if n.Node.Kind == lineage.KindIssue {
				for _, pr := range fixers[n.Node.Ref] {
					add(pr)
				}
			}
		}
		if row, ok := valueRow(wire.LineageNode{Kind: lineage.KindMilestone, Ref: ref}, parts, since); ok {
			out.Milestones = append(out.Milestones, row)
		}
	}
	if len(leads) > 0 {
		sort.Float64s(leads)
		m := leads[len(leads)/2]
		if len(leads)%2 == 0 {
			m = (leads[len(leads)/2-1] + m) / 2
		}
		out.LeadTimeSeconds = &m
	}
	limited := false
	out.Issues, limited = mostCostly(out.Issues)
	var more bool
	out.Milestones, more = mostCostly(out.Milestones)
	if limited || more {
		t := true
		out.Limited = &t
	}
	return out
}

// valueRow adds up of's parts, or says no when none of them changed since. Its lead time
// is from the first work on any part to the last of its PRs merged.
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
