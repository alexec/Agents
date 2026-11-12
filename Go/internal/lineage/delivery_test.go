package lineage

import (
	"math"
	"strconv"
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// #4552: a repo's delivery figures over the 4 weeks before now, from its nodes and its tags.
func TestDeliveryOf(t *testing.T) {
	now := time.Date(2026, 11, 11, 12, 0, 0, 0, time.UTC)
	ago := func(days float64) *wire.Date {
		d := wire.DateOf(now.Add(-time.Duration(days * float64(24*time.Hour))))
		return &d
	}
	const repo = "github:alexec/agents"
	str := func(s string) *string { return &s }
	node := func(kind, ref string, change func(*wire.LineageCostNode)) wire.LineageCostNode {
		r := repo
		n := wire.LineageCostNode{Node: wire.LineageNode{Kind: kind, Ref: ref}, Repo: &r, Banked: blankCost()}
		change(&n)
		return n
	}
	merged := func(ref string, at float64, change func(*wire.LineageCostNode)) wire.LineageCostNode {
		return node(KindPR, ref, func(n *wire.LineageCostNode) {
			n.Outcome, n.EndedAt = str(OutcomeMerged), ago(at)
			change(n)
		})
	}
	release := func(tag string) string { return repo + "/release/" + tag }
	releases := map[string]wire.Date{
		release("v1.0.0"): *ago(20), release("v1.1.0"): *ago(10), release("v1.2.0"): *ago(2),
		"github:other/repo/release/v9.0.0": *ago(1),
	}
	nodes := []wire.LineageCostNode{
		node(KindIssue, repo+"#1", func(n *wire.LineageCostNode) { n.StartedAt = ago(22) }),
		merged(repo+"#10", 21, func(n *wire.LineageCostNode) {
			n.Fixes, n.PartOf, n.Files = []string{repo + "#1"}, []string{release("v1.0.0")}, []string{"a.go"}
			n.Banked.WorkingSeconds = 6 * 3600
		}),
		node(KindIssue, repo+"#2", func(n *wire.LineageCostNode) { n.StartedAt = ago(12) }),
		merged(repo+"#11", 11, func(n *wire.LineageCostNode) {
			n.Fixes, n.PartOf, n.Files = []string{repo + "#2"}, []string{release("v1.1.0")}, []string{"c.go"}
			n.Banked.WorkingSeconds = 12 * 3600
		}),
		merged(repo+"#12", 5, func(n *wire.LineageCostNode) { n.Files = []string{"a.go"} }),
		// Rework: a.go changed 1 day before.
		merged(repo+"#13", 4, func(n *wire.LineageCostNode) {
			n.Files = []string{"a.go", "b.go"}
			n.Resolved = &wire.LineageResolved{Title: "Add x"}
		}),
		// A revert of #13, a day later.
		merged(repo+"#14", 3, func(n *wire.LineageCostNode) {
			n.Outcome = str(OutcomeReverted)
			n.Reverts = str(repo + "#13")
		}),
		// A priority:high bug filed a day after v1.1.0, fixed a day later.
		node(KindIssue, repo+"#3", func(n *wire.LineageCostNode) {
			n.Level = str("bug")
			n.Resolved = &wire.LineageResolved{Title: "Crash", Labels: []string{"bug", "priority:high"}, CreatedAt: ago(9)}
		}),
		merged(repo+"#15", 8, func(n *wire.LineageCostNode) { n.Fixes = []string{repo + "#3"} }),
		// A priority:high bug filed 8 days after a release is no failure, nor its fix.
		node(KindIssue, repo+"#4", func(n *wire.LineageCostNode) {
			n.Resolved = &wire.LineageResolved{Title: "Slow", Labels: []string{"bug", "priority:high"}, CreatedAt: ago(12)}
		}),
		merged(repo+"#16", 11.5, func(n *wire.LineageCostNode) { n.Fixes = []string{repo + "#4"} }),
		// Before the window: no figure counts it, but its files are recent work for #11.
		merged(repo+"#9", 30, func(n *wire.LineageCostNode) { n.Files = []string{"c.go"} }),
		// Another repo's.
		{Node: wire.LineageNode{Kind: KindPR, Ref: "github:other/repo#1"}, Repo: str("github:other/repo"),
			Outcome: str(OutcomeReverted), EndedAt: ago(1)},
	}

	d := DeliveryOf(nodes, repo, releases, now)
	near := func(what string, got *float64, want float64) {
		t.Helper()
		if got == nil || math.Abs(*got-want) > 1e-6 {
			t.Errorf("%s: got %v, want %v", what, deref64(got), want)
		}
	}
	day := 24 * time.Hour.Seconds()
	if d.WindowDays != 28 || len(d.LeadTime.Weeks) != 4 {
		t.Fatalf("window %d, weeks %d", d.WindowDays, len(d.LeadTime.Weeks))
	}
	near("lead time", d.LeadTime.Value, 2*day)
	near("lead time p90", d.LeadTime.P90, 2*day)
	if d.LeadTime.Count != 2 || deref(d.LeadTime.Band) != BandHigh {
		t.Errorf("lead time %+v", d.LeadTime)
	}
	near("deploys a week", d.DeploymentFrequency.Value, 0.75)
	if d.DeploymentFrequency.Count != 3 || deref(d.DeploymentFrequency.Band) != BandMedium {
		t.Errorf("deployment frequency %+v", d.DeploymentFrequency)
	}
	for i, want := range []int64{0, 1, 1, 1} {
		if w := d.DeploymentFrequency.Weeks[i]; w.Count != want || w.Value == nil || *w.Value != float64(want) {
			t.Errorf("deploy week %d: %+v", i, w)
		}
	}
	// #10 to #16 merged; #14 (a revert) and #15 (the bug's fix) failed.
	near("change failure rate", d.ChangeFailureRate.Value, 2.0/7)
	if d.ChangeFailureRate.Count != 7 || deref(d.ChangeFailureRate.Band) != BandHigh {
		t.Errorf("change failure rate %+v", d.ChangeFailureRate)
	}
	near("recovery", d.RecoveryTime.Value, day)
	if d.RecoveryTime.Count != 2 || deref(d.RecoveryTime.Band) != BandMedium {
		t.Errorf("recovery %+v", d.RecoveryTime)
	}
	// #10, #11, #12 and #13 have files; #11 (c.go, #9's), #12 (a.go, #10's) and #13 (a.go,
	// #12's) change a file merged in the 21 days before.
	near("rework rate", d.ReworkRate.Value, 0.75)
	if d.ReworkRate.Count != 4 || d.ReworkRate.Band != nil {
		t.Errorf("rework %+v", d.ReworkRate)
	}
	// #1: 6 hours over a day; #2: 12 hours over a day.
	near("flow efficiency", d.FlowEfficiency.Value, 0.375)
	if d.FlowEfficiency.Count != 2 || d.FlowEfficiency.Band != nil {
		t.Errorf("flow %+v", d.FlowEfficiency)
	}
	if w := d.FlowEfficiency.Weeks; w[0].Value != nil || w[0].Count != 0 || w[1].Count != 1 || w[2].Count != 1 {
		t.Errorf("flow weeks %+v", w)
	}

	// Nothing to count: no values, but deploys a week is 0.
	empty := DeliveryOf(nil, repo, nil, now)
	if empty.LeadTime.Value != nil || empty.ChangeFailureRate.Value != nil || empty.ReworkRate.Value != nil {
		t.Errorf("empty %+v", empty)
	}
	near("no deploys", empty.DeploymentFrequency.Value, 0)
}

// #4552: a revert's body names the PR it reverts; its title is the way when the body does not.
func TestRevertsIn(t *testing.T) {
	for body, want := range map[string]string{
		"Reverts alexec/agents#4800":         "github:alexec/agents#4800",
		"This PR reverts #12 as it broke CI": "github:alexec/agents#12",
		"Fixes #12":                          "",
	} {
		if got := RevertsIn("github:alexec/agents", body); got != want {
			t.Errorf("%q: got %q, want %q", body, got, want)
		}
	}
	byTitle := map[string]wire.LineageCostNode{"Add x": {Node: wire.LineageNode{Kind: KindPR, Ref: "r#1"}}}
	revert := wire.LineageCostNode{Node: wire.LineageNode{Kind: KindPR, Ref: "r#2"}, Resolved: &wire.LineageResolved{Title: `Revert "Add x"`}}
	if r, ok := revertedBy(revert, nil, byTitle); !ok || r.Node.Ref != "r#1" {
		t.Errorf("by title: %+v %v", r, ok)
	}
}

func deref64(v *float64) any {
	if v == nil {
		return nil
	}
	return *v
}

func TestDeliveryBands(t *testing.T) {
	day := 24 * time.Hour.Seconds()
	for _, c := range []struct {
		of   func(float64) string
		v    float64
		want string
	}{
		{leadBand, 0.5 * day, BandElite}, {leadBand, 40 * day, BandLow},
		{frequencyBand, 10, BandElite}, {frequencyBand, 0.1, BandLow},
		{failureBand, 0.04, BandElite}, {failureBand, 0.11, BandMedium}, {failureBand, 0.19, BandHigh},
		{recoveryBand, 600, BandElite}, {recoveryBand, 8 * day, BandLow},
	} {
		if got := c.of(c.v); got != c.want {
			t.Errorf("%v: got %s, want %s", c.v, got, c.want)
		}
	}
}

// #4554: CI time to green is each merged PR's last push to its last pass, the median and P90,
// by merge; failed rounds is the mean of its failed CI runs, 0 for none.
func TestDeliveryCITimeToGreen(t *testing.T) {
	now := time.Date(2026, 11, 11, 12, 0, 0, 0, time.UTC)
	ago := func(days float64) *wire.Date {
		d := wire.DateOf(now.Add(-time.Duration(days * float64(24*time.Hour))))
		return &d
	}
	const repo = "github:repo:#alexec/agents"
	minute := wire.Date(60)
	merged := func(n int, at float64, green wire.Date, failed int64) wire.LineageCostNode {
		r, o := repo, OutcomeMerged
		c := wire.LineageCostNode{Node: wire.LineageNode{Kind: KindPR, Ref: "github:pr:alexec/agents#" + strconv.Itoa(n)}, Repo: &r,
			Banked: blankCost(), Outcome: &o, EndedAt: ago(at)}
		if green > 0 {
			pushed := *ago(at) - green - minute
			g := pushed + green
			c.Ci = &wire.LineagePRCI{HeadSha: "abc", PushedAt: &pushed, GreenAt: &g}
		}
		if failed > 0 {
			c.FailedChecks = &failed
		}
		return c
	}
	open := merged(9, 1, 5*minute, 3)
	open.Outcome, open.EndedAt = nil, nil
	never := merged(8, 2, 0, 0)
	never.Ci = &wire.LineagePRCI{HeadSha: "def", PushedAt: ago(2)}
	nodes := []wire.LineageCostNode{
		merged(1, 20, 10*minute, 0),
		merged(2, 10, 20*minute, 1),
		merged(3, 3, 12*minute, 2),
		merged(4, 2, 40*minute, 1),
		// No pass kept: counts for failed rounds only.
		never,
		// Open: neither.
		open,
		// Before the window: neither.
		merged(7, 40, 99*minute, 9),
	}
	d := DeliveryOf(nodes, repo, nil, now)
	g := d.CiTimeToGreen
	if g.Count != 4 || g.Value == nil || *g.Value != float64(16*minute) || g.P90 == nil || g.Band != nil {
		t.Fatalf("ci time to green %+v", g)
	}
	if *g.P90 < float64(20*minute) || *g.P90 > float64(40*minute) {
		t.Errorf("p90 %v", *g.P90)
	}
	if w := g.Weeks; len(w) != 4 || w[0].Count != 0 || w[1].Count != 1 || w[2].Count != 1 || w[3].Count != 2 {
		t.Errorf("weeks %+v", w)
	}
	f := d.FailedRounds
	if f.Count != 5 || f.Value == nil || math.Abs(*f.Value-4.0/5) > 1e-9 || f.Band != nil {
		t.Errorf("failed rounds %+v", f)
	}
	empty := DeliveryOf(nil, repo, nil, now)
	if empty.CiTimeToGreen.Value != nil || empty.FailedRounds.Value != nil || len(empty.CiTimeToGreen.Weeks) != 4 {
		t.Errorf("empty %+v", empty)
	}
}
