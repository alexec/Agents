package githubmcp

import (
	"context"
	"encoding/json"
	"fmt"
	"reflect"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"
)

// CIWatcherTests.swift's event cases, over a fake GitHub held in memory.

const repo = "alexec/agents"

type fakeGitHub struct {
	mu         sync.Mutex
	runs       []fakeRun
	prs        map[int]*fakePR
	activity   []IssueActivity
	prLabels   []PRLabelActivity
	reviewed   []ReviewedPR
	rabbit     []CodeRabbitComment
	prComments []PRComment
	err        error
	noRepo     bool
	// reviews and assigned are what ask the connection's owner, alexec (#2034).
	reviews  []OpenPR
	assigned []Issue
}

func (f *fakeGitHub) Yours(context.Context, string) (Yours, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.err != nil {
		return Yours{}, f.err
	}
	y := Yours{Login: "alexec", Reviews: f.reviews, Assigned: f.assigned}
	for n, p := range f.prs {
		if p.state == "open" && p.author == y.Login {
			y.PRs = append(y.PRs, n)
		}
	}
	return y, nil
}

type fakeRun struct {
	ref        RunRef
	trusted    bool
	conclusion string
}

type fakePR struct {
	pr                 PR
	author             string
	draft, trusted     bool
	state              string // open, merged or closed
	mergedAt, closedAt string
	conflicts          *bool
}

func newFake() *fakeGitHub { return &fakeGitHub{prs: map[int]*fakePR{}} }

func (f *fakeGitHub) addPR(number int, branch string, edit func(*fakePR)) {
	f.mu.Lock()
	defer f.mu.Unlock()
	p := &fakePR{pr: PR{Number: number, Title: fmt.Sprintf("PR %d", number), Branch: branch,
		URL: fmt.Sprintf("https://github.com/%s/pull/%d", repo, number)}, author: "alexec", trusted: true, state: "open"}
	if edit != nil {
		edit(p)
	}
	f.prs[number] = p
}

func (f *fakeGitHub) edit(number int, edit func(*fakePR)) {
	f.mu.Lock()
	defer f.mu.Unlock()
	edit(f.prs[number])
}

func (f *fakeGitHub) addRun(id int, branch, at string, pr int, trusted bool) {
	f.addRunWith(id, branch, at, pr, trusted, "failure")
}

func (f *fakeGitHub) addPassedRun(id int, branch, at string, pr int, trusted bool) {
	f.addRunWith(id, branch, at, pr, trusted, "success")
}

func (f *fakeGitHub) addRunWith(id int, branch, at string, pr int, trusted bool, conclusion string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.runs = append(f.runs, fakeRun{RunRef{ID: id, Attempt: 1, Name: "CI", URL: fmt.Sprintf("https://github.com/%s/actions/runs/%d", repo, id),
		HeadSHA: fmt.Sprintf("sha%d", id), Branch: branch, PRNumber: pr, UpdatedAt: at}, trusted, conclusion})
}

func (f *fakeGitHub) addActivity(a IssueActivity) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.activity = append(f.activity, a)
}

func (f *fakeGitHub) addPRLabel(a PRLabelActivity) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.prLabels = append(f.prLabels, a)
}

func (f *fakeGitHub) addPRComment(c PRComment) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.prComments = append(f.prComments, c)
}

func (f *fakeGitHub) DefaultRepo(context.Context) (string, error) {
	if f.noRepo {
		return "", &GitHubError{Kind: NotFound, Message: "repo is needed: /tmp has no GitHub repo"}
	}
	return repo, nil
}

func (f *fakeGitHub) FailedRuns(_ context.Context, _, branch, since string) ([]RunRef, bool, error) {
	return f.runsWith(branch, since, "failure")
}

func (f *fakeGitHub) PassedRuns(_ context.Context, _, branch, since string) ([]RunRef, bool, error) {
	return f.runsWith(branch, since, "success")
}

func (f *fakeGitHub) runsWith(branch, since, conclusion string) ([]RunRef, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.err != nil {
		return nil, false, f.err
	}
	var out []RunRef
	for _, r := range f.runs {
		if r.conclusion == conclusion && (branch == "" || r.ref.Branch == branch) && !before(r.ref.UpdatedAt, since) {
			out = append(out, r.ref)
		}
	}
	return out, false, nil
}

func (f *fakeGitHub) RunDetails(_ context.Context, _ string, run RunRef) (*RunData, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	number := run.PRNumber
	if number == 0 {
		for _, p := range f.prs {
			if p.pr.Branch == run.Branch {
				number = p.pr.Number
			}
		}
	}
	p, ok := f.prs[number]
	if !ok {
		return nil, nil
	}
	return &RunData{PR: p.pr, HeadSHA: run.HeadSHA, Run: run,
		FailedJobs: []Job{{Name: "test", URL: run.URL + "/job/1"}}, Trusted: p.trusted}, nil
}

func (f *fakeGitHub) ClosedPRs(_ context.Context, _, since string) ([]MergedPR, []ClosedPR, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.err != nil {
		return nil, nil, false, f.err
	}
	var merged []MergedPR
	var closed []ClosedPR
	for _, p := range f.prs {
		switch {
		case p.state == "merged" && !before(p.mergedAt, since):
			merged = append(merged, MergedPR{PR: p.pr, MergedAt: p.mergedAt, MergeSHA: fmt.Sprintf("abc%d", p.pr.Number), Trusted: p.trusted})
		case p.state == "closed" && !before(p.closedAt, since):
			closed = append(closed, ClosedPR{PR: p.pr, ClosedAt: p.closedAt, Trusted: p.trusted})
		}
	}
	return merged, closed, false, nil
}

func (f *fakeGitHub) ConflictPRs(context.Context, string) ([]ConflictPR, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []ConflictPR
	for _, p := range f.prs {
		if p.state == "open" {
			out = append(out, ConflictPR{PR: p.pr, Conflicts: p.conflicts, Trusted: p.trusted})
		}
	}
	return out, nil
}

func (f *fakeGitHub) OpenPRs(context.Context, string) ([]OpenPR, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []OpenPR
	for _, p := range f.prs {
		if p.state == "open" {
			out = append(out, OpenPR{PR: p.pr, Author: p.author, Draft: p.draft, Trusted: p.trusted})
		}
	}
	return out, nil
}

func (f *fakeGitHub) IssueActivity(_ context.Context, _ string, kind IssueKind, since string) ([]IssueActivity, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.err != nil {
		return nil, false, f.err
	}
	var out []IssueActivity
	for _, a := range f.activity {
		if a.Kind == kind && !before(a.At, since) {
			out = append(out, a)
		}
	}
	return out, false, nil
}

func (f *fakeGitHub) PRLabelActivity(_ context.Context, _ string, kind PRLabelKind, since string) ([]PRLabelActivity, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.err != nil {
		return nil, false, f.err
	}
	var out []PRLabelActivity
	for _, a := range f.prLabels {
		if a.Kind == kind && !before(a.At, since) {
			out = append(out, a)
		}
	}
	return out, false, nil
}

func (f *fakeGitHub) PRComments(_ context.Context, _, since string) ([]PRComment, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.err != nil {
		return nil, false, f.err
	}
	var out []PRComment
	for _, c := range f.prComments {
		if !before(c.At, since) && !strings.HasPrefix(c.Body, agentCommentPrefix) {
			out = append(out, c)
		}
	}
	return out, false, nil
}

// harness polls a fake through Events, with a clock that moves on by a second a poll, as
// real polls are seconds apart.
type harness struct {
	t      *testing.T
	fake   *fakeGitHub
	events *Events
	clock  time.Time
}

func newHarness(t *testing.T) *harness {
	h := &harness{t: t, fake: newFake(), clock: time.Now().UTC().Truncate(time.Second)}
	h.events = &Events{GitHub: h.fake, Now: func() time.Time { return h.clock }}
	return h
}

// at is a time n seconds after the harness's start.
func (h *harness) at(n int) string { return timeString(h.clock.Add(time.Duration(n) * time.Second)) }

func (h *harness) rpc(params map[string]any) (map[string]any, *rpcError) {
	raw, _ := json.Marshal(params)
	result, err := h.events.Poll(context.Background(), raw)
	if result == nil {
		return nil, err
	}
	// Through JSON, as a client sees it.
	data, _ := json.Marshal(result)
	var out map[string]any
	_ = json.Unmarshal(data, &out)
	return out, err
}

func (h *harness) poll(name string, arguments map[string]any, cursor any, maxEvents ...int) map[string]any {
	h.t.Helper()
	params := map[string]any{"name": name, "arguments": arguments, "cursor": cursor}
	if len(maxEvents) > 0 {
		params["maxEvents"] = maxEvents[0]
	}
	out, err := h.rpc(params)
	if err != nil {
		h.t.Fatalf("poll %s: %v", name, err)
	}
	return out
}

func ids(result map[string]any) []string {
	out := []string{}
	for _, e := range result["events"].([]any) {
		out = append(out, e.(map[string]any)["eventId"].(string))
	}
	return out
}

func eventsOf(result map[string]any) []map[string]any {
	var out []map[string]any
	for _, e := range result["events"].([]any) {
		out = append(out, e.(map[string]any))
	}
	return out
}

func equal(t *testing.T, got, want any, what string) {
	t.Helper()
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("%s: got %#v, want %#v", what, got, want)
	}
}

func TestEventsListGivesEveryEventPollOnlyWithTheirSchemas(t *testing.T) {
	data, _ := json.Marshal(eventsList())
	var list struct {
		Events []map[string]any `json:"events"`
	}
	_ = json.Unmarshal(data, &list)
	var names []string
	for _, e := range list.Events {
		name := e["name"].(string)
		names = append(names, name)
		equal(t, e["delivery"], []any{"poll"}, name+" delivery")
		input := e["inputSchema"].(map[string]any)
		props := input["properties"].(map[string]any)
		equal(t, input["required"], []any{}, name+" required")
		equal(t, props["repo"].(map[string]any)["type"], "string", name+" repo")
		equal(t, e["payloadSchema"].(map[string]any)["type"], "object", name+" payload")
		// The person's own (#2034) are anyone's already.
		personal := name == "review.requested" || name == "issue.assigned"
		_, hasAnyone := props["anyone"]
		equal(t, hasAnyone, !personal, name+" anyone")
		_, hasMine := props["mine"]
		equal(t, hasMine, name == "checks.failed" || name == "checks.passed" || name == "pr.conflicted", name+" mine")
		if strings.HasPrefix(name, "issue.") {
			_, hasIssue := props["issue"]
			equal(t, hasIssue, name != "issue.opened", name+" issue")
		} else {
			equal(t, props["pr"].(map[string]any)["type"], "integer", name+" pr")
		}
	}
	sort.Strings(names)
	equal(t, names, []string{"checks.failed", "checks.passed", "issue.assigned", "issue.closed", "issue.commented", "issue.labelled", "issue.opened",
		"pr.closed", "pr.commented", "pr.conflicted", "pr.labelled", "pr.merged", "pr.opened", "pr.unlabelled", "review.comment", "review.posted",
		"review.requested"}, "names")
}

func TestCursorNullGivesNoEventsAndACursor(t *testing.T) {
	h := newHarness(t)
	r := h.poll("checks.failed", map[string]any{"repo": repo}, nil)
	equal(t, r["events"], []any{}, "events")
	equal(t, r["truncated"], false, "truncated")
	equal(t, r["hasMore"], false, "hasMore")
	equal(t, r["nextPollMs"], float64(30000), "nextPollMs")
	if _, ok := r["cursor"].(string); !ok {
		t.Fatal("no cursor")
	}
}

func TestAFailedRunGivesOneChecksFailedAndASecondAttemptANewID(t *testing.T) {
	h := newHarness(t)
	args := map[string]any{"repo": repo}
	h.fake.addPR(402, "agents/queue-helpers", nil)
	first := h.poll("checks.failed", args, nil)
	h.fake.addRun(9100, "agents/queue-helpers", h.at(5), 0, true)
	raised := h.poll("checks.failed", args, first["cursor"])
	equal(t, ids(raised), []string{"checks.failed:" + repo + ":9100:1"}, "ids")
	e := eventsOf(raised)[0]
	equal(t, e["name"], "checks.failed", "name")
	equal(t, e["data"], map[string]any{
		"pr": map[string]any{"number": float64(402), "title": "PR 402", "branch": "agents/queue-helpers",
			"url": "https://github.com/" + repo + "/pull/402"},
		"headSha":    "sha9100",
		"run":        map[string]any{"id": float64(9100), "attempt": float64(1), "name": "CI", "url": "https://github.com/" + repo + "/actions/runs/9100"},
		"failedJobs": []any{map[string]any{"name": "test", "url": "https://github.com/" + repo + "/actions/runs/9100/job/1"}},
	}, "data")
	quiet := h.poll("checks.failed", args, raised["cursor"])
	equal(t, ids(quiet), []string{}, "quiet")
	h.fake.mu.Lock()
	h.fake.runs[0].ref.Attempt, h.fake.runs[0].ref.UpdatedAt = 2, h.at(1000)
	h.fake.mu.Unlock()
	equal(t, ids(h.poll("checks.failed", args, quiet["cursor"])), []string{"checks.failed:" + repo + ":9100:2"}, "attempt 2")
}

func TestAPassedRunGivesOneChecksPassedWithNoFailedJobsAndAFailedRunDoesNotLeakIn(t *testing.T) {
	h := newHarness(t)
	args := map[string]any{"repo": repo}
	h.fake.addPR(405, "agents/queue-helpers-2", nil)
	first := h.poll("checks.passed", args, nil)
	h.fake.addRun(9105, "agents/queue-helpers-2", h.at(5), 0, true) // failed: must not raise checks.passed
	h.fake.addPassedRun(9106, "agents/queue-helpers-2", h.at(5), 0, true)
	raised := h.poll("checks.passed", args, first["cursor"])
	equal(t, ids(raised), []string{"checks.passed:" + repo + ":9106:1"}, "ids")
	e := eventsOf(raised)[0]
	equal(t, e["name"], "checks.passed", "name")
	equal(t, e["data"], map[string]any{
		"pr": map[string]any{"number": float64(405), "title": "PR 405", "branch": "agents/queue-helpers-2",
			"url": "https://github.com/" + repo + "/pull/405"},
		"headSha": "sha9106",
		"run":     map[string]any{"id": float64(9106), "attempt": float64(1), "name": "CI", "url": "https://github.com/" + repo + "/actions/runs/9106"},
	}, "data")
	// checks.failed still ignores the passed run.
	firstFailed := h.poll("checks.failed", args, nil)
	equal(t, ids(h.poll("checks.failed", args, firstFailed["cursor"])), []string{"checks.failed:" + repo + ":9105:1"}, "checks.failed ids")
}

func TestPRMergedAndClosed(t *testing.T) {
	h := newHarness(t)
	args := map[string]any{"repo": repo}
	h.fake.addPR(401, "agents/fold-faster", nil)
	merged, closed := h.poll("pr.merged", args, nil), h.poll("pr.closed", args, nil)
	h.fake.edit(401, func(p *fakePR) { p.state, p.mergedAt = "merged", h.at(5) })
	closedAt := "2099-01-01T00:00:00Z"
	h.fake.addPR(408, "agents/pr-408", func(p *fakePR) { p.state, p.closedAt = "closed", closedAt })
	raised := h.poll("pr.merged", args, merged["cursor"])
	equal(t, ids(raised), []string{"pr.merged:" + repo + ":401"}, "merged")
	equal(t, eventsOf(raised)[0]["data"].(map[string]any)["mergeSha"], "abc401", "mergeSha")
	equal(t, ids(h.poll("pr.merged", args, raised["cursor"])), []string{}, "quiet")
	equal(t, ids(h.poll("pr.closed", args, closed["cursor"])), []string{"pr.closed:" + repo + ":408:" + closedAt}, "closed")
}

func TestRepoLeftOutIsTheFoldersAndNoRepoIsInvalidParams(t *testing.T) {
	h := newHarness(t)
	first := h.poll("pr.merged", map[string]any{}, nil)
	h.fake.addPR(407, "agents/pr-407", func(p *fakePR) { p.state, p.mergedAt = "merged", h.at(5) })
	equal(t, ids(h.poll("pr.merged", map[string]any{"pr": 407}, first["cursor"])), []string{"pr.merged:" + repo + ":407"}, "ids")
	h.fake.noRepo = true
	_, err := h.rpc(map[string]any{"name": "checks.failed", "arguments": map[string]any{}, "cursor": nil})
	if err == nil || err.Code != -32602 || !strings.Contains(err.Message, "repo is needed") {
		t.Fatalf("got %v", err)
	}
}

func TestPRAndBranchNarrow(t *testing.T) {
	h := newHarness(t)
	h.fake.addPR(403, "agents/pr-403", nil)
	h.fake.addPR(404, "agents/pr-404", nil)
	byPR := map[string]any{"repo": repo, "pr": 403}
	both := map[string]any{"repo": repo, "pr": 403, "branch": "agents/pr-403"}
	crossed := map[string]any{"repo": repo, "pr": 404, "branch": "agents/pr-403"}
	a, b, c := h.poll("checks.failed", byPR, nil), h.poll("checks.failed", both, nil), h.poll("checks.failed", crossed, nil)
	h.fake.addRun(9400, "agents/pr-403", h.at(5), 403, true)
	h.fake.addRun(9401, "agents/pr-404", h.at(5), 404, true)
	want := []string{"checks.failed:" + repo + ":9400:1"}
	equal(t, ids(h.poll("checks.failed", byPR, a["cursor"])), want, "pr")
	equal(t, ids(h.poll("checks.failed", both, b["cursor"])), want, "both")
	equal(t, ids(h.poll("checks.failed", crossed, c["cursor"])), []string{}, "crossed")
}

func TestIssueEventsLabelsAndReasons(t *testing.T) {
	h := newHarness(t)
	issue := func(n int, labels ...string) Issue {
		return Issue{Number: n, Title: fmt.Sprintf("Issue %d", n), Author: "someone", Labels: labels,
			URL: fmt.Sprintf("https://github.com/%s/issues/%d", repo, n)}
	}
	all, bugs := map[string]any{"repo": repo}, map[string]any{"repo": repo, "label": "bug"}
	opened, openedBug := h.poll("issue.opened", all, nil), h.poll("issue.opened", bugs, nil)
	labelled := h.poll("issue.labelled", map[string]any{"repo": repo, "label": "expedite"}, nil)
	closed := h.poll("issue.closed", map[string]any{"repo": repo, "issue": 411}, nil)
	commented := h.poll("issue.commented", bugs, nil)
	h.fake.addActivity(IssueActivity{ID: "420", At: h.at(5), Issue: issue(420, "bug"), Kind: IssueOpened, Trusted: true})
	h.fake.addActivity(IssueActivity{ID: "421", At: h.at(5), Issue: issue(421), Kind: IssueOpened, Trusted: true})
	h.fake.addActivity(IssueActivity{ID: "8100", At: h.at(5), Issue: issue(411, "expedite"), Kind: IssueLabelled, Label: "expedite", By: "alexec", Trusted: true})
	h.fake.addActivity(IssueActivity{ID: "8101", At: h.at(5), Issue: issue(411, "expedite"), Kind: IssueLabelled, Label: "enhancement", By: "alexec", Trusted: true})
	h.fake.addActivity(IssueActivity{ID: "8102", At: h.at(6), Issue: issue(411), Kind: IssueClosed, Reason: "not_planned", By: "alexec", Trusted: true})
	h.fake.addActivity(IssueActivity{ID: "7100", At: h.at(5), Issue: issue(410, "bug"), Kind: IssueCommented, CommentAuthor: "someone",
		CommentBody: clip(strings.Repeat("x", 5000)), Trusted: true})
	h.fake.addActivity(IssueActivity{ID: "7101", At: h.at(5), Issue: issue(412), Kind: IssueCommented, Trusted: true})

	raised := h.poll("issue.opened", all, opened["cursor"])
	equal(t, ids(raised), []string{"issue.opened:" + repo + ":420", "issue.opened:" + repo + ":421"}, "opened")
	equal(t, eventsOf(raised)[0]["data"].(map[string]any)["issue"], map[string]any{"number": float64(420), "title": "Issue 420",
		"author": "someone", "labels": []any{"bug"}, "url": "https://github.com/" + repo + "/issues/420", "assignees": []any{}}, "issue")
	equal(t, ids(h.poll("issue.opened", bugs, openedBug["cursor"])), []string{"issue.opened:" + repo + ":420"}, "bug")
	l := h.poll("issue.labelled", map[string]any{"repo": repo, "label": "expedite"}, labelled["cursor"])
	equal(t, ids(l), []string{"issue.labelled:" + repo + ":8100"}, "labelled")
	equal(t, eventsOf(l)[0]["data"].(map[string]any)["by"], "alexec", "by")
	c := h.poll("issue.closed", map[string]any{"repo": repo, "issue": 411}, closed["cursor"])
	equal(t, eventsOf(c)[0]["data"].(map[string]any)["reason"], "not_planned", "reason")
	cm := h.poll("issue.commented", bugs, commented["cursor"])
	equal(t, ids(cm), []string{"issue.commented:" + repo + ":7100"}, "commented")
	body := eventsOf(cm)[0]["data"].(map[string]any)["comment"].(map[string]any)["body"].(string)
	if n := len([]rune(body)); n != 4001 || !strings.HasSuffix(body, "…") {
		t.Fatalf("body is %d runes", n)
	}
}

func TestPRLabelledAndUnlabelled(t *testing.T) {
	h := newHarness(t)
	pr := func(n int) PR {
		return PR{Number: n, Title: fmt.Sprintf("PR %d", n), URL: fmt.Sprintf("https://github.com/%s/pull/%d", repo, n)}
	}
	all := map[string]any{"repo": repo}
	expedite := map[string]any{"repo": repo, "label": "needs-approval"}
	byPR := map[string]any{"repo": repo, "pr": 511}
	labelled, labelledFiltered, labelledByPR := h.poll("pr.labelled", all, nil), h.poll("pr.labelled", expedite, nil), h.poll("pr.labelled", byPR, nil)
	unlabelled := h.poll("pr.unlabelled", all, nil)
	anyone := h.poll("pr.labelled", map[string]any{"repo": repo, "anyone": true, "pr": 512}, nil)

	h.fake.addPRLabel(PRLabelActivity{ID: "9100", At: h.at(5), PR: pr(510), Kind: PRLabelled, Label: "needs-approval", By: "alexec", Trusted: true})
	h.fake.addPRLabel(PRLabelActivity{ID: "9101", At: h.at(5), PR: pr(511), Kind: PRLabelled, Label: "approved", By: "alexec", Trusted: true})
	h.fake.addPRLabel(PRLabelActivity{ID: "9102", At: h.at(5), PR: pr(510), Kind: PRUnlabelled, Label: "needs-approval", By: "alexec", Trusted: true})
	// A bot's label change (dependabot's "hold:v0.13.1") doesn't count unless anyone is true.
	h.fake.addPRLabel(PRLabelActivity{ID: "9103", At: h.at(5), PR: pr(512), Kind: PRLabelled, Label: "hold:v0.13.1", By: "renovate[bot]", Trusted: false})

	raised := h.poll("pr.labelled", all, labelled["cursor"])
	equal(t, ids(raised), []string{"pr.labelled:" + repo + ":9100", "pr.labelled:" + repo + ":9101"}, "labelled, a bot left out")
	data := eventsOf(raised)[0]["data"].(map[string]any)
	equal(t, data["label"], "needs-approval", "label")
	equal(t, data["by"], "alexec", "by")
	equal(t, data["pr"], map[string]any{"number": float64(510), "title": "PR 510", "branch": "", "url": "https://github.com/" + repo + "/pull/510"}, "pr")
	if _, ok := data["labelledAt"].(string); !ok {
		t.Fatal("no labelledAt")
	}

	equal(t, ids(h.poll("pr.labelled", expedite, labelledFiltered["cursor"])), []string{"pr.labelled:" + repo + ":9100"}, "filtered by label")
	equal(t, ids(h.poll("pr.labelled", byPR, labelledByPR["cursor"])), []string{"pr.labelled:" + repo + ":9101"}, "filtered by pr")

	un := h.poll("pr.unlabelled", all, unlabelled["cursor"])
	equal(t, ids(un), []string{"pr.unlabelled:" + repo + ":9102"}, "unlabelled")
	if _, ok := eventsOf(un)[0]["data"].(map[string]any)["unlabelledAt"].(string); !ok {
		t.Fatal("no unlabelledAt")
	}

	gotAnyone := h.poll("pr.labelled", map[string]any{"repo": repo, "anyone": true, "pr": 512}, anyone["cursor"])
	equal(t, ids(gotAnyone), []string{"pr.labelled:" + repo + ":9103"}, "anyone sees the bot too")
	h.fake.addPRLabel(PRLabelActivity{ID: "9104", At: h.at(6), PR: pr(512), Kind: PRLabelled, Label: "hold:v0.13.1", By: "renovate[bot]", Trusted: false})
	equal(t, ids(h.poll("pr.labelled", map[string]any{"repo": repo, "anyone": true, "pr": 512}, gotAnyone["cursor"])),
		[]string{"pr.labelled:" + repo + ":9104"}, "anyone again")
}

// #728: a stranger's issue, comment or PR raises nothing unless the workflow asks for anyone.
func TestStrangersRaiseNothingUnlessAnyone(t *testing.T) {
	h := newHarness(t)
	own, anyone := map[string]any{"repo": repo}, map[string]any{"repo": repo, "anyone": true}
	a, b := h.poll("issue.opened", own, nil), h.poll("issue.opened", anyone, nil)
	ca, cb := h.poll("checks.failed", own, nil), h.poll("checks.failed", anyone, nil)
	h.fake.addActivity(IssueActivity{ID: "430", At: h.at(5), Issue: Issue{Number: 430}, Kind: IssueOpened})
	h.fake.addPR(440, "fork/main", func(p *fakePR) { p.trusted = false })
	h.fake.addRun(9440, "fork/main", h.at(5), 440, false)
	equal(t, ids(h.poll("issue.opened", own, a["cursor"])), []string{}, "own")
	equal(t, ids(h.poll("issue.opened", anyone, b["cursor"])), []string{"issue.opened:" + repo + ":430"}, "anyone")
	equal(t, ids(h.poll("checks.failed", own, ca["cursor"])), []string{}, "own checks")
	equal(t, ids(h.poll("checks.failed", anyone, cb["cursor"])), []string{"checks.failed:" + repo + ":9440:1"}, "anyone checks")
	_, err := h.rpc(map[string]any{"name": "issue.opened", "arguments": map[string]any{"repo": repo, "anyone": "yes"}, "cursor": nil})
	if err == nil || err.Message != "anyone must be true or false" {
		t.Fatalf("got %v", err)
	}
}

// A PR from a fork, or by someone outside the repo, raises no PR event unless anyone is true.
func TestAForksOrStrangersPRRaisesNoPREventUnlessAnyone(t *testing.T) {
	h := newHarness(t)
	own, anyone := map[string]any{"repo": repo}, map[string]any{"repo": repo, "anyone": true}
	names := []string{"checks.failed", "pr.merged", "pr.closed", "pr.conflicted"}
	firstOwn, firstAnyone := map[string]any{}, map[string]any{}
	h.fake.addPR(460, "fork/merged", func(p *fakePR) { p.trusted = false })
	h.fake.addPR(461, "fork/conflicts", func(p *fakePR) { p.trusted, p.conflicts = false, new(false) })
	for _, name := range names {
		firstOwn[name], firstAnyone[name] = h.poll(name, own, nil)["cursor"], h.poll(name, anyone, nil)["cursor"]
	}
	h.fake.addRun(9460, "fork/merged", h.at(5), 460, false)
	h.fake.edit(460, func(p *fakePR) { p.state, p.mergedAt = "merged", h.at(5) })
	h.fake.addPR(462, "fork/closed", func(p *fakePR) { p.trusted, p.state, p.closedAt = false, "closed", h.at(5) })
	h.fake.edit(461, func(p *fakePR) { p.conflicts = new(true) })
	for _, name := range names {
		equal(t, ids(h.poll(name, own, firstOwn[name])), []string{}, name+" own")
		equal(t, len(ids(h.poll(name, anyone, firstAnyone[name]))), 1, name+" anyone")
	}
}

func TestTiesAtOneTimeArentLost(t *testing.T) {
	h := newHarness(t)
	args := map[string]any{"repo": repo, "branch": "agents/ties"}
	h.fake.addPR(450, "agents/ties", nil)
	first := h.poll("checks.failed", args, nil)
	for _, id := range []int{9301, 9302, 9303} {
		h.fake.addRun(id, "agents/ties", h.at(5), 0, true)
	}
	one := h.poll("checks.failed", args, first["cursor"], 1)
	equal(t, one["hasMore"], true, "hasMore")
	two := h.poll("checks.failed", args, one["cursor"], 1)
	rest := h.poll("checks.failed", args, two["cursor"], 5)
	equal(t, rest["hasMore"], false, "rest hasMore")
	got := append(append(ids(one), ids(two)...), ids(rest)...)
	sort.Strings(got)
	equal(t, got, []string{"checks.failed:" + repo + ":9301:1", "checks.failed:" + repo + ":9302:1", "checks.failed:" + repo + ":9303:1"}, "all")
	equal(t, ids(h.poll("checks.failed", args, rest["cursor"])), []string{}, "quiet")
}

func TestACursorOlderThan90DaysIsTruncated(t *testing.T) {
	h := newHarness(t)
	old := cursor{Since: timeString(time.Now().Add(-91 * 24 * time.Hour))}.encoded()
	equal(t, h.poll("pr.merged", map[string]any{"repo": repo}, old)["truncated"], true, "truncated")
}

func TestBadArgumentsAreInvalidParamsAnUnknownEventIsItsOwnCode(t *testing.T) {
	h := newHarness(t)
	check := func(params map[string]any, code int, message string) {
		t.Helper()
		_, err := h.rpc(params)
		if err == nil || err.Code != code || (message != "" && err.Message != message) {
			t.Fatalf("%v: got %v", params, err)
		}
	}
	check(map[string]any{"name": "pr.merged", "arguments": map[string]any{"repo": repo, "sha": "x"}, "cursor": nil}, -32602,
		"unknown argument sha; takes repo, branch, pr, anyone")
	for _, name := range []string{"checks.failed", "pr.merged"} {
		for _, pr := range []any{"551", 0, -1, 1.5} {
			check(map[string]any{"name": name, "arguments": map[string]any{"repo": repo, "pr": pr}, "cursor": nil}, -32602,
				"pr must be a positive integer")
		}
	}
	check(map[string]any{"name": "checks.failed", "arguments": map[string]any{"repo": "not a repo"}, "cursor": nil}, -32602,
		"repo must look like owner/name")
	check(map[string]any{"name": "checks.failed", "arguments": map[string]any{"repo": repo}, "cursor": "%%%"}, -32602, "")
	check(map[string]any{"name": "checks.unknown", "arguments": map[string]any{"repo": repo}, "cursor": nil}, -32011, "")
}

func TestPRConflictedRaisesAPROncePerConflictNewOnesOnly(t *testing.T) {
	h := newHarness(t)
	set := func(n int, v *bool) { h.fake.edit(n, func(p *fakePR) { p.conflicts = v }) }
	all := map[string]any{"repo": repo}
	h.fake.addPR(720, "agents/old-conflict", func(p *fakePR) { p.conflicts = new(true) })
	h.fake.addPR(721, "agents/fresh", func(p *fakePR) { p.conflicts = new(false) })
	first := h.poll("pr.conflicted", all, nil)
	equal(t, ids(first), []string{}, "one already in conflict is known")

	set(721, new(true))
	raised := h.poll("pr.conflicted", all, first["cursor"])
	e := eventsOf(raised)
	if len(e) != 1 || !strings.HasPrefix(e[0]["eventId"].(string), "pr.conflicted:"+repo+":721:") {
		t.Fatalf("raised %v", ids(raised))
	}
	set(721, nil)
	unknown := h.poll("pr.conflicted", all, raised["cursor"])
	set(721, new(true))
	still := h.poll("pr.conflicted", all, unknown["cursor"])
	equal(t, append(ids(unknown), ids(still)...), []string{}, "not worked out yet keeps its state")
	set(721, new(false))
	clean := h.poll("pr.conflicted", all, still["cursor"])
	set(721, new(true))
	equal(t, len(ids(h.poll("pr.conflicted", all, clean["cursor"]))), 1, "conflicting anew is raised again")
}

func TestPROpenedRaisesAReadyPROnceAndADraftWhenMarkedReady(t *testing.T) {
	h := newHarness(t)
	all := map[string]any{"repo": repo}
	first := h.poll("pr.opened", all, nil)
	h.fake.addPR(833, "agents/review", nil)
	h.fake.addPR(834, "agents/wip", func(p *fakePR) { p.draft = true })
	h.fake.addPR(840, "fork/main", func(p *fakePR) { p.author, p.trusted = "stranger", false })
	raised := h.poll("pr.opened", all, first["cursor"])
	e := eventsOf(raised)
	if len(e) != 1 || !strings.HasPrefix(e[0]["eventId"].(string), "pr.opened:"+repo+":833:") {
		t.Fatalf("raised %v", ids(raised))
	}
	equal(t, e[0]["data"].(map[string]any)["pr"].(map[string]any)["author"], "alexec", "author")
	quiet := h.poll("pr.opened", all, raised["cursor"])
	equal(t, ids(quiet), []string{}, "raised once")
	h.fake.edit(834, func(p *fakePR) { p.draft = false })
	ready := h.poll("pr.opened", all, quiet["cursor"])
	if got := ids(ready); len(got) != 1 || !strings.HasPrefix(got[0], "pr.opened:"+repo+":834:") {
		t.Fatalf("ready %v", got)
	}
	h.fake.edit(833, func(p *fakePR) { p.state = "closed" })
	closed := h.poll("pr.opened", all, ready["cursor"])
	h.fake.edit(833, func(p *fakePR) { p.state = "open" })
	if got := ids(h.poll("pr.opened", all, closed["cursor"])); len(got) != 1 || !strings.HasPrefix(got[0], "pr.opened:"+repo+":833:") {
		t.Fatalf("reopened %v", got)
	}
}

func TestNotSignedInAndARateLimit(t *testing.T) {
	h := newHarness(t)
	c := cursor{Since: timeString(time.Now())}.encoded()
	h.fake.err = &GitHubError{Kind: NotSignedIn, Message: NotConnected}
	_, err := h.rpc(map[string]any{"name": "checks.failed", "arguments": map[string]any{"repo": repo}, "cursor": c})
	if err == nil || err.Code != -32012 || err.Data["reason"] != "not connected" {
		t.Fatalf("got %v", err)
	}
	h.fake.err = &GitHubError{Kind: RateLimited, Message: "GitHub rate limit", RetryAfterMs: 60000}
	_, err = h.rpc(map[string]any{"name": "pr.merged", "arguments": map[string]any{"repo": repo}, "cursor": c})
	if err == nil || err.Code != -32013 || err.Data["retryAfterMs"] != 60000 {
		t.Fatalf("got %v", err)
	}
}

// Notify me (#2034): what asks the connection's owner, and their own PRs only.
func TestReviewRequestedRaisesOncePerRequestAndAgainWhenAskedAgain(t *testing.T) {
	h := newHarness(t)
	all := map[string]any{"repo": repo}
	ask := func(on bool) {
		h.fake.mu.Lock()
		defer h.fake.mu.Unlock()
		h.fake.reviews = nil
		if on {
			h.fake.reviews = []OpenPR{{PR: PR{Number: 900, Title: "Fix the walk", Branch: "b", URL: "u900"}, Author: "stranger"}}
		}
	}
	first := h.poll("review.requested", all, nil)
	ask(true)
	raised := h.poll("review.requested", all, first["cursor"])
	e := eventsOf(raised)
	if len(e) != 1 || !strings.HasPrefix(e[0]["eventId"].(string), "review.requested:"+repo+":900:") {
		t.Fatalf("raised %v", ids(raised))
	}
	equal(t, e[0]["data"].(map[string]any)["pr"].(map[string]any)["author"], "stranger", "anyone's PR")
	still := h.poll("review.requested", all, raised["cursor"])
	equal(t, ids(still), []string{}, "raised once")
	ask(false)
	gone := h.poll("review.requested", all, still["cursor"])
	ask(true)
	equal(t, len(ids(h.poll("review.requested", all, gone["cursor"]))), 1, "asked again")
}

func TestIssueAssignedRaisesTheIssue(t *testing.T) {
	h := newHarness(t)
	first := h.poll("issue.assigned", map[string]any{"repo": repo}, nil)
	h.fake.mu.Lock()
	h.fake.assigned = []Issue{{Number: 51, Title: "Notify me", URL: "u51", Author: "bob", Assignees: []string{"alexec"}}}
	h.fake.mu.Unlock()
	e := eventsOf(h.poll("issue.assigned", map[string]any{"repo": repo}, first["cursor"]))
	if len(e) != 1 {
		t.Fatalf("raised %v", e)
	}
	data := e[0]["data"].(map[string]any)
	equal(t, data["issue"].(map[string]any)["title"], "Notify me", "issue")
	if _, ok := data["assignedAt"].(string); !ok {
		t.Fatal("no assignedAt")
	}
}

func TestMineIsOnlyTheOwnersPRsAForksToo(t *testing.T) {
	h := newHarness(t)
	mine := map[string]any{"repo": repo, "mine": true}
	h.fake.addPR(910, "agents/mine", nil)
	h.fake.addPR(911, "theirs", func(p *fakePR) { p.author = "bob" })
	h.fake.addPR(912, "fork/mine", func(p *fakePR) { p.trusted = false })
	first := h.poll("checks.failed", mine, nil)
	h.fake.addRun(9910, "agents/mine", h.at(5), 910, true)
	h.fake.addRun(9911, "theirs", h.at(5), 911, true)
	h.fake.addRun(9912, "fork/mine", h.at(5), 912, false)
	equal(t, ids(h.poll("checks.failed", mine, first["cursor"])),
		[]string{"checks.failed:" + repo + ":9910:1", "checks.failed:" + repo + ":9912:1"}, "mine")

	set := func(n int) { h.fake.edit(n, func(p *fakePR) { p.conflicts = new(true) }) }
	before := h.poll("pr.conflicted", mine, nil)
	set(910)
	set(911)
	got := ids(h.poll("pr.conflicted", mine, before["cursor"]))
	if len(got) != 1 || !strings.HasPrefix(got[0], "pr.conflicted:"+repo+":910:") {
		t.Fatalf("conflicted %v", got)
	}
}

// #2838: pr.commented wakes a lane waiting for Alex's comment on a PR, without a timer. An
// agent's own comment (<!-- agent -->) and a stranger's are left out unless anyone is true.
func TestPRCommentedLeavesOutAgentsAndStrangersUnlessAnyone(t *testing.T) {
	h := newHarness(t)
	pr := PR{Number: 950, Title: "A UI enhancement", Branch: "agents/950-ui", URL: "https://github.com/" + repo + "/pull/950"}
	own, anyone := map[string]any{"repo": repo}, map[string]any{"repo": repo, "anyone": true}
	a, b := h.poll("pr.commented", own, nil), h.poll("pr.commented", anyone, nil)
	h.fake.addPRComment(PRComment{ID: 1, PR: pr, Author: "alexec", Body: "<!-- agent --> waiting for approval", At: h.at(5), Trusted: true})
	h.fake.addPRComment(PRComment{ID: 2, PR: pr, Author: "stranger", Body: "looks fine to me", At: h.at(5), Trusted: false})
	h.fake.addPRComment(PRComment{ID: 3, PR: pr, Author: "alexec", Body: "I approve these screenshots, ship it", At: h.at(5), Trusted: true})
	equal(t, ids(h.poll("pr.commented", own, a["cursor"])), []string{"pr.commented:" + repo + ":3"}, "own")
	raised := h.poll("pr.commented", anyone, b["cursor"])
	equal(t, ids(raised), []string{"pr.commented:" + repo + ":2", "pr.commented:" + repo + ":3"}, "anyone still leaves the agent's own out")
	e := eventsOf(raised)[0]
	equal(t, e["data"].(map[string]any)["pr"].(map[string]any)["branch"], "agents/950-ui", "pr")
	equal(t, e["data"].(map[string]any)["comment"].(map[string]any)["author"], "stranger", "author")
}

func TestPRCommentedNarrowsByPR(t *testing.T) {
	h := newHarness(t)
	pr950 := PR{Number: 950, URL: "u950"}
	pr951 := PR{Number: 951, URL: "u951"}
	byPR := map[string]any{"repo": repo, "pr": 950}
	first := h.poll("pr.commented", byPR, nil)
	h.fake.addPRComment(PRComment{ID: 4, PR: pr950, Author: "alexec", Body: "ship it", At: h.at(5), Trusted: true})
	h.fake.addPRComment(PRComment{ID: 5, PR: pr951, Author: "alexec", Body: "ship it", At: h.at(5), Trusted: true})
	equal(t, ids(h.poll("pr.commented", byPR, first["cursor"])), []string{"pr.commented:" + repo + ":4"}, "narrowed")
}
