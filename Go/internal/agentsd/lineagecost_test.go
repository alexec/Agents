package agentsd

import (
	"context"
	"encoding/json"
	"strconv"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/wire"
)

func usd(r wire.LineageCost) float64 { return r.Cost["USD"] }

// #2350: a turn's cost goes under the links active then, split evenly; a label taken off
// later moves nothing; a turn with no link stays on its session.
func TestCostGoesOnTheActiveLinks(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	folder := t.TempDir()
	d.repos = map[string]forgeRepo{folder: {"github", "alexec/agents"}}
	a := seeded(t, d, folder, func(a *wire.Agent) {
		a.Labels = []wire.SessionLabel{{Value: "#12", Owner: wire.SessionLabelOwnerPerson}, {Value: "P#40", Owner: wire.SessionLabelOwnerPerson}}
	})
	d.noteLineage(nil, a)
	d.bankSessionCost(a.ID, wire.Cost{Amount: 1, Currency: "USD"})
	d.bankTurnUsage(a.ID, wire.TurnUsage{TotalTokens: 1001, InputTokens: 1000, OutputTokens: 1})

	issue, pr := wire.LineageNode{Kind: "issue", Ref: "github:alexec/agents#12"}, wire.LineageNode{Kind: "pr", Ref: "github:alexec/agents#40"}
	i, p := d.lineageCost(issue), d.lineageCost(pr)
	if usd(i.Own) != 0.5 || usd(p.Own) != 0.5 || i.Own.InputTokens+p.Own.InputTokens != 1000 ||
		i.Own.OutputTokens+p.Own.OutputTokens != 1 || i.Own.Turns != 0.5 {
		t.Fatalf("issue %+v, pr %+v", i.Own, p.Own)
	}

	// The label off: what was banked stays; the next turn goes to the issue alone.
	d.change(a.ID, func(a *wire.Agent) { a.Labels = a.Labels[:1] })
	// The session's running total: up 2.
	d.bankSessionCost(a.ID, wire.Cost{Amount: 3, Currency: "USD"})
	if got := d.lineageCost(pr); usd(got.Own) != 0.5 {
		t.Fatalf("pr %+v", got.Own)
	}
	if got := d.lineageCost(issue); usd(got.Own) != 2.5 {
		t.Fatalf("issue %+v", got.Own)
	}

	// No link at all: on the session, said as unlinked in its project.
	b := seeded(t, d, folder, nil)
	d.bankSessionCost(b.ID, wire.Cost{Amount: 0.25, Currency: "USD"})
	if got := d.lineageCost(sessionNode(b.ID)); usd(got.Own) != 0.25 {
		t.Fatalf("session %+v", got.Own)
	}
	project := d.lineageCost(wire.LineageNode{Kind: lineage.KindProject, Ref: "github:alexec/agents"})
	if usd(project.Total) != 3.25 || usd(project.Unlinked) != 0.25 {
		t.Fatalf("project %+v", project)
	}
}

// #2350: a helper with no work of its own works for its parent; one with its own label
// works on that.
func TestAHelpersCostGoesToItsParentsWork(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	folder := t.TempDir()
	d.repos = map[string]forgeRepo{folder: {"github", "alexec/agents"}}
	parent := seeded(t, d, folder, func(a *wire.Agent) {
		a.Labels = []wire.SessionLabel{{Value: "#7", Owner: wire.SessionLabelOwnerPerson}}
	})
	d.noteLineage(nil, parent)
	helper := seeded(t, d, folder, func(a *wire.Agent) { a.StartedByAgent = &parent.ID })
	d.noteLineage(nil, helper)
	lane := seeded(t, d, folder, func(a *wire.Agent) {
		a.StartedByAgent = &parent.ID
		a.Labels = []wire.SessionLabel{{Value: "#8", Owner: wire.SessionLabelOwnerAgent}}
	})
	d.noteLineage(nil, lane)
	d.bankSessionCost(helper.ID, wire.Cost{Amount: 2, Currency: "USD"})
	d.bankSessionCost(lane.ID, wire.Cost{Amount: 5, Currency: "USD"})
	if got := d.lineageCost(wire.LineageNode{Kind: "issue", Ref: "github:alexec/agents#7"}); usd(got.Own) != 2 {
		t.Fatalf("#7 %+v", got.Own)
	}
	if got := d.lineageCost(wire.LineageNode{Kind: "issue", Ref: "github:alexec/agents#8"}); usd(got.Own) != 5 {
		t.Fatalf("#8 %+v", got.Own)
	}
}

// #2350: an issue adds up its PRs; a PR closed without a merge stays against it, as
// waste; failed CI rounds are counted; the nodes go to the control plane with the hours.
func TestAnIssueAddsUpItsPRsAndTheirWaste(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	d.SettingsDir = t.TempDir()
	folder := t.TempDir()
	d.repos = map[string]forgeRepo{folder: {"github", "alexec/agents"}}
	branch := "agents/7-fix"
	a := seeded(t, d, folder, func(a *wire.Agent) {
		a.Worktree = &wire.AgentWorktree{Name: "7-fix", Branch: &branch, Folder: store.FolderURL(folder)}
		a.Labels = []wire.SessionLabel{{Value: "#7", Owner: wire.SessionLabelOwnerPerson}}
	})
	d.noteLineage(nil, a)
	d.bankSessionCost(a.ID, wire.Cost{Amount: 1, Currency: "USD"})
	event := func(name string, n int) wire.Event {
		return wire.Event{Name: name, Details: map[string]string{"payload": `{"pr":{"number":` + strconv.Itoa(n) + `,"branch":"agents/7-fix",` +
			`"title":"Fix it","url":"https://github.com/alexec/Agents/pull/` + strconv.Itoa(n) + `","fixes":["#7"]}}`}}
	}
	d.lineageEvent(event("pr.opened", 9))
	// The session's running total: up 2, split between the issue and the PR it opened.
	d.bankSessionCost(a.ID, wire.Cost{Amount: 3, Currency: "USD"})
	d.lineageEvent(event("checks.failed", 9))
	d.lineageEvent(event("checks.failed", 9))
	d.lineageEvent(event("pr.closed", 9))
	d.lineageEvent(event("pr.opened", 10))
	// Up 4, split between the issue and the next PR.
	d.bankSessionCost(a.ID, wire.Cost{Amount: 7, Currency: "USD"})
	d.lineageEvent(event("pr.merged", 10))

	issue := d.lineageCost(wire.LineageNode{Kind: "issue", Ref: "github:alexec/agents#7"})
	if usd(issue.Own) != 1+1+2 || usd(issue.Total) != 7 || usd(issue.Waste) != 1 ||
		issue.PrsClosed != 1 || issue.PrsMerged != 1 || issue.FailedChecks != 2 || len(issue.Parts) != 3 {
		t.Fatalf("%+v", issue)
	}

	// A milestone holds the issue, so its PRs too.
	m := wire.LineageNode{Kind: "milestone", Ref: "github:alexec/agents/milestone/15"}
	d.link(wire.LineageNode{Kind: "issue", Ref: "github:alexec/agents#7"}, m, lineage.RelPartOf, lineage.SourcePerson)
	if got := d.lineageCost(m); usd(got.Total) != 7 || usd(got.Waste) != 1 {
		t.Fatalf("milestone %+v", got)
	}

	var sent []wire.UsageRollup
	d.SetControlAsk(askControl(func(_ context.Context, _ string, params any) (json.RawMessage, error) {
		sent = append(sent, params.(wire.UsageRollup))
		return json.RawMessage(`{}`), nil
	}))
	d.sendReport()
	work := map[string]wire.LineageCostNode{}
	for _, r := range sent {
		for _, n := range r.Work {
			work[n.Node.Ref] = n
		}
	}
	closed := work["github:alexec/agents#9"]
	if len(work) != 3 || closed.Outcome == nil || *closed.Outcome != "closed" || len(closed.Fixes) != 1 ||
		len(work["github:alexec/agents#7"].PartOf) != 1 {
		t.Fatalf("%+v", work)
	}
	// Reports ▸ Value's lead time (#2351): when the work started, and when a PR ended.
	if closed.EndedAt == nil || closed.FirstAt == nil || *closed.FirstAt > *closed.EndedAt ||
		work["github:alexec/agents#7"].FirstAt == nil || work["github:alexec/agents#7"].EndedAt != nil {
		t.Fatalf("%+v", work)
	}
	sent = nil
	d.sendReport()
	for _, r := range sent {
		if len(r.Work) != 0 {
			t.Fatalf("sent again: %+v", r.Work)
		}
	}

	// The totals outlive the host.
	d.closeCost()
	d.workLedger = nil
	if got := d.lineageCost(wire.LineageNode{Kind: "issue", Ref: "github:alexec/agents#7"}); usd(got.Total) != 7 {
		t.Fatalf("read again: %+v", got)
	}
}

// #2350: the nodes banked longest ago go first, past 90 days or the bound.
func TestPruneCost(t *testing.T) {
	now := time.Now()
	f := &costLedgerFile{Nodes: map[string]wire.LineageCostNode{}, Unsent: map[string]int64{}}
	for i := range costNodesKept + 2 {
		n := wire.LineageNode{Kind: "issue", Ref: "github:o/r#" + strconv.Itoa(i+1)}
		f.Nodes[costKey(n)] = wire.LineageCostNode{Node: n, LastAt: wire.DateOf(now.Add(-time.Duration(i) * time.Minute))}
		f.Unsent[costKey(n)] = 1
	}
	old := wire.LineageNode{Kind: "pr", Ref: "github:o/r#0"}
	f.Nodes[costKey(old)] = wire.LineageCostNode{Node: old, LastAt: wire.DateOf(now.Add(-91 * 24 * time.Hour))}
	pruneCost(f, now)
	if len(f.Nodes) != costNodesKept || len(f.Unsent) != costNodesKept {
		t.Fatalf("%d %d", len(f.Nodes), len(f.Unsent))
	}
	if _, ok := f.Nodes["issue\tgithub:o/r#1"]; !ok {
		t.Fatal("the newest went")
	}
	if _, ok := f.Nodes["issue\tgithub:o/r#"+strconv.Itoa(costNodesKept+2)]; ok {
		t.Fatal("the oldest stayed")
	}
}

// #3118: the nodes sent say the sessions that worked on them, and the title, state and
// labels the resolve cache has; a node resolved after it was sent is sent again.
func TestSentCostSaysSessionsAndResolved(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	folder := t.TempDir()
	d.repos = map[string]forgeRepo{folder: {"github", "alexec/agents"}}
	a := seeded(t, d, folder, func(a *wire.Agent) {
		a.Labels = []wire.SessionLabel{{Value: "#12", Owner: wire.SessionLabelOwnerPerson}}
	})
	d.noteLineage(nil, a)
	d.bankSessionCost(a.ID, wire.Cost{Amount: 1, Currency: "USD"})
	d.lineageSettle(2 * time.Second)

	issue := wire.LineageNode{Kind: "issue", Ref: "github:alexec/agents#12"}
	sentNode := func() (wire.LineageCostNode, bool) {
		t.Helper()
		work, sent := d.unsentCost()
		d.costSent(sent)
		for _, n := range work {
			if n.Node == issue {
				return n, true
			}
		}
		return wire.LineageCostNode{}, false
	}
	n, ok := sentNode()
	if !ok || n.Resolved != nil || len(n.Sessions) != 1 || n.Sessions[0] != sessionNode(a.ID).Ref {
		t.Fatalf("%v %+v", ok, n)
	}
	if _, again := sentNode(); again {
		t.Fatal("sent again with nothing changed")
	}

	state := "open"
	d.resolveMu.Lock()
	d.resolveCache = map[wire.LineageNode]resolvedEntry{issue: {
		resolved: wire.LineageResolved{Title: "Fix it", State: &state, Labels: []string{"bug"}}, ok: true, at: time.Now()}}
	d.resolveMu.Unlock()
	n, ok = sentNode()
	if !ok || n.Resolved == nil || n.Resolved.Title != "Fix it" || *n.Resolved.State != "open" {
		t.Fatalf("%v %+v", ok, n)
	}
	if _, again := sentNode(); again {
		t.Fatal("sent again with the same answer")
	}
}
