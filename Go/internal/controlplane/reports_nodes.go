package controlplane

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"math"
	"slices"
	"sort"
	"strings"

	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/wire"
)

// reports/nodes (#3118): the lineage nodes of one kind in a scope, as Work ▸ Issues, Pull
// requests, Milestones and Releases list them (#3100). It reads the machines' nodes as
// reports/value does (scopeLineage), so a call reads no more of the store, and it rolls
// each row up the same way. Title, state and labels are what the machines' resolve caches
// sent (resolved): the control plane holds no forge token, so it never asks a forge.

const (
	// nodesPageMost bounds a page (bound data, not concurrency).
	nodesPageMost  = 100
	nodesPageFirst = 50
)

// nodesCursor is where the last page stopped: the last row's sort key and ref. The next
// page is the rows after it in the same order, so a row added between pages moves no
// other row to a second page or out of every page.
type nodesCursor struct {
	Kind string               `json:"k"`
	Sort wire.ReportNodesSort `json:"s"`
	Key  nodesKey             `json:"v"`
	Ref  string               `json:"r"`
}

// nodesKey is a row's place in a sort: none (no lead time) goes last, then by the values,
// the most first.
type nodesKey struct {
	None bool       `json:"n,omitempty"`
	By   [2]float64 `json:"b"`
}

func (c nodesCursor) encode() string {
	data, _ := json.Marshal(c)
	return base64.RawURLEncoding.EncodeToString(data)
}

func decodeNodesCursor(s string) (nodesCursor, bool) {
	data, err := base64.RawURLEncoding.DecodeString(s)
	var c nodesCursor
	if err != nil || json.Unmarshal(data, &c) != nil {
		return nodesCursor{}, false
	}
	return c, true
}

// nodesReport is reports/nodes for the scope the caller asks for.
func (s *Service) nodesReport(ctx context.Context, q wire.ReportNodesQuery, user string) (wire.ReportNodes, error) {
	switch q.Kind {
	case lineage.KindIssue, lineage.KindPR, lineage.KindMilestone, lineage.KindRelease:
	default:
		return wire.ReportNodes{}, fail(invalidParams, "Say a kind: issue, pr, milestone or release.")
	}
	order := wire.ReportNodesSortNewest
	if q.Sort != nil {
		order = *q.Sort
	}
	switch order {
	case wire.ReportNodesSortNewest, wire.ReportNodesSortCost, wire.ReportNodesSortWaste, wire.ReportNodesSortLeadTime:
	default:
		return wire.ReportNodes{}, fail(invalidParams, "Sort by newest, cost, waste or leadTime.")
	}
	limit := nodesPageFirst
	if q.Limit != nil {
		if *q.Limit < 1 || *q.Limit > nodesPageMost {
			return wire.ReportNodes{}, fail(invalidParams, "Ask for 1 to %d nodes a page.", nodesPageMost)
		}
		limit = int(*q.Limit)
	}
	var after *nodesCursor
	if q.Cursor != nil && *q.Cursor != "" {
		c, ok := decodeNodesCursor(*q.Cursor)
		if !ok || c.Kind != q.Kind || c.Sort != order {
			return wire.ReportNodes{}, fail(invalidParams, "The cursor is not from this list: ask for the first page again.")
		}
		after = &c
	}
	_, keep, _, err := s.reportScope(ctx, q.Scope, user, s.isAdmin(user))
	if err != nil {
		return wire.ReportNodes{}, err
	}
	nodes, err := s.scopeLineage(ctx, keep)
	if err != nil {
		return wire.ReportNodes{}, err
	}
	return nodesPage(nodeRows(nodes, q.Kind), q, order, after, limit), nil
}

// nodesPage filters rows, sorts them and cuts a page after the cursor.
func nodesPage(rows []wire.ReportNode, q wire.ReportNodesQuery, order wire.ReportNodesSort, after *nodesCursor, limit int) wire.ReportNodes {
	out := wire.ReportNodes{Nodes: []wire.ReportNode{}}
	kept := rows[:0]
	for _, r := range rows {
		if q.Repo != nil && *q.Repo != "" && !inRepo(r.Node.Ref, *q.Repo) {
			continue
		}
		if q.Since != nil && r.LastAt < *q.Since {
			continue
		}
		if r.Resolved == nil {
			out.Unresolved++
		}
		if q.State != nil && *q.State != "" && nodeState(r) != *q.State {
			continue
		}
		if q.Label != nil && *q.Label != "" && (r.Resolved == nil ||
			!slices.ContainsFunc(r.Resolved.Labels, func(l string) bool { return strings.EqualFold(l, *q.Label) })) {
			continue
		}
		kept = append(kept, r)
	}
	before := func(a, b wire.ReportNode) bool {
		ka, kb := nodesKeyOf(a, order), nodesKeyOf(b, order)
		return nodesBefore(ka, a.Node.Ref, kb, b.Node.Ref)
	}
	sort.Slice(kept, func(i, j int) bool { return before(kept[i], kept[j]) })
	start := 0
	if after != nil {
		start = sort.Search(len(kept), func(i int) bool {
			return nodesBefore(after.Key, after.Ref, nodesKeyOf(kept[i], order), kept[i].Node.Ref)
		})
	}
	page := kept[start:]
	if len(page) > limit {
		page = page[:limit]
		last := page[len(page)-1]
		next := nodesCursor{Kind: q.Kind, Sort: order, Key: nodesKeyOf(last, order), Ref: last.Node.Ref}.encode()
		out.Cursor, out.Limited = &next, true
	}
	out.Nodes = append(out.Nodes, page...)
	return out
}

// nodesBefore says a row with key a and ref ra comes before one with b and rb.
func nodesBefore(a nodesKey, ra string, b nodesKey, rb string) bool {
	if a.None != b.None {
		return b.None
	}
	if a.By != b.By {
		if a.By[0] != b.By[0] {
			return a.By[0] > b.By[0]
		}
		return a.By[1] > b.By[1]
	}
	return ra < rb
}

func nodesKeyOf(r wire.ReportNode, order wire.ReportNodesSort) nodesKey {
	tokens := func(c wire.LineageCost) float64 { return float64(c.InputTokens + c.OutputTokens) }
	switch order {
	case wire.ReportNodesSortCost:
		return nodesKey{By: [2]float64{r.Cost.Total.Cost["USD"], tokens(r.Cost.Total)}}
	case wire.ReportNodesSortWaste:
		return nodesKey{By: [2]float64{r.Cost.Waste.Cost["USD"], tokens(r.Cost.Waste)}}
	case wire.ReportNodesSortLeadTime:
		if r.LeadTimeSeconds == nil {
			return nodesKey{None: true}
		}
		return nodesKey{By: [2]float64{*r.LeadTimeSeconds}}
	}
	return nodesKey{By: [2]float64{float64(r.LastAt)}}
}

// inRepo says ref is in repo, a ref prefix such as github:alexec/Agents: github:alexec/Agents#12
// is, github:alexec/AgentsX#1 is not. Forges take a repo's name in any case.
func inRepo(ref, repo string) bool {
	ref, repo = strings.ToLower(ref), strings.ToLower(strings.TrimRight(repo, "/"))
	if !strings.HasPrefix(ref, repo) {
		return false
	}
	return len(ref) == len(repo) || strings.ContainsRune("#!/:", rune(ref[len(repo)]))
}

// nodeState is a row's state: its resolved state, else a PR's outcome (a reverted PR was
// merged), else none.
func nodeState(r wire.ReportNode) string {
	if r.Resolved != nil && r.Resolved.State != nil {
		return *r.Resolved.State
	}
	if r.Node.Kind == lineage.KindPR && r.Outcome != nil {
		if *r.Outcome == lineage.OutcomeClosed {
			return "closed"
		}
		return "merged"
	}
	return ""
}

// nodeRows is a row for each node of kind, rolled up as reports/value rolls up its rows: an
// issue with the PRs that fix it (also an issue only its PRs name), a PR on its own, a
// milestone with its issues and PRs and the PRs that fix those issues, and a release with its
// PRs and the issues those PRs fix.
func nodeRows(nodes []wire.LineageCostNode, kind string) []wire.ReportNode {
	byNode := map[wire.LineageNode]wire.LineageCostNode{}
	issues := map[string]wire.LineageCostNode{}
	fixers := map[string][]wire.LineageCostNode{}
	members := map[string][]wire.LineageCostNode{}
	var refs []string
	seen := map[string]bool{}
	add := func(ref string) {
		if !seen[ref] {
			seen[ref] = true
			refs = append(refs, ref)
		}
	}
	for _, n := range nodes {
		byNode[n.Node] = n
		switch n.Node.Kind {
		case lineage.KindIssue:
			issues[n.Node.Ref] = n
			if kind == lineage.KindIssue {
				add(n.Node.Ref)
			}
		case lineage.KindPR:
			for _, f := range n.Fixes {
				fixers[f] = append(fixers[f], n)
				if kind == lineage.KindIssue {
					add(f)
				}
			}
			if kind == lineage.KindPR {
				add(n.Node.Ref)
			}
		}
		for _, m := range n.PartOf {
			members[m] = append(members[m], n)
			if lineage.PartOfKind(m) == kind {
				add(m)
			}
		}
	}
	rows := make([]wire.ReportNode, 0, len(refs))
	for _, ref := range refs {
		of := wire.LineageNode{Kind: kind, Ref: ref}
		var parts []wire.LineageCostNode
		switch kind {
		case lineage.KindIssue:
			if n, ok := issues[ref]; ok {
				parts = append(parts, n)
			}
			parts = append(parts, fixers[ref]...)
		case lineage.KindPR:
			parts = []wire.LineageCostNode{byNode[of]}
		case lineage.KindMilestone:
			parts = dedupParts(members[ref], func(n wire.LineageCostNode) []wire.LineageCostNode {
				if n.Node.Kind != lineage.KindIssue {
					return nil
				}
				return fixers[n.Node.Ref]
			})
		case lineage.KindRelease:
			parts = dedupParts(members[ref], func(n wire.LineageCostNode) []wire.LineageCostNode {
				var fixed []wire.LineageCostNode
				for _, f := range n.Fixes {
					if issue, ok := issues[f]; ok {
						fixed = append(fixed, issue)
					}
				}
				return fixed
			})
		}
		rows = append(rows, nodeRow(of, byNode, parts))
	}
	return rows
}

// nodeRow is of's row from its parts; its own node, when a machine sent one, says its own
// cost, project, title, state and labels, and how a PR ended.
func nodeRow(of wire.LineageNode, byNode map[wire.LineageNode]wire.LineageCostNode, parts []wire.LineageCostNode) wire.ReportNode {
	sum, _ := valueRow(of, parts, wire.Date(-math.MaxFloat64))
	row := wire.ReportNode{Node: of, Cost: wire.ReportNodeCost{Own: wire.LineageCost{Cost: map[string]float64{}},
		Total: sum.Total, Waste: sum.Waste}, LeadTimeSeconds: sum.LeadTimeSeconds}
	if own, ok := byNode[of]; ok {
		lineage.AddCost(&row.Cost.Own, own.Banked)
		row.Project, row.Resolved, row.Outcome = own.Project, own.Resolved, own.Outcome
	}
	if row.Project == nil {
		if p := lineage.ProjectOf(of); p != "" {
			row.Project = &p
		}
	}
	sessions := map[string]bool{}
	for _, n := range parts {
		for _, s := range n.Sessions {
			sessions[s] = true
		}
		row.LastAt = max(row.LastAt, n.LastAt)
	}
	row.Sessions = int64(len(sessions))
	return row
}
