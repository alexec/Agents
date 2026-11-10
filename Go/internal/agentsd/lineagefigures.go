package agentsd

import (
	"cmp"
	"context"
	"slices"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/wire"
)

// A milestone's and a release's Lineage panel (#4427, specs/4328-work-look/milestones.md
// notes 15, 16, 27 and 29): lineage/figures adds up what the cost ledger has, by milestone
// and by release.
//
//   - The cost and the parts are lineage/cost's rollup; the sessions are its parts' sessions,
//     each once. A session this machine has gives its runtime and whether it runs now.
//   - Released in: each issue of the milestone (and each of its PRs that fixes none of its
//     issues) is taken by the first release (by version) a PR of it is part of. A milestone
//     shipped-in a release (by title) has that release too, with what it took, perhaps none.
//   - Finished in: a closed milestone's (as the resolve cache says it) newest release.
//   - Milestones finished: the milestones shipped-in the release, and the closed milestones
//     whose newest release is this one.
//   - Lead time: from the first start of work on the release's parts to the release, which
//     its links are at (the tag's commit time, lineagerelease.go).
//
// Decided: one read for the panel, on this machine's totals as lineage/cost is, not the
// control plane's reports/nodes, because the pages ask the host that has the folder, and
// reports/nodes is a person's scope across machines, for Reports (#3224).

func (d *Daemon) registerLineageFigures() {
	On(d, wire.CallLineageFigures, func(_ context.Context, _ *Client, r wire.LineageNodeRequest) (wire.LineageFigures, error) {
		if r.Node.Kind != lineage.KindMilestone && r.Node.Kind != lineage.KindRelease {
			return wire.LineageFigures{}, Invalid("lineage/figures: a milestone or a release, not a %s", r.Node.Kind)
		}
		return d.lineageFigures(r.Node), nil
	})
}

// lineageFigures is lineage/figures for a milestone or a release.
func (d *Daemon) lineageFigures(of wire.LineageNode) wire.LineageFigures {
	d.lineageSettle(2 * time.Second)
	d.workMu.Lock()
	d.refreshCostLinksLocked()
	nodes := ledgerNodes(d.costLedgerLocked())
	d.workMu.Unlock()
	rollup := lineage.Rollup(nodes, of)
	out := wire.LineageFigures{Node: of, Cost: rollup.Total, Runtimes: []wire.LineageRuntimeCount{}, Limited: rollup.Limited}
	d.addSessionFigures(&out, rollup.Parts)
	took := releasesTaking(nodes)
	links := d.lineage().Links(of).Links
	switch of.Kind {
	case lineage.KindMilestone:
		out.ReleasedIn = took[of.Ref]
		for _, l := range links {
			if l.From == of && l.Rel == lineage.RelShippedIn && l.EndedAt == nil && l.To.Kind == lineage.KindRelease &&
				!slices.ContainsFunc(out.ReleasedIn, func(t wire.LineageReleaseTook) bool { return t.Release == l.To }) {
				out.ReleasedIn = append(out.ReleasedIn, wire.LineageReleaseTook{Release: l.To, Tag: tagOfRelease(l.To)})
			}
		}
		sortReleasesTook(out.ReleasedIn)
		if n := len(out.ReleasedIn); n > 0 && d.milestoneClosed(of) {
			last := out.ReleasedIn[n-1].Release
			out.FinishedIn = &last
		}
	case lineage.KindRelease:
		finished := []wire.LineageNode{}
		for _, l := range links {
			if l.To == of && l.Rel == lineage.RelShippedIn && l.EndedAt == nil && l.From.Kind == lineage.KindMilestone {
				finished = append(finished, l.From)
			}
		}
		for ref, releases := range took {
			m := wire.LineageNode{Kind: lineage.KindMilestone, Ref: ref}
			if releases[len(releases)-1].Release == of && !slices.Contains(finished, m) && d.milestoneClosed(m) {
				finished = append(finished, m)
			}
		}
		slices.SortFunc(finished, func(a, b wire.LineageNode) int { return cmp.Compare(a.Ref, b.Ref) })
		for _, m := range finished {
			f := wire.LineageMilestoneFinished{Milestone: m}
			if r, ok := d.resolvedOf(m); ok && r.Title != "" {
				title := r.Title
				f.Title = &title
			}
			out.MilestonesFinished = append(out.MilestonesFinished, f)
		}
		out.LeadTimeSeconds = leadTimeTo(links, of, rollup.Parts)
	}
	return out
}

// addSessionFigures counts the parts' sessions, each once, and, for those this machine has,
// their runtimes and how many run now.
func (d *Daemon) addSessionFigures(out *wire.LineageFigures, parts []wire.LineageCostNode) {
	seen := map[string]bool{}
	byRuntime := map[string]int64{}
	for _, p := range parts {
		for _, ref := range p.Sessions {
			id, ok := strings.CutPrefix(ref, "session:")
			if !ok || seen[id] {
				continue
			}
			seen[id] = true
			out.Sessions++
			a := d.Store.Agent(wire.UUID(id))
			if a == nil {
				continue
			}
			if a.RuntimeID != "" {
				byRuntime[a.RuntimeID]++
			}
			switch a.State {
			case wire.AgentStateStarting, wire.AgentStateRunning, wire.AgentStateWaitingOnUser:
				out.Running++
			}
		}
	}
	for id, n := range byRuntime {
		out.Runtimes = append(out.Runtimes, wire.LineageRuntimeCount{RuntimeID: id, Sessions: n})
	}
	slices.SortFunc(out.Runtimes, func(a, b wire.LineageRuntimeCount) int {
		return cmp.Or(cmp.Compare(b.Sessions, a.Sessions), cmp.Compare(a.RuntimeID, b.RuntimeID))
	})
}

// releasesTaking is, by milestone ref, the releases that took its items: each issue part of
// it, and each PR part of it that fixes none of its issues, in the first release (by version)
// that one of its PRs is part of. An item no release took is not counted.
func releasesTaking(nodes []wire.LineageCostNode) map[string][]wire.LineageReleaseTook {
	fixing := map[string][]wire.LineageCostNode{}
	issuesOf := map[string]map[string]bool{}
	for _, n := range nodes {
		switch n.Node.Kind {
		case lineage.KindPR:
			for _, f := range n.Fixes {
				fixing[f] = append(fixing[f], n)
			}
		case lineage.KindIssue:
			for _, m := range milestoneRefsOf(n) {
				if issuesOf[m] == nil {
					issuesOf[m] = map[string]bool{}
				}
				issuesOf[m][n.Node.Ref] = true
			}
		}
	}
	counts := map[string]map[wire.LineageNode]int64{}
	add := func(m string, prs []wire.LineageCostNode) {
		rel, ok := firstRelease(prs)
		if !ok {
			return
		}
		if counts[m] == nil {
			counts[m] = map[wire.LineageNode]int64{}
		}
		counts[m][rel]++
	}
	for _, n := range nodes {
		for _, m := range milestoneRefsOf(n) {
			switch {
			case n.Node.Kind == lineage.KindIssue:
				add(m, fixing[n.Node.Ref])
			case n.Node.Kind == lineage.KindPR && !slices.ContainsFunc(n.Fixes, func(f string) bool { return issuesOf[m][f] }):
				add(m, []wire.LineageCostNode{n})
			}
		}
	}
	out := map[string][]wire.LineageReleaseTook{}
	for m, by := range counts {
		for rel, n := range by {
			out[m] = append(out[m], wire.LineageReleaseTook{Release: rel, Tag: tagOfRelease(rel), Items: n})
		}
		sortReleasesTook(out[m])
	}
	return out
}

// milestoneRefsOf is the milestones a node is part of, by ref.
func milestoneRefsOf(n wire.LineageCostNode) []string {
	var out []string
	for _, ref := range n.PartOf {
		if lineage.PartOfKind(ref) == lineage.KindMilestone {
			out = append(out, ref)
		}
	}
	return out
}

// firstRelease is the oldest release, by version, that any of prs is part of.
func firstRelease(prs []wire.LineageCostNode) (wire.LineageNode, bool) {
	var first wire.LineageNode
	for _, p := range prs {
		for _, ref := range p.PartOf {
			if lineage.PartOfKind(ref) != lineage.KindRelease {
				continue
			}
			rel := wire.LineageNode{Kind: lineage.KindRelease, Ref: ref}
			if first.Ref == "" || releaseLess(rel, first) {
				first = rel
			}
		}
	}
	return first, first.Ref != ""
}

// tagOfRelease is a release node's tag: v0.42.0 for github:o/r/release/v0.42.0.
func tagOfRelease(n wire.LineageNode) string {
	if i := strings.LastIndex(n.Ref, "/release/"); i >= 0 {
		return n.Ref[i+len("/release/"):]
	}
	return n.Ref
}

// releaseLess orders releases by their tags' versions, then by ref.
func releaseLess(a, b wire.LineageNode) bool {
	va, vb := versionOf(tagOfRelease(a)), versionOf(tagOfRelease(b))
	if va != vb {
		return versionLess(va, vb)
	}
	return a.Ref < b.Ref
}

func sortReleasesTook(list []wire.LineageReleaseTook) {
	slices.SortFunc(list, func(a, b wire.LineageReleaseTook) int {
		switch {
		case releaseLess(a.Release, b.Release):
			return -1
		case releaseLess(b.Release, a.Release):
			return 1
		}
		return 0
	})
}

// milestoneClosed says the resolve cache has m closed.
func (d *Daemon) milestoneClosed(m wire.LineageNode) bool {
	r, ok := d.resolvedOf(m)
	return ok && r.State != nil && *r.State == "closed"
}

// resolvedOf is n's title, state and labels as the resolve cache holds them, sent to be
// resolved when it holds none, so the next read has them.
func (d *Daemon) resolvedOf(n wire.LineageNode) (wire.LineageResolved, bool) {
	d.resolveMu.Lock()
	e, ok := d.resolveCache[n]
	d.resolveMu.Unlock()
	if !ok || !e.ok {
		d.resolveSoon(n)
		return wire.LineageResolved{}, false
	}
	return e.resolved, true
}

// leadTimeTo is the seconds from the first start of work on parts to the release, whose
// links are at its tag's time; absent with no start or no link.
func leadTimeTo(links []wire.LineageLink, release wire.LineageNode, parts []wire.LineageCostNode) *float64 {
	var at, start *wire.Date
	for _, l := range links {
		if l.To == release && (at == nil || l.At < *at) {
			a := l.At
			at = &a
		}
	}
	for _, p := range parts {
		if s := lineage.StartOf(p); s != nil && (start == nil || *s < *start) {
			start = s
		}
	}
	if at == nil || start == nil || *start > *at {
		return nil
	}
	secs := float64(*at - *start)
	return &secs
}
