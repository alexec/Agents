package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/githubmcp"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// #4586: work/features gives each feature with its open epics, each with the first step that has
// an open child, that step's open blockers outside the plan, and its children as work/timeline
// says them (the timeline's start from the first pull request); an epic whose plan cannot be read
// has no children and an error; the loose open issues are those with no epic and no parent, the
// newest first; and a read again within forgeCacheFor asks GitHub for no plan.
func TestWorkFeaturesGivesEpicsWithTheirPlans(t *testing.T) {
	d, c, gh, _ := forgeDaemon(t)
	for _, f := range d.folderPaths() {
		if d.folderRepo(f).path == "alexec/agents" {
			os.MkdirAll(filepath.Join(f, ".agents"), 0o755)
			os.WriteFile(filepath.Join(f, folderConfig), []byte(`{"project":"p1"}`), 0o644)
		}
	}
	gh.epics = []githubmcp.Item{planIssue(1, "open", "epic", "feature:work"), planIssue(2, "closed", "epic", "feature:work"),
		planIssue(404, "open", "epic", "feature:work")}
	parented := planIssue(6, "open", "story", "feature:work")
	parented.ParentRepo, parented.ParentNumber = "alexec/agents", 1
	gh.open = []githubmcp.Item{planIssue(1, "open", "epic", "feature:work"), planIssue(5, "open", "bug", "feature:work"), parented,
		planIssue(7, "open", "feature:work", "alex-todo")}
	gh.open[3].UpdatedAt = "2026-11-02T10:00:00Z"
	gh.plan = githubmcp.Plan{Epic: planIssue(1, "open", "epic", "feature:work"), Children: []githubmcp.PlanChild{
		{Item: planIssue(10, "closed", "task"), BlockedBy: []githubmcp.Ref{}},
		{Item: planIssue(11, "open", "story"), BlockedBy: []githubmcp.Ref{{Repo: "alexec/agents", Number: 10}, {Repo: "alexec/agents", Number: 99, Open: true}}},
		{Item: planIssue(12, "open", "story", "needs-account"), BlockedBy: []githubmcp.Ref{{Repo: "alexec/agents", Number: 10},
			{Repo: "alexec/agents", Number: 99, Open: true}, {Repo: "alexec/agents", Number: 98, Open: true}}},
	}}
	opened := time.Now().Add(-2 * time.Hour).UTC().Format(time.RFC3339)
	gh.timeline = githubmcp.Timeline{Epics: []githubmcp.TimelineEpic{{Item: planIssue(1, "open", "epic", "feature:work"), Children: []githubmcp.TimelineChild{
		{Item: planIssue(11, "open", "story"), PROpenedAt: []string{opened}}}}}}

	var out wire.WorkFeatures
	json.Unmarshal(c.call(t, 1, "work/features", wire.WorkFeaturesRequest{}), &out)
	if len(out.Features) != 1 || out.Features[0].Feature.Name != "work" || out.Features[0].Feature.Open != 2 || len(out.Features[0].Epics) != 2 {
		t.Fatalf("features: %+v", out)
	}
	epic := out.Features[0].Epics[0]
	if epic.Item.Node.Ref != "github:issue:alexec/agents#1" || epic.Steps != 2 || epic.Step == nil || *epic.Step != 2 || len(epic.Children) != 3 {
		t.Fatalf("epic: %+v", epic)
	}
	var outside []string
	for _, b := range epic.BlockedOutside {
		outside = append(outside, b.Ref)
	}
	if !slices.Equal(outside, []string{"github:issue:alexec/agents#99", "github:issue:alexec/agents#98"}) {
		t.Fatalf("blocked outside: %q", outside)
	}
	byRef := map[string]wire.WorkTimelineChild{}
	for _, k := range epic.Children {
		byRef[k.Item.Node.Ref] = k
	}
	if k := byRef["github:issue:alexec/agents#11"]; k.StartedAt == nil || k.Item.Level == nil || *k.Item.Level != "story" {
		t.Fatalf("the timeline's child: %+v", k)
	}
	if k := byRef["github:issue:alexec/agents#12"]; k.StartedAt != nil || k.WaitsForPerson == nil {
		t.Fatalf("a child that waits: %+v", k)
	}
	if missing := out.Features[0].Epics[1]; missing.Item.Node.Ref != "github:issue:alexec/agents#404" || missing.Children != nil ||
		!slices.ContainsFunc(out.Errors, func(e wire.ForgeListError) bool { return strings.Contains(e.Message, "#404") }) {
		t.Fatalf("an epic with no plan: %+v, errors %+v", missing, out.Errors)
	}
	var loose []string
	for _, k := range out.Features[0].Loose {
		loose = append(loose, k.Item.Node.Ref)
	}
	if !slices.Equal(loose, []string{"github:issue:alexec/agents#7", "github:issue:alexec/agents#5"}) || out.Features[0].Loose[0].WaitsForPerson == nil {
		t.Fatalf("loose: %q %+v", loose, out.Features[0].Loose)
	}

	plans := gh.plans
	json.Unmarshal(c.call(t, 2, "work/features", wire.WorkFeaturesRequest{}), &out)
	if gh.plans != plans+1 { // only #404, which is not cached
		t.Fatalf("GitHub was asked for %d plans again", gh.plans-plans)
	}
}
