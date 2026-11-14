package forgejomcp

import (
	"context"
	"encoding/json"
	"reflect"
	"strconv"
	"strings"
	"testing"

	"github.com/agentloops-dev/agent-loops/Go/internal/gitlabmcp"
	"github.com/agentloops-dev/agent-loops/Go/internal/mcpevents"
)

// The events over the fake Forgejo: the gitlab server's names, the trust filter (#728), and
// each one raised once from what Forgejo says.

func TestTheEventsAreTheGitLabServersNames(t *testing.T) {
	// The gitlab server's, but for run.completed and deploy.waiting, which each forge has
	// where its API does; run.completed is after checks.failed, as there (#4217). Forgejo has
	// no deployments, so none of deploy.started, deploy.succeeded and deploy.failed (#5244).
	without := func(names []string) []string {
		var out []string
		for _, n := range names {
			if n != "run.completed" && n != "deploy.waiting" && !mcpevents.IsDeployEvent(n) {
				out = append(out, n)
			}
		}
		return out
	}
	same(t, without(EventNames()), without(gitlabmcp.EventNames()))
	if names := EventNames(); len(without(names)) != len(names) && names[1] != "run.completed" {
		t.Fatalf("run.completed is not after checks.failed: %v", names)
	}
}

func TestOpenedIsRaisedWhenReadyAndOnlyForTheReposOwn(t *testing.T) {
	f := newFake(t)
	f.pulls = []obj{pull(1, "old", alex, nil)}
	own := newPoller(t, f, "pr.opened", nil)
	anyone := newPoller(t, f, "pr.opened", map[string]any{"anyone": true})
	ids, _ := own.poll()
	same(t, ids, []string(nil)) // the first poll takes what is open as known
	anyone.poll()

	f.set(func() {
		f.pulls = append(f.pulls,
			pull(2, "feature", dev, obj{"body": "Fixes #12 and closes other/repo#3"}),
			pull(3, "wip", alex, obj{"title": "WIP: not yet"}),
			pull(4, "fork", alex, obj{"head": obj{"ref": "fork", "sha": "s4", "repo_id": 99}}),
			pull(5, "outside", stranger, nil),
			pull(6, "bot", renovate, nil),
			pull(7, "reader", reader, nil))
	})
	ids, result := own.poll()
	if len(ids) != 1 || !strings.HasPrefix(ids[0], "pr.opened:acme/app:2:") {
		t.Fatalf("own: %v", ids)
	}
	pr := data(t, result, 0)["pr"].(map[string]any)
	if pr["author"] != "dev" || pr["branch"] != "feature" || pr["number"] != 2 {
		t.Fatalf("pr %v", pr)
	}
	same(t, pr["fixes"], []string{"#12", "other/repo#3"})
	ids, _ = anyone.poll()
	if len(ids) != 5 {
		t.Fatalf("anyone: %v", ids)
	}

	// The draft marked ready is raised; nothing else again.
	f.set(func() { f.pulls[2]["title"] = "Ready now" })
	ids, _ = own.poll()
	if len(ids) != 1 || !strings.HasPrefix(ids[0], "pr.opened:acme/app:3:") {
		t.Fatalf("ready: %v", ids)
	}
	ids, _ = own.poll()
	same(t, ids, []string(nil))
}

func TestAnAdminlessTokenTrustsCollaborators(t *testing.T) {
	f := newFake(t)
	f.adminless = true
	f.collaborators["dev"] = true
	own := newPoller(t, f, "pr.opened", nil)
	own.poll()
	f.set(func() { f.pulls = []obj{pull(1, "a", dev, nil), pull(2, "b", stranger, nil), pull(3, "c", alex, nil)} })
	ids, _ := own.poll()
	// dev is a collaborator, alex owns nothing here but is not acme: only dev.
	if len(ids) != 1 || !strings.HasPrefix(ids[0], "pr.opened:acme/app:1:") {
		t.Fatalf("adminless: %v", ids)
	}
}

func TestConflictedWaitsAMinuteForForgejoToKnow(t *testing.T) {
	f := newFake(t)
	f.pulls = []obj{pull(1, "feature", dev, nil)}
	p := newPoller(t, f, "pr.conflicted", nil)
	p.poll()
	f.set(func() { f.pulls[0]["mergeable"] = false })
	ids, _ := p.poll() // first seen not mergeable: it may still be being checked
	same(t, ids, []string(nil))
	ids, result := p.poll() // a minute on, still not: a conflict
	if len(ids) != 1 || data(t, result, 0)["pr"].(map[string]any)["number"] != 1 {
		t.Fatalf("conflicted: %v", ids)
	}
	ids, _ = p.poll()
	same(t, ids, []string(nil))
	// Mergeable again, then in conflict anew: a new event, after its minute.
	f.set(func() { f.pulls[0]["mergeable"] = true })
	p.poll()
	f.set(func() { f.pulls[0]["mergeable"] = false })
	p.poll()
	ids, _ = p.poll()
	if len(ids) != 1 {
		t.Fatalf("conflicted anew: %v", ids)
	}
}

func TestMergedAndClosedSinceTheCursor(t *testing.T) {
	f := newFake(t)
	f.pulls = []obj{pull(1, "old", dev, obj{"state": "closed", "merged": true, "merged_at": at(-5), "updated_at": at(-5)})}
	merged := newPoller(t, f, "pr.merged", nil)
	closed := newPoller(t, f, "pr.closed", nil)
	merged.poll()
	closed.poll()
	f.set(func() {
		f.pulls = append(f.pulls,
			pull(2, "done", dev, obj{"state": "closed", "merged": true, "merged_at": at(1), "updated_at": at(1), "merge_commit_sha": "m2"}),
			pull(3, "dropped", dev, obj{"state": "closed", "closed_at": at(1), "updated_at": at(1)}),
			pull(4, "fork", dev, obj{"state": "closed", "merged": true, "merged_at": at(1), "updated_at": at(1),
				"head": obj{"ref": "fork", "sha": "s4", "repo_id": 99}}))
	})
	ids, result := merged.poll()
	same(t, ids, []string{"pr.merged:acme/app:2"})
	if sub, key := envelopeOf(result, 0); sub != "forgejo:pr:acme/app#2" || key != "" {
		t.Fatalf("merged: subject %q, key %q", sub, key)
	}
	same(t, data(t, result, 0)["mergeSha"], "m2")
	ids, result = closed.poll()
	if len(ids) != 1 || !strings.HasPrefix(ids[0], "pr.closed:acme/app:3:") {
		t.Fatalf("closed: %v", ids)
	}
	ids, _ = merged.poll()
	same(t, ids, []string(nil))
	if sub, key := envelopeOf(result, 0); !strings.HasSuffix(sub, "#3") || key == "" {
		t.Fatalf("closed: subject %q, key %q (#4728: a PR closed again is a new event)", sub, key)
	}
}

func TestChecksFailedForAPullRequestsHead(t *testing.T) {
	f := newFake(t)
	f.pulls = []obj{pull(1, "feature", dev, nil), pull(2, "green", dev, nil)}
	p := newPoller(t, f, "checks.failed", nil)
	p.poll()
	f.set(func() {
		f.statuses["sha1"] = obj{"state": "failure", "sha": "sha1", "statuses": []any{
			obj{"context": "ci / test (pull_request)", "status": "failure", "target_url": "https://forgejo.test/acme/app/actions/runs/12/jobs/0", "updated_at": at(1)},
			obj{"context": "ci / lint (pull_request)", "status": "success", "target_url": "https://forgejo.test/acme/app/actions/runs/12/jobs/1", "updated_at": at(1)},
		}}
		f.statuses["sha2"] = obj{"state": "success", "sha": "sha2", "statuses": []any{}}
	})
	ids, result := p.poll()
	same(t, ids, []string{"checks.failed:acme/app:sha1:" + mcpevents.TimeString(start.Add(60e9))})
	d := data(t, result, 0)
	same(t, d["headSha"], "sha1")
	same(t, d["run"], map[string]any{"id": 12, "name": "ci / test (pull_request)", "url": "https://forgejo.test/acme/app/actions/runs/12/jobs/0"})
	same(t, d["failedJobs"], []any{map[string]any{"name": "ci / test (pull_request)", "url": "https://forgejo.test/acme/app/actions/runs/12/jobs/0"}})
	ids, _ = p.poll()
	same(t, ids, []string(nil))
	// Run again and failed again: a new one.
	f.set(func() {
		f.statuses["sha1"]["statuses"].([]any)[0].(obj)["updated_at"] = at(3)
	})
	ids, _ = p.poll()
	if len(ids) != 1 {
		t.Fatalf("again: %v", ids)
	}
}

func TestIssueEvents(t *testing.T) {
	f := newFake(t)
	opened := newPoller(t, f, "issue.opened", nil)
	commented := newPoller(t, f, "issue.commented", nil)
	closed := newPoller(t, f, "issue.closed", nil)
	// A lead waits on all its open children at once (#3797).
	closedList := newPoller(t, f, "issue.closed", map[string]any{"issue": []any{1, 3}})
	closedOther := newPoller(t, f, "issue.closed", map[string]any{"issue": []any{1}})
	labelled := newPoller(t, f, "issue.labelled", map[string]any{"label": "agent"})
	for _, p := range []*poller{opened, commented, closed, closedList, closedOther, labelled} {
		p.poll()
	}
	f.set(func() {
		f.issues = []obj{
			issue(1, dev, obj{"created_at": at(1), "updated_at": at(1), "labels": []any{obj{"name": "agent"}}}),
			issue(2, stranger, obj{"created_at": at(1), "updated_at": at(1)}),
			issue(3, dev, obj{"state": "closed", "created_at": at(-5), "closed_at": at(1), "updated_at": at(1)}),
		}
		f.comments = []obj{
			{"id": 10, "issue_url": "https://forgejo.test/acme/app/issues/2", "pull_request_url": "", "user": dev, "body": "Seen it.",
				"html_url": "https://forgejo.test/acme/app/issues/2#issuecomment-10", "created_at": at(1), "updated_at": at(1)},
			{"id": 11, "issue_url": "https://forgejo.test/acme/app/issues/5", "pull_request_url": "https://forgejo.test/acme/app/pulls/5",
				"user": dev, "body": "On a PR.", "created_at": at(1), "updated_at": at(1)},
		}
		f.timeline[1] = []obj{
			{"id": 20, "type": "label", "body": "1", "user": dev, "created_at": at(1), "label": obj{"name": "agent"}},
			{"id": 21, "type": "label", "body": "", "user": dev, "created_at": at(1), "label": obj{"name": "bug"}},
		}
		f.timeline[3] = []obj{{"id": 30, "type": "close", "user": alex, "created_at": at(1)}}
	})
	ids, _ := opened.poll()
	same(t, ids, []string{"issue.opened:acme/app:1"})
	ids, result := commented.poll()
	same(t, ids, []string{"issue.commented:acme/app:10"})
	same(t, data(t, result, 0)["comment"], map[string]any{"author": "dev", "url": "https://forgejo.test/acme/app/issues/2#issuecomment-10", "body": "Seen it."})
	ids, result = closed.poll()
	same(t, ids, []string{"issue.closed:acme/app:3:" + mcpevents.TimeString(start.Add(60e9))})
	same(t, data(t, result, 0)["by"], "alex")
	ids, _ = closedList.poll()
	same(t, ids, []string{"issue.closed:acme/app:3:" + mcpevents.TimeString(start.Add(60e9))})
	ids, _ = closedOther.poll()
	same(t, ids, []string(nil))
	ids, result = labelled.poll()
	same(t, ids, []string{"issue.labelled:acme/app:label:20"})
	same(t, data(t, result, 0)["label"], "agent")
}

func TestReviewCommentIsALineOfTheDiff(t *testing.T) {
	f := newFake(t)
	f.pulls = []obj{pull(1, "feature", alex, nil)}
	p := newPoller(t, f, "review.comment", nil)
	p.poll()
	f.set(func() {
		f.pulls[0]["updated_at"] = at(1)
		f.reviews[1] = []obj{{"id": 40, "user": dev, "state": "COMMENT", "comments_count": 2, "submitted_at": at(1), "updated_at": at(1)}}
		f.lines[40] = []obj{
			{"id": 41, "body": "Rename this.", "user": dev, "path": "main.go", "position": 12, "html_url": "https://forgejo.test/c/41", "created_at": at(1)},
			{"id": 42, "body": "Spam.", "user": stranger, "path": "main.go", "position": 3, "created_at": at(1)},
		}
	})
	ids, result := p.poll()
	same(t, ids, []string{"review.comment:acme/app:41"})
	same(t, data(t, result, 0)["comment"], map[string]any{"id": 41, "author": "dev", "path": "main.go", "line": 12, "body": "Rename this.",
		"url": "https://forgejo.test/c/41"})
}

func TestReviewRequestedAndAssignedAreTheOwnersAndRaisedOnce(t *testing.T) {
	f := newFake(t)
	requested := newPoller(t, f, "review.requested", nil)
	assigned := newPoller(t, f, "issue.assigned", nil)
	requested.poll()
	assigned.poll()
	f.set(func() {
		f.pulls = []obj{pull(1, "a", stranger, obj{"requested_reviewers": []any{alex}}), pull(2, "b", dev, obj{"requested_reviewers": []any{dev}})}
		f.issues = []obj{issue(3, stranger, obj{"assignees": []any{alex}}), issue(4, dev, obj{"assignees": []any{dev}})}
	})
	ids, _ := requested.poll()
	if len(ids) != 1 || !strings.HasPrefix(ids[0], "review.requested:acme/app:1:") {
		t.Fatalf("requested: %v", ids)
	}
	ids, _ = assigned.poll()
	if len(ids) != 1 || !strings.HasPrefix(ids[0], "issue.assigned:acme/app:3:") {
		t.Fatalf("assigned: %v", ids)
	}
	ids, _ = requested.poll()
	same(t, ids, []string(nil))
}

func TestMineIsOnlyTheOwnersPullRequests(t *testing.T) {
	f := newFake(t)
	f.pulls = []obj{pull(1, "mine", alex, nil), pull(2, "theirs", dev, nil)}
	p := newPoller(t, f, "pr.conflicted", map[string]any{"mine": true})
	p.poll()
	f.set(func() { f.pulls[0]["mergeable"], f.pulls[1]["mergeable"] = false, false })
	p.poll()
	ids, _ := p.poll()
	if len(ids) != 1 || !strings.HasPrefix(ids[0], "pr.conflicted:acme/app:1:") {
		t.Fatalf("mine: %v", ids)
	}
}

func TestFailuresAreTheDraftsErrors(t *testing.T) {
	f := newFake(t)
	p := newPoller(t, f, "pr.merged", nil)
	p.poll()
	f.set(func() { f.status = 429 })
	raw, _ := json.Marshal(map[string]any{"name": "pr.merged", "cursor": p.cursor})
	_, err := p.events.Poll(context.Background(), raw)
	if err == nil || err.Code != -32013 || err.Data["retryAfterMs"] != 7000 {
		t.Fatalf("rate limited: %+v", err)
	}
	f.set(func() { f.status = 401 })
	if _, err = p.events.Poll(context.Background(), raw); err == nil || err.Code != -32012 {
		t.Fatalf("not signed in: %+v", err)
	}
	raw, _ = json.Marshal(map[string]any{"name": "pr.merged", "arguments": map[string]any{"repo": "no-slash"}})
	if _, err = p.events.Poll(context.Background(), raw); err == nil || err.Code != -32602 {
		t.Fatalf("bad repo: %+v", err)
	}
	raw, _ = json.Marshal(map[string]any{"name": "pr.labelled"})
	if _, err = p.events.Poll(context.Background(), raw); err == nil || err.Code != -32011 {
		t.Fatalf("no such event: %+v", err)
	}
}

func TestRepoOfRemote(t *testing.T) {
	for _, c := range []struct {
		base, remote, want string
	}{
		{"", "https://codeberg.org/acme/app.git", "acme/app"},
		{"", "git@codeberg.org:acme/app.git", "acme/app"},
		{"", "ssh://git@codeberg.org:2222/acme/app", "acme/app"},
		{"https://git.example.com/forgejo", "https://git.example.com/forgejo/acme/app", "acme/app"},
		{"https://git.example.com/forgejo", "https://git.example.com/acme/app", ""},
		{"", "https://github.com/acme/app", ""},
		{"", "https://codeberg.org/acme/sub/app", ""},
	} {
		got, _ := RepoOfRemote(c.base, c.remote)
		if got != c.want {
			t.Errorf("%s at %s: got %q, want %q", c.remote, c.base, got, c.want)
		}
	}
}

func TestBaseURL(t *testing.T) {
	same(t, BaseURL(""), "https://codeberg.org/")
	same(t, BaseURL("git.example.com/api/v1/"), "https://git.example.com/")
	same(t, BaseURL("http://localhost:3000"), "http://localhost:3000/")
}

// Every event about one pull request is named by pr, branch, fixes or mine, or takes any
// (#3797); the issue events but issue.opened take a list of issues and any too.
func TestEventsListSchemas(t *testing.T) {
	named := map[string]bool{"checks.failed": true, "pr.merged": true, "pr.closed": true, "pr.conflicted": true, "review.comment": true}
	for _, e := range eventsList()["events"].([]any) {
		e := e.(map[string]any)
		name := e["name"].(string)
		props := e["inputSchema"].(map[string]any)["properties"].(map[string]any)
		has := func(key string, want bool) {
			if _, ok := props[key]; ok != want {
				t.Errorf("%s: %s is %v, want %v", name, key, ok, want)
			}
		}
		has("mine", named[name])
		has("fixes", named[name])
		has("any", named[name] || name == "run.completed" || name == "issue.closed" || name == "issue.commented" || name == "issue.labelled")
		if issue, ok := props["issue"].(map[string]any); ok && name != "issue.assigned" && !reflect.DeepEqual(issue["type"], []string{"integer", "array"}) {
			t.Errorf("%s: issue is %v", name, issue["type"])
		}
		if pr, ok := e["payloadSchema"].(map[string]any)["properties"].(map[string]any)["pr"].(map[string]any); ok {
			if _, ok := pr["properties"].(map[string]any)["fixes"]; !ok {
				t.Errorf("%s: pr has no fixes", name)
			}
		}
	}
	raw, _ := json.Marshal(map[string]any{"name": "pr.merged", "arguments": map[string]any{"repo": repo, "sha": "x"}})
	_, err := newPoller(t, newFake(t), "pr.merged", nil).events.Poll(context.Background(), raw)
	if err == nil || err.Code != -32602 || err.Message != "unknown argument sha; takes repo, branch, pr, fixes, anyone, mine, any" {
		t.Fatalf("unknown argument: %+v", err)
	}
}

// #3797: a lead knows the issue a lane's pull request fixes before it is opened, so fixes
// narrows by the issues a description closes, "#12" being the repository's own; mine is
// the owner's pull request also once it is merged and no longer open.
func TestFixesAndMineNarrowMergedPRs(t *testing.T) {
	f := newFake(t)
	fixes := newPoller(t, f, "pr.merged", map[string]any{"fixes": []any{"#3795"}})
	full := newPoller(t, f, "pr.merged", map[string]any{"fixes": []any{"ACME/app#3795", "other/repo#3795"}})
	mine := newPoller(t, f, "pr.merged", map[string]any{"mine": true})
	all := newPoller(t, f, "pr.merged", map[string]any{"any": true})
	for _, p := range []*poller{fixes, full, mine, all} {
		p.poll()
	}
	merged := func(n int, author obj, body string) obj {
		return pull(n, "b"+strconv.Itoa(n), author, obj{"state": "closed", "merged": true, "merged_at": at(1), "updated_at": at(1), "body": body})
	}
	f.set(func() {
		f.pulls = []obj{merged(501, alex, "Fixes #3795"), merged(502, dev, "Closes other/repo#3795"), merged(503, dev, "")}
	})
	id := func(n int) string { return "pr.merged:acme/app:" + strconv.Itoa(n) }
	ids, _ := fixes.poll()
	same(t, ids, []string{id(501)})
	ids, _ = full.poll()
	same(t, ids, []string{id(501), id(502)})
	ids, _ = mine.poll()
	same(t, ids, []string{id(501)})
	ids, _ = all.poll()
	same(t, ids, []string{id(501), id(502), id(503)})
	raw, _ := json.Marshal(map[string]any{"name": "pr.merged", "arguments": map[string]any{"repo": repo, "fixes": []any{"3795"}}})
	if _, err := fixes.events.Poll(context.Background(), raw); err == nil || err.Code != -32602 || !strings.Contains(err.Message, `"#12"`) {
		t.Fatalf("a bare number: %+v", err)
	}
}

// envelopeOf is a polled event's subject and key (#4728).
func envelopeOf(result map[string]any, i int) (subject, key string) {
	e := result["events"].([]any)[i].(map[string]any)
	subject, _ = e["subject"].(string)
	key, _ = e["key"].(string)
	return subject, key
}
