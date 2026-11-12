package agentsd

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// A milestone's late notice (#4654), the other half of #4529: the first time a milestone's P85
// landing date (lineage.MilestoneForecastOf, method H) is after its due date on GitHub, the
// person is told once, while there is still time to trim it or move the date. It is checked when
// a milestone forecast is made: when lineage/forecast asks for one, and at most once an hour for
// each milestone whose issues get spend. A milestone with no due date, or whose scope is still
// growing (its dates are a floor), gets none. The due date told is kept in the cost ledger, so a
// restart does not say it again; a new due date can be told once more. The notice is on a session
// of the milestone's issues that is not archived; with none, it waits for the next check.

// milestoneNoticePrefix starts a milestone's late notice id; the rest is its repo and its name.
const milestoneNoticePrefix = "milestone-late:"

// milestoneCheckEvery is how often spend makes a milestone's forecast again.
const milestoneCheckEvery = time.Hour

// milestoneDueWait bounds the read of a repo's milestones.
const milestoneDueWait = 30 * time.Second

// milestoneOf is a milestone in a repo, as its items' nodes keep them.
type milestoneOf struct{ repo, name string }

func (m milestoneOf) key() string { return strings.ToLower(m.repo + "\t" + m.name) }

// milestonesDueLocked is the milestones of work's issues (and of a PR's fixed issues) not
// checked in the last milestoneCheckEvery, marked as checked now. Called with workMu held.
func (d *Daemon) milestonesDueLocked(work []wire.LineageNode, now time.Time) []milestoneOf {
	f := d.costLedgerLocked()
	var out []milestoneOf
	add := func(n wire.LineageCostNode) {
		m := milestoneOf{deref(n.Repo), deref(n.Milestone)}
		if n.Node.Kind != lineage.KindIssue || m.repo == "" || m.name == "" {
			return
		}
		if at, ok := d.milestoneChecked[m.key()]; ok && now.Sub(at) < milestoneCheckEvery {
			return
		}
		if d.milestoneChecked == nil {
			d.milestoneChecked = map[string]time.Time{}
		}
		d.milestoneChecked[m.key()] = now
		out = append(out, m)
	}
	for _, n := range work {
		c, ok := f.Nodes[costKey(n)]
		if !ok {
			continue
		}
		add(c)
		for _, ref := range c.Fixes {
			if i, ok := f.Nodes[costKey(wire.LineageNode{Kind: lineage.KindIssue, Ref: ref})]; ok {
				add(i)
			}
		}
	}
	return out
}

// checkMilestones makes each milestone's forecast again, away from the caller, and tells the
// person of one that is late.
func (d *Daemon) checkMilestones(due []milestoneOf) {
	if len(due) == 0 {
		return
	}
	safe.Go("milestone due dates", func() {
		for _, m := range due {
			d.tellMilestoneLate(m, d.milestoneForecastIn(m.name, m.repo, lineage.WhatIf{}))
		}
	})
}

// tellMilestoneLate posts m's late notice when f's P85 date is after m's due date on its forge
// and that due date was not told yet.
func (d *Daemon) tellMilestoneLate(m milestoneOf, f wire.LineageForecast) {
	if f.Lands == nil || f.Lands.Growing != nil && *f.Lands.Growing {
		return
	}
	r, err := wire.ParseRef(lineage.FullRepoText(m.repo))
	if err != nil || r.Provider != "github" || r.Type != "repo" {
		return
	}
	path := r.ID
	gh, err := d.forgeGitHub()
	if err != nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), milestoneDueWait)
	defer cancel()
	listed, err := gh.Milestones(ctx, path)
	if err != nil {
		return
	}
	due := ""
	for _, l := range listed {
		if strings.EqualFold(l.Title, m.name) {
			m.name, due = l.Title, l.Due
		}
	}
	p85 := f.Lands.P85.Time().Local().Format(time.DateOnly)
	if due == "" || p85 <= due {
		return
	}
	d.postMilestoneNotice(m, p85, due)
}

// postMilestoneNotice posts m's late notice on a session of its issues that is not archived,
// and keeps due as told; with no such session, it is not told yet.
func (d *Daemon) postMilestoneNotice(m milestoneOf, p85, due string) {
	d.workMu.Lock()
	f := d.costLedgerLocked()
	if f.MilestonesLate[m.key()] == due {
		d.workMu.Unlock()
		return
	}
	// The open issues' sessions first: their lanes and leads are on it now.
	var open, closed []string
	for _, n := range f.Nodes {
		if n.Node.Kind != lineage.KindIssue || !strings.EqualFold(deref(n.Milestone), m.name) || !strings.EqualFold(deref(n.Repo), m.repo) {
			continue
		}
		if n.Resolved != nil && n.Resolved.State != nil && *n.Resolved.State == "closed" {
			closed = append(closed, n.Sessions...)
		} else {
			open = append(open, n.Sessions...)
		}
	}
	d.workMu.Unlock()
	agent, ok := d.overrunAgent(append(open, closed...))
	if !ok {
		return
	}
	d.workMu.Lock()
	f = d.costLedgerLocked()
	if f.MilestonesLate[m.key()] == due {
		d.workMu.Unlock()
		return
	}
	if f.MilestonesLate == nil {
		f.MilestonesLate = map[string]string{}
	}
	f.MilestonesLate[m.key()] = due
	d.costChangedLocked()
	d.workMu.Unlock()
	id := milestoneNoticePrefix + m.key()
	d.attentionMu.Lock()
	kept := d.notices[:0]
	for _, n := range d.notices {
		if n.id != id {
			kept = append(kept, n)
		}
	}
	d.notices = append(kept, postedNotice{id: id, agentID: agent, raised: now(), h3: milestoneLateWords(m.name, p85, due)})
	d.attentionMu.Unlock()
	d.reconsider()
}

// milestoneLateWords is the notice's line: "Milestone Planning can be late: at P85 it lands by
// Nov 27, after its due date, Nov 20. Trim it or move its due date."
func milestoneLateWords(name, p85, due string) string {
	day := func(s string) string {
		if t, err := time.Parse(time.DateOnly, s); err == nil {
			return t.Format("Jan 2")
		}
		return s
	}
	return fmt.Sprintf("Milestone %s can be late: at P85 it lands by %s, after its due date, %s. Trim it or move its due date.",
		name, day(p85), day(due))
}
