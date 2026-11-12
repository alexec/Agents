package agentsd

import (
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/wire"
)

// overrunNotices is the host's notices that an epic passed a multiple of its estimate.
func overrunNotices(d *Daemon) []postedNotice {
	d.attentionMu.Lock()
	defer d.attentionMu.Unlock()
	var out []postedNotice
	for _, n := range d.notices {
		if strings.HasPrefix(n.id, overrunNoticePrefix) {
			out = append(out, n)
		}
	}
	return out
}

// #4529: a child's spend that takes its open epic past 2× its kept estimate posts one notice
// on the epic's lead, kept as told; the same threshold again says nothing, and 3× says it
// once more. With no session of the epic that is not archived, nothing is told yet.
func TestAnEpicPastTwiceItsEstimateTellsThePerson(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	folder := t.TempDir()
	gone := seeded(t, d, folder, func(a *wire.Agent) {
		r := wire.AgentArchivedReasonByUser
		a.State, a.ArchivedReason = wire.AgentStateArchived, &r
	}).ID
	lead := seeded(t, d, folder, nil).ID
	epic := wire.LineageNode{Kind: lineage.KindIssue, Ref: "github:issue:alexec/agents#10"}
	child := wire.LineageNode{Kind: lineage.KindIssue, Ref: "github:issue:alexec/agents#11"}
	level, parent := "epic", epic.Ref
	usd := func(v float64) wire.LineageCost { return wire.LineageCost{Cost: map[string]float64{"USD": v}} }
	set := func(spent float64, sessions ...wire.UUID) []overrunNotice {
		d.workMu.Lock()
		defer d.workMu.Unlock()
		f := d.costLedgerLocked()
		var refs []string
		for _, s := range sessions {
			refs = append(refs, sessionNode(s).Ref)
		}
		f.Nodes[costKey(epic)] = wire.LineageCostNode{Node: epic, Level: &level, Banked: usd(0), Sessions: refs,
			Resolved: &wire.LineageResolved{Title: "Forecasting"}, Estimate: &wire.LineageEstimateKept{Cost: map[string]float64{"USD": 100}}}
		f.Nodes[costKey(child)] = wire.LineageCostNode{Node: child, Parent: &parent, Banked: usd(spent)}
		return d.overrunsLocked([]wire.LineageNode{child})
	}

	d.postOverrunNotices(set(150, lead))
	if n := overrunNotices(d); len(n) != 0 {
		t.Fatalf("under 2×: %+v", n)
	}
	d.postOverrunNotices(set(210, gone))
	if n := overrunNotices(d); len(n) != 0 {
		t.Fatalf("only an archived session: %+v", n)
	}
	d.postOverrunNotices(set(210, gone, lead))
	n := overrunNotices(d)
	if len(n) != 1 || n[0].agentID != lead ||
		n[0].h3 != "Epic #10, Forecasting, has cost $210.00: 2.1× its estimate of $100.00. Stop it, trim it or go on." {
		t.Fatalf("at 2×: %+v", n)
	}
	d.attentionMu.Lock()
	d.notices = nil
	d.attentionMu.Unlock()
	if told := set(250, lead); len(told) != 0 {
		t.Fatalf("2× again: %+v", told)
	}
	d.postOverrunNotices(set(320, lead))
	if n := overrunNotices(d); len(n) != 1 || !strings.Contains(n[0].h3, "3.2×") {
		t.Fatalf("at 3×: %+v", n)
	}
	d.workMu.Lock()
	told := d.costLedgerLocked().Overruns[costKey(epic)]
	d.workMu.Unlock()
	if told != 3 {
		t.Fatalf("kept as told: %d", told)
	}
}
