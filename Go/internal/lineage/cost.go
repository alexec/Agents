package lineage

import (
	"slices"
	"sort"
	"strings"

	"github.com/alexec/agents/Go/wire"
)

// Cost on the link (#2350): each turn's cost, tokens and time are banked under the links
// that are active when it is banked, split evenly, so the totals add up to the real spend.
// What is banked stays where it went: a label changed later moves nothing. A node's banked
// cost is a wire.LineageCostNode; Rollup adds them up to a PR, an issue, a release or a
// repo. The host and the control plane add up the same way.

// The outcomes of a PR. The list is open.
const (
	OutcomeMerged   = "merged"
	OutcomeClosed   = "closed"
	OutcomeReverted = "reverted"
	// KindRepo is a rollup's node only: a repo or tracker, as LineageCostNode.repo names it.
	// It was project; a project is now only the record many folders join (#3275).
	KindRepo = "repo"
)

// Wasted says a PR's cost is waste: closed without a merge, or a merged revert.
func Wasted(n wire.LineageCostNode) bool {
	return n.Node.Kind == KindPR && n.Outcome != nil && (*n.Outcome == OutcomeClosed || *n.Outcome == OutcomeReverted)
}

// AddCost adds o to c.
func AddCost(c *wire.LineageCost, o wire.LineageCost) {
	if c.Cost == nil {
		c.Cost = map[string]float64{}
	}
	for k, v := range o.Cost {
		c.Cost[k] += v
	}
	c.InputTokens += o.InputTokens
	c.OutputTokens += o.OutputTokens
	if o.LimitTokens != nil {
		n := *o.LimitTokens
		if c.LimitTokens != nil {
			n += *c.LimitTokens
		}
		c.LimitTokens = &n
	}
	c.Turns += o.Turns
	c.WorkingSeconds += o.WorkingSeconds
	c.WaitingSeconds += o.WaitingSeconds
}

// Split is c in n even shares. The tokens are whole: the first shares take what is left
// over, so the shares add up to c.
func Split(c wire.LineageCost, n int) []wire.LineageCost {
	if n <= 1 {
		return []wire.LineageCost{c}
	}
	share := func(v int64, i int) int64 {
		q, r := v/int64(n), v%int64(n)
		if int64(i) < r {
			q++
		}
		return q
	}
	out := make([]wire.LineageCost, n)
	for i := range out {
		s := wire.LineageCost{Cost: map[string]float64{}, InputTokens: share(c.InputTokens, i), OutputTokens: share(c.OutputTokens, i),
			Turns: c.Turns / float64(n), WorkingSeconds: c.WorkingSeconds / float64(n), WaitingSeconds: c.WaitingSeconds / float64(n)}
		for k, v := range c.Cost {
			s.Cost[k] = v / float64(n)
		}
		if c.LimitTokens != nil {
			t := share(*c.LimitTokens, i)
			s.LimitTokens = &t
		}
		out[i] = s
	}
	return out
}

// RepoOf is the repo or tracker an issue's, PR's or release's ref is in: github:alexec/agents
// for github:alexec/agents#12 or github:alexec/agents/release/v1.2.0, gitlab:group/repo for
// gitlab:group/repo!4, linear for linear:ENG-4. Other refs have none.
func RepoOf(n wire.LineageNode) string {
	if n.Kind == KindRelease {
		if repo, _, ok := strings.Cut(n.Ref, "/release/"); ok {
			return repo
		}
		return ""
	}
	if n.Kind != KindIssue && n.Kind != KindPR {
		return ""
	}
	scheme, id, _ := strings.Cut(n.Ref, ":")
	if i := strings.LastIndexAny(id, "#!"); i > 0 {
		return scheme + ":" + id[:i]
	}
	return scheme
}

func blankCost() wire.LineageCost { return wire.LineageCost{Cost: map[string]float64{}} }

// IsReleaseRef says a ref in a node's PartOf is a release's (#3023): .../release/<tag>. A host
// from before #3878 sends its milestones there too, which nothing adds up now.
func IsReleaseRef(ref string) bool { return strings.Contains(ref, "/release/") }

// Rollup adds up of's cost from nodes, which hold each node once:
//
//   - a PR, or any other node: itself;
//   - an issue: itself and the PRs that fix it;
//   - a release (#3023): itself (a release session's own work, #4524), the PRs part of it,
//     and the issues those PRs fix;
//   - a repo (kind repo, ref as LineageCostNode.repo): every node in it.
//
// Each part counts once. Waste is the parts' PRs closed without a merge or reverted, and
// unlinked is the parts' sessions.
func Rollup(nodes []wire.LineageCostNode, of wire.LineageNode) wire.LineageCostRollup {
	r := wire.LineageCostRollup{Node: of, Own: blankCost(), Total: blankCost(), Waste: blankCost(), Unlinked: blankCost(),
		Parts: []wire.LineageCostNode{}}
	in := map[wire.LineageNode]bool{}
	has := func(list []string, ref string) bool {
		for _, s := range list {
			if s == ref {
				return true
			}
		}
		return false
	}
	switch of.Kind {
	case KindIssue:
		in[of] = true
		for _, n := range nodes {
			if n.Node.Kind == KindPR && has(n.Fixes, of.Ref) {
				in[n.Node] = true
			}
		}
	case KindRelease:
		in[of] = true
		fixed := map[string]bool{}
		for _, n := range nodes {
			if n.Node.Kind == KindPR && has(n.PartOf, of.Ref) {
				in[n.Node] = true
				for _, f := range n.Fixes {
					fixed[f] = true
				}
			}
		}
		for _, n := range nodes {
			if n.Node.Kind == KindIssue && fixed[n.Node.Ref] {
				in[n.Node] = true
			}
		}
	case KindRepo:
		for _, n := range nodes {
			if n.Repo != nil && *n.Repo == of.Ref {
				in[n.Node] = true
			}
		}
	default:
		in[of] = true
	}
	for _, n := range nodes {
		if !in[n.Node] {
			continue
		}
		if n.Node == of {
			AddCost(&r.Own, n.Banked)
		}
		AddCost(&r.Total, n.Banked)
		if Wasted(n) {
			AddCost(&r.Waste, n.Banked)
		}
		if n.Node.Kind == KindSession {
			AddCost(&r.Unlinked, n.Banked)
		}
		if n.Node.Kind == KindPR && n.Outcome != nil {
			switch *n.Outcome {
			case OutcomeMerged:
				r.PrsMerged++
			case OutcomeClosed:
				r.PrsClosed++
			case OutcomeReverted:
				r.PrsMerged++
				r.PrsReverted++
			}
		}
		if n.FailedChecks != nil {
			r.FailedChecks += *n.FailedChecks
		}
		r.Parts = append(r.Parts, n)
	}
	sort.SliceStable(r.Parts, func(i, j int) bool { return r.Parts[i].LastAt > r.Parts[j].LastAt })
	if len(r.Parts) > MostAnswer {
		r.Parts = r.Parts[:MostAnswer]
		t := true
		r.Limited = &t
	}
	return r
}

// The levels of an issue (#3265, #3562): a hierarchy level from its labels, else bug.
var hierarchyLevels = []string{"epic", "story", "task", "spike"}

// LevelOf is an issue's level from its labels: epic, story, task or spike, else bug, else
// none. A hierarchy level wins over bug, as a bug can be an epic's child.
func LevelOf(labels []string) string {
	bug := false
	for _, l := range labels {
		name := strings.ToLower(strings.TrimSpace(l))
		if slices.Contains(hierarchyLevels, name) {
			return name
		}
		bug = bug || name == "bug"
	}
	if bug {
		return "bug"
	}
	return ""
}

// LabelValue is the value of the first label with prefix, such as feature: or area:, in any
// case: work for feature:work.
func LabelValue(labels []string, prefix string) string {
	for _, l := range labels {
		l = strings.TrimSpace(l)
		if len(l) > len(prefix) && strings.EqualFold(l[:len(prefix)], prefix) {
			if v := strings.TrimSpace(l[len(prefix):]); v != "" {
				return v
			}
		}
	}
	return ""
}
