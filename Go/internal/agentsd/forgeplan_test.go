package agentsd

import (
	"context"
	"encoding/json"
	"fmt"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/githubmcp"
	"github.com/alexec/agents/Go/internal/gitlabmcp"
	"github.com/alexec/agents/Go/internal/linearmcp"
	"github.com/alexec/agents/Go/wire"
)

func (f *fakeForgeGitHub) Plan(_ context.Context, repo string, number int) (githubmcp.Plan, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.plans++
	if number == 404 {
		return githubmcp.Plan{}, &githubmcp.GitHubError{Kind: githubmcp.NotFound, Message: "no issue #404 in " + repo}
	}
	return f.plan, nil
}

func (f *fakeForgeGitHub) Blockers(_ context.Context, _ string, numbers []int) (map[int][]githubmcp.Ref, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.blocked = append(f.blocked, numbers)
	return f.blockers, nil
}

// Blockers, on each forge's fake (#4242): the first asked about is blocked by an open issue and a
// closed one, the rest by none.
func (f *fakeForgeGitLab) Blockers(_ context.Context, project string, numbers []int) (map[int][]gitlabmcp.Ref, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.blocked = append(f.blocked, fmt.Sprint(project, numbers))
	return map[int][]gitlabmcp.Ref{numbers[0]: {{Project: "Group/App", Number: 90, Open: true}, {Project: "ops/tool", Number: 91}}}, nil
}

// Parents, on GitLab's and Forgejo's fakes (#4335): the first asked about is a child of the
// epic #5, the rest have no parent.
func (f *fakeForgeGitLab) Parents(_ context.Context, project string, numbers []int) (map[int]gitlabmcp.Ref, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.parented = append(f.parented, fmt.Sprint(project, numbers))
	return map[int]gitlabmcp.Ref{numbers[0]: {Project: "Group/App", Number: 5, Open: true}}, nil
}

func (f *fakeForgeLinear) Blockers(_ context.Context, identifiers []string) (map[string][]linearmcp.Ref, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.blocked = append(f.blocked, fmt.Sprint(identifiers))
	return map[string][]linearmcp.Ref{identifiers[0]: {{Identifier: "OPS-1", Open: true}, {Identifier: "ENG-2"}}}, nil
}

func (f *fakeForgeGitLab) Plan(_ context.Context, project string, number int) (gitlabmcp.Plan, error) {
	return gitlabmcp.Plan{Epic: gitlabmcp.Item{Project: project, Number: number, State: "open", Title: "GitLab epic", Labels: []string{"epic"},
		SubTotal: 2, SubDone: 0},
		Children: []gitlabmcp.PlanChild{
			{Item: gitlabmcp.Item{Project: project, Number: 6, State: "open", Title: "Second", ParentProject: project, ParentNumber: number},
				BlockedBy: []gitlabmcp.Ref{{Project: project, Number: 7, Open: true}}},
			{Item: gitlabmcp.Item{Project: project, Number: 7, State: "open", Title: "First", ParentProject: project, ParentNumber: number}, BlockedBy: []gitlabmcp.Ref{}},
		}}, nil
}

func (f *fakeForgeLinear) Plan(_ context.Context, identifier string) (linearmcp.Plan, error) {
	return linearmcp.Plan{Epic: linearmcp.Item{Identifier: identifier, Team: "ENG", State: "open", Title: "Linear epic", Labels: []string{"Epic", "feature:Billing"}},
		Children: []linearmcp.PlanChild{
			{Item: linearmcp.Item{Identifier: "ENG-6", Team: "ENG", State: "open", Title: "Child", Parent: identifier},
				BlockedBy: []linearmcp.Ref{{Identifier: "OPS-1", Open: true}}},
		}}, nil
}

func planIssue(n int, state string, labels ...string) githubmcp.Item {
	return githubmcp.Item{Repo: "alexec/agents", Number: n, State: state, Title: "Issue", Labels: labels, UpdatedAt: "2026-11-01T10:00:00Z"}
}

// #3267: a child's step is one more than its blockers' in the plan; a blocker outside the plan
// adds no step but is said when open; a loop shares the step after the rest.
func TestPlanOfPutsChildrenInSteps(t *testing.T) {
	node := func(n string) wire.LineageNode { return wire.LineageNode{Kind: "issue", Ref: "github:a/b#" + n} }
	child := func(n string, blockers ...planRef) planChild {
		return planChild{item: wire.ForgeItem{Node: node(n)}, blockedBy: blockers}
	}
	p := planOf(wire.ForgeItem{Node: node("1")}, []planChild{
		child("4", planRef{node("3"), false}, planRef{node("2"), false}),
		child("2"),
		child("3", planRef{node("2"), false}, planRef{node("99"), true}, planRef{node("98"), false}),
		child("5", planRef{node("6"), true}),
		child("6", planRef{node("5"), true}),
	}, false)
	got := []string{}
	for _, c := range p.Children {
		got = append(got, c.Item.Node.Ref[len("github:a/b#"):]+"@"+strconv.FormatInt(c.Step, 10))
	}
	if strings.Join(got, " ") != "2@1 3@2 4@3 5@4 6@4" {
		t.Fatalf("steps: %v", got)
	}
	if len(p.Steps) != 4 || len(p.Steps[3].Nodes) != 2 || p.Steps[0].Step != 1 {
		t.Fatalf("steps: %+v", p.Steps)
	}
	if c := p.Children[1]; len(c.BlockedBy) != 3 || len(c.BlockedOutside) != 1 || c.BlockedOutside[0] != node("99") {
		t.Fatalf("blockers: %+v", c)
	}
	if p := planOf(wire.ForgeItem{}, nil, false); p.Children == nil || p.Steps == nil {
		t.Fatalf("an empty plan: %+v", p)
	}
}

// #3267: the level and the feature come from the labels; the parent and progress from the forge.
func TestForgeItemsSayTheirHierarchy(t *testing.T) {
	i := planIssue(3268, "open", "enhancement", "Story", "feature:work")
	i.ParentRepo, i.ParentNumber, i.SubTotal, i.SubDone = "alexec/Agents", 3265, 0, 0
	out := forgeItemOf(i, "")
	if deref(out.Level) != "story" || deref(out.Feature) != "work" || out.Parent == nil || out.Parent.Ref != "github:alexec/agents#3265" || out.Progress != nil {
		t.Fatalf("item: %+v", out)
	}
	e := planIssue(3265, "open", "epic")
	e.SubTotal, e.SubDone = 6, 2
	if out := forgeItemOf(e, ""); deref(out.Level) != "epic" || out.Feature != nil || out.Progress == nil || out.Progress.Done != 2 || out.Progress.Total != 6 {
		t.Fatalf("epic: %+v", out)
	}
	if out := linearItemOf(linearmcp.Item{Identifier: "ENG-6", Parent: "ENG-5", Labels: []string{"feature:"}}, ""); out.Parent == nil ||
		out.Parent.Ref != "linear:ENG-5" || out.Feature != nil {
		t.Fatalf("linear: %+v", out)
	}
	pr := planIssue(12, "open", "task")
	pr.PR = true
	if out := forgeItemOf(pr, ""); out.Level != nil {
		t.Fatalf("a pull request has no level: %+v", out)
	}
}

// #3267: forge/plan reads the epic's children in steps, with the lead session from lineage (a
// session labelled #<epic> and lead); the same plan again within forgeCacheFor asks GitHub
// nothing, but its lead is read again.
func TestForgePlanStepsAndLead(t *testing.T) {
	d, c, gh, _ := forgeDaemon(t)
	gh.plan = githubmcp.Plan{Epic: planIssue(3265, "open", "epic", "feature:work"), Children: []githubmcp.PlanChild{
		{Item: planIssue(3268, "open", "story"), BlockedBy: []githubmcp.Ref{{Repo: "alexec/agents", Number: 3267, Open: true}}},
		{Item: planIssue(3267, "closed", "task"), BlockedBy: []githubmcp.Ref{}},
	}}
	gh.plan.Epic.SubTotal, gh.plan.Epic.SubDone = 2, 1
	epic := wire.LineageNode{Kind: "issue", Ref: "github:alexec/agents#3265"}
	var plan wire.ForgePlan
	json.Unmarshal(c.call(t, 1, "forge/plan", wire.ForgePlanRequest{Node: epic}), &plan)
	if plan.Item.Node != epic || plan.Item.Progress == nil || plan.Item.Progress.Done != 1 || len(plan.Children) != 2 ||
		plan.Children[0].Item.Node.Ref != "github:alexec/agents#3267" || plan.Children[1].Step != 2 || plan.Lead != nil {
		t.Fatalf("plan: %+v", plan)
	}

	var folder string
	for _, f := range d.folderPaths() {
		if d.folderRepo(f) == (forgeRepo{"github", "alexec/agents"}) {
			folder = f
		}
	}
	lead := seeded(t, d, folder, func(a *wire.Agent) {
		a.Title, a.State = new("Plans lead"), wire.AgentStateRunning
		a.Labels = []wire.SessionLabel{{Value: "#3265", Owner: wire.SessionLabelOwnerAgent}, {Value: "lead", Owner: wire.SessionLabelOwnerAgent}}
	})
	lane := seeded(t, d, folder, func(a *wire.Agent) {
		a.Labels = []wire.SessionLabel{{Value: "#3265", Owner: wire.SessionLabelOwnerAgent}}
	})
	d.noteLineage(nil, lead)
	d.noteLineage(nil, lane)
	d.lineageSettle(5 * time.Second)
	plan = wire.ForgePlan{}
	json.Unmarshal(c.call(t, 2, "forge/plan", wire.ForgePlanRequest{Node: epic}), &plan)
	if plan.Lead == nil || plan.Lead.Session != lead.ID || deref(plan.Lead.Title) != "Plans lead" || plan.Lead.State != wire.AgentStateRunning {
		t.Fatalf("lead: %+v", plan.Lead)
	}
	if gh.plans != 1 {
		t.Fatalf("GitHub was asked for the plan %d times", gh.plans)
	}
	if _, err := d.forgePlan(context.Background(), wire.ForgePlanRequest{Node: wire.LineageNode{Kind: "pr", Ref: "github:alexec/agents#12"}}); err == nil {
		t.Fatal("a pull request has a plan")
	}
	if _, err := d.forgePlan(context.Background(), wire.ForgePlanRequest{Node: wire.LineageNode{Kind: "issue", Ref: "github:alexec/agents#404"}}); err == nil {
		t.Fatal("a missing issue has a plan")
	}
}

// #3267: GitLab's and Linear's plans are in the one model, each child with its parent.
func TestForgePlanOnGitLabAndLinear(t *testing.T) {
	_, c, _, _, _, _ := allForgesDaemon(t)
	var plan wire.ForgePlan
	json.Unmarshal(c.call(t, 1, "forge/plan", wire.ForgePlanRequest{Node: wire.LineageNode{Kind: "issue", Ref: "gitlab:group/app#5"}}), &plan)
	if len(plan.Children) != 2 || plan.Children[0].Item.Node.Ref != "gitlab:group/app#7" || plan.Children[1].Step != 2 ||
		plan.Children[0].Item.Parent == nil || plan.Children[0].Item.Parent.Ref != "gitlab:group/app#5" || deref(plan.Item.Level) != "epic" ||
		plan.Item.Progress == nil || plan.Item.Progress.Total != 2 {
		t.Fatalf("GitLab plan: %+v", plan)
	}
	plan = wire.ForgePlan{}
	json.Unmarshal(c.call(t, 2, "forge/plan", wire.ForgePlanRequest{Node: wire.LineageNode{Kind: "issue", Ref: "linear:ENG-5"}}), &plan)
	if deref(plan.Item.Feature) != "Billing" || deref(plan.Item.Level) != "epic" || len(plan.Children) != 1 ||
		len(plan.Children[0].BlockedOutside) != 1 || plan.Children[0].BlockedOutside[0].Ref != "linear:OPS-1" || plan.Children[0].Step != 1 {
		t.Fatalf("Linear plan: %+v", plan)
	}
}

// #3267: feature narrows a list to the label feature:<name>; forge/features counts the epics of
// each feature, open and closed, by name.
func TestForgeFeatureFilterAndFeatures(t *testing.T) {
	_, c, gh, _ := forgeDaemon(t)
	c.call(t, 1, "forge/issues", wire.ForgeListRequest{Feature: new("work")})
	if searches, _ := gh.asked(); len(searches) != 1 || !strings.Contains(searches[0], `label:"feature:work"`) {
		t.Fatalf("searches: %q", searches)
	}
	gh.epics = []githubmcp.Item{planIssue(1, "open", "epic", "feature:work"), planIssue(2, "closed", "epic", "feature:Work"),
		planIssue(3, "open", "epic", "feature:lineage"), planIssue(4, "open", "epic")}
	gh.epics[0].LabelColors = map[string]string{"feature:work": "#1d76db"}
	// #3741: the open issues that are not epics count under their feature; one with no epic adds no feature.
	gh.open = []githubmcp.Item{planIssue(1, "open", "epic", "feature:work"), planIssue(5, "open", "bug", "feature:Work"),
		planIssue(6, "open", "story", "feature:work", "alex-todo"), planIssue(7, "open", "feature:docs"), planIssue(8, "open")}
	gh.open[2].UpdatedAt = "2026-11-02T10:00:00Z"
	// #4115: the pull requests labelled needs-approval come with the features.
	gh.reviews = []githubmcp.Item{{Repo: "alexec/agents", Number: 9, PR: true, State: "open", Title: "Groups", Labels: []string{"needs-approval"}}}
	var out wire.ForgeFeatures
	json.Unmarshal(c.call(t, 2, "forge/features", wire.ForgeFeaturesRequest{}), &out)
	if len(out.Features) != 2 || out.Features[0].Name != "lineage" || out.Features[1].Name != "work" || out.Features[1].Epics != 2 ||
		out.Features[1].Open != 1 || deref(out.Features[1].Color) != "#1d76db" || len(out.Errors) != 0 ||
		out.Features[0].Issues == nil || *out.Features[0].Issues != 0 || out.Features[1].Issues == nil || *out.Features[1].Issues != 2 {
		t.Fatalf("features: %+v", out)
	}
	searches, _ := gh.asked()
	epics := slices.IndexFunc(searches, func(s string) bool { return strings.Contains(s, `label:"epic"`) })
	if epics < 0 || strings.Contains(searches[epics], "is:open") {
		t.Fatalf("searches: %q", searches)
	}
	// #4115: each feature's open issues and open epics, each once; those labelled alex-todo; the newest update.
	work := out.Features[1]
	if !slices.Equal(work.Refs, []string{"github:alexec/agents#1", "github:alexec/agents#5", "github:alexec/agents#6"}) ||
		!slices.Equal(work.Waiting, []string{"github:alexec/agents#6"}) || work.UpdatedAt == nil ||
		!slices.Equal(out.Features[0].Refs, []string{"github:alexec/agents#3"}) || len(out.Features[0].Waiting) != 0 ||
		!slices.Equal(out.Approvals, []string{"github:alexec/agents#9"}) {
		t.Fatalf("refs: %+v, approvals %q", out.Features, out.Approvals)
	}
	if lineage := out.Features[0].UpdatedAt; lineage == nil || *work.UpdatedAt <= *lineage {
		t.Fatalf("updatedAt: %v, %v", work.UpdatedAt, lineage)
	}
}
