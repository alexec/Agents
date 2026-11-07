package agentsd

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/bitbucketmcp"
	"github.com/alexec/agents/Go/internal/connections"
	"github.com/alexec/agents/Go/wire"
)

// fakeForgeBitbucket is Bitbucket's lists, item reads and writes, and what each was asked.
type fakeForgeBitbucket struct {
	mu       sync.Mutex
	searches []string
	items    []string
	wrote    []string
}

func (f *fakeForgeBitbucket) note(to *[]string, s string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	*to = append(*to, s)
}

func (f *fakeForgeBitbucket) Search(_ context.Context, repos []string, sf bitbucketmcp.SearchFilter, after string, first int) (bitbucketmcp.SearchPage, error) {
	f.note(&f.searches, fmt.Sprintf("%v prs=%v label=%s after=%s first=%d", repos, sf.PRs, sf.Label, after, first))
	page := bitbucketmcp.SearchPage{}
	for n, repo := range repos {
		page.Items = append(page.Items, bitbucketmcp.Item{Repo: repo, Number: 7 + n, PR: sf.PRs, State: "open", Title: "On " + repo,
			URL: "https://bitbucket.org/" + repo + "/issues/7", Author: "kim", UpdatedAt: "2026-11-07T10:00:00.123456+00:00",
			Labels: []string{"bug"}, Mergeable: "unknown"})
		page.Cursors = append(page.Cursors, "c"+repo)
	}
	return page, nil
}

func (f *fakeForgeBitbucket) ItemPage(_ context.Context, repo string, number int, pr bool, before string) (bitbucketmcp.ItemDetail, error) {
	f.note(&f.items, fmt.Sprintf("%s#%d pr=%v before=%s", repo, number, pr, before))
	if number == 404 {
		return bitbucketmcp.ItemDetail{}, &bitbucketmcp.BitbucketError{Kind: bitbucketmcp.NotFound, Message: "not found on Bitbucket"}
	}
	d := bitbucketmcp.ItemDetail{Item: bitbucketmcp.Item{Repo: repo, Number: number, PR: pr, State: "open", Title: "Export",
		URL: "https://bitbucket.org/" + repo + "/issues/" + fmt.Sprint(number), UpdatedAt: "2026-11-07T10:00:00Z"},
		Body: "The body.", Thread: []bitbucketmcp.Comment{{Author: "renovate-bot", Body: "Hi", At: "2026-11-07T09:00:00Z", Bot: true}}, Before: "2"}
	if pr {
		d.Checks, d.Review, d.Mergeable = "failing", "approved", "mergeable"
		d.CheckRuns = []bitbucketmcp.CheckRun{
			{Name: "Pipeline #12", State: "failing", URL: "https://bitbucket.org/x/pipelines/results/12", Run: 12},
			{Name: "Pipeline #12 again", State: "failing", URL: "https://bitbucket.org/x/pipelines/results/12", Run: 12},
			{Name: "jenkins", State: "failing", URL: "https://ci.example/3"},
			{Name: "Pipeline #11", State: "passing", Run: 11},
		}
		d.Head, d.FilesChanged, d.ReviewThreads = "abc123def456", 2, 1
	}
	return d, nil
}

func (f *fakeForgeBitbucket) Comment(_ context.Context, repo string, number int, pr bool, body string) (string, error) {
	f.note(&f.wrote, fmt.Sprintf("comment %s#%d pr=%v %s", repo, number, pr, body))
	return "https://bitbucket.org/c/1", nil
}

func (f *fakeForgeBitbucket) SetLabels(_ context.Context, repo string, number int, add, remove []string) error {
	f.note(&f.wrote, fmt.Sprintf("labels %s#%d +%v -%v", repo, number, add, remove))
	return nil
}

func (f *fakeForgeBitbucket) SetState(_ context.Context, repo string, number int, pr, closed bool) error {
	f.note(&f.wrote, fmt.Sprintf("state %s#%d pr=%v closed=%v", repo, number, pr, closed))
	return nil
}

func (f *fakeForgeBitbucket) RepoLabels(context.Context, string) ([]string, error) {
	return []string{"bug", "enhancement", "ui"}, nil
}

func (f *fakeForgeBitbucket) MergeMethods(context.Context, string, int) ([]string, error) {
	return []string{"squash", "merge"}, nil
}

func (f *fakeForgeBitbucket) Merge(_ context.Context, repo string, number int, sha, method string) error {
	f.note(&f.wrote, fmt.Sprintf("merge %s#%d %s %s", repo, number, sha, method))
	return nil
}

func (f *fakeForgeBitbucket) Approve(_ context.Context, repo string, number int, sha string) (string, error) {
	f.note(&f.wrote, fmt.Sprintf("approve %s#%d %s", repo, number, sha))
	return "https://bitbucket.org/" + repo + "/pull-requests/8", nil
}

func (f *fakeForgeBitbucket) PRDiff(context.Context, string, int) (map[string]any, error) {
	return map[string]any{"files": []any{map[string]any{"path": "hello.txt", "change": "added", "additions": 1, "deletions": 0,
		"hunks": []any{map[string]any{"oldStart": 0, "newStart": 1, "lines": []any{map[string]any{"kind": "added", "text": "hello"}}}}}}}, nil
}

func (f *fakeForgeBitbucket) RetryPipeline(_ context.Context, repo string, run int) (map[string]any, error) {
	f.note(&f.wrote, fmt.Sprintf("retry %s %d", repo, run))
	return map[string]any{"url": fmt.Sprintf("https://bitbucket.org/%s/pipelines/results/%d", repo, run+1)}, nil
}

func (f *fakeForgeBitbucket) FailedLog(_ context.Context, repo string, run int, step string) (string, error) {
	return fmt.Sprintf("log of %s %d %q", repo, run, step), nil
}

// bitbucketDaemon is a daemon with a folder on Bitbucket Cloud and one on GitHub, with a
// Bitbucket connection (an API token and its email) as a fake Bitbucket.
func bitbucketDaemon(t *testing.T) (*Daemon, *conn, *fakeForgeBitbucket, *connections.File) {
	t.Helper()
	t.Setenv("AGENTS_PERSONAL_HOME", t.TempDir())
	d, c := start(t, t.TempDir())
	t.Cleanup(d.Shutdown)
	file := &connections.File{Path: filepath.Join(t.TempDir(), ".agents-secrets", connections.FileName)}
	d.connStoreFor = func() (connections.Store, error) { return file, nil }
	bb := &fakeForgeBitbucket{}
	d.newForgeBitbucket = func(root, email, token string) forgeBitbucket {
		if root != bitbucketmcp.DefaultBase || email != "me@example.com" || token != "bb-secret" {
			t.Errorf("Bitbucket at %q with %q and %q", root, email, token)
		}
		return bb
	}
	d.newForgeGitHub = func(string) forgeGitHub { return &fakeForgeGitHub{} }
	for i, remote := range []string{"git@bitbucket.org:walkalex/App.git", "git@github.com:alexec/agents.git"} {
		c.call(t, 100+i, "folders/add", map[string]any{"folder": "file://" + gitFolder(t, remote)})
	}
	file.Put(connections.BitbucketConnection(connections.BitbucketAPI, "me@example.com", "bb-secret", "walkalex", time.Now()))
	file.Put(connections.Connection{Provider: connections.GitHub, Login: "alexec", Access: "ghu_secret",
		AccessExpiresAt: time.Now().Add(time.Hour), ConnectedAt: time.Now()})
	return d, c, bb, file
}

// #3786: forge/issues and forge/pulls list the repositories on Bitbucket with the GitHub
// folder's.
func TestForgeListsBitbucketRepositories(t *testing.T) {
	_, c, bb, _ := bitbucketDaemon(t)
	var list wire.ForgeList
	json.Unmarshal(c.call(t, 1, "forge/issues", wire.ForgeListRequest{Label: new("bug")}), &list)
	if len(bb.searches) != 1 || bb.searches[0] != "[walkalex/App] prs=false label=bug after= first=50" {
		t.Fatalf("Bitbucket was asked %v", bb.searches)
	}
	var item *wire.ForgeItem
	for _, i := range list.Items {
		if strings.HasPrefix(i.Node.Ref, "bitbucket:") {
			item = &i
		}
	}
	if item == nil || item.Node != (wire.LineageNode{Kind: "issue", Ref: "bitbucket:walkalex/app#7"}) || deref(item.Folder) == "" ||
		item.Labels[0].Name != "bug" || item.Labels[0].Color != nil || item.UpdatedAt == 0 || len(list.Errors) != 0 {
		t.Fatalf("the Bitbucket item: %+v in %+v", item, list)
	}
	var pulls wire.ForgeList
	json.Unmarshal(c.call(t, 2, "forge/pulls", wire.ForgeListRequest{}), &pulls)
	found := false
	for _, i := range pulls.Items {
		if i.Node.Ref == "bitbucket:walkalex/app#7" {
			found = true
			if i.Node.Kind != "pr" || deref(i.Mergeable) != "unknown" || i.AutoMerge == nil || *i.AutoMerge {
				t.Fatalf("a Bitbucket pull request: %+v", i)
			}
		}
	}
	if !found {
		t.Fatalf("no Bitbucket pull request in %+v", pulls)
	}
}

// Without a Bitbucket connection the list says so for Bitbucket, and still lists GitHub's.
func TestForgeListSaysBitbucketIsNotConnected(t *testing.T) {
	_, c, bb, file := bitbucketDaemon(t)
	file.Delete(connections.Bitbucket)
	var list wire.ForgeList
	json.Unmarshal(c.call(t, 1, "forge/issues", wire.ForgeListRequest{}), &list)
	if len(bb.searches) != 0 || len(list.Errors) != 1 || list.Errors[0].Forge != "bitbucket" || list.Errors[0].Message != bitbucketmcp.NotConnected {
		t.Fatalf("list: %+v", list)
	}
}

// forge/issue and forge/pull read a Bitbucket item in the repository as its folder's remote
// says it; Start Agent names the issue; one Bitbucket does not have, or no folder is on, is
// refused.
func TestForgeReadsABitbucketIssueAndPullRequest(t *testing.T) {
	_, c, bb, _ := bitbucketDaemon(t)
	var issue wire.ForgeItemDetail
	json.Unmarshal(c.call(t, 1, "forge/issue", wire.ForgeItemRequest{Node: wire.LineageNode{Kind: "issue", Ref: "bitbucket:walkalex/app#7"}}), &issue)
	if issue.Body != "The body." || deref(issue.Cursor) != "2" || len(issue.Comments) != 1 || issue.Start == nil ||
		!strings.Contains(issue.Start.Prompt, "Work on this Bitbucket issue: https://bitbucket.org/walkalex/App/issues/7") || issue.Start.Labels[0] != "#7" {
		t.Fatalf("issue: %+v", issue)
	}
	var pr wire.ForgeItemDetail
	json.Unmarshal(c.call(t, 2, "forge/pull", wire.ForgeItemRequest{Node: wire.LineageNode{Kind: "pr", Ref: "bitbucket:walkalex/app#8"}}), &pr)
	if deref(pr.Head) != "abc123def456" || len(pr.Checks) != 4 || *pr.FilesChanged != 2 || len(pr.MergeMethods) != 2 || pr.MergeMethods[0] != "squash" ||
		deref(pr.Item.Review) != "approved" || pr.Start != nil {
		t.Fatalf("pull: %+v", pr)
	}
	if bb.items[0] != "walkalex/App#7 pr=false before=" || bb.items[1] != "walkalex/App#8 pr=true before=" {
		t.Fatalf("Bitbucket was asked %v", bb.items)
	}
	for i, n := range []wire.LineageNode{
		{Kind: "issue", Ref: "bitbucket:walkalex/app#404"},
		{Kind: "issue", Ref: "bitbucket:kim/notes#1"},
		{Kind: "issue", Ref: "bitbucket:nobody#1"},
	} {
		if e := c.callError(t, 10+i, "forge/issue", wire.ForgeItemRequest{Node: n}); e == nil || !strings.Contains(e.Message, "forge/issue") {
			t.Fatalf("%s: %v", n.Ref, e)
		}
	}
}

// The Work pages' writes on a Bitbucket item go to Bitbucket; a merge takes the branch's
// default method and refuses a merge when checks pass; rerun runs each failed Pipelines run
// once; a pull request has no labels.
func TestForgeWritesOnABitbucketItem(t *testing.T) {
	_, c, bb, _ := bitbucketDaemon(t)
	issue := wire.LineageNode{Kind: "issue", Ref: "bitbucket:walkalex/app#7"}
	pr := wire.LineageNode{Kind: "pr", Ref: "bitbucket:walkalex/app#8"}
	var done wire.ForgeDone
	json.Unmarshal(c.call(t, 1, "forge/comment", wire.ForgeCommentRequest{Node: issue, Body: "Done"}), &done)
	if deref(done.URL) != "https://bitbucket.org/c/1" {
		t.Fatalf("comment: %+v", done)
	}
	c.call(t, 2, "forge/comment", wire.ForgeCommentRequest{Node: pr, Body: "LGTM"})
	c.call(t, 3, "forge/label", wire.ForgeLabelRequest{Node: issue, Add: []string{"enhancement"}, Remove: []string{"bug"}})
	c.call(t, 4, "forge/close", wire.ForgeCloseRequest{Node: issue})
	c.call(t, 5, "forge/close", wire.ForgeCloseRequest{Node: pr})
	c.call(t, 6, "forge/merge", wire.ForgeMergeRequest{Node: pr, Sha: "abc123def456"})
	c.call(t, 7, "forge/approve", wire.ForgeApproveRequest{Node: pr, Sha: "abc123def456"})
	var rerun wire.ForgeDone
	json.Unmarshal(c.call(t, 8, "forge/rerun", wire.ForgeNodeRequest{Node: pr}), &rerun)
	want := []string{"comment walkalex/App#7 pr=false Done", "comment walkalex/App#8 pr=true LGTM",
		"labels walkalex/App#7 +[enhancement] -[bug]", "state walkalex/App#7 pr=false closed=true", "state walkalex/App#8 pr=true closed=true",
		"merge walkalex/App#8 abc123def456 squash", "approve walkalex/App#8 abc123def456", "retry walkalex/App 12"}
	if strings.Join(bb.wrote, "\n") != strings.Join(want, "\n") {
		t.Fatalf("wrote %q", bb.wrote)
	}
	if rerun.Reran == nil || *rerun.Reran != 1 || deref(rerun.URL) != "https://bitbucket.org/walkalex/App/pipelines/results/13" {
		t.Fatalf("rerun: %+v", rerun)
	}
	if e := c.callError(t, 9, "forge/merge", wire.ForgeMergeRequest{Node: pr, Sha: "abc123def456", Method: new(wire.ForgeMergeMethodRebase)}); e == nil ||
		!strings.Contains(e.Message, "squash or merge") {
		t.Fatalf("a method the branch does not allow: %v", e)
	}
	if e := c.callError(t, 10, "forge/merge", wire.ForgeMergeRequest{Node: pr, Sha: "abc123def456", Auto: new(true)}); e == nil ||
		!strings.Contains(e.Message, "cannot merge when checks pass") {
		t.Fatalf("auto-merge: %v", e)
	}
	if e := c.callError(t, 11, "forge/label", wire.ForgeLabelRequest{Node: pr, Add: []string{"bug"}}); e == nil || !strings.Contains(e.Message, "no labels") {
		t.Fatalf("a pull request's label: %v", e)
	}
	var log wire.ForgeLog
	json.Unmarshal(c.call(t, 12, "forge/log", wire.ForgeLogRequest{Node: pr}), &log)
	if log.Text != `log of walkalex/App 12 ""` {
		t.Fatalf("log: %+v", log)
	}
	json.Unmarshal(c.call(t, 13, "forge/log", wire.ForgeLogRequest{Node: pr, Check: new("jenkins")}), &log)
	if !strings.Contains(log.Text, "jenkins is not a Bitbucket Pipelines run") {
		t.Fatalf("another CI's log: %+v", log)
	}
	var labels wire.ForgeLabels
	json.Unmarshal(c.call(t, 14, "forge/labels", wire.ForgeNodeRequest{Node: issue}), &labels)
	if len(labels.Labels) != 3 || labels.Labels[2].Name != "ui" {
		t.Fatalf("labels: %+v", labels)
	}
	var diff wire.ForgeDiff
	json.Unmarshal(c.call(t, 15, "forge/diff", wire.ForgeNodeRequest{Node: pr}), &diff)
	if len(diff.Files) != 1 || diff.Files[0].Path != "hello.txt" || len(diff.Files[0].Hunks[0].Lines) != 1 {
		t.Fatalf("diff: %+v", diff)
	}
}

func TestBitbucketOfNode(t *testing.T) {
	for ref, want := range map[string]string{
		"bitbucket:walkalex/app#7": "walkalex/app 7",
		"bitbucket:a/b#0":          "",
		"bitbucket:a#1":            "",
		"bitbucket:a/b/c#1":        "",
		"bitbucket:/b#1":           "",
		"forgejo:a/b#1":            "",
	} {
		repo, n, ok := bitbucketOfNode(wire.LineageNode{Kind: "issue", Ref: ref})
		got := ""
		if ok {
			got = fmt.Sprintf("%s %d", repo, n)
		}
		if got != want {
			t.Errorf("%s: %q, want %q", ref, got, want)
		}
	}
}
