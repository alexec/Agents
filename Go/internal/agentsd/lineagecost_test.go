package agentsd

import (
	"context"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
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

	issue, pr := wire.LineageNode{Kind: "issue", Ref: "github:issue:alexec/agents#12"}, wire.LineageNode{Kind: "pr", Ref: "github:pr:alexec/agents#40"}
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

	// No link at all: on the session, said as unlinked in its repo.
	b := seeded(t, d, folder, nil)
	d.bankSessionCost(b.ID, wire.Cost{Amount: 0.25, Currency: "USD"})
	if got := d.lineageCost(sessionNode(b.ID)); usd(got.Own) != 0.25 {
		t.Fatalf("session %+v", got.Own)
	}
	repo := d.lineageCost(wire.LineageNode{Kind: lineage.KindRepo, Ref: "github:repo:#alexec/agents"})
	if usd(repo.Total) != 3.25 || usd(repo.Unlinked) != 0.25 {
		t.Fatalf("repo %+v", repo)
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
	if got := d.lineageCost(wire.LineageNode{Kind: "issue", Ref: "github:issue:alexec/agents#7"}); usd(got.Own) != 2 {
		t.Fatalf("#7 %+v", got.Own)
	}
	if got := d.lineageCost(wire.LineageNode{Kind: "issue", Ref: "github:issue:alexec/agents#8"}); usd(got.Own) != 5 {
		t.Fatalf("#8 %+v", got.Own)
	}
}

// #2350: an issue adds up its PRs; a PR closed without a merge stays against it, as
// waste; failed CI rounds are counted; the nodes go to the control plane with the hours.
func TestAnIssueAddsUpItsPRsAndTheirWaste(t *testing.T) {
	d, c := start(t, t.TempDir())
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
	// The merge's multiplierChanged runs away from the caller and reports when it finds a
	// control plane: wait for it before one is set, so it does not report alongside (#4624).
	c.until(t, "the merge told", func(m string, p json.RawMessage) bool {
		return m == "multiplier/changed" && strings.Contains(string(p), `"github:pr:alexec/agents#10"`)
	})

	issue := d.lineageCost(wire.LineageNode{Kind: "issue", Ref: "github:issue:alexec/agents#7"})
	if usd(issue.Own) != 1+1+2 || usd(issue.Total) != 7 || usd(issue.Waste) != 1 ||
		issue.PrsClosed != 1 || issue.PrsMerged != 1 || issue.FailedChecks != 2 || len(issue.Parts) != 3 {
		t.Fatalf("%+v", issue)
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
	closed := work["github:pr:alexec/agents#9"]
	if len(work) != 3 || closed.Outcome == nil || *closed.Outcome != "closed" || len(closed.Fixes) != 1 ||
		len(work["github:issue:alexec/agents#7"].PartOf) != 0 {
		t.Fatalf("%+v", work)
	}
	// Reports ▸ Value's lead time (#2351): when the work started, and when a PR ended.
	if closed.EndedAt == nil || closed.FirstAt == nil || *closed.FirstAt > *closed.EndedAt ||
		work["github:issue:alexec/agents#7"].FirstAt == nil || work["github:issue:alexec/agents#7"].EndedAt != nil {
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
	d.workMu.Lock()
	d.workLedger = nil
	d.workMu.Unlock()
	if got := d.lineageCost(wire.LineageNode{Kind: "issue", Ref: "github:issue:alexec/agents#7"}); usd(got.Total) != 7 {
		t.Fatalf("read again: %+v", got)
	}
}

// #2350: the nodes banked longest ago go first, past 90 days or the bound.
func TestPruneCost(t *testing.T) {
	now := time.Now()
	f := &costLedgerFile{Nodes: map[string]wire.LineageCostNode{}, Unsent: map[string]int64{}}
	for i := range costNodesKept + 2 {
		n := wire.LineageNode{Kind: "issue", Ref: "github:issue:o/r#" + strconv.Itoa(i+1)}
		f.Nodes[costKey(n)] = wire.LineageCostNode{Node: n, LastAt: wire.DateOf(now.Add(-time.Duration(i) * time.Minute))}
		f.Unsent[costKey(n)] = 1
	}
	old := wire.LineageNode{Kind: "pr", Ref: "github:pr:o/r#0"}
	f.Nodes[costKey(old)] = wire.LineageCostNode{Node: old, LastAt: wire.DateOf(now.Add(-91 * 24 * time.Hour))}
	pruneCost(f, now)
	if len(f.Nodes) != costNodesKept || len(f.Unsent) != costNodesKept {
		t.Fatalf("%d %d", len(f.Nodes), len(f.Unsent))
	}
	if _, ok := f.Nodes["issue\tgithub:issue:o/r#1"]; !ok {
		t.Fatal("the newest went")
	}
	if _, ok := f.Nodes["issue\tgithub:issue:o/r#"+strconv.Itoa(costNodesKept+2)]; ok {
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
	// The backfill (#3562) asks for an issue with no level: never the real forge.
	d.resolveLookup = func(context.Context, string, forgeRepo, string, int) (wire.LineageResolved, error) {
		return wire.LineageResolved{}, errors.New("no forge in tests")
	}
	a := seeded(t, d, folder, func(a *wire.Agent) {
		a.Labels = []wire.SessionLabel{{Value: "#12", Owner: wire.SessionLabelOwnerPerson}}
	})
	d.noteLineage(nil, a)
	d.bankSessionCost(a.ID, wire.Cost{Amount: 1, Currency: "USD"})
	d.lineageSettle(2 * time.Second)

	issue := wire.LineageNode{Kind: "issue", Ref: "github:issue:alexec/agents#12"}
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

// #3562: an issue's start is its first works-on link, kept when the link ends; its level,
// feature, area and epic come from its labels and the forge's plan, kept when the cache
// forgets them; and an issue with none is asked of the forge, as the backfill.
func TestCostNodeKeepsStartAndLevel(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	folder := t.TempDir()
	d.repos = map[string]forgeRepo{folder: {"github", "alexec/agents"}}
	issue := wire.LineageNode{Kind: "issue", Ref: "github:issue:alexec/agents#12"}
	epic := wire.LineageNode{Kind: "issue", Ref: "github:issue:alexec/agents#10"}
	seeded(t, d, folder, nil)
	asked := make(chan int, 4)
	d.resolveLookup = func(_ context.Context, _ string, _ forgeRepo, _ string, n int) (wire.LineageResolved, error) {
		asked <- n
		return wire.LineageResolved{Title: "Fix it", Labels: []string{"Story", "feature:estimates"}}, nil
	}
	s := wire.LineageNode{Kind: "session", Ref: "agents:session:#a"}
	began := time.Now().Add(-3 * time.Hour)
	d.linkAt(s, issue, lineage.RelWorksOn, lineage.SourceStart, began)
	d.linkAt(s, issue, lineage.RelOpens, lineage.SourceStart, began.Add(time.Hour))
	d.workMu.Lock()
	d.noteCostLocked(issue, time.Now(), func(*wire.LineageCostNode) {})
	d.workMu.Unlock()
	d.unlink(s, issue, lineage.RelWorksOn)

	node := func() wire.LineageCostNode {
		t.Helper()
		_, sent := d.unsentCost()
		d.costSent(sent)
		d.workMu.Lock()
		defer d.workMu.Unlock()
		return d.costLedgerLocked().Nodes[costKey(issue)]
	}
	n := node()
	if n.StartedAt == nil || *n.StartedAt != wire.DateOf(began) {
		t.Fatalf("started %v, want %v", n.StartedAt, wire.DateOf(began))
	}
	// Asked of the forge, as it had no level.
	select {
	case got := <-asked:
		if got != 12 {
			t.Fatalf("asked #%d", got)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the backfill did not ask the forge")
	}
	d.resolveSettle(5 * time.Second)
	d.resolveMu.Lock()
	e := d.resolveCache[issue]
	e.parent = &epic
	d.resolveCache[issue] = e
	d.resolveMu.Unlock()
	// A forge list says its milestone (#4620); a list without one leaves it.
	d.resolvedFromForge([]wire.ForgeItem{{Node: issue, Title: "Fix it", State: "open", Milestone: new("Planning"),
		Labels: []wire.ForgeLabel{{Name: "Story"}, {Name: "feature:estimates"}}}})
	d.resolvedFromForge([]wire.ForgeItem{{Node: issue, Title: "Fix it", State: "open",
		Labels: []wire.ForgeLabel{{Name: "Story"}, {Name: "feature:estimates"}}}})
	n = node()
	if n.Level == nil || *n.Level != "story" || n.Feature == nil || *n.Feature != "estimates" ||
		n.Parent == nil || *n.Parent != epic.Ref || n.Milestone == nil || *n.Milestone != "Planning" {
		t.Fatalf("%+v", n)
	}

	// The cache forgets it and the links go: the node keeps them all.
	d.resolveMu.Lock()
	d.resolveCache = map[wire.LineageNode]resolvedEntry{}
	d.resolveMu.Unlock()
	d.unlink(s, issue, lineage.RelOpens)
	n = node()
	if n.StartedAt == nil || *n.StartedAt != wire.DateOf(began) || n.Level == nil || *n.Level != "story" || n.Parent == nil ||
		n.Milestone == nil {
		t.Fatalf("%+v", n)
	}
}

// #3559: lineage/estimate reads the epic's plan from the forge and its history from the totals:
// the closed child's cost is spent, and the open child is estimated from the closed issues.
func TestLineageEstimateOfAnEpic(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	issue := func(n int) wire.LineageNode {
		return wire.LineageNode{Kind: "issue", Ref: "github:issue:alexec/agents#" + strconv.Itoa(n)}
	}
	state, merged, level, ended := "closed", lineage.OutcomeMerged, "task", wire.DateOf(time.Now())
	var prs []wire.LineageCostNode
	d.workMu.Lock()
	f := d.costLedgerLocked()
	for n := 1; n <= 6; n++ {
		c := wire.LineageCostNode{Node: issue(n), Banked: wire.LineageCost{Cost: map[string]float64{"USD": float64(n)}}, Level: &level,
			Resolved: &wire.LineageResolved{Title: "Done", State: &state, Labels: []string{"enhancement", "task"}}}
		f.Nodes[costKey(c.Node)] = c
		pr := wire.LineageCostNode{Node: wire.LineageNode{Kind: "pr", Ref: "github:pr:alexec/agents#" + strconv.Itoa(100+n)},
			Banked: wire.LineageCost{Cost: map[string]float64{}}, Fixes: []string{c.Node.Ref}, Outcome: &merged, EndedAt: &ended}
		f.Nodes[costKey(pr.Node)] = pr
		prs = append(prs, pr)
	}
	d.workMu.Unlock()
	// The totals take a PR's fixes from the graph.
	for _, pr := range prs {
		d.linkAt(pr.Node, wire.LineageNode{Kind: "issue", Ref: pr.Fixes[0]}, lineage.RelFixes, lineage.SourceStart, time.Now())
	}
	key, _ := json.Marshal([]any{"forge/plan", issue(10).Ref})
	d.forgeRemember(string(key), forgeAnswer{plan: &forgePlanAnswer{
		epic: wire.ForgeItem{Node: issue(10), State: "open", Labels: []wire.ForgeLabel{{Name: "epic"}}},
		children: []planChild{
			{item: wire.ForgeItem{Node: issue(1), State: "closed"}},
			{item: wire.ForgeItem{Node: issue(11), State: "open", Labels: []wire.ForgeLabel{{Name: "enhancement"}, {Name: "task"}}}},
		}}})
	e, err := d.lineageEstimate(context.Background(), wire.LineageEstimateRequest{Node: issue(10)})
	if err != nil {
		t.Fatal(err)
	}
	if *e.OpenChildren != 1 || *e.ClosedChildren != 1 || usd(*e.Spent) != 1 || e.ClosedIssues != 6 || len(e.Children) != 1 ||
		*e.Children[0].MatchedBy != lineage.MatchedByLevel || e.Children[0].Cost["USD"].Median != 3.5 {
		t.Fatalf("%+v", e)
	}
}

// #3561: an issue keeps the estimate it had when its work started, from the issues merged
// before then only, and once closed lineage/estimate says it with what the work took.
func TestLineageEstimateKeepsTheStartAndSaysTheActual(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	issue := func(n int) wire.LineageNode {
		return wire.LineageNode{Kind: "issue", Ref: "github:issue:alexec/agents#" + strconv.Itoa(n)}
	}
	now := time.Now()
	began := wire.DateOf(now.Add(-5 * time.Hour))
	state, merged, level := "closed", lineage.OutcomeMerged, "task"
	labels := []string{"enhancement", "task"}
	var links []wire.LineageCostNode
	add := func(n int, usd float64, mergedAt time.Time, startedAt *wire.Date) {
		c := wire.LineageCostNode{Node: issue(n), Banked: wire.LineageCost{Cost: map[string]float64{"USD": usd}}, Level: &level,
			StartedAt: startedAt, Resolved: &wire.LineageResolved{Title: "Done", State: &state, Labels: labels}}
		ended := wire.DateOf(mergedAt)
		pr := wire.LineageCostNode{Node: wire.LineageNode{Kind: "pr", Ref: "github:pr:alexec/agents#" + strconv.Itoa(100+n)},
			Banked: wire.LineageCost{Cost: map[string]float64{"USD": 1}}, Fixes: []string{c.Node.Ref}, Outcome: &merged, EndedAt: &ended}
		d.workMu.Lock()
		f := d.costLedgerLocked()
		f.Nodes[costKey(c.Node)], f.Nodes[costKey(pr.Node)] = c, pr
		d.workMu.Unlock()
		links = append(links, pr)
	}
	for n := 1; n <= 6; n++ {
		add(n, float64(n)-1, now.Add(-10*time.Hour), nil)
	}
	// Merged after #20 started: not in what #20's estimate knew.
	add(7, 99, now.Add(-time.Hour), nil)
	add(20, 7, now, &began)
	for _, pr := range links {
		d.linkAt(pr.Node, wire.LineageNode{Kind: "issue", Ref: pr.Fixes[0]}, lineage.RelFixes, lineage.SourceStart, now)
	}
	key, _ := json.Marshal([]any{"forge/plan", issue(20).Ref})
	d.forgeRemember(string(key), forgeAnswer{plan: &forgePlanAnswer{
		epic: wire.ForgeItem{Node: issue(20), State: "closed", Labels: []wire.ForgeLabel{{Name: "enhancement"}, {Name: "task"}}}}})
	e, err := d.lineageEstimate(context.Background(), wire.LineageEstimateRequest{Node: issue(20)})
	if err != nil {
		t.Fatal(err)
	}
	// The six before: $1 to $6 with their PRs' $1, so a median of $3.50.
	if e.Kept == nil || e.Kept.At != began || e.Kept.Matches != 6 || e.Kept.Cost["USD"] != 3.5 {
		t.Fatalf("kept %+v", e.Kept)
	}
	if e.Actual == nil || usd(*e.Actual) != 8 {
		t.Fatalf("actual %+v", e.Actual)
	}
	// Kept on the node, so it goes to the control plane and is not made again.
	d.workMu.Lock()
	kept := d.costLedgerLocked().Nodes[costKey(issue(20))].Estimate
	d.workMu.Unlock()
	if kept == nil || kept.Cost["USD"] != 3.5 {
		t.Fatalf("%+v", kept)
	}
}

// #4525: an estimate kept before the cycle time and landsAt were added gets them the next time
// the backfill runs, from the same history, so its median dollars does not change.
func TestKeepEstimatesBackfillsCycleTimeAndLandsAt(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	issue := func(n int) wire.LineageNode {
		return wire.LineageNode{Kind: "issue", Ref: "github:issue:alexec/agents#" + strconv.Itoa(n)}
	}
	str := func(s string) *string { return &s }
	now := time.Now()
	state, merged, level := "closed", lineage.OutcomeMerged, "task"
	labels := []string{"enhancement", "task"}
	d.workMu.Lock()
	f := d.costLedgerLocked()
	for n := 1; n <= 5; n++ {
		started, ended := wire.DateOf(now.Add(-10*time.Hour)), wire.DateOf(now.Add(-9*time.Hour))
		c := wire.LineageCostNode{Node: issue(n), Banked: wire.LineageCost{Cost: map[string]float64{"USD": float64(n)}}, Level: &level,
			StartedAt: &started, Resolved: &wire.LineageResolved{Title: "Done", State: &state, Labels: labels}}
		pr := wire.LineageCostNode{Node: wire.LineageNode{Kind: "pr", Ref: "github:pr:alexec/agents#" + strconv.Itoa(100+n)},
			Banked: wire.LineageCost{Cost: map[string]float64{}}, Fixes: []string{c.Node.Ref}, Outcome: &merged, EndedAt: &ended}
		f.Nodes[costKey(c.Node)], f.Nodes[costKey(pr.Node)] = c, pr
	}
	// The target: an old-shape kept estimate, made before #4525, with no cycle time.
	began := wire.DateOf(now.Add(-time.Hour))
	target := issue(20)
	f.Nodes[costKey(target)] = wire.LineageCostNode{Node: target, StartedAt: &began,
		Resolved: &wire.LineageResolved{Title: "Open", State: str("open"), Labels: labels},
		Estimate: &wire.LineageEstimateKept{At: began, Matches: 5, MatchedBy: str(lineage.MatchedByLevel), Cost: map[string]float64{"USD": 3}}}
	d.keepEstimatesLocked()
	got := d.costLedgerLocked().Nodes[costKey(target)].Estimate
	d.workMu.Unlock()
	// The same median as before: the history it was made from has not changed.
	if got == nil || got.Cost["USD"] != 3 || got.CycleTimeSeconds == nil || got.CycleTimeSeconds.Median != 3600 ||
		got.LandsAt == nil || got.LandsAt.Median != began+3600 {
		t.Fatalf("%+v", got)
	}
}

// #4524: a turn with no work that started sessions goes on their work, a Scrum Master's turn
// on the lane it started; a later turn that started nothing stays on the session.
func TestATurnThatStartsALaneGoesOnItsWork(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	folder := t.TempDir()
	d.repos = map[string]forgeRepo{folder: {"github", "alexec/agents"}}
	sm := seeded(t, d, folder, nil)
	now := nowFunc()
	if _, err := d.lineage().SetState(sessionNode(sm.ID), wire.LineageSessionStateNameWorking, now.Add(-time.Hour)); err != nil {
		t.Fatal(err)
	}
	lane := seeded(t, d, folder, func(a *wire.Agent) {
		a.StartedByAgent = &sm.ID
		a.Labels = []wire.SessionLabel{{Value: "#8", Owner: wire.SessionLabelOwnerAgent}}
	})
	d.noteLineage(nil, lane)
	d.bankSessionCost(sm.ID, wire.Cost{Amount: 1, Currency: "USD"})
	issue := wire.LineageNode{Kind: "issue", Ref: "github:issue:alexec/agents#8"}
	if got := d.lineageCost(issue); usd(got.Own) != 1 {
		t.Fatalf("#8 %+v", got.Own)
	}

	// The next turn starts nothing: on the session.
	for i, s := range []wire.LineageSessionStateName{wire.LineageSessionStateNameWaiting, wire.LineageSessionStateNameWorking} {
		if _, err := d.lineage().SetState(sessionNode(sm.ID), s, now.Add(time.Duration(i+1)*time.Minute)); err != nil {
			t.Fatal(err)
		}
	}
	d.bankSessionCost(sm.ID, wire.Cost{Amount: 3, Currency: "USD"})
	if got := d.lineageCost(issue); usd(got.Own) != 1 {
		t.Fatalf("#8 %+v", got.Own)
	}
	if got := d.lineageCost(sessionNode(sm.ID)); usd(got.Own) != 2 {
		t.Fatalf("session %+v", got.Own)
	}
}

// #4524: a turn begins at the oldest of its newest run of working and needs-you.
func TestTurnStart(t *testing.T) {
	st := func(s wire.LineageSessionStateName, at wire.Date) wire.LineageSessionState {
		return wire.LineageSessionState{State: s, At: at}
	}
	w, n, wait := wire.LineageSessionStateNameWorking, wire.LineageSessionStateNameNeedsYou, wire.LineageSessionStateNameWaiting
	for _, c := range []struct {
		states []wire.LineageSessionState
		want   wire.Date
		ok     bool
	}{
		{nil, 0, false},
		{[]wire.LineageSessionState{st(wait, 9)}, 0, false},
		{[]wire.LineageSessionState{st(w, 9), st(wait, 8)}, 9, true},
		{[]wire.LineageSessionState{st(wire.LineageSessionStateNameStopped, 10), st(w, 9), st(n, 8), st(w, 7), st(wait, 6), st(w, 5)}, 7, true},
	} {
		if got, ok := turnStart(c.states); got != c.want || ok != c.ok {
			t.Errorf("%v: %v %v, want %v %v", c.states, got, ok, c.want, c.ok)
		}
	}
}

// #4524: a run started by a PR's checks.failed works on that PR until it merges; one started
// by pr.merged does not.
func TestARunStartedByChecksFailedWorksOnItsPR(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	folder := t.TempDir()
	d.repos = map[string]forgeRepo{folder: {"github", "alexec/agents"}}
	event := func(name string) wire.Event {
		return wire.Event{Name: name, Details: map[string]string{"payload": `{"pr":{"number":9,"title":"Fix it",` +
			`"url":"https://github.com/alexec/Agents/pull/9"},"run":{"id":5}}`}}
	}
	fix := seeded(t, d, folder, nil)
	d.lineagePRStarted(event("checks.failed"), fix.ID)
	ship := seeded(t, d, folder, nil)
	d.lineagePRStarted(event("pr.merged"), ship.ID)
	d.bankSessionCost(fix.ID, wire.Cost{Amount: 2, Currency: "USD"})
	d.bankSessionCost(ship.ID, wire.Cost{Amount: 5, Currency: "USD"})
	pr := wire.LineageNode{Kind: "pr", Ref: "github:pr:alexec/agents#9"}
	if got := d.lineageCost(pr); usd(got.Own) != 2 {
		t.Fatalf("pr %+v", got.Own)
	}
	if got := d.lineageCost(sessionNode(ship.ID)); usd(got.Own) != 5 {
		t.Fatalf("ship %+v", got.Own)
	}
}

// #4524: a release session's version label puts its cost on the release, and the release's
// rollup counts it.
func TestAReleaseSessionsCostGoesOnItsRelease(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	folder := t.TempDir()
	d.repos = map[string]forgeRepo{folder: {"github", "alexec/agents"}}
	a := seeded(t, d, folder, func(a *wire.Agent) {
		a.Labels = []wire.SessionLabel{{Value: "v1.2.0", Owner: wire.SessionLabelOwnerAgent}}
	})
	d.noteLineage(nil, a)
	d.bankSessionCost(a.ID, wire.Cost{Amount: 4, Currency: "USD"})
	release := wire.LineageNode{Kind: lineage.KindRelease, Ref: "github:release:alexec/agents#v1.2.0"}
	if got := d.lineageCost(release); usd(got.Own) != 4 || usd(got.Total) != 4 {
		t.Fatalf("release %+v", got)
	}
	repo := d.lineageCost(wire.LineageNode{Kind: lineage.KindRepo, Ref: "github:repo:#alexec/agents"})
	if usd(repo.Total) != 4 || usd(repo.Unlinked) != 0 {
		t.Fatalf("repo %+v", repo)
	}
}
