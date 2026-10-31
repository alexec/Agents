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
	details, err := g.RunDetails(context.Background(), repo, runs[0])
	if err != nil {
		t.Fatal(err)
	}
	equal(t, details.PR, PR{Number: 9, Title: "From a fork", Branch: "fork/main", URL: "p9"}, "a fork's PR is found by its commit")
	equal(t, details.FailedJobs, []Job{{Name: "test", URL: "j"}}, "failed jobs only")
	equal(t, details.Trusted, false, "a first-time contributor is not one of the repo's own")
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
