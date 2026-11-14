package gitlabmcp

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/agentloops-dev/agents/Go/internal/mcpevents"
)

// The events over the fake GitLab: the github server's cases, for merge requests, pipelines
// and issues.

type poller struct {
	t      *testing.T
	events *Events
	name   string
	args   map[string]any
	cursor any
	now    time.Time
}

func newPoller(t *testing.T, f *fakeGitLab, name string, args map[string]any) *poller {
	p := &poller{t: t, name: name, args: args, now: start}
	p.events = &Events{GitLab: f.gitlab(), Now: func() time.Time { return p.now }}
	return p
}

// poll polls once and gives the events' ids and the answer.
func (p *poller) poll() ([]string, map[string]any) {
	p.t.Helper()
	result, err := p.try()
	if err != nil {
		p.t.Fatalf("poll %s: %v", p.name, err)
	}
	p.cursor = result["cursor"]
	var ids []string
	for _, e := range result["events"].([]any) {
		ids = append(ids, e.(map[string]any)["eventId"].(string))
	}
	p.now = p.now.Add(time.Minute)
	return ids, result
}

func (p *poller) try() (map[string]any, *rpcError) {
	raw, _ := json.Marshal(map[string]any{"name": p.name, "arguments": p.args, "cursor": p.cursor})
	return p.events.Poll(context.Background(), raw)
}

func data(t *testing.T, result map[string]any, i int) map[string]any {
	t.Helper()
	return result["events"].([]any)[i].(map[string]any)["data"].(map[string]any)
}

func same(t *testing.T, got, want []string) {
	t.Helper()
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestTheEventsAreTheGitHubServersNames(t *testing.T) {
	same(t, EventNames(), []string{"checks.failed", "run.completed", "deploy.waiting", "pr.opened", "pr.merged", "pr.closed", "pr.conflicted", "review.requested", "review.comment",
		"issue.opened", "issue.labelled", "issue.commented", "issue.closed", "issue.assigned"})
}

func TestOpenedIsRaisedWhenReadyAndOnlyForTheProjectsOwn(t *testing.T) {
	f := newFake(t)
	f.addMembers()
	f.mrs = []obj{mrJSON(1, "old", alex, nil)}
	own := newPoller(t, f, "pr.opened", nil)
	anyone := newPoller(t, f, "pr.opened", map[string]any{"anyone": true})
	ids, _ := own.poll()
	same(t, ids, nil) // the first poll takes what is open as known
	anyone.poll()

	f.set(func() {
		f.mrs = append(f.mrs,
			mrJSON(2, "feature", dev, nil),
			mrJSON(3, "wip", alex, obj{"draft": true}),
			mrJSON(4, "fork", alex, obj{"source_project_id": 99}),
			mrJSON(5, "outside", stranger, nil),
			mrJSON(6, "bot", tokenBot, nil),
			mrJSON(7, "guest", guest, nil))
	})
	ids, result := own.poll()
	same(t, ids, []string{"pr.opened:group/app:2:" + mcpevents.TimeString(start.Add(time.Minute))})
	pr := data(t, result, 0)["pr"].(map[string]any)
	if pr["author"] != "dev" || pr["branch"] != "feature" || pr["number"] != 2 {
		t.Fatalf("pr %v", pr)
	}
	ids, _ = anyone.poll()
	if len(ids) != 5 {
		t.Fatalf("anyone: %v", ids)
	}

	// The draft marked ready is raised; nothing else again.
	f.set(func() { f.mrs[2]["draft"] = false })
	ids, _ = own.poll()
	if len(ids) != 1 || !strings.HasPrefix(ids[0], "pr.opened:group/app:3:") {
		t.Fatalf("ready: %v", ids)
	}
	ids, _ = own.poll()
	same(t, ids, nil)
}

func TestConflictedWaitsForGitLabToKnow(t *testing.T) {
	f := newFake(t)
	f.addMembers()
	f.mrs = []obj{mrJSON(1, "a", alex, nil)}
	p := newPoller(t, f, "pr.conflicted", map[string]any{"branch": "a"})
	p.poll()
	f.set(func() { f.mrs[0]["detailed_merge_status"], f.mrs[0]["merge_status"] = "checking", "checking" })
	ids, _ := p.poll()
	same(t, ids, nil)
	f.set(func() { f.mrs[0]["detailed_merge_status"], f.mrs[0]["has_conflicts"] = "conflict", true })
	ids, result := p.poll()
	if len(ids) != 1 || data(t, result, 0)["conflictedAt"] == nil {
		t.Fatalf("conflict: %v", ids)
	}
	// Still in conflict, and then working it out again: not raised twice.
	f.set(func() { f.mrs[0]["detailed_merge_status"] = "checking" })
	ids, _ = p.poll()
	same(t, ids, nil)
	f.set(func() { f.mrs[0]["detailed_merge_status"] = "conflict" })
	ids, _ = p.poll()
	same(t, ids, nil)
}

func TestMergedAndClosedSinceTheCursor(t *testing.T) {
	f := newFake(t)
	f.addMembers()
	merged := newPoller(t, f, "pr.merged", nil)
	closed := newPoller(t, f, "pr.closed", map[string]any{"pr": 3})
	merged.poll()
	closed.poll()
	f.set(func() {
		f.mrs = []obj{
			mrJSON(1, "old", alex, obj{"state": "merged", "merged_at": at(-30), "updated_at": at(-30)}),
			mrJSON(2, "new", alex, obj{"state": "merged", "merged_at": at(1), "updated_at": at(1), "merge_commit_sha": "", "squash_commit_sha": "sq2"}),
			mrJSON(3, "gone", dev, obj{"state": "closed", "closed_at": at(2), "updated_at": at(2)}),
			mrJSON(4, "other", dev, obj{"state": "closed", "closed_at": at(2), "updated_at": at(2)}),
			mrJSON(5, "fork", alex, obj{"state": "merged", "merged_at": at(2), "updated_at": at(2), "source_project_id": 99}),
		}
	})
	ids, result := merged.poll()
	same(t, ids, []string{"pr.merged:group/app:2"})
	if sub, key := envelopeOf(result, 0); sub != "gitlab:mr:group/app#2" || key != "" {
		t.Fatalf("merged: subject %q, key %q", sub, key)
	}
	if d := data(t, result, 0); d["mergeSha"] != "sq2" || d["mergedAt"] != at(1) {
		t.Fatalf("merged %v", d)
	}
	ids, result = closed.poll()
	same(t, ids, []string{"pr.closed:group/app:3:" + at(2)})
	if sub, key := envelopeOf(result, 0); !strings.HasSuffix(sub, "#3") || key == "" {
		t.Fatalf("closed: subject %q, key %q (#4728: a PR closed again is a new event)", sub, key)
	}
	ids, _ = merged.poll()
	same(t, ids, nil)
	for _, r := range f.asked() {
		if strings.Contains(r, "state=merged") && !strings.Contains(r, "updated_after=") {
			t.Fatalf("listed every merged one: %s", r)
		}
	}
}

func TestChecksFailedForAMergeRequestsPipelines(t *testing.T) {
	f := newFake(t)
	f.addMembers()
	f.mrs = []obj{mrJSON(3, "feature", dev, nil), mrJSON(4, "push", alex, nil), mrJSON(5, "fork", alex, obj{"source_project_id": 99})}
	p := newPoller(t, f, "checks.failed", nil)
	only4 := newPoller(t, f, "checks.failed", map[string]any{"pr": 4})
	p.poll()
	only4.poll()
	f.set(func() {
		f.pipes = []obj{
			{"id": 100, "status": "failed", "ref": "refs/merge-requests/3/head", "sha": "s3", "web_url": "https://gitlab.test/p/100", "updated_at": at(1), "source": "merge_request_event"},
			{"id": 101, "status": "failed", "ref": "push", "sha": "s4", "web_url": "https://gitlab.test/p/101", "updated_at": at(2), "source": "push", "name": "Build"},
			{"id": 102, "status": "failed", "ref": "main", "sha": "s0", "web_url": "https://gitlab.test/p/102", "updated_at": at(2), "source": "push"},
			{"id": 103, "status": "failed", "ref": "refs/merge-requests/5/head", "sha": "s5", "web_url": "https://gitlab.test/p/103", "updated_at": at(3)},
			{"id": 99, "status": "failed", "ref": "refs/merge-requests/3/head", "sha": "s3", "web_url": "https://gitlab.test/p/99", "updated_at": at(-10)},
		}
		f.jobs[100] = []obj{{"id": 1, "name": "test", "status": "failed", "web_url": "https://gitlab.test/j/1"},
			{"id": 2, "name": "lint", "status": "failed", "allow_failure": true, "web_url": "https://gitlab.test/j/2"},
			{"id": 3, "name": "build", "status": "success", "web_url": "https://gitlab.test/j/3"}}
		f.commits["s4"] = []obj{mrJSON(4, "push", alex, nil)}
	})
	ids, result := p.poll()
	same(t, ids, []string{"checks.failed:group/app:100:" + at(1), "checks.failed:group/app:101:" + at(2)})
	d := data(t, result, 0)
	jobs := d["failedJobs"].([]any)
	if len(jobs) != 1 || jobs[0].(map[string]any)["name"] != "test" || d["headSha"] != "s3" ||
		d["pr"].(map[string]any)["number"] != 3 || d["run"].(map[string]any)["id"] != 100 {
		t.Fatalf("data %v", d)
	}
	if run := data(t, result, 1)["run"].(map[string]any); run["name"] != "Build" {
		t.Fatalf("run %v", run)
	}
	ids, _ = only4.poll()
	same(t, ids, []string{"checks.failed:group/app:101:" + at(2)})

	// Retried and failed again: a new event.
	f.set(func() { f.pipes[0]["updated_at"] = at(5) })
	ids, _ = p.poll()
	same(t, ids, []string{"checks.failed:group/app:100:" + at(5)})
}

func TestIssueEvents(t *testing.T) {
	f := newFake(t)
	f.addMembers()
	opened := newPoller(t, f, "issue.opened", map[string]any{"label": "bug"})
	closed := newPoller(t, f, "issue.closed", nil)
	commented := newPoller(t, f, "issue.commented", map[string]any{"issue": 1})
	// A lead waits on all its open children at once (#3797).
	listed := newPoller(t, f, "issue.closed", map[string]any{"issue": []any{3, 4}, "anyone": true})
	notListed := newPoller(t, f, "issue.closed", map[string]any{"issue": []any{3}, "anyone": true})
	for _, p := range []*poller{opened, closed, commented, listed, notListed} {
		p.poll()
	}
	f.set(func() {
		f.issues = []obj{
			issueObj(1, alex, obj{"created_at": at(1), "updated_at": at(3), "labels": []string{"bug"}}),
			issueObj(2, stranger, obj{"created_at": at(1), "labels": []string{"bug"}}),
			issueObj(3, dev, obj{"created_at": at(2), "labels": []string{"idea"}}),
			issueObj(4, stranger, obj{"state": "closed", "closed_at": at(2), "updated_at": at(2), "closed_by": dev}),
			issueObj(5, stranger, obj{"state": "closed", "closed_at": at(2), "updated_at": at(2), "closed_by": stranger}),
		}
		f.activity = []obj{
			{"created_at": at(3), "note": obj{"id": 12, "body": "@alex looks good", "author": tokenBot, "noteable_type": "Issue", "noteable_iid": 1, "created_at": at(3)}},
			{"created_at": at(2), "note": obj{"id": 11, "body": "added ~bug label", "system": true, "author": alex, "noteable_type": "Issue", "noteable_iid": 1, "created_at": at(2)}},
			{"created_at": at(2), "note": obj{"id": 10, "body": "Can I take this?", "author": dev, "noteable_type": "Issue", "noteable_iid": 1, "created_at": at(2)}},
			{"created_at": at(1), "note": obj{"id": 9, "body": "on an MR", "author": dev, "noteable_type": "MergeRequest", "noteable_iid": 1, "created_at": at(1)}},
			{"created_at": at(-90), "note": obj{"id": 8, "body": "old", "author": dev, "noteable_type": "Issue", "noteable_iid": 1, "created_at": at(-90)}},
		}
	})
	ids, result := opened.poll()
	same(t, ids, []string{"issue.opened:group/app:1"})
	if issue := data(t, result, 0)["issue"].(map[string]any); issue["author"] != "alex" || issue["number"] != 1 {
		t.Fatalf("issue %v", issue)
	}
	ids, result = closed.poll()
	same(t, ids, []string{"issue.closed:group/app:4:" + at(2)})
	if d := data(t, result, 0); d["by"] != "dev" || d["closedAt"] != at(2) {
		t.Fatalf("closed %v", d)
	}
	ids, _ = listed.poll()
	same(t, ids, []string{"issue.closed:group/app:4:" + at(2)})
	ids, _ = notListed.poll()
	same(t, ids, nil)
	ids, result = commented.poll()
	same(t, ids, []string{"issue.commented:group/app:10"})
	comment := data(t, result, 0)["comment"].(map[string]any)
	if comment["author"] != "dev" || comment["url"] != "https://gitlab.test/group/app/-/issues/1#note_10" {
		t.Fatalf("comment %v", comment)
	}
	var after string
	for _, r := range f.asked() {
		if strings.Contains(r, "/events?") {
			after = r
		}
	}
	if !strings.Contains(after, "action=commented") || !strings.Contains(after, "after=2026-10-18") {
		t.Fatalf("events asked as %s", after)
	}
}

// issue.labelled (#1633): one event per label added since the last poll, by the project's
// own people unless anyone, and only the label asked for.
func TestIssueLabelled(t *testing.T) {
	f := newFake(t)
	f.addMembers()
	agent := newPoller(t, f, "issue.labelled", map[string]any{"label": "agent"})
	agent.poll()
	f.set(func() {
		f.issues = []obj{
			issueObj(1, stranger, obj{"updated_at": at(3), "labels": []string{"agent", "bug"}}),
			issueObj(2, alex, obj{"updated_at": at(2), "labels": []string{"agent"}}),
		}
		f.labelled[1] = []obj{
			{"id": 31, "action": "add", "created_at": at(3), "user": dev, "label": obj{"name": "agent"}},
			{"id": 30, "action": "add", "created_at": at(2), "user": dev, "label": obj{"name": "bug"}},
			{"id": 29, "action": "add", "created_at": at(-90), "user": dev, "label": obj{"name": "agent"}},
		}
		f.labelled[2] = []obj{
			{"id": 40, "action": "add", "created_at": at(2), "user": stranger, "label": obj{"name": "agent"}},
			{"id": 41, "action": "remove", "created_at": at(2), "user": alex, "label": obj{"name": "agent"}},
		}
	})
	ids, result := agent.poll()
	same(t, ids, []string{"issue.labelled:group/app:label:31"})
	if d := data(t, result, 0); d["label"] != "agent" || d["by"] != "dev" || d["labelledAt"] != at(3) ||
		d["issue"].(map[string]any)["number"] != 1 {
		t.Fatalf("labelled %v", d)
	}
}

// A wait whose label nobody adds still moves on (P20261020-1): each poll reads what changed
// since the last poll, not everything since the last label it raised.
func TestLabelledWaitReadsOnlyWhatIsNew(t *testing.T) {
	f := newFake(t)
	f.addMembers()
	agent := newPoller(t, f, "issue.labelled", map[string]any{"label": "agent"})
	agent.poll()
	var asked []int
	for i := 1; i <= 20; i++ {
		f.set(func() {
			f.issues = append(f.issues, issueObj(i, dev, obj{"updated_at": mcpevents.TimeString(agent.now), "labels": []string{"bug"}}))
			f.labelled[i] = []obj{{"id": 100 + i, "action": "add", "created_at": mcpevents.TimeString(agent.now), "user": dev, "label": obj{"name": "bug"}}}
		})
		before := len(f.asked())
		ids, _ := agent.poll()
		same(t, ids, nil)
		asked = append(asked, len(f.asked())-before)
	}
	if asked[len(asked)-1] > asked[1] {
		t.Fatalf("requests per poll grow: %v", asked)
	}
}

// The cursor moves past what the wait does not want, but never past one it does: a label at
// the second the cursor stopped is raised once, and a truncated poll keeps its old cursor.
func TestLabelledCursorLosesNothingAtItsEdge(t *testing.T) {
	f := newFake(t)
	f.addMembers()
	agent := newPoller(t, f, "issue.labelled", map[string]any{"label": "agent"})
	agent.poll()
	f.set(func() {
		f.issues = []obj{issueObj(1, dev, obj{"updated_at": at(2), "labels": []string{"bug"}})}
		f.labelled[1] = []obj{{"id": 10, "action": "add", "created_at": at(2), "user": dev, "label": obj{"name": "bug"}}}
	})
	ids, _ := agent.poll()
	same(t, ids, nil)
	// A label added in the same second, seen only now.
	f.set(func() {
		f.issues = append(f.issues, issueObj(2, dev, obj{"updated_at": at(2), "labels": []string{"agent"}}))
		f.labelled[2] = []obj{{"id": 11, "action": "add", "created_at": at(2), "user": dev, "label": obj{"name": "agent"}}}
	})
	ids, _ = agent.poll()
	same(t, ids, []string{"issue.labelled:group/app:label:11"})
	ids, _ = agent.poll()
	same(t, ids, nil)

	// More than ten pages: the cursor stays at the last label raised, as before.
	f.set(func() {
		for i := 3; i < 3+maxPages*perPage+1; i++ {
			f.issues = append(f.issues, issueObj(i, dev, obj{"updated_at": at(10 + i), "labels": []string{"bug"}}))
		}
	})
	_, result := agent.poll()
	if result["truncated"] != true {
		t.Fatalf("not truncated: %v", result)
	}
	c, _ := decodeCursor(json.RawMessage(`"` + result["cursor"].(string) + `"`))
	if c.Since != at(2) || strings.Join(c.IDs, ",") != "issue.labelled:group/app:label:11" {
		t.Fatalf("cursor %+v", c)
	}
}

// Two waits on one project share an issue's label events while it is unchanged, but a label
// added since is read afresh, never hidden by what was shared.
func TestLabelEventsAreSharedByTheIssuesUpdate(t *testing.T) {
	f := newFake(t)
	f.addMembers()
	gl := f.gitlab()
	gl.sharing = time.Hour
	waits := []*poller{newPoller(t, f, "issue.labelled", map[string]any{"label": "agent"}),
		newPoller(t, f, "issue.labelled", map[string]any{"label": "agent", "issue": 1})}
	for _, w := range waits {
		w.events.GitLab = gl
		w.poll()
	}
	read := func() int {
		n := 0
		for _, r := range f.asked() {
			if strings.Contains(r, "/resource_label_events") {
				n++
			}
		}
		return n
	}
	f.set(func() {
		f.issues = []obj{issueObj(1, dev, obj{"updated_at": at(1), "labels": []string{"bug"}})}
		f.labelled[1] = []obj{{"id": 10, "action": "add", "created_at": at(1), "user": dev, "label": obj{"name": "bug"}}}
	})
	for _, w := range waits {
		ids, _ := w.poll()
		same(t, ids, nil)
	}
	if read() != 1 {
		t.Fatalf("label events read %d times, want once", read())
	}
	f.set(func() {
		f.issues[0]["updated_at"], f.issues[0]["labels"] = at(2), []string{"bug", "agent"}
		f.labelled[1] = append(f.labelled[1], obj{"id": 11, "action": "add", "created_at": at(2), "user": dev, "label": obj{"name": "agent"}})
	})
	for _, w := range waits {
		ids, _ := w.poll()
		same(t, ids, []string{"issue.labelled:group/app:label:11"})
	}
	if read() != 2 {
		t.Fatalf("label events read %d times, want twice", read())
	}
}

func TestReviewCommentIsALineOfTheDiff(t *testing.T) {
	f := newFake(t)
	f.addMembers()
	f.mrs = []obj{mrJSON(3, "feature", dev, nil)}
	p := newPoller(t, f, "review.comment", nil)
	p.poll()
	f.set(func() {
		f.activity = []obj{
			{"created_at": at(2), "note": obj{"id": 21, "type": "DiffNote", "body": "Off by one?", "author": alex, "noteable_type": "MergeRequest",
				"noteable_iid": 3, "position": obj{"new_path": "main.go", "new_line": 42}}},
			{"created_at": at(2), "note": obj{"id": 22, "type": "DiffNote", "body": "removed line", "author": alex, "noteable_type": "MergeRequest",
				"noteable_iid": 3, "position": obj{"old_path": "old.go", "old_line": 7}}},
			{"created_at": at(1), "note": obj{"id": 20, "body": "LGTM", "author": alex, "noteable_type": "MergeRequest", "noteable_iid": 3}},
			{"created_at": at(1), "note": obj{"id": 19, "type": "DiffNote", "body": "spam", "author": stranger, "noteable_type": "MergeRequest", "noteable_iid": 3}},
		}
	})
	ids, result := p.poll()
	same(t, ids, []string{"review.comment:group/app:21", "review.comment:group/app:22"})
	d := data(t, result, 0)
	c := d["comment"].(map[string]any)
	if c["path"] != "main.go" || c["line"] != 42 || c["author"] != "alex" || d["pr"].(map[string]any)["branch"] != "feature" ||
		d["commentedAt"] != at(2) {
		t.Fatalf("data %v", d)
	}
	if c := data(t, result, 1)["comment"].(map[string]any); c["path"] != "old.go" || c["line"] != 7 {
		t.Fatalf("old line %v", c)
	}
}

func TestFailuresAreTheDraftsErrors(t *testing.T) {
	f := newFake(t)
	p := newPoller(t, f, "issue.opened", nil)
	p.poll()

	f.set(func() { f.status = 429; f.header = map[string][]string{"Retry-After": {"7"}} })
	_, err := p.try()
	if err == nil || err.Code != -32013 || err.Data["retryAfterMs"] != 7000 {
		t.Fatalf("rate limit: %v", err)
	}
	f.set(func() { f.status, f.header = 404, nil })
	if _, err = p.try(); err == nil || err.Code != -32602 || !strings.Contains(err.Message, "check project") {
		t.Fatalf("not found: %v", err)
	}
	f.set(func() { f.status = 0 })

	noToken := newPoller(t, f, "issue.opened", nil)
	noToken.events.GitLab.(*RealGitLab).Token = func() string { return "" }
	noToken.poll() // the first poll asks GitLab nothing
	if _, err = noToken.try(); err == nil || err.Code != -32012 {
		t.Fatalf("no token: %v", err)
	}
	wrong := newPoller(t, f, "issue.opened", nil)
	wrong.events.GitLab.(*RealGitLab).Token = func() string { return "glpat-ended" }
	wrong.poll()
	if _, err = wrong.try(); err == nil || err.Code != -32012 || err.Message != NotConnected {
		t.Fatalf("ended token: %v", err)
	}

	noRemote := newPoller(t, f, "pr.merged", nil)
	noRemote.events.GitLab.(*RealGitLab).Project = GitProject("https://gitlab.test")
	t.Chdir(t.TempDir())
	if _, err = noRemote.try(); err == nil || err.Code != -32602 || !strings.Contains(err.Message, "has no gitlab.test remote") {
		t.Fatalf("no remote: %v", err)
	}

	for _, bad := range []map[string]any{{"project": "no spaces/here x"}, {"pr": "3"}, {"repo": "a/b"}, {"anyone": "yes"}} {
		p := newPoller(t, f, "pr.merged", bad)
		if _, err := p.try(); err == nil || err.Code != -32602 {
			t.Fatalf("%v: %v", bad, err)
		}
	}
	unknown := newPoller(t, f, "issue.renamed", nil)
	if _, err := unknown.try(); err == nil || err.Code != -32011 {
		t.Fatalf("unknown: %v", err)
	}
}

func TestProjectByIDOrPath(t *testing.T) {
	f := newFake(t)
	p := newPoller(t, f, "pr.merged", map[string]any{"project": "group/sub/app"})
	p.poll()
	_, _ = p.try()
	asked := f.asked()
	if len(asked) == 0 || !strings.Contains(asked[0], "/projects/group%2Fsub%2Fapp/merge_requests") {
		t.Fatalf("asked %v", asked)
	}
}

// P20261020-2: a pr.opened wait on a project with 500 open merge requests lists them all each
// poll, but GitLab answers 304 while none changed, so an hour of polls is six pages of 304s
// each (five full and the empty one that ends the list) and no bodies, not 1.7 MB a poll. A merge request that changes is seen at the next poll.
func TestOpenedListsAgainOnlyWhatChanged(t *testing.T) {
	f := newFake(t)
	f.addMembers()
	for i := 1; i <= 500; i++ {
		f.mrs = append(f.mrs, mrJSON(i, "b"+strconv.Itoa(i), dev, obj{"draft": true, "description": strings.Repeat("words ", 500)}))
	}
	p := newPoller(t, f, "pr.opened", nil)
	p.poll()
	asked, sent := len(f.asked()), f.sent
	for poll := 1; poll <= 120; poll++ { // an hour at 30 s
		if ids, _ := p.poll(); len(ids) != 0 {
			t.Fatalf("poll %d: %v", poll, ids)
		}
	}
	requests, bytes := len(f.asked())-asked, f.sent-sent
	t.Logf("an hour of polls with 500 open: %d requests, %d bytes (the first poll: %d bytes)", requests, bytes, sent)
	if requests != 120*6 || bytes != 0 {
		t.Fatalf("an hour of polls: %d requests, %d bytes; want 720 and 0", requests, bytes)
	}
	f.set(func() { f.mrs[0]["draft"] = false })
	ids, _ := p.poll()
	if len(ids) != 1 || !strings.HasPrefix(ids[0], "pr.opened:group/app:1:") {
		t.Fatalf("ready: %v", ids)
	}
}

// Notify me (#2034): what asks the connection's owner, and their own merge requests only.
func TestReviewRequestedAndAssignedAreTheOwnersAndRaisedOnce(t *testing.T) {
	f := newFake(t)
	f.addMembers()
	f.mrs = []obj{mrJSON(1, "a", stranger, nil)}
	f.issues = []obj{issueObj(5, dev, nil)}
	reviews := newPoller(t, f, "review.requested", nil)
	assigned := newPoller(t, f, "issue.assigned", nil)
	reviews.poll()
	assigned.poll()
	f.set(func() {
		f.mrs[0]["reviewers"] = []obj{alex}
		f.issues[0]["assignees"] = []obj{alex}
	})
	ids, result := reviews.poll()
	if len(ids) != 1 || data(t, result, 0)["pr"].(map[string]any)["author"] != "stranger" {
		t.Fatalf("review: %v", ids)
	}
	ids, result = assigned.poll()
	if len(ids) != 1 || fmt.Sprint(data(t, result, 0)["issue"].(map[string]any)["number"]) != "5" {
		t.Fatalf("assigned: %v", ids)
	}
	ids, _ = reviews.poll()
	same(t, ids, nil)
	f.set(func() { f.mrs[0]["reviewers"] = []obj{dev} })
	reviews.poll()
	f.set(func() { f.mrs[0]["reviewers"] = []obj{alex} })
	if ids, _ = reviews.poll(); len(ids) != 1 {
		t.Fatalf("asked again: %v", ids)
	}
}

func TestMineIsOnlyTheOwnersMergeRequests(t *testing.T) {
	f := newFake(t)
	f.addMembers()
	f.mrs = []obj{mrJSON(1, "a", alex, nil), mrJSON(2, "b", dev, nil)}
	p := newPoller(t, f, "pr.conflicted", map[string]any{"mine": true})
	p.poll()
	f.set(func() {
		for _, m := range f.mrs {
			m["detailed_merge_status"], m["has_conflicts"] = "conflict", true
		}
	})
	ids, _ := p.poll()
	if len(ids) != 1 || !strings.HasPrefix(ids[0], "pr.conflicted:"+project+":1:") {
		t.Fatalf("mine: %v", ids)
	}
}

// #2349: the issues a merge request's description closes, in a nested group too.
func TestClosingRefs(t *testing.T) {
	got := closingRefs("Closes #4 and implements group/sub/project#9; fixing #4 again.")
	if len(got) != 2 || got[0] != "#4" || got[1] != "group/sub/project#9" {
		t.Fatalf("got %v", got)
	}
}

// #3797: every event about one merge request names it by pr, branch, fixes or mine, or takes
// any; an issue event takes one issue or a list of them.
func TestEventsListGivesWhichArgumentsNameOne(t *testing.T) {
	named := map[string]bool{"checks.failed": true, "pr.merged": true, "pr.closed": true, "pr.conflicted": true, "review.comment": true}
	for _, e := range eventsList()["events"].([]any) {
		e := e.(map[string]any)
		name := e["name"].(string)
		props := e["inputSchema"].(map[string]any)["properties"].(map[string]any)
		_, hasMine := props["mine"]
		_, hasFixes := props["fixes"]
		_, hasAny := props["any"]
		if hasMine != named[name] || hasFixes != named[name] {
			t.Fatalf("%s: mine %v, fixes %v", name, hasMine, hasFixes)
		}
		if want := named[name] || name == "run.completed" || name == "issue.closed" || name == "issue.commented" || name == "issue.labelled"; hasAny != want {
			t.Fatalf("%s: any %v", name, hasAny)
		}
		if hasFixes {
			items := props["fixes"].(map[string]any)["items"].(map[string]any)
			if props["fixes"].(map[string]any)["type"] != "array" || items["pattern"] == nil {
				t.Fatalf("%s: fixes %v", name, props["fixes"])
			}
		}
		if issue, ok := props["issue"].(map[string]any); ok {
			list := fmt.Sprint(issue["type"]) == "[integer array]"
			if list != (name != "issue.assigned") {
				t.Fatalf("%s: issue %v", name, issue)
			}
		}
		if strings.HasPrefix(name, "pr.") || name == "checks.failed" || name == "review.comment" {
			pr := e["payloadSchema"].(map[string]any)["properties"].(map[string]any)["pr"].(map[string]any)["properties"].(map[string]any)
			if _, ok := pr["fixes"]; !ok {
				t.Fatalf("%s: no fixes in pr", name)
			}
		}
	}
	for _, ref := range []string{"#12", "group/app#12", "group/sub/app#12"} {
		if !issueRefPattern.MatchString(ref) {
			t.Fatalf("refused %s", ref)
		}
	}
	for _, ref := range []string{"12", "app#12", "#0", "group/app#"} {
		if issueRefPattern.MatchString(ref) {
			t.Fatalf("took %s", ref)
		}
	}
}

func TestUnknownArgumentSaysWhatItTakes(t *testing.T) {
	f := newFake(t)
	_, err := newPoller(t, f, "pr.merged", map[string]any{"sha": "x"}).try()
	if err == nil || err.Code != -32602 || err.Message != "unknown argument sha; takes project, branch, pr, fixes, anyone, mine, any" {
		t.Fatalf("unknown: %v", err)
	}
	for _, bad := range []map[string]any{{"fixes": []any{"12"}}, {"fixes": []any{}}, {"fixes": "#12"}, {"any": "yes"}} {
		if _, err := newPoller(t, f, "pr.merged", bad).try(); err == nil || err.Code != -32602 {
			t.Fatalf("%v: %v", bad, err)
		}
	}
	for _, bad := range []any{[]any{}, []any{1, "2"}, []any{0}, "3"} {
		if _, err := newPoller(t, f, "issue.closed", map[string]any{"issue": bad}).try(); err == nil || err.Code != -32602 {
			t.Fatalf("issue %v: %v", bad, err)
		}
	}
}

// #3797: a lead knows the issue a lane's merge request fixes before it is opened, so fixes
// narrows by the issues a description closes, "#12" being the project's own; mine is the
// owner's merge request also once it is merged and no longer open.
func TestFixesAndMineNarrowMergedMRs(t *testing.T) {
	f := newFake(t)
	f.addMembers()
	f.mrs = []obj{
		mrJSON(1, "a", alex, obj{"description": "Closes #37."}),
		mrJSON(2, "b", dev, obj{"description": "Fixes group/sub/other#37"}),
		mrJSON(3, "c", dev, nil),
	}
	fixes := newPoller(t, f, "pr.merged", map[string]any{"fixes": []any{"#37"}})
	full := newPoller(t, f, "pr.merged", map[string]any{"fixes": []any{"Group/App#37", "group/sub/other#37"}})
	mine := newPoller(t, f, "pr.merged", map[string]any{"mine": true})
	all := newPoller(t, f, "pr.merged", map[string]any{"any": true})
	for _, p := range []*poller{fixes, full, mine, all} {
		p.poll()
	}
	f.set(func() {
		for _, m := range f.mrs {
			m["state"], m["merged_at"], m["updated_at"] = "merged", at(5), at(5)
		}
	})
	id := func(n int) string { return fmt.Sprintf("pr.merged:%s:%d", project, n) }
	ids, result := fixes.poll()
	same(t, ids, []string{id(1)})
	if got := fmt.Sprint(data(t, result, 0)["pr"].(map[string]any)["fixes"]); got != "[#37]" {
		t.Fatalf("fixes in the payload: %s", got)
	}
	ids, _ = full.poll()
	same(t, ids, []string{id(1), id(2)})
	ids, _ = mine.poll()
	same(t, ids, []string{id(1)})
	ids, _ = all.poll()
	same(t, ids, []string{id(1), id(2), id(3)})
}

// envelopeOf is a polled event's subject and key (#4728).
func envelopeOf(result map[string]any, i int) (subject, key string) {
	e := result["events"].([]any)[i].(map[string]any)
	subject, _ = e["subject"].(string)
	key, _ = e["key"].(string)
	return subject, key
}
