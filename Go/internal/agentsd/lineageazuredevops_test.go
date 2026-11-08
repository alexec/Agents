package agentsd

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/azuredevopsmcp"
	"github.com/alexec/agents/Go/internal/connections"
	"github.com/alexec/agents/Go/wire"
	sdk "github.com/coder/acp-go-sdk"
)

func (f *fakeForgeAzureDevOps) Node(_ context.Context, repo string, number int) (azuredevopsmcp.Node, error) {
	f.note(&f.asked, fmt.Sprintf("node %s#%d", repo, number))
	return azuredevopsmcp.Node{Title: "Add a", State: "merged", Labels: []string{"ui"}}, nil
}

func (f *fakeForgeAzureDevOps) CommitTime(_ context.Context, repo, ref string) (time.Time, error) {
	f.note(&f.asked, "time "+repo+" "+ref)
	return time.Date(2026, 11, 7, 13, 17, 47, 0, time.UTC), nil
}

func (f *fakeForgeAzureDevOps) Compare(_ context.Context, repo, base, head string) ([]azuredevopsmcp.Commit, error) {
	f.note(&f.asked, "compare "+repo+" "+base+"..."+head)
	return []azuredevopsmcp.Commit{{SHA: "aaa", Message: "Merged PR 8: Add a"}, {SHA: "bbb", Message: "Fix b"}}, nil
}

func (f *fakeForgeAzureDevOps) CommitPR(_ context.Context, repo, sha string) (int, error) {
	f.note(&f.asked, "pull of "+repo+" "+sha)
	return 9, nil
}

func (f *fakeForgeAzureDevOps) CostComment(_ context.Context, repo string, number int, id, mark, body string) (string, error) {
	f.note(&f.asked, fmt.Sprintf("cost %s#%d id=%s %v", repo, number, id, mark == prCommentMark))
	return "77/1", nil
}

// azureDevOpsRepo is the azureDevOpsDaemon's repository on Azure DevOps, as a node names it.
var azureDevOpsRepo = forgeRepo{"azuredevops", "acme/web app/app"}

// azureDevOpsFolder is the azureDevOpsDaemon's folder on Azure DevOps.
func azureDevOpsFolder(t *testing.T, d *Daemon) string {
	t.Helper()
	for _, f := range d.folderPaths() {
		if d.folderRepo(f) == azureDevOpsRepo {
			return f
		}
	}
	t.Fatalf("no folder on %v: %v", azureDevOpsRepo, d.folderPaths())
	return ""
}

// #3952: lineage takes an Azure Repos folder's labels and pull request events as Azure DevOps
// nodes, by its remote's host, with or without a connection. Its "#7" is the work item 7 of its
// project on Azure Boards. Nothing is asked of gh or glab about them.
func TestLineageOnAnAzureReposFolder(t *testing.T) {
	d, _, _, file := azureDevOpsDaemon(t)
	folder := azureDevOpsFolder(t, d)
	branch := "agents/7-fix"
	a := seeded(t, d, folder, func(a *wire.Agent) {
		a.Labels = []wire.SessionLabel{{Value: "#7", Owner: wire.SessionLabelOwnerPerson}}
		a.Worktree = &wire.AgentWorktree{Name: "7-fix", Branch: &branch, Folder: store.FolderURL(folder)}
	})
	d.noteLineage(nil, a)
	s := sessionNode(a.ID)
	d.lineageEvent(wire.Event{Name: "pr.opened", Details: map[string]string{"payload": `{"pr":{"number":8,"branch":"agents/7-fix",` +
		`"url":"https://dev.azure.com/acme/Web%20App/_git/App/pullrequest/8","fixes":["#7"]}}`}})
	pr := wire.LineageNode{Kind: "pr", Ref: "azuredevops:acme/web app/app#8"}
	item := wire.LineageNode{Kind: "issue", Ref: "azureboards:acme/web app#7"}
	wantLinks(t, active(d, pr),
		s.Ref+" opens "+pr.Ref+" (branch)",
		pr.Ref+" fixes "+item.Ref+" (pr-body)")
	wantLinks(t, active(d, s),
		s.Ref+" works-on "+item.Ref+" (start)",
		s.Ref+" opens "+pr.Ref+" (branch)")
	if n, ok := d.labelNode(folder, "P#4"); !ok || n != (wire.LineageNode{Kind: "pr", Ref: "azuredevops:acme/web app/app#4"}) {
		t.Fatalf("P#4: %+v", n)
	}
	if _, _, ok := nodeOfRepo(pr); ok {
		t.Fatal("an Azure Repos node is asked of gh")
	}
	if r, n, ok := askedNode(pr); !ok || r != azureDevOpsRepo || n != 8 {
		t.Fatalf("not asked of Azure DevOps: %+v %d %v", r, n, ok)
	}

	// An Azure Pipelines build builds the pull request; its node says builds, not GitHub's actions.
	d.lineageCIEvent(wire.Event{Name: "checks.failed", Details: map[string]string{"payload": `{"pr":{"number":8,` +
		`"url":"https://dev.azure.com/acme/Web%20App/_git/App/pullrequest/8"},"run":{"id":12}}`}})
	settleMilestones(t, d)
	if !active(d, pr)["azuredevops:acme/web app/app/builds/12 builds "+pr.Ref+" (forge)"] {
		t.Errorf("the build: %v", active(d, pr))
	}

	// With no connection the folder is still on Azure DevOps, by its host.
	file.Delete(connections.AzureDevOps)
	if r := d.folderRepo(folder); r != azureDevOpsRepo {
		t.Fatalf("with no Azure DevOps connection: %+v", r)
	}
}

// #3952: lineage asks Azure DevOps, by its connection, for a pull request's title and state, a
// release's pull requests, and the cost comment. It asks no milestone: Azure Repos has none.
func TestLineageAsksAzureDevOps(t *testing.T) {
	d, _, ado, _ := azureDevOpsDaemon(t)
	repo := azureDevOpsRepo
	folder := azureDevOpsFolder(t, d)
	ctx := context.Background()

	pr := repo.pr(8)
	d.resolveNode(ctx, pr)
	if e := d.resolveCache[pr]; !e.ok || fmt.Sprintf("%s %s %v", e.resolved.Title, deref(e.resolved.State), e.resolved.Labels) != "Add a merged [ui]" {
		t.Errorf("%s resolved %+v", pr.Ref, e)
	}

	// A release: the merge title's "Merged PR 8:", another commit's pull request asked.
	if !d.linkRelease(ctx, folder, repo, "v0.2.0", "v0.1.0") {
		t.Fatal("the release is not done")
	}
	release := repo.release("v0.2.0")
	wantLinks(t, active(d, release),
		pr.Ref+" part-of "+release.Ref+" (forge)",
		"azuredevops:acme/web app/app#9 part-of "+release.Ref+" (forge)")

	asks, _ := d.connectionAsks("azuredevops")
	if id, err := asks.costComment(ctx, prCommentRecord{Folder: folder, Forge: "azuredevops", Path: repo.path, Number: 8}, "body"); err != nil || id != "77/1" {
		t.Fatalf("the cost comment: %q %v", id, err)
	}

	want := []string{"node acme/Web App/App#8", "time acme/Web App/App v0.2.0", "compare acme/Web App/App v0.1.0...v0.2.0",
		"pull of acme/Web App/App bbb", "cost acme/Web App/App#8 id= true"}
	if fmt.Sprint(ado.asked) != fmt.Sprint(want) {
		t.Errorf("Azure DevOps was asked\n%v\nwant\n%v", ado.asked, want)
	}
}

// #3952: an Azure Repos pull request's address on dev.azure.com, <org>.visualstudio.com and a
// Server of any name, and back.
func TestAzureReposAddresses(t *testing.T) {
	for raw, want := range map[string]string{
		"https://dev.azure.com/acme/Web%20App/_git/App/pullrequest/8":                      "azuredevops:acme/web app/app#8",
		"https://dev.azure.com/acme/Web%20App/_git/App/pullrequest/8?_a=files":             "azuredevops:acme/web app/app#8",
		"https://acme.visualstudio.com/Web%20App/_git/App/pullrequest/8":                   "azuredevops:acme/web app/app#8",
		"https://acme.visualstudio.com/DefaultCollection/Web%20App/_git/App/pullrequest/8": "azuredevops:acme/web app/app#8",
		"https://dev.azure.com/acme/_git/App/pullrequest/8":                                "azuredevops:acme/app/app#8",
		"https://tfs.example/tfs/Main/Web/_git/App/pullrequest/8":                          "azuredevops:main/web/app#8",
		"https://ado.example/Main/Web/_git/App/pullrequest/8":                              "azuredevops:main/web/app#8",
		"https://dev.azure.com/acme/Web/pullrequest/8":                                     "",
		"https://example.com/a/pullrequest/8":                                              "",
	} {
		repo, n, ok := prOfURL(raw)
		got := ""
		if ok {
			got = repo.pr(n).Ref
		}
		if got != want {
			t.Errorf("%s: %q, want %q", raw, got, want)
		}
	}
	for host, path := range map[string]string{"dev.azure.com": "acme/Web App/_git/App", "ssh.dev.azure.com": "v3/acme/Web App/App",
		"acme.visualstudio.com": "Web App/_git/App.git"} {
		if r := forgeOf(host, path); r != azureDevOpsRepo {
			t.Errorf("the remote %s:%s is %+v", host, path, r)
		}
	}
	if u := refURL(azureDevOpsRepo.pr(8), ""); u != "https://dev.azure.com/acme/web%20app/_git/app/pullrequest/8" {
		t.Errorf("the pull request's address: %s", u)
	}
	if u := refURL(azureDevOpsRepo.pr(8), "https://ado.example"); u != "https://ado.example/acme/web%20app/_git/app/pullrequest/8" {
		t.Errorf("the pull request's address on a Server: %s", u)
	}
	if u := docURL(azureDevOpsRepo.doc("docs/a b.md").Ref, ""); u != "https://dev.azure.com/acme/web%20app/_git/app?path=%2Fdocs%2Fa+b.md" {
		t.Errorf("a doc's address: %s", u)
	}
}

// #3952: an Azure Boards view of a work item lists the Azure Repos pull requests that fix it,
// each with its address on Azure DevOps.
func TestAnAzureBoardsViewListsItsAzureReposPullRequests(t *testing.T) {
	d, _, _, _ := azureDevOpsDaemon(t)
	folder := azureDevOpsFolder(t, d)
	a := seeded(t, d, folder, func(a *wire.Agent) {
		title := "Fix the walk"
		a.Title = &title
		a.Labels = []wire.SessionLabel{{Value: "#7", Owner: wire.SessionLabelOwnerPerson}}
	})
	d.noteLineage(nil, a)
	d.lineageEvent(wire.Event{Name: "pr.opened", Details: map[string]string{"payload": `{"pr":{"number":8,"branch":"b",` +
		`"title":"Fix it","url":"https://dev.azure.com/acme/Web%20App/_git/App/pullrequest/8","fixes":["#7"]}}`}})

	boards := viewServer{name: "azureboards", filled: sdk.McpServer{Stdio: &sdk.McpServerStdio{Name: "azureboards", Command: "azureboards-mcp"}}}
	raw, err := d.lineageViewResult(boards, json.RawMessage(`{"url":"https://dev.azure.com/acme/Web%20App/_workitems/edit/7"}`))
	if err != nil {
		t.Fatal(err)
	}
	var r struct {
		StructuredContent lineageView `json:"structuredContent"`
		IsError           bool        `json:"isError"`
	}
	if json.Unmarshal(raw, &r) != nil || r.IsError {
		t.Fatalf("the work item's: %s", raw)
	}
	v := r.StructuredContent
	if v.Ref != "azureboards:acme/web app#7" || len(v.Sessions) != 1 || v.Sessions[0].Title != "Fix the walk" {
		t.Errorf("the work item's: %+v", v)
	}
	if len(v.PRs) != 1 || v.PRs[0].URL != "https://dev.azure.com/acme/web%20app/_git/app/pullrequest/8" {
		t.Errorf("the work item's pull requests: %+v", v.PRs)
	}
}

// #4098: the azuredevops server's pull request page asks for lineage by its address: the
// sessions on the pull request.
func TestTheAzureDevOpsServersViewsAskForLineage(t *testing.T) {
	d, _, _, _ := azureDevOpsDaemon(t)
	folder := azureDevOpsFolder(t, d)
	a := seeded(t, d, folder, func(a *wire.Agent) {
		title := "Fix the walk"
		a.Title = &title
		a.Labels = []wire.SessionLabel{{Value: "P#8", Owner: wire.SessionLabelOwnerPerson}}
	})
	d.noteLineage(nil, a)

	ado := viewServer{name: "azuredevops", filled: sdk.McpServer{Stdio: &sdk.McpServerStdio{Name: "azuredevops", Command: "azuredevops-mcp"}}}
	raw, err := d.lineageViewResult(ado, json.RawMessage(`{"url":"https://dev.azure.com/acme/Web%20App/_git/App/pullrequest/8"}`))
	if err != nil {
		t.Fatal(err)
	}
	var r struct {
		StructuredContent lineageView `json:"structuredContent"`
		IsError           bool        `json:"isError"`
	}
	if json.Unmarshal(raw, &r) != nil || r.IsError {
		t.Fatalf("the pull request's: %s", raw)
	}
	v := r.StructuredContent
	if v.Ref != "azuredevops:acme/web app/app#8" || len(v.Sessions) != 1 || v.Sessions[0].Title != "Fix the walk" {
		t.Errorf("the pull request's: %+v", v)
	}
}
