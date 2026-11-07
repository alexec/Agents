package agentsd

import (
	"context"
	"encoding/json"
	"log"
	"time"

	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// The Multiplier (#3903): multiplier/state, which the Mac window asks on each open, and
// multiplier/changed, told when a PR the agents worked on merges or a revert merges. With a
// control plane the figure is the person's over all their machines (multiplier/count, kept
// there by their lineage objects' tags); with none, or when it cannot answer, it is this
// machine's, from its merges in the cost ledger, kept as they happen so an ask reads no
// file and walks no graph.

// multiplierPatience is how long an ask of the control plane may take.
const multiplierPatience = 5 * time.Second

// multiplierState is multiplier/state.
func (d *Daemon) multiplierState(ctx context.Context) wire.Multiplier {
	now := nowFunc()
	m, ok := d.multiplierOfControl(ctx)
	if !ok {
		d.workMu.Lock()
		m = lineage.MultiplierOf(d.multiplierMergesLocked(), now)
		d.workMu.Unlock()
	}
	m.AgentsWorking = d.agentsWorking()
	return m
}

// multiplierOfControl is the control plane's count, when this machine has one and it answered.
func (d *Daemon) multiplierOfControl(ctx context.Context) (wire.Multiplier, bool) {
	ask := d.askControl.Load()
	if ask == nil {
		return wire.Multiplier{}, false
	}
	ctx, cancel := context.WithTimeout(ctx, multiplierPatience)
	defer cancel()
	raw, err := (*ask)(ctx, wire.CallMultiplierCount.Name, wire.Empty{})
	var m wire.Multiplier
	if err == nil {
		err = json.Unmarshal(raw, &m)
	}
	if err != nil {
		log.Printf("multiplier/count: this machine's own figure instead: %v", err)
		return wire.Multiplier{}, false
	}
	return m, true
}

// agentsWorking is this machine's agents with a turn starting or running.
func (d *Daemon) agentsWorking() int64 {
	var n int64
	for _, a := range d.Store.Agents() {
		if a.State == wire.AgentStateStarting || a.State == wire.AgentStateRunning {
			n++
		}
	}
	return n
}

// multiplierMergesLocked is this machine's merges in the range, counted from the ledger the
// first time and kept by noteMergeLocked after.
func (d *Daemon) multiplierMergesLocked() map[wire.LineageNode]lineage.Merge {
	if d.multiplierMerges == nil {
		d.refreshCostLinksLocked()
		d.multiplierMerges = lineage.Merges(ledgerNodes(d.costLedgerLocked()), lineage.MultiplierSince(nowFunc()))
	}
	return d.multiplierMerges
}

// noteMergeLocked keeps how c, a PR whose outcome just changed, counts, and says whether it
// is a merge or a merged revert the agents worked on: one that changes the figure. A session's
// links to it say so, as its sessions are only refreshed for a send.
func (d *Daemon) noteMergeLocked(c wire.LineageCostNode) bool {
	merges := d.multiplierMergesLocked()
	since := lineage.MultiplierSince(nowFunc())
	for n, m := range merges {
		if m.At < since {
			delete(merges, n)
		}
	}
	delete(merges, c.Node)
	if len(c.Sessions) == 0 {
		for _, l := range d.lineage().Links(c.Node).Links {
			if l.To == c.Node && l.From.Kind == lineage.KindSession &&
				(l.Rel == lineage.RelWorksOn || l.Rel == lineage.RelOpens || l.Rel == lineage.RelReviews) {
				c.Sessions = []string{l.From.Ref}
				break
			}
		}
	}
	for n, m := range lineage.Merges([]wire.LineageCostNode{c}, since) {
		merges[n] = m
		return true
	}
	return false
}

// multiplierChanged tells every client the figure after pr merged, away from the caller.
// With a control plane, the work goes to it first, so its count has the merge.
func (d *Daemon) multiplierChanged(pr wire.LineageNode) {
	safe.Go("multiplier/changed", func() {
		if d.askControl.Load() != nil {
			d.sendReport()
		}
		m := d.multiplierState(d.ctx)
		m.ChangedBy = &pr
		Broadcast(d, wire.NotifyMultiplierChanged, m)
	})
}
