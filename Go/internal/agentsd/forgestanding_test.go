package agentsd

import (
	"context"
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
		q.Labels == nil || q.Any == nil || q.Not == nil || q.Parent != nil {
		t.Fatalf("query: %+v", q)
	}
	if q := standingOf("```standing\nlabels: enhancement\nParent: None\n```"); q.Error != nil || deref(q.Parent) != "none" {
		t.Fatalf("parent: none: %+v", q)
	}
	for body, want := range map[string]string{
		"no block here\n```go\nlabels: bug\n```":                 "no standing block",
		"```standing\nlabels: bug\n```\n```standing\nany: x\n```": "2 standing blocks",
		"```standing\nlabel: bug\n```":                            `unknown field "label"`,
		"```standing\nlanes: 0\n```":                              "lanes",
		"```standing\nlabels bug\n```":                            "not field: value",
		"```standing\nlabels: a\nlabels: b\n```":                  "twice",
		"```standing\nparent: any\n```":                           "parent",
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

// #4242: a standing epic's children say their blockers on GitLab, Forgejo, Linear, Jira and
// Azure Boards, from one read on the epic's own forge, as on GitHub.
func TestStandingBlockersOnEveryForge(t *testing.T) {
	children := func(refs ...string) []planChild {
		var out []planChild
		for _, r := range refs {
			out = append(out, planChild{item: wire.ForgeItem{Node: wire.LineageNode{Kind: "issue", Ref: r}}})
		}
		return out
	}
	said := func(cs []planChild) string {
		var out []string
		for _, c := range cs {
			var b []string
			for _, r := range c.blockedBy {
				b = append(b, fmt.Sprintf("%s:%v", r.node.Ref, r.open))
			}
			out = append(out, strings.Join(b, " "))
		}
		return strings.Join(out, "|")
	}
	check := func(name string, d *Daemon, epic string, cs []planChild, want string) {
		t.Helper()
		if err := d.standingBlockers(context.Background(), "forge/plan", wire.ForgeItem{Node: wire.LineageNode{Kind: "issue", Ref: epic}}, cs); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if got := said(cs); got != want {
			t.Errorf("%s: %q, want %q", name, got, want)
		}
	}

	d, _, _, gl, ln, _ := allForgesDaemon(t)
	check("GitLab", d, "gitlab:group/app#5", children("gitlab:group/app#7", "gitlab:group/app#8"),
		"gitlab:group/app#90:true gitlab:ops/tool#91:false|")
	check("Linear", d, "linear:ENG-5", children("linear:ENG-6", "linear:ENG-9"), "linear:OPS-1:true linear:ENG-2:false|")
	if fmt.Sprint(gl.blocked) != "[Group/App[7 8]]" || fmt.Sprint(ln.blocked) != "[[ENG-6 ENG-9]]" {
		t.Errorf("asked GitLab %q, Linear %q", gl.blocked, ln.blocked)
	}

	d, _, j, _ := jiraDaemon(t)
	check("Jira", d, "jira:PROJ-7", children("jira:PROJ-8", "jira:PROJ-9"), "jira:OPS-1:true jira:PROJ-2:false|")
	if fmt.Sprint(j.blocked) != "[[PROJ-8 PROJ-9]]" {
		t.Errorf("asked Jira %q", j.blocked)
	}

	d, _, b, _ := boardsDaemon(t)
	check("Azure Boards", d, "azureboards:acme/web app#12", children("azureboards:acme/web app#13", "azureboards:acme/web app#14"),
		"azureboards:acme/ops#90:true azureboards:acme/web app#91:false|")
	if fmt.Sprint(b.blocked) != "[acme/web app[13 14]]" {
		t.Errorf("asked Azure Boards %q", b.blocked)
	}

	d, _, fj, _ := forgejoDaemon(t)
	check("Forgejo", d, "forgejo:walkalex/app#1", children("forgejo:walkalex/app#2", "forgejo:walkalex/app#3"),
		"forgejo:kim/notes#9:true forgejo:walkalex/app#5:false|")
	if fmt.Sprint(fj.blocked) != "[walkalex/App[2 3]]" {
		t.Errorf("asked Forgejo %q", fj.blocked)
	}
	// A forge the epic is on but no folder here is: the read says why.
	if err := d.standingBlockers(context.Background(), "forge/plan", wire.ForgeItem{Node: wire.LineageNode{Kind: "issue", Ref: "forgejo:kim/notes#1"}},
		children("forgejo:kim/notes#2")); err == nil || !strings.Contains(err.Error(), "forge/plan") {
		t.Errorf("Forgejo with no folder: %v", err)
	}
}

// #4335: parent: none leaves out the issues that are another's sub-issue. GitHub's list says the
// parent, so the plan asks nothing more.
func TestForgePlanOfAStandingEpicWithNoParent(t *testing.T) {
	_, c, gh, _ := forgeDaemon(t)
	gh.plan = githubmcp.Plan{Epic: planIssue(4208, "open", "epic", "Standing")}
	gh.bodies = map[int]string{4208: "```standing\nlabels: enhancement\nmilestone: none\nparent: none\n```\n"}
	child := planIssue(12, "open", "enhancement")
	child.ParentRepo, child.ParentNumber = "alexec/Agents", 3265
	gh.labeled = map[string][]githubmcp.Item{"enhancement": {planIssue(10, "open", "enhancement"), child, planIssue(14, "open", "enhancement")}}
	var plan wire.ForgePlan
	json.Unmarshal(c.call(t, 1, "forge/plan", wire.ForgePlanRequest{Node: wire.LineageNode{Kind: "issue", Ref: "github:alexec/agents#4208"}}), &plan)
	got := []string{}
	for _, ch := range plan.Children {
		got = append(got, strings.TrimPrefix(ch.Item.Node.Ref, "github:alexec/agents#"))
	}
	if strings.Join(got, " ") != "10 14" || plan.Standing == nil || plan.Standing.Error != nil {
		t.Fatalf("plan %v: %+v", got, plan.Standing)
	}
}

// #4335: GitLab's and Forgejo's lists do not say an issue's parent, so parent: none reads them
// for the epic's own repo, a page at a time, and keeps the issues with none, in order.
func TestStandingParentlessOnGitLabAndForgejo(t *testing.T) {
	items := func(refs ...string) []wire.ForgeItem {
		var out []wire.ForgeItem
		for _, r := range refs {
			out = append(out, wire.ForgeItem{Node: wire.LineageNode{Kind: "issue", Ref: r}})
		}
		return out
	}
	refs := func(is []wire.ForgeItem) string {
		var out []string
		for _, i := range is {
			out = append(out, i.Node.Ref)
		}
		return strings.Join(out, " ")
	}
	d, _, _, gl, _, _ := allForgesDaemon(t)
	kept, err := d.standingParentless(context.Background(), "forge/plan", wire.ForgeItem{Node: wire.LineageNode{Kind: "issue", Ref: "gitlab:group/app#5"}},
		items("gitlab:group/app#7", "gitlab:group/app#8", "gitlab:group/app#9"))
	if err != nil || refs(kept) != "gitlab:group/app#8 gitlab:group/app#9" || fmt.Sprint(gl.parented) != "[Group/App[7 8 9]]" {
		t.Errorf("GitLab: %q, %v, asked %q", refs(kept), err, gl.parented)
	}

	d, _, fj, _ := forgejoDaemon(t)
	kept, err = d.standingParentless(context.Background(), "forge/plan", wire.ForgeItem{Node: wire.LineageNode{Kind: "issue", Ref: "forgejo:walkalex/app#1"}},
		items("forgejo:walkalex/app#2", "forgejo:walkalex/app#3"))
	if err != nil || refs(kept) != "forgejo:walkalex/app#3" || fmt.Sprint(fj.parented) != "[walkalex/App[2 3]]" {
		t.Errorf("Forgejo: %q, %v, asked %q", refs(kept), err, fj.parented)
	}

	// On Linear the list said the parent: nothing more is asked.
	parent := wire.LineageNode{Kind: "issue", Ref: "linear:ENG-5"}
	linear := items("linear:ENG-6", "linear:ENG-7")
	linear[0].Parent = &parent
	if kept, err = d.standingParentless(context.Background(), "forge/plan", wire.ForgeItem{Node: parent}, linear); err != nil || refs(kept) != "linear:ENG-7" {
		t.Errorf("Linear: %q, %v", refs(kept), err)
	}
}
