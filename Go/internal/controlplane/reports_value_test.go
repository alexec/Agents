package controlplane

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// Reports ▸ Value (#2351): the machines' copies of a node add up; an issue's cost is its
// own and its PRs', a closed PR is waste, a merged one gives the lead time, and a member
// sees only their own machines.
func TestReportsValueAddsUpTheWork(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	owner := p.host("OWNERS-MAC")
	_, admin := p.client("Owner's window")
	bea := p.invite(admin, "Bea", wire.UserRoleMember)
	beas := p.machine(bea, "BEAS-MAC")

	now := time.Now()
	at := func(ago time.Duration) *wire.Date { d := wire.DateOf(now.Add(-ago)); return &d }
	str := func(s string) *string { return &s }
	n64 := func(n int64) *int64 { return &n }
	node := func(kind, ref string, usd float64) wire.LineageCostNode {
		return wire.LineageCostNode{Node: wire.LineageNode{Kind: kind, Ref: ref},
			Banked: wire.LineageCost{Cost: map[string]float64{"USD": usd}, InputTokens: 10, Turns: 1}, LastAt: wire.DateOf(now)}
	}
	issue := node("issue", "github:o/r#1", 1)
	issue.FirstAt = at(10 * time.Hour)
	issue.PartOf = []string{"github:o/r/milestone/1"}
	merged := node("pr", "github:o/r#2", 4)
	merged.Fixes, merged.Outcome, merged.EndedAt, merged.FailedChecks = []string{"github:o/r#1"}, str("merged"), at(time.Hour), n64(2)
	closed := node("pr", "github:o/r#3", 3)
	closed.Fixes, closed.Outcome, closed.EndedAt = []string{"github:o/r#1"}, str("closed"), at(2*time.Hour)
	session := node("session", "session:a", 0.5)
	old := node("issue", "github:o/r#9", 100)
	old.LastAt = wire.DateOf(now.Add(-40 * 24 * time.Hour))
	// Bea's machine banked its own turns on the same issue.
	beaIssue := node("issue", "github:o/r#1", 2)
	beaIssue.FirstAt = at(20 * time.Hour)

	send := func(host string, work ...wire.LineageCostNode) {
		t.Helper()
		params, _ := json.Marshal(wire.UsageRollup{Hours: []wire.UsageRollupPeriod{}, Days: []wire.UsageRollupPeriod{}, Work: work})
		if _, err := p.s.methods.HostSaid(host, "usage/rollup", params); err != nil {
			t.Fatal(err)
		}
	}
	send(owner.member.Host, issue, merged, closed, session, old)
	send(beas.member.Host, beaIssue)

	value := func(s *controllink.Session, r wire.ReportRange, scope *wire.ReportScope) wire.ReportValue {
		t.Helper()
		var v wire.ReportValue
		if err := json.Unmarshal(call(t, s, "", "reports/value", wire.ReportQuery{Range: r, Scope: scope}), &v); err != nil {
			t.Fatal(err)
		}
		return v
	}
	org := value(admin, wire.ReportRangeMonth, &wire.ReportScope{Kind: wire.ReportScopeKindOrg})
	// 1 + 2 (two machines) + 4 + 3; the old issue is out of the month.
	if org.Total.Cost["USD"] != 10 || org.Waste.Cost["USD"] != 3 || org.Unlinked.Cost["USD"] != 0.5 {
		t.Fatalf("%+v", org)
	}
	if org.PrsMerged != 1 || org.PrsClosed != 1 || org.FailedChecks != 2 || org.PerMergedPR["USD"] != 10 {
		t.Fatalf("%+v", org)
	}
	if len(org.Issues) != 1 || org.Issues[0].Node.Ref != "github:o/r#1" || org.Issues[0].Total.Cost["USD"] != 10 ||
		org.Issues[0].Waste.Cost["USD"] != 3 {
		t.Fatalf("%+v", org.Issues)
	}
	// From Bea's first work, 20 hours ago, to the merge an hour ago.
	if lead := org.Issues[0].LeadTimeSeconds; lead == nil || *lead < 18.9*3600 || *lead > 19.1*3600 ||
		org.LeadTimeSeconds == nil || *org.LeadTimeSeconds != *lead {
		t.Fatalf("%v %v", lead, org.LeadTimeSeconds)
	}
	if len(org.Milestones) != 1 || org.Milestones[0].Total.Cost["USD"] != 10 || org.Milestones[0].PrsMerged != 1 {
		t.Fatalf("%+v", org.Milestones)
	}
	if all := value(admin, wire.ReportRangeThreeMonths, &wire.ReportScope{Kind: wire.ReportScopeKindOrg}); len(all.Issues) != 2 ||
		all.Issues[0].Node.Ref != "github:o/r#9" {
		t.Fatalf("%+v", all.Issues)
	}

	// Bea sees her own machine's share only, and not the organisation.
	mine := value(bea.window, wire.ReportRangeWeek, nil)
	if mine.Scope.Kind != wire.ReportScopeKindMe || mine.Total.Cost["USD"] != 2 || mine.PrsMerged != 0 ||
		len(mine.PerMergedPR) != 0 || len(mine.Issues) != 1 || mine.Issues[0].LeadTimeSeconds != nil {
		t.Fatalf("%+v", mine)
	}
	if e := callError(t, bea.window, "", "reports/value", wire.ReportQuery{Range: wire.ReportRangeWeek,
		Scope: &wire.ReportScope{Kind: wire.ReportScopeKindOrg}}); e == "" {
		t.Fatal("a member read the organisation")
	}
}

// #2975: every machine's lineage is read once, and a view again with nothing changed
// reads none of it from the store; a machine that sent new work is read again.
func TestReportsValueReadsLineageOnceByTag(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	st := &lineageGets{Store: store.NewMemory()}
	p := startPlane(t, st, controllink.NewPrivateKey())
	now := time.Now()
	put := func(host string, usd float64) {
		t.Helper()
		node := wire.LineageCostNode{Node: wire.LineageNode{Kind: "issue", Ref: "github:o/r#1"},
			Banked: wire.LineageCost{Cost: map[string]float64{"USD": usd}}, LastAt: wire.DateOf(now)}
		if err := p.s.keepWork(ctx, host, []wire.LineageCostNode{node}, now); err != nil {
			t.Fatal(err)
		}
	}
	const machines = 40
	for i := range machines {
		put(fmt.Sprintf("HOST-%02d", i), 1)
	}
	all := func(string) bool { return true }
	usd := func() float64 {
		t.Helper()
		nodes, err := p.s.scopeLineage(ctx, all)
		if err != nil || len(nodes) != 1 {
			t.Fatalf("%v %+v", err, nodes)
		}
		return nodes[0].Banked.Cost["USD"]
	}
	before := st.gets.Load()
	if got := usd(); got != machines || st.gets.Load()-before != machines {
		t.Fatalf("%v USD, %d reads", got, st.gets.Load()-before)
	}
	before = st.gets.Load()
	if got := usd(); got != machines || st.gets.Load() != before {
		t.Fatalf("%v USD, read again: %d", got, st.gets.Load()-before)
	}
	put("HOST-07", 5)
	before = st.gets.Load()
	if got := usd(); got != machines+4 || st.gets.Load()-before != 1 {
		t.Fatalf("%v USD, %d reads", got, st.gets.Load()-before)
	}
}

// lineageGets counts the reads of lineage objects only, as the plane reads its records too.
type lineageGets struct {
	store.Store
	gets atomic.Int64
}

func (g *lineageGets) Get(ctx context.Context, key string) (*store.Object, error) {
	if strings.HasPrefix(key, lineagePrefix) {
		g.gets.Add(1)
	}
	return g.Store.Get(ctx, key)
}
