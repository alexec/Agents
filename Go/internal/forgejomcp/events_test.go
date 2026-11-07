package forgejomcp

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/gitlabmcp"
)

// The events over the fake Forgejo: the gitlab server's names, the trust filter (#728), and
// each one raised once from what Forgejo says.

func TestTheEventsAreTheGitLabServersNames(t *testing.T) {
	same(t, EventNames(), gitlabmcp.EventNames())
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
	same(t, data(t, result, 0)["mergeSha"], "m2")
	ids, _ = closed.poll()
	if len(ids) != 1 || !strings.HasPrefix(ids[0], "pr.closed:acme/app:3:") {
		t.Fatalf("closed: %v", ids)
	}
	ids, _ = merged.poll()
	same(t, ids, []string(nil))
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
	same(t, ids, []string{"checks.failed:acme/app:sha1:" + timeString(start.Add(60e9))})
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
	labelled := newPoller(t, f, "issue.labelled", map[string]any{"label": "agent"})
	for _, p := range []*poller{opened, commented, closed, labelled} {
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
	same(t, ids, []string{"issue.closed:acme/app:3:" + timeString(start.Add(60e9))})
	same(t, data(t, result, 0)["by"], "alex")
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
