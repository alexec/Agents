package agentsd

import (
	"fmt"
	"strings"

	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/wire"
)

// An epic's overrun notice (#4529): an open epic whose spend passes 2×, then 3×, its kept
// estimate (lineage.OverrunOf) tells the person once for each, while there is still a choice
// to stop, trim or go on. Before, an overrun showed only in the lead's closing summary. The
// notice is on a session of the epic (its lead's) that is not archived, so a tap opens the
// chat where that choice is made; with none, it waits for the next spend. The threshold told
// is kept in the cost ledger, so a restart does not say it again. It is not taken from the
// person's notice bucket: it comes once per threshold.

// overrunNoticePrefix starts an overrun notice's id; the rest is the epic's ref.
const overrunNoticePrefix = "overrun:"

// overrunNotice is an epic past a threshold it was not told at, with its sessions.
type overrunNotice struct {
	key      string
	over     lineage.Overrun
	title    string
	sessions []string
}

// overrunsLocked is the epics that work's cost counts towards that passed a threshold since
// the person was last told. Called with workMu held.
func (d *Daemon) overrunsLocked(work []wire.LineageNode) []overrunNotice {
	f := d.costLedgerLocked()
	byKey := map[wire.LineageNode]wire.LineageCostNode{}
	epics := map[wire.LineageNode]bool{}
	for _, n := range work {
		if c, ok := f.Nodes[costKey(n)]; ok {
			byKey[n] = c
		}
		// A PR's fixed issues, so EpicsOf finds their parents.
		for _, ref := range byKey[n].Fixes {
			i := wire.LineageNode{Kind: lineage.KindIssue, Ref: ref}
			if c, ok := f.Nodes[costKey(i)]; ok {
				byKey[i] = c
			}
		}
		for _, e := range lineage.EpicsOf(byKey, n) {
			if c, ok := f.Nodes[costKey(e)]; ok && c.Estimate != nil && c.Estimate.MatchedBy == nil {
				epics[e] = true
			}
		}
	}
	if len(epics) == 0 {
		return nil
	}
	nodes := ledgerNodes(f)
	var out []overrunNotice
	for e := range epics {
		o, ok := lineage.OverrunOf(nodes, e)
		k := costKey(e)
		if !ok || o.Passed <= f.Overruns[k] {
			continue
		}
		c := f.Nodes[k]
		title := ""
		if c.Resolved != nil {
			title = c.Resolved.Title
		}
		out = append(out, overrunNotice{key: k, over: o, title: title, sessions: c.Sessions})
	}
	return out
}

// postOverrunNotices posts each notice on a session of its epic that is not archived, and
// keeps its threshold as told; one with no such session is not told yet.
func (d *Daemon) postOverrunNotices(told []overrunNotice) {
	for _, t := range told {
		agent, ok := d.overrunAgent(t.sessions)
		if !ok {
			continue
		}
		d.workMu.Lock()
		f := d.costLedgerLocked()
		if t.over.Passed <= f.Overruns[t.key] {
			d.workMu.Unlock()
			continue
		}
		if f.Overruns == nil {
			f.Overruns = map[string]int64{}
		}
		f.Overruns[t.key] = t.over.Passed
		d.costChangedLocked()
		d.workMu.Unlock()
		id := overrunNoticePrefix + t.over.Epic.Ref
		d.attentionMu.Lock()
		kept := d.notices[:0]
		for _, n := range d.notices {
			if n.id != id {
				kept = append(kept, n)
			}
		}
		d.notices = append(kept, postedNotice{id: id, agentID: agent, raised: now(), h3: overrunWords(t)})
		d.attentionMu.Unlock()
		d.reconsider()
	}
}

// overrunAgent is the first of sessions (refs, as a cost node keeps them) that is an agent in
// the store and not archived.
func (d *Daemon) overrunAgent(sessions []string) (wire.UUID, bool) {
	for _, ref := range sessions {
		id, ok := strings.CutPrefix(ref, "session:")
		if !ok {
			continue
		}
		if a := d.Store.Agent(wire.UUID(id)); a != nil && a.State != wire.AgentStateArchived {
			return a.ID, true
		}
	}
	return "", false
}

// overrunWords is the notice's line: "Epic #4533, Forecasting, has cost $412.00: 2.2× its
// estimate of $190.00. Stop it, trim it or go on."
func overrunWords(t overrunNotice) string {
	name := "Epic " + issueWords(t.over.Epic.Ref)
	if t.title != "" {
		name += ", " + t.title + ","
	}
	return fmt.Sprintf("%s has cost %s: %.1f× its estimate of %s. Stop it, trim it or go on.", name,
		costWords(t.over.Spent, t.over.Currency), t.over.Spent/t.over.Estimate, costWords(t.over.Estimate, t.over.Currency))
}

// issueWords is an issue's ref as a person says it: #4533 for github:o/r#4533, else the ref.
func issueWords(ref string) string {
	if i := strings.LastIndex(ref, "#"); i >= 0 {
		return ref[i:]
	}
	return ref
}
