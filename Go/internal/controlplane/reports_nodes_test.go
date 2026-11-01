package controlplane

import (
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// reports/nodes (#3118): each kind is listed once per node, a node two machines sent is
// merged with its cost added, the newest resolved wins, and a member sees only their own
// machines.
func TestReportsNodesListsEachKind(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	owner := p.host("OWNERS-MAC")
	_, admin := p.client("Owner's window")
	bea := p.invite(admin, "Bea", wire.UserRoleMember)
	beas := p.machine(bea, "BEAS-MAC")

	now := time.Now()
	at := func(ago time.Duration) *wire.Date { d := wire.DateOf(now.Add(-ago)); return &d }
	str := func(s string) *string { return &s }
	node := func(kind, ref string, usd float64, sessions ...string) wire.LineageCostNode {
		return wire.LineageCostNode{Node: wire.LineageNode{Kind: kind, Ref: ref}, Sessions: sessions,
			Banked: wire.LineageCost{Cost: map[string]float64{"USD": usd}, Turns: 1}, LastAt: wire.DateOf(now)}
	}
	issue := node("issue", "github:o/r#1", 1, "s1")
	issue.FirstAt = at(10 * time.Hour)
	issue.PartOf = []string{"github:o/r/milestone/1"}
	issue.Resolved = &wire.LineageResolved{Title: "Old title", State: str("open")}
	issue.LastAt = wire.DateOf(now.Add(-time.Hour))
	merged := node("pr", "github:o/r#2", 4, "s1")
	merged.Fixes, merged.Outcome, merged.EndedAt = []string{"github:o/r#1"}, str("merged"), at(time.Hour)
	merged.PartOf = []string{"github:o/r/release/v1.0.0"}
	closed := node("pr", "github:o/r#3", 3, "s2")
	closed.Fixes, closed.Outcome, closed.EndedAt = []string{"github:o/r#1"}, str("closed"), at(2*time.Hour)
	// Only a PR names this issue.
	named := node("pr", "github:o/r#5", 2)
	named.Fixes = []string{"github:o/r#4"}
	// Bea's machine banked its own turns on the same issue, and resolved it later.
	beaIssue := node("issue", "github:o/r#1", 2, "s3")
	beaIssue.Resolved = &wire.LineageResolved{Title: "Fix it", State: str("closed"), Labels: []string{"bug"}}

	send := func(host string, work ...wire.LineageCostNode) {
		t.Helper()
		params, _ := json.Marshal(wire.UsageRollup{Hours: []wire.UsageRollupPeriod{}, Days: []wire.UsageRollupPeriod{}, Work: work})
		if _, err := p.s.methods.HostSaid(host, "usage/rollup", params); err != nil {
			t.Fatal(err)
		}
	}
	send(owner.member.Host, issue, merged, closed, named)
	send(beas.member.Host, beaIssue)

	org := &wire.ReportScope{Kind: wire.ReportScopeKindOrg}
	list := func(s *controllink.Session, q wire.ReportNodesQuery) wire.ReportNodes {
		t.Helper()
		var v wire.ReportNodes
		if err := json.Unmarshal(call(t, s, "", "reports/nodes", q), &v); err != nil {
			t.Fatal(err)
		}
		return v
	}
	issues := list(admin, wire.ReportNodesQuery{Kind: "issue", Scope: org})
	if len(issues.Nodes) != 2 || issues.Limited || issues.Cursor != nil {
		t.Fatalf("%+v", issues)
	}
	one := issues.Nodes[0]
	if one.Node.Ref != "github:o/r#1" {
		one = issues.Nodes[1]
	}
	// Own 1 + 2 (two machines); total adds both PRs; the closed PR is waste; s1 once.
	if one.Cost.Own.Cost["USD"] != 3 || one.Cost.Total.Cost["USD"] != 10 || one.Cost.Waste.Cost["USD"] != 3 ||
		one.Sessions != 3 || one.Resolved == nil || one.Resolved.Title != "Fix it" ||
		one.Project == nil || *one.Project != "github:o/r" || one.LeadTimeSeconds == nil {
		t.Fatalf("%+v", one)
	}
	prs := list(admin, wire.ReportNodesQuery{Kind: "pr", Scope: org, Sort: new(wire.ReportNodesSortCost)})
	if len(prs.Nodes) != 3 || prs.Nodes[0].Node.Ref != "github:o/r#2" || prs.Nodes[0].Outcome == nil ||
		*prs.Nodes[0].Outcome != "merged" || prs.Unresolved != 3 {
		t.Fatalf("%+v", prs)
	}
	if got := list(admin, wire.ReportNodesQuery{Kind: "pr", Scope: org, State: str("closed")}); len(got.Nodes) != 1 ||
		got.Nodes[0].Node.Ref != "github:o/r#3" {
		t.Fatalf("%+v", got)
	}
	if got := list(admin, wire.ReportNodesQuery{Kind: "milestone", Scope: org}); len(got.Nodes) != 1 ||
		got.Nodes[0].Cost.Total.Cost["USD"] != 10 {
		t.Fatalf("%+v", got)
	}
	// The merged PR and the issue it fixes, from both machines.
	if got := list(admin, wire.ReportNodesQuery{Kind: "release", Scope: org}); len(got.Nodes) != 1 ||
		got.Nodes[0].Cost.Total.Cost["USD"] != 7 {
		t.Fatalf("%+v", got)
	}

	// Bea sees her own machine's issue only, and not the organisation.
	mine := list(bea.window, wire.ReportNodesQuery{Kind: "issue"})
	if len(mine.Nodes) != 1 || mine.Nodes[0].Cost.Own.Cost["USD"] != 2 || mine.Nodes[0].Sessions != 1 {
		t.Fatalf("%+v", mine)
	}
	if e := callError(t, bea.window, "", "reports/nodes", wire.ReportNodesQuery{Kind: "issue", Scope: org}); e == "" {
		t.Fatal("a member read the organisation")
	}
	for _, q := range []wire.ReportNodesQuery{
		{Kind: "commit"},
		{Kind: "issue", Limit: new(int64(101))},
		{Kind: "issue", Limit: new(int64(0))},
		{Kind: "issue", Sort: new(wire.ReportNodesSort("oldest"))},
		{Kind: "issue", Cursor: str("not a cursor")},
	} {
		if e := callError(t, admin, "", "reports/nodes", q); e == "" {
			t.Errorf("%+v: no error", q)
		}
	}
}

// Every filter, each sort and the cursor over pages, on the rows alone.
func TestReportsNodesFiltersSortsAndPages(t *testing.T) {
	t.Parallel()
	str := func(s string) *string { return &s }
	var nodes []wire.LineageCostNode
	for i := range 250 {
		n := wire.LineageCostNode{Node: wire.LineageNode{Kind: "issue", Ref: fmt.Sprintf("github:o/r#%d", i)},
			Banked: wire.LineageCost{Cost: map[string]float64{"USD": float64(i % 7)}}, LastAt: wire.Date(i)}
		if i%2 == 0 {
			n.Resolved = &wire.LineageResolved{Title: "t", State: str("open"), Labels: []string{"Bug"}}
		}
		nodes = append(nodes, n)
	}
	nodes = append(nodes, wire.LineageCostNode{Node: wire.LineageNode{Kind: "issue", Ref: "github:o/rx#1"},
		Banked: wire.LineageCost{Cost: map[string]float64{}}, LastAt: 1000})
	page := func(q wire.ReportNodesQuery, order wire.ReportNodesSort, limit int) []wire.ReportNode {
		t.Helper()
		var all []wire.ReportNode
		var after *nodesCursor
		for range 100 {
			got := nodesPage(nodeRows(nodes, "issue"), q, order, after, limit)
			if len(got.Nodes) > limit {
				t.Fatalf("a page of %d", len(got.Nodes))
			}
			all = append(all, got.Nodes...)
			if got.Cursor == nil {
				if got.Limited {
					t.Fatal("limited with no cursor")
				}
				return all
			}
			c, ok := decodeNodesCursor(*got.Cursor)
			if !ok {
				t.Fatal(*got.Cursor)
			}
			after = &c
		}
		t.Fatal("the pages did not end")
		return nil
	}
	all := page(wire.ReportNodesQuery{Kind: "issue"}, wire.ReportNodesSortNewest, nodesPageMost)
	if len(all) != 251 || all[0].Node.Ref != "github:o/rx#1" || all[1].Node.Ref != "github:o/r#249" {
		t.Fatalf("%d %v", len(all), all[0].Node)
	}
	seen := map[string]bool{}
	for _, r := range all {
		if seen[r.Node.Ref] {
			t.Fatalf("%s twice", r.Node.Ref)
		}
		seen[r.Node.Ref] = true
	}
	if got := page(wire.ReportNodesQuery{Kind: "issue", Repo: str("github:o/r")}, wire.ReportNodesSortNewest, 7); len(got) != 250 {
		t.Fatalf("repo: %d", len(got))
	}
	since := wire.Date(200)
	if got := page(wire.ReportNodesQuery{Kind: "issue", Since: &since}, wire.ReportNodesSortNewest, 50); len(got) != 51 {
		t.Fatalf("since: %d", len(got))
	}
	open := wire.ReportNodesQuery{Kind: "issue", State: str("open")}
	if got := page(open, wire.ReportNodesSortNewest, 50); len(got) != 125 {
		t.Fatalf("state: %d", len(got))
	}
	if got := nodesPage(nodeRows(nodes, "issue"), open, wire.ReportNodesSortNewest, nil, 50); got.Unresolved != 126 {
		t.Fatalf("unresolved: %d", got.Unresolved)
	}
	if got := page(wire.ReportNodesQuery{Kind: "issue", Label: str("bug")}, wire.ReportNodesSortNewest, 50); len(got) != 125 {
		t.Fatalf("label: %d", len(got))
	}
	byCost := page(wire.ReportNodesQuery{Kind: "issue"}, wire.ReportNodesSortCost, 33)
	if len(byCost) != 251 {
		t.Fatalf("cost: %d", len(byCost))
	}
	for i := 1; i < len(byCost); i++ {
		a, b := byCost[i-1], byCost[i]
		if a.Cost.Total.Cost["USD"] < b.Cost.Total.Cost["USD"] ||
			a.Cost.Total.Cost["USD"] == b.Cost.Total.Cost["USD"] && a.Node.Ref > b.Node.Ref {
			t.Fatalf("cost order at %d: %v %v", i, a.Node, b.Node)
		}
	}
	// No issue here has a merged PR, so none has a lead time: all of them, by ref.
	if got := page(wire.ReportNodesQuery{Kind: "issue"}, wire.ReportNodesSortLeadTime, 100); len(got) != 251 ||
		got[0].Node.Ref != "github:o/r#0" {
		t.Fatalf("leadTime: %d", len(got))
	}
}

func TestReportsNodesLeadTimeAndWasteSort(t *testing.T) {
	t.Parallel()
	str := func(s string) *string { return &s }
	at := func(d float64) *wire.Date { v := wire.Date(d); return &v }
	pr := func(ref, outcome string, usd, first, ended float64) wire.LineageCostNode {
		return wire.LineageCostNode{Node: wire.LineageNode{Kind: "pr", Ref: ref}, Outcome: str(outcome),
			Banked: wire.LineageCost{Cost: map[string]float64{"USD": usd}}, FirstAt: at(first), EndedAt: at(ended), LastAt: wire.Date(ended)}
	}
	open := wire.LineageCostNode{Node: wire.LineageNode{Kind: "pr", Ref: "github:o/r#9"},
		Banked: wire.LineageCost{Cost: map[string]float64{"USD": 9}}, LastAt: 5}
	nodes := []wire.LineageCostNode{pr("github:o/r#1", "merged", 1, 0, 100), pr("github:o/r#2", "merged", 2, 0, 50),
		pr("github:o/r#3", "closed", 5, 0, 10), pr("github:o/r#4", "reverted", 1, 0, 20), open}
	refs := func(order wire.ReportNodesSort) []string {
		var out []string
		for _, r := range nodesPage(nodeRows(nodes, "pr"), wire.ReportNodesQuery{Kind: "pr"}, order, nil, 50).Nodes {
			out = append(out, r.Node.Ref)
		}
		return out
	}
	if got := fmt.Sprint(refs(wire.ReportNodesSortLeadTime)); got != "[github:o/r#1 github:o/r#2 github:o/r#3 github:o/r#4 github:o/r#9]" {
		t.Fatal(got)
	}
	if got := fmt.Sprint(refs(wire.ReportNodesSortWaste)); got != "[github:o/r#3 github:o/r#4 github:o/r#1 github:o/r#2 github:o/r#9]" {
		t.Fatal(got)
	}
	merged := nodesPage(nodeRows(nodes, "pr"), wire.ReportNodesQuery{Kind: "pr", State: str("merged")}, wire.ReportNodesSortNewest, nil, 50)
	if len(merged.Nodes) != 3 {
		t.Fatalf("%+v", merged.Nodes)
	}
}
