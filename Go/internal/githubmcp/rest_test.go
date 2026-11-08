package githubmcp

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"testing/iotest"
	"time"
)

// RealGitHub against a fake of GitHub's API: what it reads, who it trusts (#728), its ETags
// and the listings it shares (#932).

type fakeAPI struct {
	*httptest.Server
	hits   map[string]*atomic.Int32
	status int
	header http.Header
}

func newFakeAPI(t *testing.T, routes map[string]string) *fakeAPI {
	f := &fakeAPI{hits: map[string]*atomic.Int32{}}
	for path := range routes {
		f.hits[path] = &atomic.Int32{}
	}
	f.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer token" {
			t.Errorf("%s without the token", r.URL)
		}
		if f.status != 0 {
			for k, v := range f.header {
				w.Header()[k] = v
			}
			w.WriteHeader(f.status)
			_, _ = io.WriteString(w, `{"message":"API rate limit exceeded"}`)
			return
		}
		path := strings.TrimPrefix(r.URL.Path, "/")
		body, ok := routes[path]
		if !ok {
			http.NotFound(w, r)
			return
		}
		f.hits[path].Add(1)
		w.Header().Set("ETag", `"v1"`)
		if r.Header.Get("If-None-Match") == `"v1"` {
			w.WriteHeader(http.StatusNotModified)
			return
		}
		_, _ = io.WriteString(w, body)
	}))
	t.Cleanup(f.Close)
	return f
}

func (f *fakeAPI) github() *RealGitHub {
	return NewRealGitHub(f.URL, func() string { return "token" }, func(context.Context) (string, error) { return repo, nil })
}

func TestFailedRunsAndTheirDetails(t *testing.T) {
	since := "2026-10-16T10:00:00.000Z"
	api := newFakeAPI(t, map[string]string{
		"repos/" + repo + "/actions/runs": `{"workflow_runs": [
			{"id": 2, "run_attempt": 1, "name": "CI", "html_url": "u2", "head_sha": "s2", "head_branch": "fork/main", "status": "completed",
			 "conclusion": "failure", "updated_at": "2026-10-16T10:05:00Z", "created_at": "2026-10-16T10:00:00Z", "pull_requests": []},
			{"id": 1, "run_attempt": 2, "name": "CI", "html_url": "u1", "head_sha": "s1", "head_branch": "agents/a", "status": "completed",
			 "conclusion": "timed_out", "updated_at": "2026-10-16T10:01:00Z", "created_at": "2026-10-15T10:00:00Z", "pull_requests": [{"number": 7}]},
			{"id": 0, "status": "completed", "conclusion": "failure", "updated_at": "2026-10-16T09:00:00Z"}]}`,
		"repos/" + repo + "/commits/s2/pulls":    `[{"number": 9, "head": {"ref": "fork/main"}}]`,
		"repos/" + repo + "/actions/runs/2/jobs": `{"jobs": [{"name": "test", "html_url": "j", "conclusion": "failure"}, {"name": "lint", "conclusion": "success"}]}`,
		"repos/" + repo + "/pulls/9": `{"number": 9, "title": "From a fork", "html_url": "p9", "head": {"ref": "fork/main", "repo": {"full_name": "stranger/agents"}},
			"user": {"login": "stranger"}, "author_association": "FIRST_TIME_CONTRIBUTOR"}`,
	})
	g := api.github()
	runs, truncated, err := g.FailedRuns(context.Background(), repo, "", since)
	if err != nil || truncated {
		t.Fatal(err, truncated)
	}
	equal(t, len(runs), 2, "runs since")
	equal(t, runs[1], RunRef{ID: 1, Attempt: 2, Name: "CI", URL: "u1", HeadSHA: "s1", Branch: "agents/a", PRNumber: 7,
		UpdatedAt: "2026-10-16T10:01:00Z"}, "run")
	details, err := g.RunDetails(context.Background(), repo, runs[0], true)
	if err != nil {
		t.Fatal(err)
	}
	equal(t, details.PR, PR{Number: 9, Title: "From a fork", Branch: "fork/main", URL: "p9", Author: "stranger"}, "a fork's PR is found by its commit")
	equal(t, details.FailedJobs, []Job{{Name: "test", URL: "j"}}, "failed jobs only")
	equal(t, details.Trusted, false, "a first-time contributor is not one of the repo's own")
}

func TestRunDetailsWithoutJobsAndPRBranchAskOnce(t *testing.T) {
	api := newFakeAPI(t, map[string]string{
		"repos/" + repo + "/actions/runs/3/jobs": `{"jobs": []}`,
		"repos/" + repo + "/pulls/11": `{"number": 11, "title": "Green", "html_url": "p11", "head": {"ref": "agents/b", "repo": {"full_name": "` + repo + `"}},
			"user": {"login": "alexec"}, "author_association": "OWNER"}`,
	})
	g := api.github()
	run := RunRef{ID: 3, Attempt: 1, HeadSHA: "s3", Branch: "agents/b", PRNumber: 11}
	details, err := g.RunDetails(context.Background(), repo, run, false)
	if err != nil {
		t.Fatal(err)
	}
	equal(t, details.PR.Number, 11, "the PR")
	equal(t, api.hits["repos/"+repo+"/actions/runs/3/jobs"].Load(), int32(0), "checks.passed fetches no jobs (#3107)")
	for range 3 {
		branch, err := g.PRBranch(context.Background(), repo, 11)
		if err != nil {
			t.Fatal(err)
		}
		equal(t, branch, "agents/b", "the PR's branch")
	}
	equal(t, api.hits["repos/"+repo+"/pulls/11"].Load(), int32(2), "the branch is asked once, after RunDetails' own GET")
}

func TestPassedRunsOnlyMatchesSuccess(t *testing.T) {
	since := "2026-10-16T10:00:00.000Z"
	api := newFakeAPI(t, map[string]string{
		"repos/" + repo + "/actions/runs": `{"workflow_runs": [
			{"id": 3, "run_attempt": 1, "name": "CI", "html_url": "u3", "head_sha": "s3", "head_branch": "agents/b", "status": "completed",
			 "conclusion": "success", "updated_at": "2026-10-16T10:05:00Z", "created_at": "2026-10-16T10:00:00Z", "pull_requests": [{"number": 11}]},
			{"id": 4, "run_attempt": 1, "name": "CI", "html_url": "u4", "head_sha": "s4", "head_branch": "agents/c", "status": "completed",
			 "conclusion": "failure", "updated_at": "2026-10-16T10:05:00Z", "created_at": "2026-10-16T10:00:00Z", "pull_requests": [{"number": 12}]}]}`,
	})
	g := api.github()
	runs, truncated, err := g.PassedRuns(context.Background(), repo, "", since)
	if err != nil || truncated {
		t.Fatal(err, truncated)
	}
	equal(t, runs, []RunRef{{ID: 3, Attempt: 1, Name: "CI", URL: "u3", HeadSHA: "s3", Branch: "agents/b", PRNumber: 11,
		UpdatedAt: "2026-10-16T10:05:00Z"}}, "only the successful run")
}

func TestCompletedRunsOfAWorkflowAndByID(t *testing.T) {
	since := "2026-10-16T10:00:00.000Z"
	api := newFakeAPI(t, map[string]string{
		"repos/" + repo + "/actions/workflows/release.yml/runs": `{"workflow_runs": [
			{"id": 5, "run_attempt": 1, "check_suite_id": 55, "name": "Release", "path": ".github/workflows/release.yml", "event": "push", "html_url": "u5",
			 "head_sha": "s5", "head_branch": "v0.16.0", "status": "completed", "conclusion": "success",
			 "updated_at": "2026-10-16T10:30:00Z", "created_at": "2026-10-16T09:00:00Z", "pull_requests": [],
			 "actor": {"login": "alexec", "type": "User"}, "head_repository": {"full_name": "` + repo + `"}},
			{"id": 6, "run_attempt": 1, "name": "Release", "path": ".github/workflows/release.yml", "event": "push",
			 "head_branch": "v0.16.0", "status": "in_progress", "updated_at": "2026-10-16T10:31:00Z", "created_at": "2026-10-16T09:30:00Z"},
			{"id": 7, "run_attempt": 1, "name": "Release", "path": ".github/workflows/release.yml", "event": "push",
			 "head_branch": "v0.15.0", "status": "completed", "conclusion": "success", "updated_at": "2026-10-15T10:00:00Z",
			 "created_at": "2026-10-15T09:00:00Z"}]}`,
		"repos/" + repo + "/actions/runs/8": `{"id": 8, "run_attempt": 2, "name": "Dependabot", "path": ".github/workflows/ci.yml",
			"event": "pull_request", "head_branch": "dependabot/x", "status": "completed", "conclusion": "failure",
			"updated_at": "2026-10-16T10:10:00Z", "triggering_actor": {"login": "dependabot[bot]", "type": "Bot"},
			"actor": {"login": "alexec", "type": "User"}}`,
	})
	g := api.github()
	runs, truncated, err := g.CompletedRuns(context.Background(), repo, "release.yml", "", 0, since)
	if err != nil || truncated {
		t.Fatal(err, truncated)
	}
	equal(t, runs, []CompletedRun{{Run: RunRef{ID: 5, Attempt: 1, Name: "Release", URL: "u5", HeadSHA: "s5", Branch: "v0.16.0",
		UpdatedAt: "2026-10-16T10:30:00Z"}, CheckSuite: 55, Workflow: "release.yml", Event: "push", Conclusion: "success", Actor: "alexec", Trusted: true}},
		"only the finished run since")
	byID, _, err := g.CompletedRuns(context.Background(), repo, "", "", 8, since)
	if err != nil {
		t.Fatal(err)
	}
	equal(t, len(byID), 1, "the run by its id")
	equal(t, byID[0].Actor, "dependabot[bot]", "the actor that started this attempt")
	equal(t, byID[0].Trusted, false, "a bot's run is not the repo's own")
}

// A run says what it deployed with a notice titled deploy (#3584): only check runs with
// annotations are read, and other notices, warnings and bad refs are left out.
func TestRunDeploysAreTheRunsDeployNotices(t *testing.T) {
	api := newFakeAPI(t, map[string]string{
		"repos/" + repo + "/check-suites/77/check-runs": `{"check_runs": [
			{"id": 1, "output": {"annotations_count": 0}},
			{"id": 2, "output": {"annotations_count": 4}}]}`,
		"repos/" + repo + "/check-runs/2/annotations": `[
			{"annotation_level": "notice", "title": "deploy", "message": "testflight:com.example.app/42\n"},
			{"annotation_level": "notice", "title": "deploy", "message": "testflight:com.example.app/42"},
			{"annotation_level": "warning", "title": "deploy", "message": "testflight:com.example.other/1"},
			{"annotation_level": "notice", "title": "deploy", "message": "not a ref"},
			{"annotation_level": "notice", "title": "Node 20 is deprecated", "message": "testflight:x/1"}]`,
	})
	g := api.github()
	deploys, err := g.RunDeploys(context.Background(), repo, CompletedRun{CheckSuite: 77})
	if err != nil {
		t.Fatal(err)
	}
	equal(t, deploys, []string{"testflight:com.example.app/42"}, "the deploy notice, once")
	equal(t, api.hits["repos/"+repo+"/check-runs/1/annotations"] == nil, true, "a job with no annotations is not read")
	none, err := g.RunDeploys(context.Background(), repo, CompletedRun{})
	equal(t, none, []string(nil), "no check suite, nothing read")
	equal(t, err, error(nil), "no error")
}

// A PR is the repo's own only from a branch of the repo, by one of its own: a collaborator's
// fork, or a fork since deleted, is not.
func TestAPRFromAForkIsNotTheReposOwn(t *testing.T) {
	head := func(r string) string {
		if r == "" {
			return `{"ref": "main", "repo": null}`
		}
		return `{"ref": "main", "repo": {"full_name": "` + r + `"}}`
	}
	api := newFakeAPI(t, map[string]string{"repos/" + repo + "/pulls": `[
		{"number": 1, "user": {"login": "alexec"}, "author_association": "OWNER", "head": ` + head("Alexec/Agents") + `},
		{"number": 2, "user": {"login": "friend"}, "author_association": "COLLABORATOR", "head": ` + head("friend/agents") + `},
		{"number": 3, "user": {"login": "gone"}, "author_association": "COLLABORATOR", "head": ` + head("") + `},
		{"number": 4, "user": {"login": "stranger"}, "author_association": "CONTRIBUTOR", "head": ` + head(repo) + `}]`})
	prs, err := api.github().OpenPRs(context.Background(), repo)
	if err != nil {
		t.Fatal(err)
	}
	got := []bool{}
	for _, p := range prs {
		got = append(got, p.Trusted)
	}
	equal(t, got, []bool{true, false, false, false}, "trusted")
}

func TestIssueActivityLeavesPullRequestsOutAndJudgesWhoDidIt(t *testing.T) {
	api := newFakeAPI(t, map[string]string{
		"repos/" + repo + "/issues/events": `[
			{"id": 3, "event": "closed", "actor": {"login": "stranger"}, "created_at": "2026-10-16T10:03:00Z",
			 "issue": {"number": 30, "user": {"login": "stranger"}, "author_association": "NONE", "state_reason": "not_planned"}},
			{"id": 2, "event": "labeled", "actor": {"login": "renovate[bot]", "type": "Bot"}, "label": {"name": "deps"}, "created_at": "2026-10-16T10:02:00Z",
			 "issue": {"number": 20, "user": {"login": "alexec"}, "author_association": "OWNER"}},
			{"id": 1, "event": "labeled", "actor": {"login": "alexec"}, "label": {"name": "bug"}, "created_at": "2026-10-16T10:01:00Z",
			 "issue": {"number": 10, "title": "T", "html_url": "i10", "user": {"login": "x"}, "labels": [{"name": "bug"}], "assignees": [{"login": "alexec"}]}},
			{"id": 4, "event": "labeled", "actor": {"login": "alexec"}, "created_at": "2026-10-16T10:01:00Z",
			 "issue": {"number": 11, "pull_request": {"url": "x"}}},
			{"id": 0, "event": "labeled", "created_at": "2026-10-16T09:00:00Z", "issue": {"number": 1}}]`,
		"repos/" + repo + "/issues/comments": `[
			{"id": 5, "html_url": "c5", "issue_url": "https://api.github.com/repos/` + repo + `/issues/50", "body": "hi", "user": {"login": "alexec"},
			 "author_association": "OWNER", "created_at": "2026-10-16T10:05:00Z"},
			{"id": 6, "issue_url": "https://api.github.com/repos/` + repo + `/issues/51", "user": {"login": "alexec"}, "created_at": "2026-10-16T10:05:00Z"}]`,
		"repos/" + repo + "/issues/50": `{"number": 50, "title": "An issue"}`,
		"repos/" + repo + "/issues/51": `{"number": 51, "pull_request": {"url": "x"}}`,
	})
	g := api.github()
	since := "2026-10-16T10:00:00.000Z"
	labels, _, err := g.IssueActivity(context.Background(), repo, IssueLabelled, since)
	if err != nil {
		t.Fatal(err)
	}
	equal(t, len(labels), 2, "a PR's label and one before since are left out")
	equal(t, labels[0].Trusted, false, "a bot")
	equal(t, labels[1].Trusted, true, "a person who can label")
	equal(t, labels[1].Issue, Issue{Number: 10, Title: "T", Author: "x", Labels: []string{"bug"}, URL: "i10", Assignees: []string{"alexec"}}, "issue")
	closes, _, _ := g.IssueActivity(context.Background(), repo, IssueClosed, since)
	equal(t, len(closes), 1, "closes")
	equal(t, closes[0].Reason, "not_planned", "the issue's reason")
	equal(t, closes[0].Trusted, false, "a stranger closing their own")
	comments, _, err := g.IssueActivity(context.Background(), repo, IssueCommented, since)
	if err != nil {
		t.Fatal(err)
	}
	equal(t, len(comments), 1, "a PR's comment is left out")
	equal(t, comments[0].Issue.Title, "An issue", "the comment's issue")
}

func TestPRLabelActivityLeavesIssuesOutAndJudgesWhoDidIt(t *testing.T) {
	api := newFakeAPI(t, map[string]string{
		"repos/" + repo + "/issues/events": `[
			{"id": 3, "event": "unlabeled", "actor": {"login": "alexec"}, "label": {"name": "needs-approval"}, "created_at": "2026-10-16T10:03:00Z",
			 "issue": {"number": 61, "title": "A UI change", "html_url": "p61", "pull_request": {"url": "x"}}},
			{"id": 2, "event": "labeled", "actor": {"login": "renovate[bot]", "type": "Bot"}, "label": {"name": "hold:v0.13.1"}, "created_at": "2026-10-16T10:02:00Z",
			 "issue": {"number": 62, "pull_request": {"url": "x"}}},
			{"id": 1, "event": "labeled", "actor": {"login": "alexec"}, "label": {"name": "needs-approval"}, "created_at": "2026-10-16T10:01:00Z",
			 "issue": {"number": 60, "title": "A UI change", "html_url": "p60", "pull_request": {"url": "x"}}},
			{"id": 4, "event": "labeled", "actor": {"login": "alexec"}, "label": {"name": "bug"}, "created_at": "2026-10-16T10:01:00Z",
			 "issue": {"number": 10, "title": "An issue"}},
			{"id": 0, "event": "labeled", "created_at": "2026-10-16T09:00:00Z", "issue": {"number": 1, "pull_request": {"url": "x"}}}]`,
	})
	g := api.github()
	since := "2026-10-16T10:00:00.000Z"
	labelled, _, err := g.PRLabelActivity(context.Background(), repo, PRLabelled, since)
	if err != nil {
		t.Fatal(err)
	}
	equal(t, len(labelled), 2, "an issue's label and one before since are left out")
	equal(t, labelled[0].Trusted, false, "a bot")
	equal(t, labelled[1].Trusted, true, "a person who can label")
	equal(t, labelled[1].PR, PR{Number: 60, Title: "A UI change", URL: "p60"}, "pr")
	unlabelled, _, err := g.PRLabelActivity(context.Background(), repo, PRUnlabelled, since)
	if err != nil {
		t.Fatal(err)
	}
	equal(t, len(unlabelled), 1, "unlabelled")
	equal(t, unlabelled[0].Label, "needs-approval", "label")
}

// #2838: pr.commented's reads: an issue's comment is left out, an agent's own (<!-- agent -->)
// is left out, and what is left gets the pull's branch and the commenter's trust.
func TestPRCommentsLeavesOutIssuesAndAgentsAndJudgesTheCommenter(t *testing.T) {
	api := newFakeAPI(t, map[string]string{
		"repos/" + repo + "/issues/comments": `[
			{"id": 60, "html_url": "c60", "issue_url": "https://api.github.com/repos/` + repo + `/issues/60", "body": "<!-- agent --> waiting",
			 "user": {"login": "alexec"}, "author_association": "OWNER", "created_at": "2026-10-28T10:05:00Z"},
			{"id": 61, "html_url": "c61", "issue_url": "https://api.github.com/repos/` + repo + `/issues/61", "body": "I approve, ship it",
			 "user": {"login": "alexec"}, "author_association": "OWNER", "created_at": "2026-10-28T10:04:00Z"},
			{"id": 62, "html_url": "c62", "issue_url": "https://api.github.com/repos/` + repo + `/issues/62", "body": "looks off to me",
			 "user": {"login": "stranger"}, "author_association": "NONE", "created_at": "2026-10-28T10:03:00Z"},
			{"id": 63, "html_url": "c63", "issue_url": "https://api.github.com/repos/` + repo + `/issues/63", "body": "a plain issue, not a PR",
			 "user": {"login": "alexec"}, "author_association": "OWNER", "created_at": "2026-10-28T10:02:00Z"}]`,
		"repos/" + repo + "/issues/60": `{"number": 60, "pull_request": {"url": "x"}}`,
		"repos/" + repo + "/issues/61": `{"number": 61, "pull_request": {"url": "x"}}`,
		"repos/" + repo + "/issues/62": `{"number": 62, "pull_request": {"url": "x"}}`,
		"repos/" + repo + "/issues/63": `{"number": 63}`,
		"repos/" + repo + "/pulls/60":  `{"number": 60, "title": "Waiting", "html_url": "u60", "head": {"ref": "agents/60"}}`,
		"repos/" + repo + "/pulls/61":  `{"number": 61, "title": "Approved", "html_url": "u61", "head": {"ref": "agents/61"}}`,
		"repos/" + repo + "/pulls/62":  `{"number": 62, "title": "Off", "html_url": "u62", "head": {"ref": "agents/62"}}`,
	})
	g := api.github()
	since := "2026-10-28T10:00:00.000Z"
	comments, _, err := g.PRComments(context.Background(), repo, since, 0)
	if err != nil {
		t.Fatal(err)
	}
	equal(t, len(comments), 4, "every comment, so the cursor moves past them all")
	equal(t, comments[0], PRComment{ID: 60, At: "2026-10-28T10:05:00Z", Other: true}, "the agent's own is left out")
	equal(t, comments[3], PRComment{ID: 63, At: "2026-10-28T10:02:00Z", Other: true}, "the plain issue's comment is left out")
	equal(t, comments[1].PR.Branch, "agents/61", "its PR's branch")
	equal(t, comments[1].Trusted, true, "alexec can approve")
	equal(t, comments[2].Author, "stranger", "the stranger's comment")
	equal(t, comments[2].Trusted, false, "a stranger is not trusted")
}

func TestAnUnchangedListingIsSharedThenAskedWithItsETag(t *testing.T) {
	path := "repos/" + repo + "/pulls"
	api := newFakeAPI(t, map[string]string{path: `[{"number": 1, "state": "open", "user": {"login": "alexec"}, "author_association": "OWNER", "head": {"ref": "a", "repo": {"full_name": "` + repo + `"}}}]`})
	g := api.github()
	for range 10 {
		if prs, err := g.OpenPRs(context.Background(), repo); err != nil || len(prs) != 1 || !prs[0].Trusted {
			t.Fatal(prs, err)
		}
	}
	equal(t, api.hits[path].Load(), int32(1), "ten polls inside the window fetch once")
	g.sharing = time.Nanosecond
	time.Sleep(time.Millisecond)
	if prs, err := g.OpenPRs(context.Background(), repo); err != nil || len(prs) != 1 {
		t.Fatal(prs, err)
	}
	equal(t, api.hits[path].Load(), int32(2), "after the window it asks again, and a 304 keeps the body")
}

func TestConflictsComeFromGraphQL(t *testing.T) {
	api := newFakeAPI(t, map[string]string{"graphql": `{"data": {"repository": {"pullRequests": {"nodes": [
		{"number": 1, "headRefName": "a", "mergeable": "CONFLICTING", "authorAssociation": "OWNER", "author": {"login": "alexec", "__typename": "User"}},
		{"number": 2, "mergeable": "MERGEABLE", "isCrossRepository": true, "authorAssociation": "OWNER", "author": {"login": "alexec", "__typename": "User"}},
		{"number": 3, "mergeable": "UNKNOWN", "authorAssociation": "NONE", "author": {"login": "stranger", "__typename": "User"}}]}}}}`})
	prs, err := api.github().ConflictPRs(context.Background(), repo)
	if err != nil {
		t.Fatal(err)
	}
	got := []string{}
	for _, p := range prs {
		if p.Conflicts == nil {
			got = append(got, fmt.Sprintf("%d:?", p.PR.Number))
		} else {
			got = append(got, fmt.Sprintf("%d:%v", p.PR.Number, *p.Conflicts))
		}
	}
	equal(t, got, []string{"1:true", "2:false", "3:?"}, "conflicts")
	equal(t, []bool{prs[0].Trusted, prs[1].Trusted, prs[2].Trusted}, []bool{true, false, false}, "only the repo's own, not a fork")
}

func TestRefusalsAreSignInRateLimitAndNotFound(t *testing.T) {
	api := newFakeAPI(t, map[string]string{})
	g := api.github()
	kind := func() *GitHubError {
		_, err := g.OpenPRs(context.Background(), repo)
		gh, _ := err.(*GitHubError)
		if gh == nil {
			t.Fatalf("got %v", err)
		}
		return gh
	}
	equal(t, kind().Kind, NotFound, "404")
	api.status = http.StatusUnauthorized
	equal(t, kind().Kind, NotSignedIn, "401")
	api.status, api.header = http.StatusForbidden, http.Header{"Retry-After": {"30"}}
	e := kind()
	equal(t, [2]any{e.Kind, e.RetryAfterMs}, [2]any{RateLimited, 30000}, "403 with Retry-After")
	none := NewRealGitHub(api.URL, func() string { return "" }, nil)
	_, err := none.OpenPRs(context.Background(), repo)
	if gh, _ := err.(*GitHubError); gh == nil || gh.Kind != NotSignedIn {
		t.Fatalf("no token: %v", err)
	}
}

func TestTheRepoIsReadFromTheGitRemote(t *testing.T) {
	for remote, want := range map[string]string{
		"https://github.com/alexec/agents-walk.git":   "alexec/agents-walk",
		"https://github.com/alexec/agents-walk":       "alexec/agents-walk",
		"git@github.com:alexec/agents-walk.git":       "alexec/agents-walk",
		"ssh://git@github.com/alexec/agents-walk.git": "alexec/agents-walk",
		"https://alexec@github.com/alexec/Agents.git": "alexec/Agents",
		"https://gitlab.com/alexec/agents-walk.git":   "",
		"git@github.com:alexec":                       "",
	} {
		got, ok := RepoOfRemote(remote)
		if got != want || ok != (want != "") {
			t.Errorf("%s: got %q %v, want %q", remote, got, ok, want)
		}
	}
}

func TestTheETagCacheHasAByteCap(t *testing.T) {
	g := NewRealGitHub("", func() string { return "token" }, nil)
	g.remember("big", `"v1"`, strings.Repeat("x", etagLargest+1))
	_, kept := g.etags["big"]
	equal(t, kept, false, "a body over the largest is not kept")
	equal(t, g.etagBytes, 0, "and holds no bytes")

	g.remember("listing", `"v1"`, "[]")
	g.remember("listing", `"v2"`, strings.Repeat("x", etagLargest+1))
	_, kept = g.etags["listing"]
	equal(t, kept, false, "a body grown too large drops its old copy")

	body := strings.Repeat("x", etagLargest)
	for i := range 2 * etagCap / etagLargest {
		g.remember(fmt.Sprintf("diff/%d", i), `"v1"`, body)
	}
	equal(t, g.etagBytes <= etagCap, true, "the cache holds no more than the cap")
	equal(t, len(g.etags), etagCap/etagLargest, "the newest bodies are kept")
	_, kept = g.etags["diff/0"]
	equal(t, kept, false, "the oldest is dropped first")
	_, kept = g.etags[fmt.Sprintf("diff/%d", 2*etagCap/etagLargest-1)]
	equal(t, kept, true, "the newest is kept")

	g.remember("diff/0", `"v1"`, "[]")
	g.remember("diff/0", `"v2"`, "[1]")
	equal(t, g.etags["diff/0"].etag, `"v2"`, "a path is kept once, with its newest ETag")
	equal(t, g.etagBytes, (etagCap/etagLargest-1)*etagLargest+3, "and its bytes are counted once")
}

func TestLastBytesKeepsOnlyTheEndFromAWholeLine(t *testing.T) {
	for _, c := range []struct {
		in, want string
		n        int
	}{
		{"one\ntwo\n", "one\ntwo\n", 16},
		{"one\ntwo\nthree\n", "three\n", 8},
		{strings.Repeat("ab\n", 1000) + "end\n", "ab\nend\n", 8},
		{"", "", 8},
	} {
		got, err := lastBytes(iotest.OneByteReader(strings.NewReader(c.in)), c.n)
		if err != nil {
			t.Fatal(err)
		}
		equal(t, string(got), c.want, fmt.Sprintf("the last %d bytes of %d", c.n, len(c.in)))
		got, _ = lastBytes(strings.NewReader(c.in), c.n)
		equal(t, string(got), c.want, fmt.Sprintf("the last %d bytes of %d in one read", c.n, len(c.in)))
	}
}

func TestAFailedLogReadsOnlyTheLogsEnd(t *testing.T) {
	var log strings.Builder
	for i := range 200_000 {
		fmt.Fprintf(&log, "\x1b[32m2026-10-19T00:00:00Z\x1b[0m step line %d\n", i)
	}
	log.WriteString("FAIL: the end\n")
	api := newFakeAPI(t, map[string]string{
		"repos/" + repo + "/actions/runs/9/jobs": `{"jobs": [{"id": 5, "name": "test", "html_url": "j", "conclusion": "failure"}]}`,
		"repos/" + repo + "/actions/jobs/5/logs": log.String(),
	})
	text, err := api.github().FailedLog(context.Background(), repo, 9, "")
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(text, "\n")
	equal(t, len(lines), logLines+1, "a heading and the last lines")
	equal(t, lines[len(lines)-1], "FAIL: the end", "the failure at the end")
	equal(t, lines[1], "2026-10-19T00:00:00Z step line 199701", "the first line kept, clean")
}

// #2349: the issues a PR's body closes, by GitHub's keywords, each once.
func TestClosingRefs(t *testing.T) {
	got := closingRefs("Fixes #12. Also closes alexec/Other#3, resolved: #12, fixes #0, and see #99.\nCloses #7")
	want := []string{"#12", "alexec/Other#3", "#7"}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("got %v, want %v", got, want)
		}
	}
	if j := (PR{Number: 1, Fixes: got}).json(); j["fixes"] == nil {
		t.Fatalf("no fixes in %v", j)
	}
	if j := (PR{Number: 1}).json(); j["fixes"] != nil {
		t.Fatalf("fixes with none: %v", j)
	}
}

// #3860: pr.reviewed's read: a person's Approve and Request changes, a comment with words;
// never a pending, dismissed or empty review, or one before since. A bot's is not trusted.
func TestPRReviewsKeepsPostedReviewsAndJudgesTheReviewer(t *testing.T) {
	api := newFakeAPI(t, map[string]string{"graphql": `{"data": {"repository": {"pullRequests": {"nodes": [
		{"number": 70, "title": "New control", "body": "Fixes #69", "headRefName": "agents/70", "url": "u70", "author": {"login": "alexec-agents"},
		 "reviews": {"nodes": [
			{"author": {"login": "alexec", "__typename": "User"}, "authorAssociation": "OWNER", "state": "APPROVED", "body": "", "url": "r1", "databaseId": 1, "submittedAt": "2026-11-07T10:05:00Z", "commit": {"oid": "h70"}},
			{"author": {"login": "alexec", "__typename": "User"}, "authorAssociation": "OWNER", "state": "CHANGES_REQUESTED", "body": "Move it left", "url": "r2", "databaseId": 2, "submittedAt": "2026-11-07T10:06:00Z", "commit": {"oid": "h70"}},
			{"author": {"login": "alexec", "__typename": "User"}, "authorAssociation": "OWNER", "state": "COMMENTED", "body": "", "databaseId": 3, "submittedAt": "2026-11-07T10:07:00Z"},
			{"author": {"login": "alexec", "__typename": "User"}, "authorAssociation": "OWNER", "state": "PENDING", "body": "draft", "databaseId": 4},
			{"author": {"login": "alexec", "__typename": "User"}, "authorAssociation": "OWNER", "state": "DISMISSED", "body": "", "databaseId": 5, "submittedAt": "2026-11-07T10:08:00Z"},
			{"author": {"login": "alexec", "__typename": "User"}, "authorAssociation": "OWNER", "state": "APPROVED", "body": "", "databaseId": 6, "submittedAt": "2026-11-06T10:00:00Z"},
			{"author": {"login": "coderabbitai", "__typename": "Bot"}, "authorAssociation": "NONE", "state": "COMMENTED", "body": "Actionable comments posted: 0", "databaseId": 7, "submittedAt": "2026-11-07T10:09:00Z"}]}},
		{"number": 71, "headRefName": "agents/71", "url": "u71", "author": {"login": "alexec"},
		 "reviews": {"nodes": [{"author": {"login": "alexec", "__typename": "User"}, "authorAssociation": "OWNER", "state": "APPROVED", "databaseId": 8, "submittedAt": "2026-11-07T10:10:00Z"}]}}]}}}}`})
	g := api.github()
	since := "2026-11-07T10:00:00.000Z"
	reviews, err := g.PRReviews(context.Background(), repo, since, 70)
	if err != nil {
		t.Fatal(err)
	}
	equal(t, len(reviews), 3, "approve, request changes and CodeRabbit's words")
	equal(t, reviews[0].State, "approved", "approve")
	equal(t, reviews[0].Commit, "h70", "its commit")
	equal(t, reviews[0].PR.Branch, "agents/70", "its PR")
	equal(t, reviews[0].PR.Fixes, []string{"#69"}, "its fixes")
	equal(t, reviews[0].Trusted, true, "Alex")
	equal(t, reviews[1].State, "changes_requested", "request changes")
	equal(t, reviews[1].Body, "Move it left", "body")
	equal(t, reviews[2].Author, "coderabbitai", "CodeRabbit")
	equal(t, reviews[2].Trusted, false, "a bot's review is not a person's")
	all, err := g.PRReviews(context.Background(), repo, since, 0)
	if err != nil {
		t.Fatal(err)
	}
	equal(t, len(all), 4, "every open PR's")
}

// #3860: the person's agents' bot opens the repo's own PRs; another bot does not.
func TestTheAgentsBotsPRIsTheReposOwn(t *testing.T) {
	equal(t, isOwnAuthor("CONTRIBUTOR", "alexec-agents[bot]", "Bot"), true, "REST's bot")
	equal(t, isOwnAuthor("NONE", "alexec-agents", "Bot"), true, "GraphQL's bot")
	equal(t, isOwnAuthor("NONE", "dependabot[bot]", "Bot"), false, "another bot")
	equal(t, isOwnAuthor("NONE", "some-agents", "User"), false, "a person named so")
	equal(t, isOwnAuthor("OWNER", "alexec", "User"), true, "the person")
	equal(t, isTrusted("CONTRIBUTOR", "alexec-agents[bot]", "Bot"), false, "the bot's comments are still the agents' own")
	equal(t, isTrustedActor("alexec-agents[bot]", "Bot", false, "", false), true, "the bot's labels")
}
