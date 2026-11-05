package lineage

import (
	"math/rand/v2"
	"slices"
	"sort"
	"strings"

	"github.com/alexec/agents/Go/wire"
)

// Estimates from past work (#3559; the rule is the spike's, specs/3557-estimates/spec.md):
//
//   - An issue matches the closed issues with its type (bug or enhancement) and level; when
//     fewer than EstimateMinMatches match, those with its type; then all of them.
//   - Only issues that closed with a merged PR that fixes them count, and no epic.
//   - A figure is the median and the P10 to P90 of the matches.
//   - An epic adds up its open children by a simulation with a fixed seed: draw one match per
//     child, EstimateDraws times. Its times follow its steps: a draw's time is the sum over the
//     steps of the longest child in each.

const (
	// EstimateMinMatches is the fewest matches an estimate is made from.
	EstimateMinMatches = 5
	// EstimateDraws is an epic's simulation's draws.
	EstimateDraws = 1000
	// estimateSeed fixes the simulation, so the same history gives the same estimate.
	estimateSeed = 3557
)

// The rules an issue's estimate matched by, narrowest first.
const (
	MatchedByLevel = "level"
	MatchedByType  = "type"
	MatchedByAll   = "all"
)

// Past is a closed issue an estimate can match: its type, level and what it took, with the
// PRs that fix it.
type Past struct {
	Ref         string
	Type, Level string
	Cost        wire.LineageCost
	// Lead is from its first work to its last PR merged; Cycle from its start (#3562). Nil
	// when not known.
	Lead, Cycle *float64
}

// TypeOf is an issue's type from its labels: bug or enhancement, else none.
func TypeOf(labels []string) string {
	for _, want := range []string{"bug", "enhancement"} {
		for _, l := range labels {
			if strings.EqualFold(strings.TrimSpace(l), want) {
				return want
			}
		}
	}
	return ""
}

// History is the closed issues in nodes that an estimate can match: each issue that is not an
// epic, not open, and has a merged PR that fixes it.
func History(nodes []wire.LineageCostNode) []Past {
	fixers := map[string][]wire.LineageCostNode{}
	for _, n := range nodes {
		if n.Node.Kind == KindPR {
			for _, f := range n.Fixes {
				fixers[f] = append(fixers[f], n)
			}
		}
	}
	var out []Past
	for _, n := range nodes {
		if n.Node.Kind != KindIssue || (n.Level != nil && *n.Level == "epic") ||
			(n.Resolved != nil && n.Resolved.State != nil && *n.Resolved.State != "closed") {
			continue
		}
		p := Past{Ref: n.Node.Ref, Cost: blankCost()}
		if n.Level != nil {
			p.Level = *n.Level
		}
		if n.Resolved != nil {
			p.Type = TypeOf(n.Resolved.Labels)
		}
		AddCost(&p.Cost, n.Banked)
		first, start := n.FirstAt, n.StartedAt
		var merged *wire.Date
		for _, pr := range fixers[n.Node.Ref] {
			AddCost(&p.Cost, pr.Banked)
			if pr.FirstAt != nil && (first == nil || *pr.FirstAt < *first) {
				first = pr.FirstAt
			}
			if pr.StartedAt != nil && (start == nil || *pr.StartedAt < *start) {
				start = pr.StartedAt
			}
			if pr.Outcome != nil && *pr.Outcome == OutcomeMerged && pr.EndedAt != nil && (merged == nil || *pr.EndedAt > *merged) {
				merged = pr.EndedAt
			}
		}
		if merged == nil {
			continue
		}
		p.Lead, p.Cycle = since(first, *merged), since(start, *merged)
		out = append(out, p)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Ref < out[j].Ref })
	return out
}

func since(from *wire.Date, to wire.Date) *float64 {
	if from == nil || to < *from {
		return nil
	}
	s := float64(to - *from)
	return &s
}

// Matches is the past issues like one of typ and level, by the first rule with at least
// EstimateMinMatches, and that rule; none with too few in all. not is left out: the issue itself.
func Matches(history []Past, typ, level, not string) ([]Past, string) {
	rules := []struct {
		by    string
		match func(Past) bool
	}{
		{MatchedByLevel, func(p Past) bool { return p.Type == typ && p.Level == level }},
		{MatchedByType, func(p Past) bool { return p.Type == typ }},
		{MatchedByAll, func(Past) bool { return true }},
	}
	for _, r := range rules {
		var out []Past
		for _, p := range history {
			if p.Ref != not && r.match(p) {
				out = append(out, p)
			}
		}
		if len(out) >= EstimateMinMatches {
			return out, r.by
		}
	}
	return nil, ""
}

// figures is each figure of a set of past issues, by name; a figure a past issue lacks is not
// in its list.
type figures map[string][]float64

const (
	figInput   = "inputTokens"
	figOutput  = "outputTokens"
	figWorking = "workingSeconds"
	figLead    = "leadTimeSeconds"
	figCycle   = "cycleTimeSeconds"
	figCost    = "cost:"
)

func figuresOf(matches []Past) figures {
	f := figures{}
	for _, p := range matches {
		for currency, v := range p.Cost.Cost {
			f[figCost+currency] = append(f[figCost+currency], v)
		}
		f[figInput] = append(f[figInput], float64(p.Cost.InputTokens))
		f[figOutput] = append(f[figOutput], float64(p.Cost.OutputTokens))
		f[figWorking] = append(f[figWorking], p.Cost.WorkingSeconds)
		if p.Lead != nil {
			f[figLead] = append(f[figLead], *p.Lead)
		}
		if p.Cycle != nil {
			f[figCycle] = append(f[figCycle], *p.Cycle)
		}
	}
	return f
}

// put sets e's figures from f: each with at least EstimateMinMatches values.
func put(e *wire.LineageEstimate, f figures) {
	r := func(name string) *wire.LineageEstimateRange {
		if len(f[name]) < EstimateMinMatches {
			return nil
		}
		return rangeOf(f[name])
	}
	for name := range f {
		if currency, ok := strings.CutPrefix(name, figCost); ok {
			if v := r(name); v != nil {
				if e.Cost == nil {
					e.Cost = map[string]wire.LineageEstimateRange{}
				}
				e.Cost[currency] = *v
			}
		}
	}
	e.InputTokens, e.OutputTokens, e.WorkingSeconds = r(figInput), r(figOutput), r(figWorking)
	e.LeadTimeSeconds, e.CycleTimeSeconds = r(figLead), r(figCycle)
}

// rangeOf is the median and P10 to P90 of values, between the nearest two.
func rangeOf(values []float64) *wire.LineageEstimateRange {
	v := slices.Clone(values)
	sort.Float64s(v)
	return &wire.LineageEstimateRange{Median: percentile(v, 0.5), P10: percentile(v, 0.1), P90: percentile(v, 0.9)}
}

func percentile(sorted []float64, p float64) float64 {
	at := p * float64(len(sorted)-1)
	i := int(at)
	if i+1 >= len(sorted) {
		return sorted[len(sorted)-1]
	}
	return sorted[i] + (at-float64(i))*(sorted[i+1]-sorted[i])
}

// landsAt is start plus the cycle time.
func landsAt(e *wire.LineageEstimate, start wire.Date) {
	if c := e.CycleTimeSeconds; c != nil {
		e.LandsAt = &wire.LineageEstimateDates{Median: start + wire.Date(c.Median), P10: start + wire.Date(c.P10),
			P90: start + wire.Date(c.P90)}
	}
}

// EstimateIssue estimates an issue with labels from history, landing from start.
func EstimateIssue(history []Past, of wire.LineageNode, labels []string, start wire.Date) wire.LineageEstimate {
	e, matches := issueEstimate(history, of, labels)
	put(&e, figuresOf(matches))
	landsAt(&e, start)
	return e
}

func issueEstimate(history []Past, of wire.LineageNode, labels []string) (wire.LineageEstimate, []Past) {
	e := wire.LineageEstimate{Node: of, ClosedIssues: int64(len(history))}
	typ, level := TypeOf(labels), LevelOf(labels)
	if typ != "" {
		e.Type = &typ
	}
	if level != "" {
		e.Level = &level
	}
	matches, by := Matches(history, typ, level, of.Ref)
	if by != "" {
		e.MatchedBy = &by
	}
	e.Matches = int64(len(matches))
	return e, matches
}

// EpicChild is a child of an epic, as its plan says it.
type EpicChild struct {
	Node   wire.LineageNode
	Labels []string
	Step   int64
	Open   bool
}

// EstimateEpic estimates an epic: its open children by the simulation, and what its closed
// children spent from nodes, landing from start.
func EstimateEpic(history []Past, nodes []wire.LineageCostNode, of wire.LineageNode, labels []string,
	children []EpicChild, start wire.Date) wire.LineageEstimate {
	e := wire.LineageEstimate{Node: of, ClosedIssues: int64(len(history)), Children: []wire.LineageEstimate{}}
	if typ := TypeOf(labels); typ != "" {
		e.Type = &typ
	}
	if level := LevelOf(labels); level != "" {
		e.Level = &level
	}
	spent := blankCost()
	var open, closed int64
	type kid struct {
		step int64
		f    figures
	}
	var kids []kid
	used := map[string]bool{}
	children = slices.Clone(children)
	slices.SortStableFunc(children, func(a, b EpicChild) int { return int(a.Step - b.Step) })
	for _, c := range children {
		if !c.Open {
			closed++
			AddCost(&spent, Rollup(nodes, c.Node).Total)
			continue
		}
		open++
		ce, matches := issueEstimate(history, c.Node, c.Labels)
		step := c.Step
		ce.Step = &step
		f := figuresOf(matches)
		put(&ce, f)
		e.Children = append(e.Children, ce)
		for _, m := range matches {
			used[m.Ref] = true
		}
		kids = append(kids, kid{c.Step, f})
	}
	e.OpenChildren, e.ClosedChildren, e.Spent, e.Matches = &open, &closed, &spent, int64(len(used))
	if len(kids) == 0 || len(used) == 0 {
		return e
	}
	// The figures every open child has, in a fixed order so the seed fixes the draws. Each draw
	// adds them up, but takes the longest time per step.
	var names []string
	for name := range kids[0].f {
		if !slices.ContainsFunc(kids, func(k kid) bool { return len(k.f[name]) < EstimateMinMatches }) {
			names = append(names, name)
		}
	}
	sort.Strings(names)
	rng := rand.New(rand.NewPCG(estimateSeed, estimateSeed))
	sums := figures{}
	for range EstimateDraws {
		draw := map[string]float64{}
		longest := map[string]map[int64]float64{figLead: {}, figCycle: {}}
		for _, k := range kids {
			for _, name := range names {
				values := k.f[name]
				v := values[rng.IntN(len(values))]
				if per, ok := longest[name]; ok {
					per[k.step] = max(per[k.step], v)
				} else {
					draw[name] += v
				}
			}
		}
		for name, per := range longest {
			for _, v := range per {
				draw[name] += v
			}
		}
		for name, v := range draw {
			sums[name] = append(sums[name], v)
		}
	}
	put(&e, sums)
	landsAt(&e, start)
	return e
}
