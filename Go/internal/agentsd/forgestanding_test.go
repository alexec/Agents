package agentsd

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/githubmcp"
	"github.com/alexec/agents/Go/wire"
)

// #3661: the standing block's fields, case-insensitive, with lanes 1 when not said; no block, a
// second block, an unknown field and a bad value are errors.
func TestStandingOfReadsTheBlock(t *testing.T) {
	q := standingOf("The bug lane.\r\n\r\n```standing\r\nLabels: bug\r\nany: polish, , competitor\r\nnot: wontfix\r\nmilestone: None\r\n```\r\n")
	if q.Error != nil || strings.Join(q.Labels, ",") != "bug" || strings.Join(q.Any, ",") != "polish,competitor" ||
		strings.Join(q.Not, ",") != "wontfix" || deref(q.Milestone) != "none" || q.Lanes != 1 {
		t.Fatalf("query: %+v", q)
	}
	if q := standingOf("```standing\nlanes: 2\nmilestone: Projects\n```"); q.Error != nil || q.Lanes != 2 || deref(q.Milestone) != "Projects" ||
		q.Labels == nil || q.Any == nil || q.Not == nil {
		t.Fatalf("query: %+v", q)
	}
	for body, want := range map[string]string{
		"no block here\n```go\nlabels: bug\n```":                 "no standing block",
		"```standing\nlabels: bug\n```\n```standing\nany: x\n```": "2 standing blocks",
		"```standing\nlabel: bug\n```":                            `unknown field "label"`,
		"```standing\nlanes: 0\n```":                              "lanes",
		"```standing\nlabels bug\n```":                            "not field: value",
		"```standing\nlabels: a\nlabels: b\n```":                  "twice",
	} {
		if q := standingOf(body); q.Error == nil || !strings.Contains(*q.Error, want) || q.Labels == nil {
			t.Errorf("%q: %+v", body, q)
		}
	}
}

// #3661: the query takes open issues that are not epics, with its labels and milestone; the
// order is priority (high, medium, none, low), then the oldest.
func TestStandingMatchesAndOrder(t *testing.T) {
	item := func(n string, milestone string, labels ...string) wire.ForgeItem {
		i := forgeItemOf(planIssue(0, "open", labels...), "")
		i.Node.Ref = "github:alexec/agents#" + n
		if milestone != "" {
			i.Milestone = &milestone
		}
		return i
	}
	q := standingOf("```standing\nlabels: bug\nnot: wontfix\nmilestone: none\n```")
	for _, c := range []struct {
		item wire.ForgeItem
		want bool
	}{
		{item("1", "", "Bug"), true},
		{item("2", "Projects", "bug"), false},
		{item("3", "", "bug", "epic"), false},
		{item("4", "", "bug", "wontfix"), false},
		{item("5", "", "polish"), false},
	} {
		if got := standingMatches(q, c.item); got != c.want {
			t.Errorf("%s: %v", c.item.Node.Ref, got)
		}
	}
	closed := item("6", "", "bug")
	closed.State = "closed"
	if standingMatches(q, closed) {
		t.Error("a closed issue matches")
	}
	if anyOf := standingOf("```standing\nany: polish, competitor\nmilestone: any\n```"); !standingMatches(anyOf, item("7", "Projects", "competitor")) ||
		standingMatches(anyOf, item("8", "", "competitor")) || standingMatches(anyOf, item("9", "Projects", "bug")) {
		t.Error("any and milestone: any")
	}
	items := []wire.ForgeItem{item("30", "", "bug"), item("12", "", "priority:low"), item("40", "", "priority:high"),
		item("25", "", "priority:medium"), item("9", "", "bug"), item("31", "", "Priority:High")}
	standingOrder(items)
	got := []string{}
	for _, i := range items {
		got = append(got, strings.TrimPrefix(i.Node.Ref, "github:alexec/agents#"))
	}
	if strings.Join(got, " ") != "31 40 25 9 30 12" {
		t.Fatalf("order: %v", got)
	}
}

// #3661: forge/plan of an epic labelled standing returns its query's open issues of its own repo
// in order, all in one step, with the query, their blockers and no progress; the same plan again
// asks GitHub nothing.
func TestForgePlanOfAStandingEpic(t *testing.T) {
	_, c, gh, _ := forgeDaemon(t)
	gh.plan = githubmcp.Plan{Epic: planIssue(3659, "open", "epic", "Standing")}
	gh.plan.Epic.SubTotal, gh.plan.Epic.SubDone = 3, 1
	gh.bodies = map[int]string{3659: "The bug lane.\n\n```standing\nlabels: bug\nmilestone: none\n```\n"}
	low, high, milestoned, other := planIssue(9, "open", "bug", "priority:low"), planIssue(11, "open", "bug", "priority:high"),
		planIssue(13, "open", "bug"), planIssue(5, "open", "bug")
	milestoned.Milestone, other.Repo = "Projects", "alexec/web"
	gh.labeled = map[string][]githubmcp.Item{"bug": {low, planIssue(10, "open", "bug"), high, milestoned, planIssue(14, "open", "bug", "epic"), other}}
	gh.blockers = map[int][]githubmcp.Ref{10: {{Repo: "alexec/Agents", Number: 11, Open: true}, {Repo: "alexec/web", Number: 2, Open: false}},
		9: {{Repo: "alexec/web", Number: 3, Open: true}}}
	epic := wire.LineageNode{Kind: "issue", Ref: "github:alexec/agents#3659"}
	var plan wire.ForgePlan
	json.Unmarshal(c.call(t, 1, "forge/plan", wire.ForgePlanRequest{Node: epic}), &plan)
	got := []string{}
	for _, ch := range plan.Children {
		got = append(got, strings.TrimPrefix(ch.Item.Node.Ref, "github:alexec/agents#"))
		if ch.Step != 1 || ch.BlockedBy == nil {
			t.Errorf("child: %+v", ch)
		}
	}
	// #4200: each child's blockers come from one read; an open one is said even when it is in the
	// plan, which has one step.
	blockers := func(n int) string {
		var b []string
		for _, r := range plan.Children[n].BlockedBy {
			b = append(b, r.Ref)
		}
		b = append(b, "|")
		for _, r := range plan.Children[n].BlockedOutside {
			b = append(b, r.Ref)
		}
		return strings.Join(b, " ")
	}
	if len(plan.Children) == 3 && (blockers(0) != "|" || blockers(1) != "github:alexec/agents#11 github:alexec/web#2 | github:alexec/agents#11" ||
		blockers(2) != "github:alexec/web#3 | github:alexec/web#3") {
		t.Errorf("blockers: %q, %q, %q", blockers(0), blockers(1), blockers(2))
	}
	if len(gh.blocked) != 1 || fmt.Sprint(gh.blocked[0]) != "[11 10 9]" {
		t.Errorf("blockers asked: %v", gh.blocked)
	}
	if strings.Join(got, " ") != "11 10 9" || len(plan.Steps) != 1 || len(plan.Steps[0].Nodes) != 3 || plan.Item.Progress != nil ||
		plan.Item.Standing == nil || !*plan.Item.Standing || plan.Standing == nil || plan.Standing.Error != nil || plan.Standing.Lanes != 1 ||
		deref(plan.Standing.Milestone) != "none" || strings.Join(plan.Standing.Labels, ",") != "bug" {
		t.Fatalf("plan %v: %+v", got, plan)
	}
	if searches, _ := gh.asked(); len(searches) != 1 || !strings.Contains(searches[0], `label:"bug"`) || !strings.Contains(searches[0], "is:open") {
		t.Fatalf("searches: %q", searches)
	}
	json.Unmarshal(c.call(t, 2, "forge/plan", wire.ForgePlanRequest{Node: epic}), &plan)
	if searches, _ := gh.asked(); gh.plans != 1 || len(searches) != 1 || len(gh.blocked) != 1 || plan.Standing == nil || len(plan.Children) != 3 {
		t.Fatalf("again: %d plans, %q, %+v", gh.plans, searches, plan)
	}

	gh.bodies[3659] = "No block."
	gh.plan.Epic.Number = 3700
	gh.bodies[3700] = "No block."
	plan = wire.ForgePlan{}
	json.Unmarshal(c.call(t, 3, "forge/plan", wire.ForgePlanRequest{Node: wire.LineageNode{Kind: "issue", Ref: "github:alexec/agents#3700"}}), &plan)
	if plan.Standing == nil || plan.Standing.Error == nil || len(plan.Children) != 0 || plan.Children == nil || len(plan.Steps) != 0 {
		t.Fatalf("no block: %+v", plan)
	}
}
