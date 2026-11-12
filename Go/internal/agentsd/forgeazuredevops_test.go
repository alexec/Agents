package agentsd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/azuredevopsmcp"
	"github.com/alexec/agents/Go/internal/connections"
	"github.com/alexec/agents/Go/wire"
)

// fakeForgeAzureDevOps is Azure DevOps's lists, pull request reads and writes, and what each
// was asked.
type fakeForgeAzureDevOps struct {
	mu       sync.Mutex
	searches []string
	items    []string
	wrote    []string
	asked    []string
}

func (f *fakeForgeAzureDevOps) note(to *[]string, s string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	*to = append(*to, s)
}

func (f *fakeForgeAzureDevOps) Search(_ context.Context, repos []string, sf azuredevopsmcp.SearchFilter, after string, first int) (azuredevopsmcp.SearchPage, error) {
	f.note(&f.searches, fmt.Sprintf("%v state=%s label=%s after=%s first=%d", repos, sf.State, sf.Label, after, first))
	page := azuredevopsmcp.SearchPage{}
	for _, repo := range repos {
		page.Items = append(page.Items, azuredevopsmcp.Item{Repo: repo, Number: 3, State: "open", Title: "On " + repo,
			URL: "https://dev.azure.com/acme/Web%20App/_git/App/pullrequest/3", Author: "kim@example.com",
			UpdatedAt: "2026-11-07T10:00:00.1234567Z", Labels: []string{"ui"}, Review: "approved", Mergeable: "mergeable"})
		page.Cursors = append(page.Cursors, "c"+repo)
	}
	return page, nil
}

func (f *fakeForgeAzureDevOps) ItemPage(_ context.Context, repo string, number int, before string) (azuredevopsmcp.ItemDetail, error) {
	f.note(&f.items, fmt.Sprintf("%s#%d before=%s", repo, number, before))
	if number == 404 {
		return azuredevopsmcp.ItemDetail{}, &azuredevopsmcp.AzureDevOpsError{Kind: azuredevopsmcp.NotFound, Message: "not found on Azure DevOps"}
	}
	return azuredevopsmcp.ItemDetail{Item: azuredevopsmcp.Item{Repo: repo, Number: number, State: "open", Title: "Export", AutoMerge: true,
		URL: "https://dev.azure.com/acme/Web%20App/_git/App/pullrequest/3", UpdatedAt: "2026-11-07T10:00:00Z", Checks: "failing",
		Review: "review_required", Mergeable: "mergeable"},
		Body: "The body.", Thread: []azuredevopsmcp.Comment{{Author: "renovate-bot", Body: "Hi", At: "2026-11-07T09:00:00Z", Bot: true}}, Before: "4",
		CheckRuns: []azuredevopsmcp.CheckRun{
			{Name: "ci", State: "failing", URL: "https://dev.azure.com/b/70", Build: 70},
			{Name: "ci again", State: "failing", URL: "https://dev.azure.com/b/70", Build: 70},
			{Name: "scan/secrets", State: "failing", URL: "https://scan.example/1"},
			{Name: "lint", State: "passing", Build: 71},
		},
		Head: "abc123", FilesChanged: 2, ReviewThreads: 1}, nil
}

func (f *fakeForgeAzureDevOps) Comment(_ context.Context, repo string, number int, body string) (string, error) {
	f.note(&f.wrote, fmt.Sprintf("comment %s#%d %s", repo, number, body))
	return "https://dev.azure.com/c/1", nil
}

func (f *fakeForgeAzureDevOps) SetLabels(_ context.Context, repo string, number int, add, remove []string) error {
	f.note(&f.wrote, fmt.Sprintf("labels %s#%d +%v -%v", repo, number, add, remove))
	return nil
}

func (f *fakeForgeAzureDevOps) SetState(_ context.Context, repo string, number int, closed bool) error {
	f.note(&f.wrote, fmt.Sprintf("state %s#%d closed=%v", repo, number, closed))
	return nil
}

func (f *fakeForgeAzureDevOps) RepoLabels(context.Context, string) ([]string, error) {
	return []string{"docs", "ui"}, nil
}

func (f *fakeForgeAzureDevOps) MergeMethods(context.Context, string, int) ([]string, error) {
	return []string{"squash", "rebase"}, nil
}

func (f *fakeForgeAzureDevOps) Merge(_ context.Context, repo string, number int, sha, method string, auto bool) error {
	f.note(&f.wrote, fmt.Sprintf("merge %s#%d %s %s auto=%v", repo, number, sha, method, auto))
	return nil
}

func (f *fakeForgeAzureDevOps) CancelAutoMerge(_ context.Context, repo string, number int) error {
	f.note(&f.wrote, fmt.Sprintf("auto-merge off %s#%d", repo, number))
	return nil
}

func (f *fakeForgeAzureDevOps) MarkReady(_ context.Context, repo string, number int) error {
	f.note(&f.wrote, fmt.Sprintf("ready %s#%d", repo, number))
	return nil
}

func (f *fakeForgeAzureDevOps) Approve(_ context.Context, repo string, number int, sha string) (string, error) {
	f.note(&f.wrote, fmt.Sprintf("approve %s#%d %s", repo, number, sha))
	return "https://dev.azure.com/acme/Web%20App/_git/App/pullrequest/3", nil
}

func (f *fakeForgeAzureDevOps) PRDiff(context.Context, string, int) (map[string]any, error) {
	return map[string]any{"files": []any{map[string]any{"path": "hello.txt", "change": "added", "additions": 1, "deletions": 0,
		"hunks": []any{map[string]any{"oldStart": 1, "newStart": 1, "lines": []any{map[string]any{"kind": "added", "text": "hello"}}}}}}}, nil
}

func (f *fakeForgeAzureDevOps) RetryBuild(_ context.Context, repo string, build int) (string, error) {
	f.note(&f.wrote, fmt.Sprintf("retry %s %d", repo, build))
	return fmt.Sprintf("https://dev.azure.com/b/%d", build), nil
}

func (f *fakeForgeAzureDevOps) FailedLog(_ context.Context, repo string, build int) (string, error) {
	return fmt.Sprintf("log of %s %d", repo, build), nil
}

// azureDevOpsDaemon is a daemon with a folder on Azure DevOps and one on GitHub, with an
// Azure DevOps connection to dev.azure.com as a fake Azure DevOps.
func azureDevOpsDaemon(t *testing.T) (*Daemon, *conn, *fakeForgeAzureDevOps, *connections.File) {
	t.Helper()
	t.Setenv("AGENTS_PERSONAL_HOME", t.TempDir())
	d, c := start(t, t.TempDir())
	t.Cleanup(d.Shutdown)
	file := &connections.File{Path: filepath.Join(t.TempDir(), ".agents-secrets", connections.FileName)}
	d.connStoreFor = func() (connections.Store, error) { return file, nil }
	ado := &fakeForgeAzureDevOps{}
	d.newForgeAzureDevOps = func(root, token string) forgeAzureDevOps {
		if root != azuredevopsmcp.DefaultBase || token != "ado-secret" {
			t.Errorf("Azure DevOps at %q with %q", root, token)
		}
		return ado
	}
	d.newForgeGitHub = func(string) forgeGitHub { return &fakeForgeGitHub{} }
	for i, remote := range []string{"https://acme@dev.azure.com/acme/Web%20App/_git/App", "git@github.com:alexec/agents.git"} {
		c.call(t, 100+i, "folders/add", map[string]any{"folder": "file://" + gitFolder(t, remote)})
	}
	file.Put(connections.AzureDevOpsConnection(connections.AzureDevOpsServices, "acme", "ado-secret", "Agents Test", time.Now()))
	file.Put(connections.Connection{Provider: connections.GitHub, Login: "alexec", Access: "ghu_secret",
		AccessExpiresAt: time.Now().Add(time.Hour), ConnectedAt: time.Now()})
	return d, c, ado, file
}

// #3803: forge/pulls lists the repositories on Azure DevOps with the GitHub folder's;
// forge/issues does not ask Azure Repos, whose issues are Azure Boards' work items.
func TestForgeListsAzureDevOpsPullRequests(t *testing.T) {
	_, c, ado, _ := azureDevOpsDaemon(t)
	var pulls wire.ForgeList
	json.Unmarshal(c.call(t, 1, "forge/pulls", wire.ForgeListRequest{Label: new("ui")}), &pulls)
	if len(ado.searches) != 1 || ado.searches[0] != "[acme/Web App/App] state= label=ui after= first=50" {
		t.Fatalf("Azure DevOps was asked %v", ado.searches)
	}
	var item *wire.ForgeItem
	for _, i := range pulls.Items {
		if strings.HasPrefix(i.Node.Ref, "azuredevops:") {
			item = &i
		}
	}
	if item == nil || item.Node != (wire.LineageNode{Kind: "pr", Ref: "azuredevops:pr:acme/web app/app#3"}) || deref(item.Folder) == "" ||
		item.Labels[0].Name != "ui" || item.UpdatedAt == 0 || deref(item.Review) != "approved" || deref(item.Mergeable) != "mergeable" ||
		item.AutoMerge == nil || *item.AutoMerge || len(item.Assignees) != 0 || len(pulls.Errors) != 0 {
		t.Fatalf("the Azure DevOps pull request: %+v in %+v", item, pulls)
	}
	var issues wire.ForgeList
	json.Unmarshal(c.call(t, 2, "forge/issues", wire.ForgeListRequest{}), &issues)
	if len(ado.searches) != 1 {
		t.Fatalf("issues asked Azure Repos: %v", ado.searches)
	}
}

// Without a token for its Azure DevOps the list says so for Azure DevOps, and still lists GitHub's.
func TestForgeListSaysAzureDevOpsIsNotConnected(t *testing.T) {
	_, c, ado, file := azureDevOpsDaemon(t)
	file.Delete(connections.AzureDevOps)
	var list wire.ForgeList
	json.Unmarshal(c.call(t, 1, "forge/pulls", wire.ForgeListRequest{}), &list)
	if len(ado.searches) != 0 || len(list.Errors) != 1 || list.Errors[0].Forge != "azuredevops" || list.Errors[0].Message != azuredevopsmcp.NotConnected {
		t.Fatalf("list: %+v", list)
	}
}

// forge/pull reads an Azure Repos pull request in the repository as its folder's remote says
// it; one Azure DevOps does not have, or no folder is on, is refused.
func TestForgeReadsAnAzureDevOpsPullRequest(t *testing.T) {
	_, c, ado, _ := azureDevOpsDaemon(t)
	var pr wire.ForgeItemDetail
	json.Unmarshal(c.call(t, 1, "forge/pull", wire.ForgeItemRequest{Node: wire.LineageNode{Kind: "pr", Ref: "azuredevops:pr:acme/web app/app#3"}}), &pr)
	if pr.Body != "The body." || deref(pr.Cursor) != "4" || len(pr.Comments) != 1 || pr.Comments[0].Bot == nil || deref(pr.Head) != "abc123" ||
		len(pr.Checks) != 4 || *pr.FilesChanged != 2 || *pr.ReviewThreads != 1 || len(pr.MergeMethods) != 2 || pr.MergeMethods[0] != "squash" ||
		deref(pr.Item.Checks) != "failing" || pr.Item.AutoMerge == nil || !*pr.Item.AutoMerge || pr.Start != nil {
		t.Fatalf("pull: %+v", pr)
	}
	if ado.items[0] != "acme/Web App/App#3 before=" {
		t.Fatalf("Azure DevOps was asked %v", ado.items)
	}
	for i, n := range []wire.LineageNode{
		{Kind: "pr", Ref: "azuredevops:pr:acme/web app/app#404"},
		{Kind: "pr", Ref: "azuredevops:pr:kim/notes/notes#1"},
		{Kind: "pr", Ref: "azuredevops:pr:acme/app#1"},
	} {
		if e := c.callError(t, 10+i, "forge/pull", wire.ForgeItemRequest{Node: n}); e == nil || !strings.Contains(e.Message, "forge/pull") {
			t.Fatalf("%s: %v", n.Ref, e)
		}
	}
}

// The Work pages' writes on an Azure Repos pull request go to Azure DevOps; a merge takes the
// branch's first method, or completes on its own with auto; rerun runs each failed build once.
func TestForgeWritesOnAnAzureDevOpsPullRequest(t *testing.T) {
	_, c, ado, _ := azureDevOpsDaemon(t)
	pr := wire.LineageNode{Kind: "pr", Ref: "azuredevops:pr:acme/web app/app#3"}
	var done wire.ForgeDone
	json.Unmarshal(c.call(t, 1, "forge/comment", wire.ForgeCommentRequest{Node: pr, Body: "LGTM"}), &done)
	if deref(done.URL) != "https://dev.azure.com/c/1" {
		t.Fatalf("comment: %+v", done)
	}
	c.call(t, 2, "forge/label", wire.ForgeLabelRequest{Node: pr, Add: []string{"docs"}, Remove: []string{"ui"}})
	c.call(t, 3, "forge/close", wire.ForgeCloseRequest{Node: pr})
	c.call(t, 4, "forge/merge", wire.ForgeMergeRequest{Node: pr, Sha: "abc123"})
	var auto wire.ForgeDone
	json.Unmarshal(c.call(t, 5, "forge/merge", wire.ForgeMergeRequest{Node: pr, Sha: "abc123", Method: new(wire.ForgeMergeMethodRebase), Auto: new(true)}), &auto)
	if auto.Auto == nil || !*auto.Auto {
		t.Fatalf("auto: %+v", auto)
	}
	c.call(t, 6, "forge/approve", wire.ForgeApproveRequest{Node: pr, Sha: "abc123"})
	var rerun wire.ForgeDone
	json.Unmarshal(c.call(t, 7, "forge/rerun", wire.ForgeNodeRequest{Node: pr}), &rerun)
	want := []string{"comment acme/Web App/App#3 LGTM", "labels acme/Web App/App#3 +[docs] -[ui]", "state acme/Web App/App#3 closed=true",
		"merge acme/Web App/App#3 abc123 squash auto=false", "merge acme/Web App/App#3 abc123 rebase auto=true",
		"approve acme/Web App/App#3 abc123", "retry acme/Web App/App 70"}
	if strings.Join(ado.wrote, "\n") != strings.Join(want, "\n") {
		t.Fatalf("wrote %q", ado.wrote)
	}
	if rerun.Reran == nil || *rerun.Reran != 1 || deref(rerun.URL) != "https://dev.azure.com/b/70" {
		t.Fatalf("rerun: %+v", rerun)
	}
	if e := c.callError(t, 8, "forge/merge", wire.ForgeMergeRequest{Node: pr, Sha: "abc123", Method: new(wire.ForgeMergeMethodMerge)}); e == nil ||
		!strings.Contains(e.Message, "squash or rebase") {
		t.Fatalf("a method the branch does not allow: %v", e)
	}
	var log wire.ForgeLog
	json.Unmarshal(c.call(t, 9, "forge/log", wire.ForgeLogRequest{Node: pr}), &log)
	if log.Text != "log of acme/Web App/App 70" {
		t.Fatalf("log: %+v", log)
	}
	json.Unmarshal(c.call(t, 10, "forge/log", wire.ForgeLogRequest{Node: pr, Check: new("scan/secrets")}), &log)
	if !strings.Contains(log.Text, "scan/secrets is not an Azure Pipelines build") {
		t.Fatalf("another service's log: %+v", log)
	}
	var labels wire.ForgeLabels
	json.Unmarshal(c.call(t, 11, "forge/labels", wire.ForgeNodeRequest{Node: pr}), &labels)
	if len(labels.Labels) != 2 || labels.Labels[1].Name != "ui" {
		t.Fatalf("labels: %+v", labels)
	}
	var diff wire.ForgeDiff
	json.Unmarshal(c.call(t, 12, "forge/diff", wire.ForgeNodeRequest{Node: pr}), &diff)
	if len(diff.Files) != 1 || diff.Files[0].Path != "hello.txt" || len(diff.Files[0].Hunks[0].Lines) != 1 {
		t.Fatalf("diff: %+v", diff)
	}
}

func TestAzureDevOpsOfNode(t *testing.T) {
	for ref, want := range map[string]string{
		"azuredevops:pr:acme/web app/app#3": "acme/web app/app 3",
		"azuredevops:pr:a/b/c#0":            "",
		"azuredevops:pr:a/b#1":              "",
		"azuredevops:pr:a/b/c/d#1":          "",
		"azuredevops:pr:a//c#1":             "",
		"bitbucket:issue:a/b#1":             "",
	} {
		repo, n, ok := azureDevOpsOfNode(wire.LineageNode{Kind: "pr", Ref: ref})
		got := ""
		if ok {
			got = fmt.Sprintf("%s %d", repo, n)
		}
		if got != want {
			t.Errorf("%s: %q, want %q", ref, got, want)
		}
	}
	if _, _, ok := azureDevOpsOfNode(wire.LineageNode{Kind: "issue", Ref: "azuredevops:pr:a/b/c#1"}); ok {
		t.Error("an issue on Azure Repos")
	}
}

// #4055: a Pull requests list narrowed to a board lists Azure Repos pull requests only for an
// Azure DevOps board, and then only the repositories of its project, on its Azure DevOps.
func TestABoardNarrowsAzureReposToItsProject(t *testing.T) {
	d, _, ado, _ := azureDevOpsDaemon(t)
	scope := azureDevOpsScope{root: azuredevopsmcp.DefaultBase, repos: []string{"Acme/Web/app", "acme/web/site", "acme/Ops/infra"},
		folderOf: map[string]string{}}
	list := func(b wire.ProjectBoard, prs bool) (forgePage, error) {
		ado.searches = nil
		board := narrowToBoard(b, []string{"/f"}, prs)
		return azureDevOpsForge{d: d}.List(context.Background(), scope, forgeFilter{PRs: prs, Board: board}, "", 10)
	}
	if p, err := list(wire.ProjectBoard{Forge: new(wire.ConnectionProviderGithub), Key: new("alexec/1")}, true); err != nil || len(p.items) > 0 || len(ado.searches) > 0 {
		t.Fatalf("a GitHub board: %+v, %v, searched %v", p, err, ado.searches)
	}
	azure := wire.ProjectBoard{Forge: new(wire.ConnectionProviderAzuredevops), Key: new("acme/web/Web Team"), Site: new("dev.azure.com")}
	if p, err := list(azure, true); err != nil || len(p.items) != 2 || len(ado.searches) != 1 || !strings.HasPrefix(ado.searches[0], "[Acme/Web/app acme/web/site] ") {
		t.Fatalf("an Azure DevOps board: %+v, %v, searched %v", p, err, ado.searches)
	}
	elsewhere := wire.ProjectBoard{Forge: new(wire.ConnectionProviderAzuredevops), Key: new("acme/web/Web Team"), Site: new("ado.example.com")}
	if p, err := list(elsewhere, true); err != nil || len(p.items) > 0 || len(ado.searches) > 0 {
		t.Fatalf("a board on another Azure DevOps: %+v, %v, searched %v", p, err, ado.searches)
	}
	if p, err := list(azure, false); err != nil || len(p.items) > 0 || len(ado.searches) > 0 {
		t.Fatalf("an Issues list: %+v, %v, searched %v", p, err, ado.searches)
	}
	// With no token for the folders' Azure DevOps, a board's list still says so.
	scope = azureDevOpsScope{unsigned: errors.New(azuredevopsmcp.NotConnected)}
	if scope.Empty() {
		t.Fatal("a scope with no token is empty, so the list says nothing")
	}
	if _, err := list(azure, true); err == nil || err.Error() != azuredevopsmcp.NotConnected {
		t.Fatalf("no token: %v", err)
	}
}
