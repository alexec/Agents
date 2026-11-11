package agentsd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/azureboardsmcp"
	"github.com/alexec/agents/Go/internal/azuredevopsmcp"
	"github.com/alexec/agents/Go/internal/bitbucketmcp"
	"github.com/alexec/agents/Go/internal/connections"
	"github.com/alexec/agents/Go/internal/forgejomcp"
	"github.com/alexec/agents/Go/internal/githubmcp"
	"github.com/alexec/agents/Go/internal/gitlabmcp"
	"github.com/alexec/agents/Go/internal/jiramcp"
	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/internal/linearmcp"
	"github.com/alexec/agents/Go/wire"
)

// The conformance test (#4329, #4352): one row for each forge on the interface, each with its
// fake and fixed data (an open issue, a closed issue, an open pull request and a merged one, each
// where the forge has them), and the same checks on every row. A new forge gets its row and
// passes it before it gets its own tests.
//
// ForgeList.forges and ForgeItemDetail.actions are checked here since #4361, authorAvatar since
// #4363, stateReason since #4365, createdAt, closedAt and an issue's children, linkedPulls and
// events since #4373, ForgeList.total since #4396, the comment count by commentCount since
// #4364, and a pull request's branches, merge, size, reviewers, closing issues and check times
// since #4409.

type conformRow struct {
	name string
	// daemon is a daemon with the forge's fake and its fixed data, and a client on it.
	daemon func(t *testing.T) (*Daemon, *conn)
}

var conformRows = []conformRow{
	{name: "github", daemon: conformGitHubDaemon},
	{name: "gitlab", daemon: conformGitLabDaemon},
	{name: "forgejo", daemon: conformForgejoDaemon},
	{name: "bitbucket", daemon: conformBitbucketDaemon},
	{name: "azuredevops", daemon: conformAzureDevOpsDaemon},
	{name: "linear", daemon: conformLinearDaemon},
	{name: "jira", daemon: conformJiraDaemon},
	{name: "azureboards", daemon: conformBoardsDaemon},
}

// conformGitHub is GitHub with four items on alexec/agents, which pages by its cursor.
type conformGitHub struct {
	*fakeForgeGitHub
}

var conformGitHubItems = []githubmcp.Item{
	{Repo: "alexec/agents", Number: 4, PR: true, State: "merged", HeadRef: "agents/4-merged", BaseRef: "main", MergeCommit: "9f1c2b3a4d5e6f708192a3b4c5d6e7f809a1b2c3", MergedBy: "alexec", Title: "Merged", URL: "https://github.com/alexec/agents/pull/4",
		Author: "alexec", AuthorAvatar: "https://avatars.githubusercontent.com/u/1?v=4", Labels: []string{"enhancement"}, LabelColors: map[string]string{"enhancement": "#a2eeef"},
		CreatedAt: "2026-10-01T10:00:00Z", ClosedAt: "2026-11-04T10:00:00Z", UpdatedAt: "2026-11-04T10:00:00Z", Comments: 1},
	{Repo: "alexec/agents", Number: 3, PR: true, State: "open", HeadRef: "agents/3-open", BaseRef: "main", Title: "Open", URL: "https://github.com/alexec/agents/pull/3",
		Author: "alexec", AuthorAvatar: "https://avatars.githubusercontent.com/u/1?v=4", Labels: []string{"bug"}, LabelColors: map[string]string{"bug": "#d73a4a"}, Assignees: []string{"alexec"},
		CreatedAt: "2026-10-01T10:00:00Z", UpdatedAt: "2026-11-03T10:00:00Z", Checks: "failing", Comments: 1},
	{Repo: "alexec/agents", Number: 2, State: "closed", StateReason: "not_planned", Title: "Closed", URL: "https://github.com/alexec/agents/issues/2",
		Author: "alexec", AuthorAvatar: "https://avatars.githubusercontent.com/u/1?v=4", CreatedAt: "2026-10-01T10:00:00Z", ClosedAt: "2026-11-02T10:00:00Z", UpdatedAt: "2026-11-02T10:00:00Z", Comments: 1},
	{Repo: "alexec/agents", Number: 1, State: "open", Title: "Open issue", URL: "https://github.com/alexec/agents/issues/1",
		Author: "alexec", AuthorAvatar: "https://avatars.githubusercontent.com/u/1?v=4", Labels: []string{"task", "feature:work"}, LabelColors: map[string]string{"task": "#c5def5", "feature:work": "#1d76db"},
		CreatedAt: "2026-10-01T10:00:00Z", UpdatedAt: "2026-11-01T10:00:00Z", Comments: 2},
}

func (g conformGitHub) Search(_ context.Context, _ []string, sf githubmcp.SearchFilter, after string, first int) (githubmcp.SearchPage, error) {
	var kept []githubmcp.Item
	for _, i := range conformGitHubItems {
		open := i.State == "open"
		if i.PR == sf.PRs && (sf.State == "all" || (sf.State == "closed") != open) {
			kept = append(kept, i)
		}
	}
	from, _ := strconv.Atoi(after)
	var page githubmcp.SearchPage
	for n := from; n < len(kept) && len(page.Items) < first; n++ {
		page.Items = append(page.Items, kept[n])
		page.Cursors = append(page.Cursors, strconv.Itoa(n+1))
	}
	if end := from + len(page.Items); end < len(kept) {
		page.Next = strconv.Itoa(end)
	}
	// The first page counts the list (#4396).
	if after == "" {
		page.Total = new(len(kept))
	}
	return page, nil
}

func (g conformGitHub) ItemPage(_ context.Context, _ string, number int, _ string) (githubmcp.ItemDetail, error) {
	for _, i := range conformGitHubItems {
		if i.Number == number {
			d := githubmcp.ItemDetail{Item: i, Body: "The body.",
				Thread: []githubmcp.Comment{{Author: "alexec", Avatar: "https://avatars.githubusercontent.com/u/1?v=4", Body: "A comment.", At: i.UpdatedAt}}}
			if i.PR {
				d.Head, d.MergeMethods = "abc", []string{"squash"}
				d.CheckRuns = []githubmcp.Check{
					{Name: "test", State: "failing", URL: "https://github.com/alexec/agents/actions/runs/7", StartedAt: "2026-11-03T10:00:00Z", FinishedAt: "2026-11-03T10:02:10Z"},
					{Name: "lint", State: "running", URL: "https://github.com/alexec/agents/actions/runs/8", StartedAt: "2026-11-03T10:00:05Z"},
					{Name: "ci/status", State: "passing", URL: "https://ci.example.com/1"},
				}
				d.Additions, d.Deletions, d.Commits = 412, 18, 3
				d.Reviewers = []githubmcp.Reviewer{{Login: "kim", Avatar: "https://avatars.githubusercontent.com/u/2?v=4", State: "approved"}, {Login: "alexec/reviewers", State: "pending"}}
				d.Closes = []githubmcp.Linked{{Repo: "alexec/agents", Number: 1, Title: "Open issue", State: "open", URL: "https://github.com/alexec/agents/issues/1"}}
			} else {
				d.Children = []githubmcp.Linked{{Repo: "alexec/agents", Number: 2, Title: "Closed", State: "closed", URL: "https://github.com/alexec/agents/issues/2"}}
				d.LinkedPulls = []githubmcp.Linked{{Repo: "alexec/agents", Number: 4, PR: true, Title: "Merged", State: "merged", URL: "https://github.com/alexec/agents/pull/4"}}
				d.Events = []githubmcp.Event{
					{Kind: "labeled", Actor: "alexec", At: "2026-10-01T11:00:00Z", Label: "task", LabelColor: "#c5def5"},
					{Kind: "assigned", Actor: "alexec", At: "2026-10-01T12:00:00Z", Assignee: "alexec"},
					{Kind: "referenced", Actor: "alexec", At: "2026-10-02T10:00:00Z", SourceRepo: "alexec/agents", SourceNumber: 4, SourcePR: true},
				}
			}
			return d, nil
		}
	}
	return githubmcp.ItemDetail{}, &githubmcp.GitHubError{Kind: githubmcp.NotFound, Message: "not found on GitHub"}
}

func (g conformGitHub) Plan(_ context.Context, _ string, number int) (githubmcp.Plan, error) {
	return githubmcp.Plan{Epic: conformGitHubItems[3]}, nil
}

func (g conformGitHub) CreateIssue(_ context.Context, repo, title string, _ []string) (int, string, error) {
	g.note("create %s %s", repo, title)
	return 9, "https://github.com/" + repo + "/issues/9", nil
}

func (g conformGitHub) AddSubIssue(_ context.Context, repo string, number int, childRepo string, childNumber int) error {
	g.note("sub-issue %s#%d %s#%d", repo, number, childRepo, childNumber)
	return nil
}

func (g conformGitHub) SetBlockedBy(_ context.Context, repo string, number int, blockerRepo string, blockerNumber int, blocked bool) error {
	g.note("blocked-by %s#%d %s#%d %v", repo, number, blockerRepo, blockerNumber, blocked)
	return nil
}

func conformGitHubDaemon(t *testing.T) (*Daemon, *conn) {
	d, c, gh, _ := forgeDaemon(t)
	fake := conformGitHub{gh}
	d.newForgeGitHub = func(string) forgeGitHub { return fake }
	return d, c
}

// conformGitLab is GitLab with four items on Group/App, which pages by its cursor.
type conformGitLab struct {
	*fakeForgeGitLab
}

var conformGitLabItems = []gitlabmcp.Item{
	{Project: "Group/App", Number: 4, MR: true, State: "merged", HeadRef: "agents/4-merged", BaseRef: "main", MergeCommit: "9f1c2b3a4d5e6f708192a3b4c5d6e7f809a1b2c3", MergedBy: "kim", Title: "Merged", URL: "https://gitlab.com/Group/App/-/merge_requests/4",
		Author: "kim", AuthorAvatar: "https://gitlab.com/uploads/-/system/user/avatar/7/avatar.png", Labels: []string{"enhancement"}, LabelColors: map[string]string{"enhancement": "#a2eeef"},
		CreatedAt: "2026-10-01T10:00:00Z", ClosedAt: "2026-11-04T10:00:00Z", UpdatedAt: "2026-11-04T10:00:00Z", Comments: 1},
	{Project: "Group/App", Number: 3, MR: true, State: "open", HeadRef: "agents/3-open", BaseRef: "main", Title: "Open", URL: "https://gitlab.com/Group/App/-/merge_requests/3",
		Author: "kim", AuthorAvatar: "https://gitlab.com/uploads/-/system/user/avatar/7/avatar.png", Labels: []string{"bug"}, LabelColors: map[string]string{"bug": "#d9534f"}, Assignees: []string{"kim"},
		CreatedAt: "2026-10-01T10:00:00Z", UpdatedAt: "2026-11-03T10:00:00Z", Checks: "failing", Comments: 1},
	{Project: "Group/App", Number: 2, State: "closed", Title: "Closed", URL: "https://gitlab.com/Group/App/-/issues/2",
		Author: "kim", AuthorAvatar: "https://gitlab.com/uploads/-/system/user/avatar/7/avatar.png", CreatedAt: "2026-10-01T10:00:00Z", ClosedAt: "2026-11-02T10:00:00Z", UpdatedAt: "2026-11-02T10:00:00Z", Comments: 1},
	{Project: "Group/App", Number: 1, State: "open", Title: "Open issue", URL: "https://gitlab.com/Group/App/-/issues/1",
		Author: "kim", AuthorAvatar: "https://gitlab.com/uploads/-/system/user/avatar/7/avatar.png", Labels: []string{"task"}, LabelColors: map[string]string{"task": "#c5def5"},
		CreatedAt: "2026-10-01T10:00:00Z", UpdatedAt: "2026-11-01T10:00:00Z", Comments: 2},
}

func (g conformGitLab) Search(_ context.Context, _ []string, sf gitlabmcp.SearchFilter, after string, first int) (gitlabmcp.SearchPage, error) {
	var kept []gitlabmcp.Item
	for _, i := range conformGitLabItems {
		open := i.State == "open"
		if i.MR == sf.MRs && (sf.State == "all" || (sf.State == "closed") != open) {
			kept = append(kept, i)
		}
	}
	from, _ := strconv.Atoi(after)
	var page gitlabmcp.SearchPage
	for n := from; n < len(kept) && len(page.Items) < first; n++ {
		page.Items = append(page.Items, kept[n])
		page.Cursors = append(page.Cursors, strconv.Itoa(n+1))
	}
	if end := from + len(page.Items); end < len(kept) {
		page.Next = strconv.Itoa(end)
	}
	// The first page counts the list (#4396).
	if after == "" {
		page.Total = new(len(kept))
	}
	return page, nil
}

func (g conformGitLab) ItemPage(_ context.Context, _ string, number int, mr bool, _ string) (gitlabmcp.ItemDetail, error) {
	for _, i := range conformGitLabItems {
		if i.Number == number && i.MR == mr {
			d := gitlabmcp.ItemDetail{Item: i, Body: "The body.",
				Thread: []gitlabmcp.Comment{{Author: "kim", Avatar: "https://gitlab.com/uploads/-/system/user/avatar/7/avatar.png", Body: "A comment.", At: i.UpdatedAt}}}
			if i.MR {
				d.Head, d.Pipeline = "abc", 7
				d.CheckRuns = []gitlabmcp.Check{{Name: "test: unit", State: "failing"}}
			}
			return d, nil
		}
	}
	return gitlabmcp.ItemDetail{}, &gitlabmcp.GitLabError{Kind: gitlabmcp.NotFound, Message: "not found on GitLab"}
}

func (g conformGitLab) Plan(_ context.Context, _ string, _ int) (gitlabmcp.Plan, error) {
	return gitlabmcp.Plan{Epic: conformGitLabItems[3]}, nil
}

// conformGitLabDaemon is a daemon with one folder on Group/App on the connected gitlab.com.
func conformGitLabDaemon(t *testing.T) (*Daemon, *conn) {
	t.Helper()
	t.Setenv("AGENTS_PERSONAL_HOME", t.TempDir())
	d, c := start(t, t.TempDir())
	t.Cleanup(d.Shutdown)
	file := &connections.File{Path: filepath.Join(t.TempDir(), ".agents-secrets", connections.FileName)}
	d.connStoreFor = func() (connections.Store, error) { return file, nil }
	fake := conformGitLab{&fakeForgeGitLab{}}
	d.newForgeGitLab = func(string, string) forgeGitLab { return fake }
	c.call(t, 100, "folders/add", map[string]any{"folder": "file://" + gitFolder(t, "git@gitlab.com:Group/App.git")})
	if err := file.Put(connections.Connection{Provider: connections.GitLab, Login: "kim", Access: "gloas-secret", URL: connections.GitLabCom,
		AccessExpiresAt: time.Now().Add(time.Hour), ConnectedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	return d, c
}

// conformForgejo is Forgejo with four items on walkalex/App, which pages by its cursor.
type conformForgejo struct {
	*fakeForgeForgejo
}

var conformForgejoItems = []forgejomcp.Item{
	{Repo: "walkalex/App", Number: 4, PR: true, State: "merged", Title: "Merged", URL: "http://localhost:3753/walkalex/App/pulls/4", HeadRef: "agents/4-merged", BaseRef: "main", MergeCommit: "9f1c2b3a4d5e6f708192a3b4c5d6e7f809a1b2c3", MergedBy: "walkalex",
		Author: "kim", AuthorAvatar: "http://localhost:3753/avatars/k", Labels: []string{"enhancement"}, LabelColors: map[string]string{"enhancement": "#a2eeef"},
		CreatedAt: "2026-10-01T10:00:00Z", ClosedAt: "2026-11-04T10:00:00Z", UpdatedAt: "2026-11-04T10:00:00Z", Comments: 1},
	{Repo: "walkalex/App", Number: 3, PR: true, State: "open", Title: "Open", URL: "http://localhost:3753/walkalex/App/pulls/3", HeadRef: "agents/3-open", BaseRef: "main",
		Author: "kim", AuthorAvatar: "http://localhost:3753/avatars/k", Labels: []string{"bug"}, LabelColors: map[string]string{"bug": "#ee0701"}, Assignees: []string{"kim"},
		CreatedAt: "2026-10-01T10:00:00Z", UpdatedAt: "2026-11-03T10:00:00Z", Checks: "failing", Comments: 1},
	{Repo: "walkalex/App", Number: 2, State: "closed", Title: "Closed", URL: "http://localhost:3753/walkalex/App/issues/2",
		Author: "kim", AuthorAvatar: "http://localhost:3753/avatars/k", CreatedAt: "2026-10-01T10:00:00Z", ClosedAt: "2026-11-02T10:00:00Z", UpdatedAt: "2026-11-02T10:00:00Z", Comments: 1},
	{Repo: "walkalex/App", Number: 1, State: "open", Title: "Open issue", URL: "http://localhost:3753/walkalex/App/issues/1",
		Author: "kim", AuthorAvatar: "http://localhost:3753/avatars/k", Labels: []string{"task"}, LabelColors: map[string]string{"task": "#c5def5"},
		CreatedAt: "2026-10-01T10:00:00Z", UpdatedAt: "2026-11-01T10:00:00Z", Comments: 2},
}

func (g conformForgejo) Search(_ context.Context, _ []string, sf forgejomcp.SearchFilter, after string, first int) (forgejomcp.SearchPage, error) {
	var kept []forgejomcp.Item
	for _, i := range conformForgejoItems {
		open := i.State == "open"
		if i.PR == sf.PRs && (sf.State == "all" || (sf.State == "closed") != open) {
			kept = append(kept, i)
		}
	}
	from, _ := strconv.Atoi(after)
	var page forgejomcp.SearchPage
	for n := from; n < len(kept) && len(page.Items) < first; n++ {
		page.Items = append(page.Items, kept[n])
		page.Cursors = append(page.Cursors, strconv.Itoa(n+1))
	}
	if end := from + len(page.Items); end < len(kept) {
		page.Next = strconv.Itoa(end)
	}
	return page, nil
}

func (g conformForgejo) ItemPage(_ context.Context, _ string, number int, pr bool, _ string) (forgejomcp.ItemDetail, error) {
	for _, i := range conformForgejoItems {
		if i.Number == number && i.PR == pr {
			d := forgejomcp.ItemDetail{Item: i, Body: "The body.",
				Thread: []forgejomcp.Comment{{Author: "kim", Avatar: "http://localhost:3753/avatars/k", Body: "A comment.", At: i.UpdatedAt}}}
			if i.PR {
				d.Head = "abc"
				d.CheckRuns = []forgejomcp.CheckRun{{Name: "ci / test", State: "failing"}}
			}
			return d, nil
		}
	}
	return forgejomcp.ItemDetail{}, &forgejomcp.ForgejoError{Kind: forgejomcp.NotFound, Message: "not found on Forgejo"}
}

func (g conformForgejo) Plan(_ context.Context, _ string, _ int) (forgejomcp.Plan, error) {
	return forgejomcp.Plan{Epic: conformForgejoItems[3]}, nil
}

// conformForgejoDaemon is a daemon with one folder on walkalex/App on the connected Forgejo.
func conformForgejoDaemon(t *testing.T) (*Daemon, *conn) {
	t.Helper()
	t.Setenv("AGENTS_PERSONAL_HOME", t.TempDir())
	d, c := start(t, t.TempDir())
	t.Cleanup(d.Shutdown)
	file := &connections.File{Path: filepath.Join(t.TempDir(), ".agents-secrets", connections.FileName)}
	d.connStoreFor = func() (connections.Store, error) { return file, nil }
	fake := conformForgejo{&fakeForgeForgejo{}}
	d.newForgeForgejo = func(string, string) forgeForgejo { return fake }
	c.call(t, 100, "folders/add", map[string]any{"folder": "file://" + gitFolder(t, "http://localhost:3753/walkalex/App.git")})
	if err := file.Put(connections.Connection{Provider: connections.Forgejo, Login: "walkalex", Access: "forgejo-secret",
		URL: "http://localhost:3753/", ConnectedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	return d, c
}

// conformBitbucket is Bitbucket Cloud with four items on walkalex/App, which pages by its cursor.
type conformBitbucket struct {
	*fakeForgeBitbucket
}

var conformBitbucketItems = []bitbucketmcp.Item{
	{Repo: "walkalex/App", Number: 4, PR: true, State: "merged", Title: "Merged", URL: "https://bitbucket.org/walkalex/App/pull-requests/4", HeadRef: "agents/4-merged", BaseRef: "main", MergeCommit: "9f1c2b3a4d5e",
		Author: "kim", AuthorAvatar: "https://avatar-management--avatars.us-west-2.prod.public.atl-paas.net/k/48", CreatedAt: "2026-10-01T10:00:00Z", UpdatedAt: "2026-11-04T10:00:00Z", Comments: 1},
	{Repo: "walkalex/App", Number: 3, PR: true, State: "open", Title: "Open", URL: "https://bitbucket.org/walkalex/App/pull-requests/3", HeadRef: "agents/3-open", BaseRef: "main",
		Author: "kim", AuthorAvatar: "https://avatar-management--avatars.us-west-2.prod.public.atl-paas.net/k/48", Assignees: []string{"kim"}, CreatedAt: "2026-10-01T10:00:00Z", UpdatedAt: "2026-11-03T10:00:00Z", Checks: "failing", Comments: 1},
	{Repo: "walkalex/App", Number: 2, State: "closed", StateReason: "duplicate", Title: "Closed", URL: "https://bitbucket.org/walkalex/App/issues/2",
		Author: "kim", AuthorAvatar: "https://avatar-management--avatars.us-west-2.prod.public.atl-paas.net/k/48", Labels: []string{"bug"}, CreatedAt: "2026-10-01T10:00:00Z", UpdatedAt: "2026-11-02T10:00:00Z"},
	{Repo: "walkalex/App", Number: 1, State: "open", Title: "Open issue", URL: "https://bitbucket.org/walkalex/App/issues/1",
		Author: "kim", AuthorAvatar: "https://avatar-management--avatars.us-west-2.prod.public.atl-paas.net/k/48", Labels: []string{"task", "feature:Export"}, CreatedAt: "2026-10-01T10:00:00Z", UpdatedAt: "2026-11-01T10:00:00Z"},
}

func (g conformBitbucket) Search(_ context.Context, _ []string, sf bitbucketmcp.SearchFilter, after string, first int) (bitbucketmcp.SearchPage, error) {
	var kept []bitbucketmcp.Item
	for _, i := range conformBitbucketItems {
		open := i.State == "open"
		if i.PR == sf.PRs && (sf.State == "all" || (sf.State == "closed") != open) {
			kept = append(kept, i)
		}
	}
	from, _ := strconv.Atoi(after)
	var page bitbucketmcp.SearchPage
	for n := from; n < len(kept) && len(page.Items) < first; n++ {
		page.Items = append(page.Items, kept[n])
		page.Cursors = append(page.Cursors, strconv.Itoa(n+1))
	}
	if end := from + len(page.Items); end < len(kept) {
		page.Next = strconv.Itoa(end)
	}
	return page, nil
}

func (g conformBitbucket) ItemPage(_ context.Context, _ string, number int, pr bool, _ string) (bitbucketmcp.ItemDetail, error) {
	for _, i := range conformBitbucketItems {
		if i.Number == number && i.PR == pr {
			d := bitbucketmcp.ItemDetail{Item: i, Body: "The body.",
				Thread: []bitbucketmcp.Comment{{Author: "kim", Avatar: "https://avatar-management--avatars.us-west-2.prod.public.atl-paas.net/k/48", Body: "A comment.", At: i.UpdatedAt}}}
			if i.PR {
				d.Head = "abc"
				d.CheckRuns = []bitbucketmcp.CheckRun{{Name: "Pipeline #12", State: "failing", Run: 12}}
			} else {
				// An issue's count is only on its page (commentCount detail).
				d.Comments = len(d.Thread)
			}
			return d, nil
		}
	}
	return bitbucketmcp.ItemDetail{}, &bitbucketmcp.BitbucketError{Kind: bitbucketmcp.NotFound, Message: "not found on Bitbucket"}
}

// conformBitbucketDaemon is a daemon with one folder on walkalex/App on Bitbucket Cloud.
func conformBitbucketDaemon(t *testing.T) (*Daemon, *conn) {
	t.Helper()
	t.Setenv("AGENTS_PERSONAL_HOME", t.TempDir())
	d, c := start(t, t.TempDir())
	t.Cleanup(d.Shutdown)
	file := &connections.File{Path: filepath.Join(t.TempDir(), ".agents-secrets", connections.FileName)}
	d.connStoreFor = func() (connections.Store, error) { return file, nil }
	fake := conformBitbucket{&fakeForgeBitbucket{}}
	d.newForgeBitbucket = func(string, string, string) forgeBitbucket { return fake }
	c.call(t, 100, "folders/add", map[string]any{"folder": "file://" + gitFolder(t, "git@bitbucket.org:walkalex/App.git")})
	if err := file.Put(connections.BitbucketConnection(connections.BitbucketAPI, "me@example.com", "bb-secret", "walkalex", time.Now())); err != nil {
		t.Fatal(err)
	}
	return d, c
}

// conformAzureDevOps is Azure Repos with two pull requests on acme/Web App/App, which pages by
// its cursor. It has no issues: Azure Boards has them.
type conformAzureDevOps struct {
	*fakeForgeAzureDevOps
}

var conformAzureDevOpsItems = []azuredevopsmcp.Item{
	{Repo: "acme/Web App/App", Number: 4, State: "merged", HeadRef: "agents/4-merged", BaseRef: "main", MergeCommit: "9f1c2b3a4d5e6f708192a3b4c5d6e7f809a1b2c3", MergedBy: "Kim", Title: "Merged", URL: "https://dev.azure.com/acme/Web%20App/_git/App/pullrequest/4",
		Author: "kim@example.com", AuthorAvatar: "https://dev.azure.com/acme/_apis/GraphProfile/MemberAvatars/aad.aw0", CreatedAt: "2026-10-01T10:00:00Z", ClosedAt: "2026-11-04T10:00:00Z", UpdatedAt: "2026-11-04T10:00:00Z"},
	{Repo: "acme/Web App/App", Number: 3, State: "open", HeadRef: "agents/3-open", BaseRef: "main", Title: "Open", URL: "https://dev.azure.com/acme/Web%20App/_git/App/pullrequest/3",
		Author: "kim@example.com", AuthorAvatar: "https://dev.azure.com/acme/_apis/GraphProfile/MemberAvatars/aad.aw0", Labels: []string{"ui"}, CreatedAt: "2026-10-01T10:00:00Z", UpdatedAt: "2026-11-03T10:00:00Z", Checks: "failing"},
}

func (g conformAzureDevOps) Search(_ context.Context, _ []string, sf azuredevopsmcp.SearchFilter, after string, first int) (azuredevopsmcp.SearchPage, error) {
	var kept []azuredevopsmcp.Item
	for _, i := range conformAzureDevOpsItems {
		if sf.State == "all" || (sf.State == "closed") != (i.State == "open") {
			kept = append(kept, i)
		}
	}
	from, _ := strconv.Atoi(after)
	var page azuredevopsmcp.SearchPage
	for n := from; n < len(kept) && len(page.Items) < first; n++ {
		page.Items = append(page.Items, kept[n])
		page.Cursors = append(page.Cursors, strconv.Itoa(n+1))
	}
	if end := from + len(page.Items); end < len(kept) {
		page.Next = strconv.Itoa(end)
	}
	return page, nil
}

func (g conformAzureDevOps) ItemPage(_ context.Context, _ string, number int, _ string) (azuredevopsmcp.ItemDetail, error) {
	for _, i := range conformAzureDevOpsItems {
		if i.Number == number {
			// The count is only on the page (commentCount detail).
			i.Comments = 1
			return azuredevopsmcp.ItemDetail{Item: i, Body: "The body.", Head: "abc",
				Thread:    []azuredevopsmcp.Comment{{Author: "kim@example.com", Avatar: "https://dev.azure.com/acme/_apis/GraphProfile/MemberAvatars/aad.aw0", Body: "A comment.", At: i.UpdatedAt}},
				CheckRuns: []azuredevopsmcp.CheckRun{{Name: "ci", State: "failing", Build: 70}}}, nil
		}
	}
	return azuredevopsmcp.ItemDetail{}, &azuredevopsmcp.AzureDevOpsError{Kind: azuredevopsmcp.NotFound, Message: "not found on Azure DevOps"}
}

// conformAzureDevOpsDaemon is a daemon with one folder on acme/Web App/App on Azure DevOps.
func conformAzureDevOpsDaemon(t *testing.T) (*Daemon, *conn) {
	t.Helper()
	t.Setenv("AGENTS_PERSONAL_HOME", t.TempDir())
	d, c := start(t, t.TempDir())
	t.Cleanup(d.Shutdown)
	file := &connections.File{Path: filepath.Join(t.TempDir(), ".agents-secrets", connections.FileName)}
	d.connStoreFor = func() (connections.Store, error) { return file, nil }
	fake := conformAzureDevOps{&fakeForgeAzureDevOps{}}
	d.newForgeAzureDevOps = func(string, string) forgeAzureDevOps { return fake }
	c.call(t, 100, "folders/add", map[string]any{"folder": "file://" + gitFolder(t, "https://acme@dev.azure.com/acme/Web%20App/_git/App")})
	if err := file.Put(connections.AzureDevOpsConnection(connections.AzureDevOpsServices, "acme", "ado-secret", "Agents Test", time.Now())); err != nil {
		t.Fatal(err)
	}
	return d, c
}

// conformLinear is Linear with two issues in the workspace, which pages by its cursor. It has no
// pull requests.
type conformLinear struct {
	*fakeForgeLinear
}

var conformLinearItems = []linearmcp.Item{
	{Identifier: "ENG-2", Team: "ENG", State: "closed", StateReason: "completed", Title: "Closed", URL: "https://linear.app/acme/issue/ENG-2", Author: "kim", AuthorAvatar: "https://public.linear.app/k/avatar",
		CreatedAt: "2026-10-01T10:00:00Z", ClosedAt: "2026-11-02T10:00:00Z", UpdatedAt: "2026-11-02T10:00:00Z", Comments: 1},
	{Identifier: "ENG-1", Team: "ENG", State: "open", Title: "Open issue", URL: "https://linear.app/acme/issue/ENG-1", Author: "kim", AuthorAvatar: "https://public.linear.app/k/avatar",
		Labels: []string{"task", "feature:Export"}, LabelColors: map[string]string{"task": "#c5def5", "feature:Export": "#1d76db"},
		Assignees: []string{"kim"}, CreatedAt: "2026-10-01T10:00:00Z", UpdatedAt: "2026-11-01T10:00:00Z", Comments: 2},
}

func (g conformLinear) Search(_ context.Context, _ []string, sf linearmcp.SearchFilter, after string, first int) (linearmcp.SearchPage, error) {
	var kept []linearmcp.Item
	for _, i := range conformLinearItems {
		if sf.State == "all" || (sf.State == "closed") != (i.State == "open") {
			kept = append(kept, i)
		}
	}
	from, _ := strconv.Atoi(after)
	var page linearmcp.SearchPage
	for n := from; n < len(kept) && len(page.Items) < first; n++ {
		page.Items = append(page.Items, kept[n])
		page.Cursors = append(page.Cursors, strconv.Itoa(n+1))
	}
	if end := from + len(page.Items); end < len(kept) {
		page.Next = strconv.Itoa(end)
	}
	return page, nil
}

func (g conformLinear) ItemPage(_ context.Context, identifier, _ string) (linearmcp.ItemDetail, error) {
	for _, i := range conformLinearItems {
		if i.Identifier == identifier {
			return linearmcp.ItemDetail{Item: i, Body: "The body.",
				Thread:   []linearmcp.Comment{{Author: "kim", Avatar: "https://public.linear.app/k/avatar", Body: "A comment.", At: i.UpdatedAt}},
				Children: []linearmcp.Child{{Identifier: "ENG-2", Title: "Closed", State: "closed", URL: "https://linear.app/acme/issue/ENG-2"}}}, nil
		}
	}
	return linearmcp.ItemDetail{}, &linearmcp.LinearError{Kind: linearmcp.NotFound, Message: "Linear issue " + identifier + " was not found"}
}

func (g conformLinear) Plan(_ context.Context, identifier string) (linearmcp.Plan, error) {
	return linearmcp.Plan{Epic: conformLinearItems[1]}, nil
}

// conformLinearDaemon is a daemon with the Linear connection and no folder that names a team, so
// its lists are of the whole workspace (#3311).
func conformLinearDaemon(t *testing.T) (*Daemon, *conn) {
	t.Helper()
	t.Setenv("AGENTS_PERSONAL_HOME", t.TempDir())
	d, c := start(t, t.TempDir())
	t.Cleanup(d.Shutdown)
	file := &connections.File{Path: filepath.Join(t.TempDir(), ".agents-secrets", connections.FileName)}
	d.connStoreFor = func() (connections.Store, error) { return file, nil }
	fake := conformLinear{&fakeForgeLinear{}}
	d.newForgeLinear = func(string) forgeLinear { return fake }
	if err := file.Put(connections.Connection{Provider: connections.Linear, Login: "kim", Access: "lin_oauth",
		AccessExpiresAt: time.Now().Add(time.Hour), ConnectedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	return d, c
}

// conformJira is Jira with two issues in the project PROJ, which pages by its cursor. It has no
// pull requests.
type conformJira struct {
	*fakeForgeJira
}

var conformJiraItems = []jiramcp.Item{
	{Key: "PROJ-2", Project: "PROJ", State: "closed", StateReason: "completed", Status: "Done", Title: "Closed", URL: "https://acme.atlassian.net/browse/PROJ-2",
		Author: "Kim", AuthorAvatar: "https://avatar-management--avatars.us-west-2.prod.public.atl-paas.net/k/48", CreatedAt: "2026-10-01T10:00:00.000Z", ClosedAt: "2026-11-02T10:00:00.000Z", UpdatedAt: "2026-11-02T10:00:00.000Z", Comments: 1},
	{Key: "PROJ-1", Project: "PROJ", State: "open", Status: "To Do", Title: "Open issue", URL: "https://acme.atlassian.net/browse/PROJ-1",
		Author: "Kim", AuthorAvatar: "https://avatar-management--avatars.us-west-2.prod.public.atl-paas.net/k/48", Labels: []string{"billing"}, Assignees: []string{"Kim"}, CreatedAt: "2026-10-01T10:00:00.000Z", UpdatedAt: "2026-11-01T10:00:00.000Z", Comments: 2},
}

func (g conformJira) Search(_ context.Context, _ []string, sf jiramcp.SearchFilter, after string, first int) (jiramcp.SearchPage, error) {
	var kept []jiramcp.Item
	for _, i := range conformJiraItems {
		if sf.State == "all" || (sf.State == "closed") != (i.State == "open") {
			kept = append(kept, i)
		}
	}
	from, _ := strconv.Atoi(after)
	var page jiramcp.SearchPage
	for n := from; n < len(kept) && len(page.Items) < first; n++ {
		page.Items = append(page.Items, kept[n])
		page.Cursors = append(page.Cursors, strconv.Itoa(n+1))
	}
	if end := from + len(page.Items); end < len(kept) {
		page.Next = strconv.Itoa(end)
	}
	// The first page counts the list (#4396).
	if after == "" {
		page.Total = new(len(kept))
	}
	return page, nil
}

func (g conformJira) ItemPage(_ context.Context, key, _ string) (jiramcp.ItemDetail, error) {
	for _, i := range conformJiraItems {
		if i.Key == key {
			return jiramcp.ItemDetail{Item: i, Body: "The body.",
				Thread:      []jiramcp.Comment{{Author: "Kim", Avatar: "https://avatar-management--avatars.us-west-2.prod.public.atl-paas.net/k/48", Body: "A comment.", At: i.UpdatedAt}},
				Transitions: []jiramcp.Transition{{ID: "31", Name: "Done", Category: "done"}}}, nil
		}
	}
	return jiramcp.ItemDetail{}, &jiramcp.JiraError{Kind: jiramcp.NotFound, Message: "Jira: Issue does not exist"}
}

func (g conformJira) Plan(_ context.Context, key string) (jiramcp.Plan, error) {
	return jiramcp.Plan{Epic: conformJiraItems[1]}, nil
}

// conformJiraDaemon is a daemon with the jira connector's sign-in and one folder, on no forge,
// whose .agents/folder.json names the project PROJ.
func conformJiraDaemon(t *testing.T) (*Daemon, *conn) {
	t.Helper()
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	d, c := start(t, t.TempDir())
	t.Cleanup(d.Shutdown)
	fake := conformJira{&fakeForgeJira{}}
	d.newForgeJira = func(jiramcp.Auth) forgeJira { return fake }
	folder := gitFolder(t, "")
	os.MkdirAll(filepath.Join(folder, ".agents"), 0o755)
	os.WriteFile(filepath.Join(folder, ".agents", "folder.json"), []byte(`{"jiraProjects": ["PROJ"]}`), 0o644)
	c.call(t, 100, "folders/add", map[string]any{"folder": "file://" + folder})
	os.MkdirAll(filepath.Join(home, ".agents-secrets"), 0o700)
	os.WriteFile(filepath.Join(home, ".agents-secrets", "secrets.env"),
		[]byte("JIRA_URL=https://acme.atlassian.net/\nJIRA_EMAIL=kim@acme.com\nJIRA_API_TOKEN=tok\n"), 0o600)
	return d, c
}

// conformBoards is Azure Boards with two work items in the project acme/web, which pages by its
// cursor. It has no pull requests.
type conformBoards struct {
	*fakeForgeBoards
}

var conformBoardsItems = []azureboardsmcp.Item{
	{ID: 2, Project: "acme/web", Type: "Task", State: "closed", StateReason: "not_planned", Status: "Done", Title: "Closed",
		URL: "https://dev.azure.com/acme/web/_workitems/edit/2", Author: "Kim", AuthorAvatar: "https://dev.azure.com/acme/_apis/GraphProfile/MemberAvatars/aad.aw0", CreatedAt: "2026-10-01T10:00:00.000Z", ClosedAt: "2026-11-02T10:00:00.000Z", UpdatedAt: "2026-11-02T10:00:00.000Z", Comments: 1},
	{ID: 1, Project: "acme/web", Type: "Task", State: "open", Status: "To Do", Title: "Open work item",
		URL: "https://dev.azure.com/acme/web/_workitems/edit/1", Author: "Kim", AuthorAvatar: "https://dev.azure.com/acme/_apis/GraphProfile/MemberAvatars/aad.aw0", Labels: []string{"billing"},
		Assignees: []string{"Kim"}, CreatedAt: "2026-10-01T10:00:00.000Z", UpdatedAt: "2026-11-01T10:00:00.000Z", Comments: 2},
}

func (g conformBoards) Search(_ context.Context, _ []string, sf azureboardsmcp.SearchFilter, after string, first int) (azureboardsmcp.SearchPage, error) {
	var kept []azureboardsmcp.Item
	for _, i := range conformBoardsItems {
		if sf.State == "all" || (sf.State == "closed") != (i.State == "open") {
			kept = append(kept, i)
		}
	}
	from, _ := strconv.Atoi(after)
	var page azureboardsmcp.SearchPage
	for n := from; n < len(kept) && len(page.Items) < first; n++ {
		page.Items = append(page.Items, kept[n])
		page.Cursors = append(page.Cursors, strconv.Itoa(n+1))
	}
	if end := from + len(page.Items); end < len(kept) {
		page.Next = strconv.Itoa(end)
	}
	return page, nil
}

func (g conformBoards) ItemPage(_ context.Context, project string, id int, _ string) (azureboardsmcp.ItemDetail, error) {
	for _, i := range conformBoardsItems {
		if i.ID == id && i.Project == project {
			return azureboardsmcp.ItemDetail{Item: i, Body: "The description.",
				Thread:      []azureboardsmcp.ForgeComment{{Author: "Kim", Avatar: "https://dev.azure.com/acme/_apis/GraphProfile/MemberAvatars/aad.aw0", Body: "A comment.", At: i.UpdatedAt}},
				Transitions: []azureboardsmcp.Transition{{ID: "Done", Name: "Done", Category: "done"}}}, nil
		}
	}
	return azureboardsmcp.ItemDetail{}, &azureboardsmcp.BoardsError{Kind: azureboardsmcp.NotFound, Message: "Azure Boards: no work item"}
}

// conformBoardsDaemon is a daemon with the azuredevops connector's sign-in and one folder, on no
// forge, whose .agents/folder.json names the project acme/web.
func conformBoardsDaemon(t *testing.T) (*Daemon, *conn) {
	t.Helper()
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	d, c := start(t, t.TempDir())
	t.Cleanup(d.Shutdown)
	fake := conformBoards{&fakeForgeBoards{}}
	d.newForgeAzureBoards = func(string, string) forgeAzureBoards { return fake }
	folder := gitFolder(t, "")
	os.MkdirAll(filepath.Join(folder, ".agents"), 0o755)
	os.WriteFile(filepath.Join(folder, ".agents", "folder.json"), []byte(`{"azureBoardsProjects": ["acme/web"]}`), 0o644)
	c.call(t, 100, "folders/add", map[string]any{"folder": "file://" + folder})
	os.MkdirAll(filepath.Join(home, ".agents-secrets"), 0o700)
	os.WriteFile(filepath.Join(home, ".agents-secrets", "secrets.env"),
		[]byte("AZURE_DEVOPS_URL=https://dev.azure.com/\nAZURE_DEVOPS_TOKEN=tok\n"), 0o600)
	return d, c
}

// conformList is every item of a forge/issues or forge/pulls list, a page of limit at a time.
func conformList(t *testing.T, c *conn, method string, limit int64) []wire.ForgeItem {
	t.Helper()
	items, _ := conformPages(t, c, method, limit)
	return items
}

// conformPages is conformList, and each page's total.
func conformPages(t *testing.T, c *conn, method string, limit int64) ([]wire.ForgeItem, []*int64) {
	t.Helper()
	var items []wire.ForgeItem
	var totals []*int64
	var cursor *string
	for n := 0; ; n++ {
		if n > 20 {
			t.Fatalf("%s: the list does not end", method)
		}
		var page wire.ForgeList
		if err := json.Unmarshal(c.call(t, 1000+n, method, wire.ForgeListRequest{State: new("all"), Limit: new(limit), Cursor: cursor}), &page); err != nil {
			t.Fatal(err)
		}
		if len(page.Errors) > 0 {
			t.Fatalf("%s: %+v", method, page.Errors)
		}
		items = append(items, page.Items...)
		totals = append(totals, page.Total)
		if page.Cursor == nil {
			return items, totals
		}
		cursor = page.Cursor
	}
}

var labelColor = regexp.MustCompile(`^#[0-9a-f]{6}$`)

func TestForgeConformance(t *testing.T) {
	for _, row := range conformRows {
		t.Run(row.name, func(t *testing.T) {
			d, c := row.daemon(t)
			var f Forge
			for _, g := range d.forges() {
				if g.Name() == row.name {
					f = g
				}
			}
			if f == nil {
				t.Fatalf("%s is not in the registry", row.name)
			}
			caps := f.Caps()
			ctx := context.Background()

			all := map[bool][]wire.ForgeItem{}
			for _, prs := range []bool{false, true} {
				method := map[bool]string{false: "forge/issues", true: "forge/pulls"}[prs]
				all[prs] = conformList(t, c, method, forgeListMost)
				// 4. The list pages: a limit of 1 gives every item once, by the cursors.
				d.forgeWrote()
				one, totals := conformPages(t, c, method, 1)
				if !slices.EqualFunc(one, all[prs], func(a, b wire.ForgeItem) bool { return a.Node == b.Node }) {
					t.Errorf("%s by ones: %v, want %v", method, conformNodes(one), conformNodes(all[prs]))
				}
				// 5. The total (#4396): a forge that counts says the whole list's on every page; one
				// that does not says none, unless its list ends on its first page.
				for n, total := range totals {
					counts := caps.Total || len(all[prs]) <= 1
					if counts != (total != nil) || total != nil && *total != int64(len(all[prs])) {
						got := "none"
						if total != nil {
							got = strconv.FormatInt(*total, 10)
						}
						t.Errorf("%s page %d: total %s, want %d (caps say total=%v)", method, n, got, len(all[prs]), caps.Total)
					}
				}
			}
			// The list says the forge's capabilities (#4361).
			var page wire.ForgeList
			method := map[bool]string{false: "forge/issues", true: "forge/pulls"}[caps.PRs && !caps.Issues]
			if err := json.Unmarshal(c.call(t, 990, method, wire.ForgeListRequest{State: new("all")}), &page); err != nil {
				t.Fatal(err)
			}
			if want := []wire.ForgeCapabilities{caps.wire(f.Name())}; !reflect.DeepEqual(page.Forges, want) {
				t.Errorf("%s forges = %+v, want %+v", method, page.Forges, want)
			}
			// Issues and PRs agree with the kinds that List returns.
			if caps.Issues != (len(all[false]) > 0) || caps.PRs != (len(all[true]) > 0) {
				t.Errorf("caps say issues=%v prs=%v; the lists gave %d and %d", caps.Issues, caps.PRs, len(all[false]), len(all[true]))
			}

			refs := map[string]forgeRef{}
			for prs, items := range all {
				for _, i := range items {
					// 1. The node goes round, and no other forge owns it.
					r, ok := f.Owns(i.Node)
					if !ok || r.Node != i.Node {
						t.Fatalf("Owns(%v) = %+v, %v", i.Node, r, ok)
					}
					if (i.Node.Kind == lineage.KindPR) != prs {
						t.Errorf("%v is in the wrong list", i.Node)
					}
					for _, g := range d.forges() {
						if _, ok := g.Owns(i.Node); ok && g.Name() != f.Name() {
							t.Errorf("%s owns %s's %v too", g.Name(), f.Name(), i.Node)
						}
					}
					detail, err := f.Item(ctx, r, "")
					if err != nil || detail.Item.Node != i.Node {
						t.Fatalf("Item(%v) = %v, %v", i.Node, detail.Item.Node, err)
					}
					// 3. The model is filled.
					for _, m := range []wire.ForgeItem{i, detail.Item} {
						conformModel(t, d, caps, m)
					}
					refs[i.Node.Kind+" "+i.State] = r
					// 5. actions follows the state, on the item's page.
					var page wire.ForgeItemDetail
					if err := json.Unmarshal(c.call(t, 991, itemMethod(i.Node.Kind), wire.ForgeItemRequest{Node: i.Node}), &page); err != nil {
						t.Fatal(err)
					}
					conformItemActions(t, caps, i, page.Actions)
					conformComments(t, caps, i, page)
					conformAvatars(t, d, caps, page)
					conformLinks(t, d, f, caps, page)
					conformPull(t, d, f, caps, i, page)
				}
			}

			// forge/labels gives the colours as the lists do (#4362).
			for _, kind := range []string{lineage.KindIssue, lineage.KindPR} {
				r, ok := refs[kind+" open"]
				if !ok {
					continue
				}
				labels, err := f.Labels(ctx, r)
				if errors.Is(err, errForgeCannot) && !caps.PR.Label && kind == lineage.KindPR {
					continue
				}
				if err != nil {
					t.Fatalf("Labels(%v): %v", r.Node, err)
				}
				if len(labels) == 0 {
					t.Errorf("Labels(%v): none", r.Node)
				}
				conformLabelColors(t, "labels of "+fmt.Sprint(r.Node), caps, labels)
			}

			// 2. Caps agrees with the methods.
			for kind, actions := range map[string]forgeActions{lineage.KindIssue: caps.Issue, lineage.KindPR: caps.PR} {
				r, ok := refs[kind+" open"]
				if !ok {
					continue
				}
				for name, call := range conformActions(f, r) {
					err := call(ctx)
					cannotNow := errors.Is(err, errForgeCannot)
					switch {
					case actions.on(name) && cannotNow:
						t.Errorf("%s %s: caps say yes, the method says %v", kind, name, err)
					case !actions.on(name) && !cannotNow:
						t.Errorf("%s %s: caps say no, the method says %v", kind, name, err)
					case !actions.on(name):
						if cannotReason(f, err) == "" {
							t.Errorf("%s %s: no reason", kind, name)
						}
					}
				}
			}
			if r, ok := refs[lineage.KindIssue+" open"]; ok {
				for name, on := range map[string]bool{actionPlan: caps.Plan, actionAddChild: caps.AddChild, actionBlockedBy: caps.BlockedBy} {
					var err error
					switch name {
					case actionPlan:
						_, err = f.Plan(ctx, r)
					case actionAddChild:
						_, err = f.AddChild(ctx, r, forgeChild{Title: "A child"})
					case actionBlockedBy:
						err = f.SetBlockedBy(ctx, r, refs[lineage.KindIssue+" closed"], true)
					}
					if errors.Is(err, errForgeCannot) == on {
						t.Errorf("issue %s: caps say %v, the method says %v", name, on, err)
					}
				}
			}
			// 6. Releases agrees with Caps (#4426): a forge with none says why.
			s, _ := f.Sources(ctx, d.folderPaths(), caps.PRs && !caps.Issues)
			if _, err := f.Releases(ctx, s, 1); errors.Is(err, errForgeCannot) == caps.Releases {
				t.Errorf("releases: caps say %v, the method says %v", caps.Releases, err)
			} else if !caps.Releases && cannotReason(f, err) == "the forge cannot releases" {
				t.Errorf("releases: no reason of its own")
			}
		})
	}
}

// conformActions are the writes of forgeActions on r, by name.
func conformActions(f Forge, r forgeRef) map[string]func(context.Context) error {
	return map[string]func(context.Context) error{
		actionComment: func(ctx context.Context) error { _, err := f.Comment(ctx, r, "A comment."); return err },
		actionLabel:   func(ctx context.Context) error { return f.SetLabels(ctx, r, []string{"bug"}, nil) },
		actionAssign:  func(ctx context.Context) error { return f.SetAssignees(ctx, r, []string{"kim"}, nil) },
		actionClose:   func(ctx context.Context) error { return f.SetState(ctx, r, true, "") },
		actionReopen:  func(ctx context.Context) error { return f.SetState(ctx, r, false, "") },
		actionCloseNotPlanned: func(ctx context.Context) error {
			return f.CloseNotPlanned(ctx, r)
		},
		actionTransition: func(ctx context.Context) error {
			return f.SetState(ctx, r, true, "31")
		},
		actionMerge:      func(ctx context.Context) error { _, err := f.Merge(ctx, r, "abc", "", false); return err },
		actionAutoMerge:  func(ctx context.Context) error { _, err := f.Merge(ctx, r, "abc", "", true); return err },
		actionApprove:    func(ctx context.Context) error { _, err := f.Approve(ctx, r, "abc"); return err },
		actionCancelAuto: func(ctx context.Context) error { return f.CancelAutoMerge(ctx, r) },
		actionReady:      func(ctx context.Context) error { return f.Ready(ctx, r) },
		actionRerun:      func(ctx context.Context) error { _, err := f.Rerun(ctx, r); return err },
		actionLog:        func(ctx context.Context) error { _, err := f.Log(ctx, r, ""); return err },
		actionDiff:       func(ctx context.Context) error { _, err := f.Diff(ctx, r); return err },
	}
}

// conformLabelColors: each label has a #rrggbb colour when the forge says LabelColors, and none when
// it does not (#4362).
func conformLabelColors(t *testing.T, where string, caps forgeCaps, labels []wire.ForgeLabel) {
	t.Helper()
	for _, l := range labels {
		switch {
		case caps.LabelColors && !labelColor.MatchString(deref(l.Color)):
			t.Errorf("%s: label %s's colour is %q, not #rrggbb", where, l.Name, deref(l.Color))
		case !caps.LabelColors && l.Color != nil:
			t.Errorf("%s: label %s has colour %q; caps say labelColors=false", where, l.Name, *l.Color)
		}
	}
}

func conformModel(t *testing.T, d *Daemon, caps forgeCaps, i wire.ForgeItem) {
	t.Helper()
	if i.Labels == nil || i.Assignees == nil {
		t.Errorf("%v: labels %v, assignees %v", i.Node, i.Labels, i.Assignees)
	}
	if i.UpdatedAt == 0 {
		t.Errorf("%v: no updatedAt", i.Node)
	}
	if !slices.Contains([]string{"open", "closed", "merged"}, i.State) {
		t.Errorf("%v: state %q", i.Node, i.State)
	}
	conformLabelColors(t, fmt.Sprint(i.Node), caps, i.Labels)
	if caps.Avatars {
		conformAvatar(t, d, fmt.Sprint(i.Node), i.AuthorAvatar)
	}
	// stateReason is one of the three on a closed issue when the forge gives it, and missing on
	// every other item (#4365).
	closedIssue := i.Node.Kind == lineage.KindIssue && i.State == "closed"
	switch r := deref(i.StateReason); {
	case caps.StateReason && closedIssue:
		if r != "completed" && r != "not_planned" && r != "duplicate" {
			t.Errorf("%v: stateReason %q, not completed, not_planned or duplicate", i.Node, r)
		}
	case i.StateReason != nil:
		t.Errorf("%v: stateReason %q on an item that has none", i.Node, r)
	}
	// createdAt is there when the forge says it, and is no later than updatedAt; closedAt is on a
	// closed or merged item when the forge says it, no earlier than createdAt, and missing on an
	// open one (#4373).
	switch {
	case caps.CreatedAt && (i.CreatedAt == nil || *i.CreatedAt == 0 || *i.CreatedAt > i.UpdatedAt):
		t.Errorf("%v: createdAt %v, updatedAt %v", i.Node, i.CreatedAt, i.UpdatedAt)
	case !caps.CreatedAt && i.CreatedAt != nil:
		t.Errorf("%v: createdAt %v, which the forge does not say", i.Node, *i.CreatedAt)
	}
	switch {
	case i.State == "open" || !caps.ClosedAt:
		if i.ClosedAt != nil {
			t.Errorf("%v: closedAt %v on an item that has none", i.Node, *i.ClosedAt)
		}
	case i.ClosedAt == nil || *i.ClosedAt == 0 || i.CreatedAt != nil && *i.ClosedAt < *i.CreatedAt:
		t.Errorf("%v: closedAt %v, createdAt %v", i.Node, i.ClosedAt, i.CreatedAt)
	}
}

// conformComments checks that an item's comment count follows commentCount (#4364): exact, the
// list's count is the page's; capped, it is the page's up to commentsMost; detail, the list has
// none, or the page's, as Bitbucket's pull requests have. The page's count is never less than the
// comments it holds.
func conformComments(t *testing.T, caps forgeCaps, listed wire.ForgeItem, page wire.ForgeItemDetail) {
	t.Helper()
	counted, held := page.Item.Comments, int64(len(page.Comments))
	switch {
	case counted < held:
		t.Errorf("%v: the page counts %d comments and holds %d", listed.Node, counted, held)
	case caps.CommentCount == "capped" && counted > int64(caps.CommentsMost):
		t.Errorf("%v: the page counts %d comments, over the cap of %d", listed.Node, counted, caps.CommentsMost)
	}
	switch caps.CommentCount {
	case "exact":
		if listed.Comments != counted || caps.CommentsMost != 0 {
			t.Errorf("%v: exact, the list counts %d and the page %d (commentsMost %d)", listed.Node, listed.Comments, counted, caps.CommentsMost)
		}
	case "capped":
		if caps.CommentsMost <= 0 || listed.Comments != min(counted, int64(caps.CommentsMost)) {
			t.Errorf("%v: capped at %d, the list counts %d and the page %d", listed.Node, caps.CommentsMost, listed.Comments, counted)
		}
	case "detail":
		if listed.Comments != 0 && listed.Comments != counted || caps.CommentsMost != 0 {
			t.Errorf("%v: detail, the list counts %d and the page %d (commentsMost %d)", listed.Node, listed.Comments, counted, caps.CommentsMost)
		}
	default:
		t.Errorf("commentCount %q, not exact, capped or detail", caps.CommentCount)
	}
}

// conformLinks checks an item's children, linkedPulls and events (#4373): on an issue's page
// where the forge says it has them, absent elsewhere; each child is an issue and each linked pull
// request a pull request of this forge, and each event of a kind the wire has.
func conformLinks(t *testing.T, d *Daemon, f Forge, caps forgeCaps, page wire.ForgeItemDetail) {
	t.Helper()
	issue := page.Item.Node.Kind == lineage.KindIssue
	for _, l := range []struct {
		name  string
		on    bool
		kind  string
		items []wire.ForgeLinked
	}{{"children", caps.Children, lineage.KindIssue, page.Children}, {"linkedPulls", caps.LinkedPulls, lineage.KindPR, page.LinkedPulls}} {
		if (l.items != nil) != (l.on && issue) {
			t.Errorf("%v: %s %v, caps say %v", page.Item.Node, l.name, l.items, l.on)
		}
		for _, i := range l.items {
			if g, _, ok := d.forgeOwning(i.Node); !ok || g.Name() != f.Name() || i.Node.Kind != l.kind {
				t.Errorf("%v: %s %v is not a %s of %s", page.Item.Node, l.name, i.Node, l.kind, f.Name())
			}
			if i.Title == "" || !slices.Contains([]string{"open", "closed", "merged"}, i.State) {
				t.Errorf("%v: %s %v: title %q, state %q", page.Item.Node, l.name, i.Node, i.Title, i.State)
			}
		}
	}
	if (page.Events != nil) != (caps.Events && issue) {
		t.Errorf("%v: events %v, caps say %v", page.Item.Node, page.Events, caps.Events)
	}
	kinds := []wire.ForgeEventKind{wire.ForgeEventKindLabeled, wire.ForgeEventKindUnlabeled, wire.ForgeEventKindAssigned,
		wire.ForgeEventKindUnassigned, wire.ForgeEventKindClosed, wire.ForgeEventKindReopened, wire.ForgeEventKindReferenced}
	for n, e := range page.Events {
		if !slices.Contains(kinds, e.Kind) || e.At == 0 || n > 0 && e.At < page.Events[n-1].At {
			t.Errorf("%v: event %d %+v: an unknown kind, no time, or out of order", page.Item.Node, n, e)
		}
		switch e.Kind {
		case wire.ForgeEventKindLabeled, wire.ForgeEventKindUnlabeled:
			if e.Label == nil {
				t.Errorf("%v: event %d %s names no label", page.Item.Node, n, e.Kind)
			}
		case wire.ForgeEventKindAssigned, wire.ForgeEventKindUnassigned:
			if e.Assignee == nil {
				t.Errorf("%v: event %d %s names nobody", page.Item.Node, n, e.Kind)
			}
		case wire.ForgeEventKindReferenced:
			if e.Source == nil {
				t.Errorf("%v: event %d referenced names no source", page.Item.Node, n)
			}
		}
	}
}

// conformPull checks a pull request's fields (#4409) against the capabilities: the branches on
// its page (and the same on its row, where the list says them), who merged it and its merge commit
// on a merged one only, its size, reviewers and the issues it closes on its page, and its checks'
// times; an issue has none of them.
func conformPull(t *testing.T, d *Daemon, f Forge, caps forgeCaps, listed wire.ForgeItem, page wire.ForgeItemDetail) {
	t.Helper()
	i, node := page.Item, page.Item.Node
	pr, merged := node.Kind == lineage.KindPR, i.State == "merged"
	for _, b := range []struct {
		name         string
		row, onPage  *string
		on, expected bool
	}{
		{"headRef", listed.HeadRef, i.HeadRef, caps.Branches, pr},
		{"baseRef", listed.BaseRef, i.BaseRef, caps.Branches, pr},
		{"mergedBy", listed.MergedBy, i.MergedBy, caps.MergedBy, pr && merged},
		{"mergeCommit", listed.MergeCommit, i.MergeCommit, caps.MergeCommit, pr && merged},
	} {
		switch {
		case (b.onPage != nil && *b.onPage != "") != (b.on && b.expected):
			t.Errorf("%v: %s %q, caps say %v", node, b.name, deref(b.onPage), b.on)
		case b.row != nil && deref(b.row) != deref(b.onPage):
			t.Errorf("%v: %s %q on the row, %q on the page", node, b.name, *b.row, deref(b.onPage))
		}
	}
	if c := deref(i.MergeCommit); c != "" && !regexp.MustCompile(`^[0-9a-f]{7,40}$`).MatchString(c) {
		t.Errorf("%v: mergeCommit %q is not a commit", node, c)
	}
	size := page.Additions != nil && page.Deletions != nil && page.Commits != nil
	if none := page.Additions == nil && page.Deletions == nil && page.Commits == nil; !size && !none || size != (caps.Size && pr) {
		t.Errorf("%v: additions %v, deletions %v, commits %v; caps say size=%v", node, page.Additions, page.Deletions, page.Commits, caps.Size)
	} else if size && (*page.Additions < 0 || *page.Deletions < 0 || *page.Commits < 1) {
		t.Errorf("%v: +%d −%d in %d commits", node, *page.Additions, *page.Deletions, *page.Commits)
	}
	if (page.Reviewers != nil) != (caps.Reviewers && pr) {
		t.Errorf("%v: reviewers %v, caps say %v", node, page.Reviewers, caps.Reviewers)
	}
	states := []wire.ForgeReviewerState{wire.ForgeReviewerStateApproved, wire.ForgeReviewerStateChangesRequested, wire.ForgeReviewerStateCommented, wire.ForgeReviewerStatePending}
	seen := map[string]bool{}
	for _, r := range page.Reviewers {
		if r.Login == "" || seen[r.Login] || !slices.Contains(states, r.State) {
			t.Errorf("%v: reviewer %+v: no login, twice, or an unknown state", node, r)
		}
		seen[r.Login] = true
		if caps.Avatars && r.Avatar != nil {
			conformAvatar(t, d, fmt.Sprint(node), r.Avatar)
		}
	}
	if (page.Closes != nil) != (caps.Closes && pr) {
		t.Errorf("%v: closes %v, caps say %v", node, page.Closes, caps.Closes)
	}
	for _, c := range page.Closes {
		if g, _, ok := d.forgeOwning(c.Node); !ok || g.Name() != f.Name() || c.Node.Kind != lineage.KindIssue || c.Title == "" {
			t.Errorf("%v: closes %+v, not an issue of %s", node, c, f.Name())
		}
	}
	for _, c := range page.Checks {
		switch {
		case !caps.CheckTimes && (c.StartedAt != nil || c.FinishedAt != nil):
			t.Errorf("%v: check %s has times; caps say checkTimes=false", node, c.Name)
		case c.FinishedAt != nil && (c.StartedAt == nil || *c.FinishedAt < *c.StartedAt || c.State == "running"):
			t.Errorf("%v: check %s (%s) started %v, finished %v", node, c.Name, c.State, c.StartedAt, *c.FinishedAt)
		}
	}
}

// conformAvatars checks that each comment on an item's page has an avatar that forge/image
// reads, when the forge says it gives avatars.
func conformAvatars(t *testing.T, d *Daemon, caps forgeCaps, page wire.ForgeItemDetail) {
	t.Helper()
	if !caps.Avatars {
		return
	}
	for n, c := range page.Comments {
		conformAvatar(t, d, fmt.Sprintf("%v comment %d", page.Item.Node, n), c.Avatar)
	}
}

// conformAvatar checks that avatar is set and that forge/image allows its host (#4363).
func conformAvatar(t *testing.T, d *Daemon, what string, avatar *string) {
	t.Helper()
	u, err := url.Parse(deref(avatar))
	if err != nil || deref(avatar) == "" {
		t.Errorf("%s: no avatar", what)
		return
	}
	if d.forgeImageOf(u) == nil {
		t.Errorf("%s: forge/image does not read the avatar %s", what, u)
	}
}

// conformItemActions checks an item page's actions against caps and the item's state: a merged
// pull request has no merge and no reopen, a closed item has reopen and not close, and an open
// one the reverse.
func conformItemActions(t *testing.T, caps forgeCaps, i wire.ForgeItem, actions []wire.ForgeAction) {
	t.Helper()
	if actions == nil {
		t.Errorf("%v: no actions", i.Node)
	}
	a := caps.Issue
	if i.Node.Kind == lineage.KindPR {
		a = caps.PR
	}
	for _, name := range actions {
		if n := string(name); n != actionAddChild && n != actionBlockedBy && !a.on(n) {
			t.Errorf("%v: actions has %s, which caps say no to", i.Node, n)
		}
	}
	has := func(n wire.ForgeAction) bool { return slices.Contains(actions, n) }
	switch i.State {
	case "merged":
		if has(wire.ForgeActionMerge) || has(wire.ForgeActionReopen) || has(wire.ForgeActionClose) || has(wire.ForgeActionCloseNotPlanned) {
			t.Errorf("%v (merged): actions %v", i.Node, actions)
		}
	case "closed":
		if has(wire.ForgeActionClose) || has(wire.ForgeActionCloseNotPlanned) || has(wire.ForgeActionMerge) ||
			has(wire.ForgeActionReopen) != a.Reopen {
			t.Errorf("%v (closed): actions %v", i.Node, actions)
		}
	case "open":
		if has(wire.ForgeActionReopen) || has(wire.ForgeActionClose) != a.Close || has(wire.ForgeActionMerge) != a.Merge ||
			has(wire.ForgeActionCloseNotPlanned) != a.CloseNotPlanned {
			t.Errorf("%v (open): actions %v", i.Node, actions)
		}
	}
	if i.Node.Kind == lineage.KindPR && (has(wire.ForgeActionAddChild) || has(wire.ForgeActionBlockedBy)) {
		t.Errorf("%v: a pull request with a plan's actions %v", i.Node, actions)
	}
}

func conformNodes(items []wire.ForgeItem) []string {
	var out []string
	for _, i := range items {
		out = append(out, i.Node.Ref)
	}
	return out
}

// noForge does nothing but say so, as forgeNone makes a forge that has not written a method.
type noForge struct{ forgeNone }

func (noForge) Name() string { return "none" }
func (noForge) Caps() forgeCaps {
	return forgeCaps{Reasons: map[string]string{actionMerge: "this forge has no merge"}}
}
func (noForge) Owns(wire.LineageNode) (forgeRef, bool) { return forgeRef{}, false }
func (noForge) Sources(context.Context, []string, bool) (forgeScope, error) {
	return githubScope{}, nil
}

// #4352: forgeNone says "cannot" for each action, and the answer is Invalid with the forge's own
// reason when Caps gives one, else one that names the action.
func TestForgeNoneCannotAnything(t *testing.T) {
	ctx := context.Background()
	var f Forge = noForge{}
	r := forgeRef{Node: wire.LineageNode{Kind: lineage.KindPR, Ref: "none:a#1"}}
	calls := conformActions(f, r)
	calls[actionPlan] = func(ctx context.Context) error { _, err := f.Plan(ctx, r); return err }
	calls[actionAddChild] = func(ctx context.Context) error { _, err := f.AddChild(ctx, r, forgeChild{}); return err }
	calls[actionBlockedBy] = func(ctx context.Context) error { return f.SetBlockedBy(ctx, r, r, true) }
	calls["labels"] = func(ctx context.Context) error { _, err := f.Labels(ctx, r); return err }
	calls["read"] = func(ctx context.Context) error { _, err := f.Item(ctx, r, ""); return err }
	for name, call := range calls {
		err := call(ctx)
		if !errors.Is(err, errForgeCannot) {
			t.Errorf("%s: %v, not errForgeCannot", name, err)
			continue
		}
		reason := cannotReason(f, err)
		if name == actionMerge && reason != "this forge has no merge" || reason == "" {
			t.Errorf("%s: %q", name, reason)
		}
	}
	if p, err := f.List(ctx, githubScope{}, forgeFilter{}, "", 1); err != nil || len(p.items) > 0 {
		t.Errorf("list: %+v, %v", p, err)
	}
	if by, err := f.Blockers(ctx, []forgeRef{r}); err != nil || len(by) > 0 {
		t.Errorf("blockers: %v, %v", by, err)
	}
	var e *Error
	if !errors.As(forgeCannotErr("forge/x", f, cannot(actionLog)), &e) || e.Code != CodeInvalidParams {
		t.Errorf("cannot is not Invalid: %v", e)
	}
	if other := errors.New("down"); forgeCannotErr("forge/x", f, other) != other {
		t.Error("another error changed")
	}
}

// cannotReason is the reason a person reads when f cannot do what err says, or "".
func cannotReason(f Forge, err error) string {
	var e *Error
	if !errors.As(forgeCannotErr("forge/x", f, err), &e) {
		return ""
	}
	return strings.TrimSpace(strings.TrimPrefix(e.Message, "forge/x:"))
}
