package githubmcp

import (
	"context"
	"errors"
	"net/http"
	"os/exec"
	"testing"
)

// The set-up's reads (#1336): the newest issue skips pull requests, a run says its outcome,
// the App's reach counts repositories, and GitHub's no is a refusal, not a failure to reach.
func TestTheSetUpsReads(t *testing.T) {
	api := newFakeAPI(t, map[string]string{
		"repos/" + repo + "/issues": `[{"number": 9, "title": "A pull request", "pull_request": {"url": "x"}},
			{"number": 8, "title": "Fix the walk", "html_url": "i8", "created_at": "2026-10-19T10:00:00Z"}]`,
		"repos/" + repo + "/pulls":          `[]`,
		"repos/" + repo + "/actions/runs":   `{"workflow_runs": [{"name": "CI", "head_branch": "main", "status": "completed", "conclusion": "success", "html_url": "r1"}]}`,
		"user/installations":                `{"installations": [{"id": 1, "app_slug": "someone-else"}, {"id": 2, "app_slug": "agents-loops"}]}`,
		"user/installations/2/repositories": `{"total_count": 2, "repositories": [{"full_name": "other/one"}, {"full_name": "` + repo + `"}]}`,
	})
	gh := api.github()
	ctx := context.Background()
	issue, err := gh.NewestIssue(ctx, repo)
	if err != nil || issue == nil || issue.Number != 8 || issue.Title != "Fix the walk" || issue.URL != "i8" {
		t.Fatalf("issue: %+v %v", issue, err)
	}
	if pull, err := gh.NewestPull(ctx, repo); err != nil || pull != nil {
		t.Fatalf("no pull requests: %+v %v", pull, err)
	}
	run, err := gh.LastRun(ctx, repo)
	if err != nil || run.Title != "CI on main" || run.Outcome != "passed" {
		t.Fatalf("run: %+v %v", run, err)
	}
	installed, count, err := gh.AppReach(ctx, repo, "agents-loops")
	if err != nil || !installed || count != 2 {
		t.Fatalf("reach: %v %d %v", installed, count, err)
	}
	if installed, _, _ := gh.AppReach(ctx, "someone/else", "agents-loops"); installed {
		t.Fatal("installed on a repository it is not on")
	}

	_, err = gh.NewestIssue(ctx, "private/hidden")
	var refusal *GitHubError
	if !errors.As(err, &refusal) || !refusal.Refused {
		t.Fatalf("404 is a refusal: %v", err)
	}
	api.status = http.StatusForbidden
	_, err = gh.LastRun(ctx, repo)
	if !errors.As(err, &refusal) || refusal.Kind != RateLimited {
		t.Fatalf("a 403 that says rate limit: %v", err)
	}
}

func TestTheRepoAFolderPushesTo(t *testing.T) {
	dir := t.TempDir()
	for _, args := range [][]string{{"init", "-q"}, {"remote", "add", "upstream", "https://gitlab.com/a/b.git"},
		{"remote", "add", "origin", "git@github.com:alexec/agents-walk.git"}} {
		if out, err := exec.Command("git", append([]string{"-C", dir}, args...)...).CombinedOutput(); err != nil {
			t.Fatalf("%v %s", err, out)
		}
	}
	if r, ok := RepoAt(context.Background(), dir); !ok || r != "alexec/agents-walk" {
		t.Fatalf("%q %v", r, ok)
	}
	if _, ok := RepoAt(context.Background(), t.TempDir()); ok {
		t.Fatal("a folder with no git")
	}
}
