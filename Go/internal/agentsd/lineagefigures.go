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

// A release's Lineage panel (#4427, specs/4328-work-look/milestones.md notes 15, 16, 27 and
// 29): lineage/figures adds up what the cost ledger has for a release.
//
//   - The cost and the parts are lineage/cost's rollup; the sessions are its parts' sessions,
//     each once. A session this machine has gives its runtime and whether it runs now.
//   - Lead time: from the first start of work on the release's parts to the release, which
//     its links are at (the tag's commit time, lineagerelease.go).
//
// #3878 removed a milestone's panel (Released in, Finished in) and a release's Milestones
// finished: Work has no milestones now.
//
// Decided: one read for the panel, on this machine's totals as lineage/cost is, not the
// control plane's reports/nodes, because the pages ask the host that has the folder, and
// reports/nodes is a person's scope across machines, for Reports (#3224).

func (d *Daemon) registerLineageFigures() {
	On(d, wire.CallLineageFigures, func(_ context.Context, _ *Client, r wire.LineageNodeRequest) (wire.LineageFigures, error) {
		if r.Node.Kind != lineage.KindRelease {
			return wire.LineageFigures{}, Invalid("lineage/figures: a release, not a %s", r.Node.Kind)
		}
		return d.lineageFigures(r.Node), nil
	})
}

// lineageFigures is lineage/figures for a release.
func (d *Daemon) lineageFigures(of wire.LineageNode) wire.LineageFigures {
	d.lineageSettle(2 * time.Second)
	d.workMu.Lock()
	d.refreshCostLinksLocked()
	nodes := ledgerNodes(d.costLedgerLocked())
	d.workMu.Unlock()
	rollup := lineage.Rollup(nodes, of)
	out := wire.LineageFigures{Node: of, Cost: rollup.Total, Runtimes: []wire.LineageRuntimeCount{}, Limited: rollup.Limited}
	d.addSessionFigures(&out, rollup.Parts)
	out.LeadTimeSeconds = leadTimeTo(d.lineage().Links(of).Links, of, rollup.Parts)
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
