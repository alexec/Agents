package agentsd

import (
	"context"
	"encoding/json"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/connections"
	"github.com/alexec/agents/Go/internal/githubmcp"
	"github.com/alexec/agents/Go/wire"
)

// fakeForgeGitHub is GitHub's search and item reads, and what each was asked.
type fakeForgeGitHub struct {
	mu       sync.Mutex
	searches []string
	items    int
}

func (f *fakeForgeGitHub) Search(_ context.Context, repos []string, sf githubmcp.SearchFilter, after string, first int) (githubmcp.SearchPage, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.searches = append(f.searches, strings.Join(repos, ",")+" "+githubmcp.SearchQuery(repos, sf)+" after="+after)
	if after != "" {
		return githubmcp.SearchPage{Items: []githubmcp.Item{{Repo: "alexec/web", Number: 2, PR: sf.PRs, State: "open", Title: "Older"}}}, nil
	}
	return githubmcp.SearchPage{Next: "Y3Vyc29y", Items: []githubmcp.Item{
		{Repo: "alexec/agents", Number: 12, PR: sf.PRs, State: "merged", Title: "Forge reads", URL: "https://github.com/alexec/agents/pull/12",
			Author: "alexec", Labels: []string{"enhancement", "odd"}, LabelColors: map[string]string{"enhancement": "#a2eeef"},
			Assignees: []string{"alexec"}, Milestone: "0.16", UpdatedAt: "2026-11-01T10:00:00Z", Comments: 3,
			Draft: true, Checks: "passing", Review: "approved", Mergeable: "mergeable", AutoMerge: true},
	}}, nil
}

func (f *fakeForgeGitHub) ItemPage(_ context.Context, repo string, number int, before string) (githubmcp.ItemDetail, error) {
	f.mu.Lock()
	f.items++
	f.mu.Unlock()
	if number == 404 {
		return githubmcp.ItemDetail{}, &githubmcp.GitHubError{Kind: githubmcp.NotFound, Message: "not found on GitHub"}
	}
	return githubmcp.ItemDetail{
		Item: githubmcp.Item{Repo: repo, Number: number, PR: number == 12, State: "open", Title: "Forge reads", UpdatedAt: "2026-11-01T10:00:00Z"},
		Body: "The body.", Before: "b2xkZXI=",
		Thread:        []githubmcp.Comment{{Author: "coderabbitai", Body: "Looks fine.", At: "2026-11-01T10:05:00Z", URL: "u1", Bot: true}},
		CheckRuns:     []githubmcp.Check{{Name: "test", State: "failing", URL: "https://github.com/alexec/agents/actions/runs/1"}},
		ReviewThreads: 2, FilesChanged: 5,
	}, nil
}

func (f *fakeForgeGitHub) asked() ([]string, int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return slices.Clone(f.searches), f.items
}

// forgeDaemon is a daemon with three folders, two of them on one repo, and a GitHub connection
// as a fake GitHub.
func forgeDaemon(t *testing.T) (*Daemon, *conn, *fakeForgeGitHub, *connections.File) {
	t.Helper()
	t.Setenv("AGENTS_PERSONAL_HOME", t.TempDir())
	d, c := start(t, t.TempDir())
	t.Cleanup(d.Shutdown)
	file := &connections.File{Path: filepath.Join(t.TempDir(), ".agents-secrets", connections.FileName)}
	d.connStoreFor = func() (connections.Store, error) { return file, nil }
	gh := &fakeForgeGitHub{}
	d.newForgeGitHub = func(token string) forgeGitHub {
		if token != "ghu_secret" {
			t.Errorf("token %q", token)
		}
		return gh
	}
	for i, remote := range []string{"git@github.com:alexec/agents.git", "https://github.com/alexec/agents", "git@github.com:alexec/web.git"} {
		c.call(t, 100+i, "folders/add", map[string]any{"folder": "file://" + gitFolder(t, remote)})
	}
	file.Put(connections.Connection{Provider: connections.GitHub, Login: "alexec", Access: "ghu_secret",
		AccessExpiresAt: time.Now().Add(time.Hour), ConnectedAt: time.Now()})
	return d, c, gh, file
}

// #3129: forge/pulls lists the pull requests of every repo the folders are on in one search,
// each repo once, in the one model; the next page goes on from the cursor; the same list again
// within forgeCacheFor asks GitHub nothing; and what a list read is in the lineage cache.
func TestForgePullsListsEveryRepoInOneSearch(t *testing.T) {
	d, c, gh, _ := forgeDaemon(t)
	var list wire.ForgeList
	json.Unmarshal(c.call(t, 1, "forge/pulls", wire.ForgeListRequest{Label: new("enhancement")}), &list)
	searches, _ := gh.asked()
	if len(searches) != 1 || !strings.HasPrefix(searches[0], "alexec/agents,alexec/web is:pr is:open repo:alexec/agents repo:alexec/web label:\"enhancement\"") {
		t.Fatalf("searches: %q", searches)
	}
	if len(list.Items) != 1 || list.Cursor == nil || len(list.Errors) != 0 {
		t.Fatalf("list: %+v", list)
	}
	i := list.Items[0]
	if i.Node != (wire.LineageNode{Kind: "pr", Ref: "github:alexec/agents#12"}) || i.State != "merged" || i.Title != "Forge reads" ||
		deref(i.Folder) == "" || deref(i.Author) != "alexec" || deref(i.Milestone) != "0.16" || i.Comments != 3 ||
		len(i.Assignees) != 1 || i.UpdatedAt.Time().UTC().Format(time.RFC3339) != "2026-11-01T10:00:00Z" {
		t.Fatalf("item: %+v", i)
	}
	if len(i.Labels) != 2 || deref(i.Labels[0].Color) != "#a2eeef" || i.Labels[1].Color != nil {
		t.Fatalf("labels: %+v", i.Labels)
	}
	if !*i.Draft || !*i.AutoMerge || *i.Checks != "passing" || *i.Review != "approved" || *i.Mergeable != "mergeable" {
		t.Fatalf("pull request fields: %+v", i)
	}
	if !slices.Contains(d.folderPaths(), *i.Folder) || d.folderRepo(*i.Folder) != (forgeRepo{"github", "alexec/agents"}) {
		t.Fatalf("folder %q is not on alexec/agents", *i.Folder)
	}

	json.Unmarshal(c.call(t, 2, "forge/pulls", wire.ForgeListRequest{Label: new("enhancement")}), &list)
	if searches, _ = gh.asked(); len(searches) != 1 {
		t.Fatalf("the same list within a minute asked again: %q", searches)
	}

	var next wire.ForgeList
	json.Unmarshal(c.call(t, 3, "forge/pulls", wire.ForgeListRequest{Label: new("enhancement"), Cursor: list.Cursor}), &next)
	if searches, _ = gh.asked(); len(searches) != 2 || !strings.HasSuffix(searches[1], "after=Y3Vyc29y") {
		t.Fatalf("next page: %q", searches)
	}
	if len(next.Items) != 1 || next.Items[0].Title != "Older" || next.Cursor != nil {
		t.Fatalf("next page: %+v", next)
	}

	d.resolveMu.Lock()
	e := d.resolveCache[i.Node]
	d.resolveMu.Unlock()
	if !e.ok || e.resolved.Title != "Forge reads" || deref(e.resolved.State) != "merged" || len(e.resolved.Labels) != 2 {
		t.Fatalf("lineage cache: %+v", e)
	}
}

// One folder's list is its repo's only; issues are is:issue and state all has no state.
func TestForgeIssuesOfOneFolder(t *testing.T) {
	d, c, gh, _ := forgeDaemon(t)
	var web string
	for _, f := range d.folderPaths() {
		if d.folderRepo(f).path == "alexec/web" {
			web = f
		}
	}
	c.call(t, 1, "forge/issues", wire.ForgeListRequest{Folder: &web, State: new("all"), Assignee: new("alexec"), Query: new("flaky test")})
	searches, _ := gh.asked()
	if len(searches) != 1 || !strings.HasPrefix(searches[0], "alexec/web is:issue repo:alexec/web assignee:alexec flaky test sort:updated-desc") {
		t.Fatalf("searches: %q", searches)
	}
}

// With no GitHub connection the list still answers, empty, and says why; nothing is kept, so
// the next ask after connecting reads GitHub.
func TestForgeListSaysGitHubIsNotConnected(t *testing.T) {
	_, c, gh, file := forgeDaemon(t)
	file.Delete(connections.GitHub)
	var list wire.ForgeList
	json.Unmarshal(c.call(t, 1, "forge/issues", wire.ForgeListRequest{}), &list)
	if len(list.Items) != 0 || len(list.Errors) != 1 || list.Errors[0].Forge != "github" || list.Errors[0].Message != githubmcp.NotConnected {
		t.Fatalf("list: %+v", list)
	}
	file.Put(connections.Connection{Provider: connections.GitHub, Access: "ghu_secret", ConnectedAt: time.Now()})
	var connected wire.ForgeList
	json.Unmarshal(c.call(t, 2, "forge/issues", wire.ForgeListRequest{}), &connected)
	if searches, _ := gh.asked(); len(searches) != 1 || len(connected.Errors) != 0 || len(connected.Items) != 1 {
		t.Fatalf("after connecting: %q %+v", searches, connected)
	}
}

// What a list refuses: a limit over 100, a state it does not know, a cursor it did not give,
// a folder not on this machine.
func TestForgeListRefusals(t *testing.T) {
	_, c, _, _ := forgeDaemon(t)
	for i, r := range []wire.ForgeListRequest{{Limit: new(int64(101))}, {Limit: new(int64(0))}, {State: new("merged")},
		{Cursor: new("not a cursor")}, {Folder: new("/no/such/folder")}} {
		if e := c.callError(t, i+1, "forge/pulls", r); e == nil || !strings.Contains(e.Message, "forge/pulls") {
			t.Fatalf("%+v: %v", r, e)
		}
	}
}

// #3129: forge/pull is one pull request with its body, a page of comments and its cursor, its
// checks, review threads and files; forge/issue on a pull request's number, an issue node to
// forge/pull, a GitLab node and an item GitHub does not have are refused.
func TestForgePullReadsOne(t *testing.T) {
	_, c, gh, _ := forgeDaemon(t)
	pr := wire.LineageNode{Kind: "pr", Ref: "github:alexec/agents#12"}
	var p wire.ForgeItemDetail
	json.Unmarshal(c.call(t, 1, "forge/pull", wire.ForgeItemRequest{Node: pr}), &p)
	if p.Item.Node != pr || p.Body != "The body." || deref(p.Cursor) != "b2xkZXI=" || deref(p.Item.Folder) == "" {
		t.Fatalf("pull: %+v", p)
	}
	if len(p.Comments) != 1 || p.Comments[0].Author != "coderabbitai" || p.Comments[0].Bot == nil || !*p.Comments[0].Bot ||
		p.Comments[0].At == 0 || deref(p.Comments[0].URL) != "u1" {
		t.Fatalf("comments: %+v", p.Comments)
	}
	if len(p.Checks) != 1 || p.Checks[0].State != "failing" || *p.ReviewThreads != 2 || *p.FilesChanged != 5 {
		t.Fatalf("checks: %+v", p)
	}
	c.call(t, 2, "forge/pull", wire.ForgeItemRequest{Node: pr})
	if _, items := gh.asked(); items != 1 {
		t.Fatalf("the same pull within a minute asked %d times", items)
	}
	for i, ask := range []struct {
		method string
		node   wire.LineageNode
	}{
		{"forge/issue", wire.LineageNode{Kind: "issue", Ref: "github:alexec/agents#12"}},
		{"forge/pull", wire.LineageNode{Kind: "issue", Ref: "github:alexec/agents#13"}},
		{"forge/pull", wire.LineageNode{Kind: "pr", Ref: "gitlab:group/project!4"}},
		{"forge/pull", wire.LineageNode{Kind: "pr", Ref: "github:alexec/agents#404"}},
		{"forge/issue", wire.LineageNode{Kind: "issue", Ref: "linear:ENG-4"}},
	} {
		if e := c.callError(t, 10+i, ask.method, wire.ForgeItemRequest{Node: ask.node}); e == nil || !strings.Contains(e.Message, ask.method) {
			t.Fatalf("%s %s: %v", ask.method, ask.node.Ref, e)
		}
	}
}
