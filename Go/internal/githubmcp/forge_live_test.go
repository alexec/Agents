//go:build live

package githubmcp

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"slices"
	"testing"
	"time"
)

// The forge's reads, writes and plans on a real GitHub (#3412), run by hand, never by CI:
//
//	AGENTS_LIVE_GITHUB_TOKEN=$(gh auth token) go test -tags live -run Live -v ./internal/githubmcp/
//
// AGENTS_LIVE_GITHUB_REPO is a test repo (alexec/agents-walk when empty). The test opens an epic
// and two children, a branch and a pull request, merges it, and closes every issue it opened.
// The merged pull request's number is in the log, for the cost comment's live test (agentsd).

func liveGitHub(t *testing.T) (*RealGitHub, string) {
	t.Helper()
	token := os.Getenv("AGENTS_LIVE_GITHUB_TOKEN")
	if token == "" {
		t.Skip("AGENTS_LIVE_GITHUB_TOKEN is not set")
	}
	repo := os.Getenv("AGENTS_LIVE_GITHUB_REPO")
	if repo == "" {
		repo = "alexec/agents-walk"
	}
	g := NewRealGitHub("", func() string { return token }, func(context.Context) (string, error) { return repo, nil })
	return g, repo
}

func TestLiveGitHubForge(t *testing.T) {
	g, repo := liveGitHub(t)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	stamp := time.Now().UTC().Format("2006-01-02 15:04")
	var opened []int
	t.Cleanup(func() {
		for _, n := range opened {
			if err := g.SetState(context.Background(), repo, n, true); err != nil {
				t.Errorf("close #%d: %v", n, err)
			}
		}
	})

	// The plan (#3265, #3271): an epic, two children, the second blocked by the first.
	epic, url, err := g.CreateIssue(ctx, repo, "Live #3412: an epic ("+stamp+")", []string{"epic"})
	if err != nil {
		t.Fatalf("create the epic: %v", err)
	}
	opened = append(opened, epic)
	t.Logf("epic %s", url)
	var kids []int
	for _, name := range []string{"first", "second"} {
		n, _, err := g.CreateIssue(ctx, repo, "Live #3412: the "+name+" child ("+stamp+")", []string{"task"})
		if err != nil {
			t.Fatalf("create a child: %v", err)
		}
		opened = append(opened, n)
		kids = append(kids, n)
		if err := g.AddSubIssue(ctx, repo, epic, repo, n); err != nil {
			t.Fatalf("add #%d to the epic: %v", n, err)
		}
	}
	if err := g.SetBlockedBy(ctx, repo, kids[1], repo, kids[0], true); err != nil {
		t.Fatalf("blocked by: %v", err)
	}
	plan, err := g.Plan(ctx, repo, epic)
	if err != nil {
		t.Fatalf("plan: %v", err)
	}
	if len(plan.Children) != 2 || plan.Children[0].Number != kids[0] || plan.Children[1].Number != kids[1] {
		t.Fatalf("the plan's children = %+v, want #%d and #%d", plan.Children, kids[0], kids[1])
	}
	if b := plan.Children[1].BlockedBy; len(b) != 1 || b[0].Number != kids[0] || !b[0].Open {
		t.Fatalf("the second child's blockers = %+v, want the open #%d", b, kids[0])
	}
	if err := g.SetBlockedBy(ctx, repo, kids[1], repo, kids[0], false); err != nil {
		t.Fatalf("not blocked by: %v", err)
	}
	if plan, err = g.Plan(ctx, repo, epic); err != nil || len(plan.Children[1].BlockedBy) != 0 {
		t.Fatalf("after the blocker went: %+v, %v", plan.Children, err)
	}

	// The writes (#3130) on the epic: a comment, labels, close and reopen.
	if _, err := g.CommentOnPR(ctx, repo, epic, "<!-- agent -->\nA comment from the forge's live test (#3412)."); err != nil {
		t.Fatalf("comment: %v", err)
	}
	if err := g.SetLabels(ctx, repo, epic, []string{"live-3412"}, []string{"epic"}); err != nil {
		t.Fatalf("labels: %v", err)
	}
	if err := g.SetState(ctx, repo, epic, true); err != nil {
		t.Fatalf("close: %v", err)
	}
	if err := g.SetState(ctx, repo, epic, false); err != nil {
		t.Fatalf("reopen: %v", err)
	}
	labels, _, err := g.RepoLabels(ctx, repo)
	if err != nil || !slices.Contains(labels, "live-3412") {
		t.Fatalf("the repo's labels = %v, %v; want live-3412", labels, err)
	}

	// The reads (#3129): the epic in a search, and its own page with the comment.
	// GitHub's search index is up to a minute late.
	var page SearchPage
	for range 20 {
		if page, err = g.Search(ctx, []string{repo}, SearchFilter{Label: "live-3412"}, "", 10); err != nil {
			t.Fatalf("search: %v", err)
		}
		if slices.ContainsFunc(page.Items, func(i Item) bool { return i.Number == epic }) {
			break
		}
		time.Sleep(5 * time.Second)
	}
	if !slices.ContainsFunc(page.Items, func(i Item) bool { return i.Number == epic }) {
		t.Fatalf("the search found %+v, not #%d", page.Items, epic)
	}
	item, err := g.ItemPage(ctx, repo, epic, "")
	if err != nil {
		t.Fatalf("the epic's page: %v", err)
	}
	if item.State != "open" || len(item.Thread) != 1 || !slices.Contains(item.Labels, "live-3412") || item.SubTotal != 2 {
		t.Fatalf("the epic's page = %+v", item)
	}

	// A pull request: a branch with one file, opened, read, its diff, and merged by squash.
	branch := "live-3412/" + time.Now().UTC().Format("20060102-150405")
	var head struct {
		Object struct{ SHA string } `json:"object"`
	}
	if err := g.get(ctx, "repos/"+repo+"/git/ref/heads/main", false, &head); err != nil {
		t.Fatalf("main's head: %v", err)
	}
	send := func(method, path string, v any, into any) {
		t.Helper()
		body, _ := json.Marshal(v)
		out, err := g.do(ctx, method, path, body, false)
		if err != nil {
			t.Fatalf("%s %s: %v", method, path, err)
		}
		if into != nil {
			json.Unmarshal(out, into)
		}
	}
	send(http.MethodPost, "repos/"+repo+"/git/refs", map[string]string{"ref": "refs/heads/" + branch, "sha": head.Object.SHA}, nil)
	send(http.MethodPut, "repos/"+repo+"/contents/live/3412-"+branch[len("live-3412/"):]+".md", map[string]string{
		"message": "Live #3412: a file to merge", "branch": branch,
		"content": base64.StdEncoding.EncodeToString([]byte("Written by the forge's live test (#3412) at " + stamp + ".\n")),
	}, nil)
	var pr struct{ Number int }
	send(http.MethodPost, "repos/"+repo+"/pulls", map[string]string{"title": "Live #3412: a pull request to merge (" + stamp + ")",
		"head": branch, "base": "main", "body": "Opened and merged by the forge's live test (#3412)."}, &pr)
	t.Logf("pull request #%d", pr.Number)
	var detail ItemDetail
	for range 10 {
		if detail, err = g.ItemPage(ctx, repo, pr.Number, ""); err == nil && detail.Head != "" && detail.Mergeable != "unknown" {
			break
		}
		time.Sleep(2 * time.Second)
	}
	if err != nil || !detail.PR || detail.Head == "" || detail.FilesChanged != 1 || len(detail.MergeMethods) == 0 {
		t.Fatalf("the pull request's page = %+v, %v", detail, err)
	}
	diff, err := g.PRDiff(ctx, repo, pr.Number, detail.Head)
	if err != nil {
		t.Fatalf("diff: %v", err)
	}
	if fmt.Sprint(diff["files"]) == "[]" {
		t.Fatalf("the diff has no files: %v", diff)
	}
	if _, err := g.MergeBy(ctx, repo, pr.Number, detail.Head, "squash", false); err != nil {
		t.Fatalf("merge: %v", err)
	}
	merged, err := g.ItemPage(ctx, repo, pr.Number, "")
	if err != nil || merged.State != "merged" {
		t.Fatalf("after the merge: %+v, %v", merged.Item, err)
	}
	t.Logf("merged pull request #%d: AGENTS_LIVE_GITHUB_PR=%d", pr.Number, pr.Number)
}

// TestLiveGitHubFailedLog reads the log of the newest failed Actions run in the test repo, as
// the Work pages' log and Fix failed checks do.
func TestLiveGitHubFailedLog(t *testing.T) {
	g, repo := liveGitHub(t)
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	var runs struct {
		WorkflowRuns []struct {
			ID      int    `json:"id"`
			HTMLURL string `json:"html_url"`
		} `json:"workflow_runs"`
	}
	if err := g.get(ctx, "repos/"+repo+"/actions/runs?status=failure&per_page=1", false, &runs); err != nil {
		t.Fatalf("the failed runs: %v", err)
	}
	if len(runs.WorkflowRuns) == 0 {
		t.Skip("the test repo has no failed run")
	}
	run := runs.WorkflowRuns[0]
	text, err := g.FailedLog(ctx, repo, run.ID, "")
	if err != nil {
		t.Fatalf("the log of %s: %v", run.HTMLURL, err)
	}
	if len(text) < 40 {
		t.Fatalf("the log of %s is %q", run.HTMLURL, text)
	}
	t.Logf("%s: %d bytes of log", run.HTMLURL, len(text))
}
