package azuredevopsmcp

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/gitlabmcp"
)

// The events over the fake Azure DevOps: the gitlab server's names, the trust filter (#728),
// and each one raised once from what Azure DevOps says.

func TestTheEventsAreTheGitLabServersPullRequestEventsAndChecksPassed(t *testing.T) {
	var want []string
	for _, name := range gitlabmcp.EventNames() {
		if !strings.HasPrefix(name, "issue.") {
			want = append(want, name)
		}
		if name == "checks.failed" {
			want = append(want, "checks.passed")
		}
	}
	same(t, EventNames(), want)
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
			pull(2, "feature", dev, obj{"description": "Fixes #12 and resolves AB#3"}),
			pull(3, "draft", alex, obj{"isDraft": true}),
			pull(4, "fork", alex, obj{"forkSource": obj{"name": "refs/heads/fork"}}),
			pull(5, "bot", builder, nil),
			pull(6, "renovate", renovate, nil))
	})
	ids, result := own.poll()
	if len(ids) != 1 || !strings.HasPrefix(ids[0], "pr.opened:acme/Web App/app:2:") {
		t.Fatalf("own: %v", ids)
	}
	pr := data(t, result, 0)["pr"].(map[string]any)
	if pr["author"] != "dev@acme.test" || pr["branch"] != "feature" || pr["number"] != 2 ||
		pr["url"] != f.server.URL+web+"/pullrequest/2" {
		t.Fatalf("pr %v", pr)
	}
	same(t, pr["fixes"], []string{"#12", "#3"})
	ids, _ = anyone.poll()
	if len(ids) != 4 {
		t.Fatalf("anyone: %v", ids)
	}

	// The draft published is raised; nothing else again.
	f.set(func() { f.pulls[2]["isDraft"] = false })
	ids, _ = own.poll()
	if len(ids) != 1 || !strings.HasPrefix(ids[0], "pr.opened:acme/Web App/app:3:") {
		t.Fatalf("published: %v", ids)
	}
	ids, _ = own.poll()
	same(t, ids, []string(nil))
}

func TestConflictedOnceAzureDevOpsKnows(t *testing.T) {
	f := newFake(t)
	f.pulls = []obj{pull(1, "feature", dev, nil)}
	p := newPoller(t, f, "pr.conflicted", nil)
	p.poll()
	f.set(func() { f.pulls[0]["mergeStatus"] = "queued" })
	ids, _ := p.poll() // still being worked out
	same(t, ids, []string(nil))
	f.set(func() { f.pulls[0]["mergeStatus"] = "conflicts" })
	ids, result := p.poll()
	if len(ids) != 1 || data(t, result, 0)["pr"].(map[string]any)["number"] != 1 {
		t.Fatalf("conflicted: %v", ids)
	}
	// Queued again after a push keeps the conflict it had: no new event.
	f.set(func() { f.pulls[0]["mergeStatus"] = "queued" })
	ids, _ = p.poll()
	same(t, ids, []string(nil))
	f.set(func() { f.pulls[0]["mergeStatus"] = "conflicts" })
	ids, _ = p.poll()
	same(t, ids, []string(nil))
	// Merges cleanly, then conflicts anew: a new event.
	f.set(func() { f.pulls[0]["mergeStatus"] = "succeeded" })
	p.poll()
	f.set(func() { f.pulls[0]["mergeStatus"] = "conflicts" })
	ids, _ = p.poll()
	if len(ids) != 1 {
		t.Fatalf("conflicted anew: %v", ids)
	}
}

func TestMergedAndClosedSinceTheCursor(t *testing.T) {
	f := newFake(t)
	f.pulls = []obj{pull(1, "old", dev, obj{"status": "completed", "closedDate": at(-5)})}
	merged := newPoller(t, f, "pr.merged", nil)
	closed := newPoller(t, f, "pr.closed", nil)
	merged.poll()
	closed.poll()
	f.set(func() {
		f.pulls = append(f.pulls,
			pull(2, "done", dev, obj{"status": "completed", "closedDate": at(1), "lastMergeCommit": obj{"commitId": "m2"}}),
			pull(3, "dropped", dev, obj{"status": "abandoned", "closedDate": at(1)}),
			pull(4, "fork", dev, obj{"status": "completed", "closedDate": at(1), "forkSource": obj{"name": "refs/heads/fork"}}))
	})
	ids, result := merged.poll()
	same(t, ids, []string{"pr.merged:acme/Web App/app:2"})
	same(t, data(t, result, 0)["mergeSha"], "m2")
	ids, _ = closed.poll()
	if len(ids) != 1 || !strings.HasPrefix(ids[0], "pr.closed:acme/Web App/app:3:") {
		t.Fatalf("closed: %v", ids)
	}
	ids, _ = merged.poll()
	same(t, ids, []string(nil))
}

func TestChecksFailedForAPullRequestsHead(t *testing.T) {
	f := newFake(t)
	f.pulls = []obj{pull(1, "feature", dev, nil), pull(2, "pushed", dev, nil)}
	p := newPoller(t, f, "checks.failed", nil)
	p.poll()
	f.set(func() {
		f.builds = []obj{
			build(11, 1, "sha1", "ci", "failed", 1),
			build(12, 1, "sha1", "lint", "succeeded", 1),
			build(13, 2, "old", "ci", "failed", 1),  // a push since: not its head's
			build(14, 8, "sha8", "ci", "failed", 1), // not an open pull request
		}
	})
	ids, result := p.poll()
	same(t, ids, []string{"checks.failed:acme/Web App/app:sha1:" + timeString(start.Add(60e9))})
	d := data(t, result, 0)
	same(t, d["headSha"], "sha1")
	url := "https://ado.test/acme/Web%20App/_build/results?buildId=11"
	same(t, d["run"], map[string]any{"id": 11, "name": "ci", "url": url})
	same(t, d["failedJobs"], []any{map[string]any{"name": "ci", "url": url}})
	ids, _ = p.poll()
	same(t, ids, []string(nil))
	// Run again and failed again: a new one.
	f.set(func() { f.builds = append(f.builds, build(15, 1, "sha1", "ci", "failed", 3)) })
	ids, _ = p.poll()
	if len(ids) != 1 {
		t.Fatalf("again: %v", ids)
	}
}

func TestChecksFailedFromABranchBuildAtTheHead(t *testing.T) {
	f := newFake(t)
	f.pulls = []obj{pull(1, "feature", dev, nil), pull(2, "pushed", dev, nil),
		pull(3, "forked", dev, obj{"forkSource": obj{"name": "fork"}})}
	p := newPoller(t, f, "checks.failed", nil)
	p.poll()
	f.set(func() {
		f.builds = []obj{
			branchBuild(21, "feature", "sha1", "ci", "failed", 1),
			branchBuild(22, "pushed", "old", "ci", "failed", 1),  // an older push's
			branchBuild(23, "forked", "sha3", "ci", "failed", 1), // this repository's branch, not the fork's
			branchBuild(24, "main", "sha1", "ci", "failed", 1),   // no pull request's branch
		}
	})
	ids, result := p.poll()
	same(t, ids, []string{"checks.failed:acme/Web App/app:sha1:" + timeString(start.Add(60e9))})
	url := "https://ado.test/acme/Web%20App/_build/results?buildId=21"
	same(t, data(t, result, 0)["run"], map[string]any{"id": 21, "name": "ci", "url": url})
}

func TestChecksFailedFromAnotherServicesStatus(t *testing.T) {
	f := newFake(t)
	f.pulls = []obj{pull(1, "feature", dev, nil), pull(2, "fixed", dev, nil), pull(3, "pushed", dev, nil)}
	f.iterations[3] = []obj{{"id": 1}, {"id": 2}}
	p := newPoller(t, f, "checks.failed", nil)
	p.poll()
	f.set(func() {
		f.statuses[1] = []obj{prStatus(1, "scan", "deps", "failed", 1, 0), prStatus(2, "scan", "licence", "error", 1, 0)}
		// Failed, then passed: the newest of a context counts.
		f.statuses[2] = []obj{prStatus(3, "scan", "deps", "failed", 1, 0), prStatus(4, "scan", "deps", "succeeded", 1, 0)}
		// Of the first push, not the head's.
		f.statuses[3] = []obj{prStatus(5, "scan", "deps", "failed", 1, 1)}
	})
	ids, result := p.poll()
	same(t, ids, []string{"checks.failed:acme/Web App/app:sha1:" + timeString(start.Add(60e9))})
	d := data(t, result, 0)
	same(t, d["run"], map[string]any{"id": 0, "name": "scan/deps", "url": "https://scan.test/1"})
	same(t, d["failedJobs"], []any{map[string]any{"name": "scan/deps", "url": "https://scan.test/1"},
		map[string]any{"name": "scan/licence", "url": "https://scan.test/2"}})
	ids, _ = p.poll()
	same(t, ids, []string(nil))
	// A failed build too: the build is the run.
	f.set(func() {
		f.statuses[3] = append(f.statuses[3], prStatus(6, "scan", "deps", "failed", 3, 2))
		f.builds = []obj{build(31, 1, "sha1", "ci", "failed", 3)}
	})
	ids, result = p.poll()
	same(t, ids, []string{"checks.failed:acme/Web App/app:sha1:" + timeString(start.Add(180e9)),
		"checks.failed:acme/Web App/app:sha3:" + timeString(start.Add(180e9))})
	same(t, data(t, result, 0)["run"].(map[string]any)["id"], 31)
}

func TestChecksPassedForEachBuildAndStatusAtTheHead(t *testing.T) {
	f := newFake(t)
	f.pulls = []obj{pull(1, "feature", dev, nil), pull(2, "bot", renovate, nil)}
	p := newPoller(t, f, "checks.passed", nil)
	mine := newPoller(t, f, "checks.passed", map[string]any{"pr": 1})
	p.poll()
	mine.poll()
	f.set(func() {
		f.builds = []obj{
			build(41, 1, "sha1", "ci", "succeeded", 1),
			branchBuild(42, "feature", "sha1", "push", "succeeded", 1),
			build(43, 1, "sha1", "lint", "failed", 1),
			build(44, 1, "sha1", "flaky", "canceled", 1),
			build(45, 2, "sha2", "ci", "succeeded", 1), // a bot's pull request
		}
		f.statuses[1] = []obj{prStatus(7, "scan", "deps", "succeeded", 1, 0), prStatus(8, "scan", "wait", "pending", 1, 0)}
	})
	ids, result := p.poll()
	at := timeString(start.Add(60e9))
	same(t, ids, []string{"checks.passed:acme/Web App/app:sha1:build:41:" + at, "checks.passed:acme/Web App/app:sha1:build:42:" + at,
		"checks.passed:acme/Web App/app:sha1:status:7:" + at})
	d := data(t, result, 0)
	same(t, d["headSha"], "sha1")
	same(t, d["pr"].(map[string]any)["number"], 1)
	same(t, d["run"], map[string]any{"id": 41, "name": "ci", "url": "https://ado.test/acme/Web%20App/_build/results?buildId=41"})
	same(t, data(t, result, 2)["run"], map[string]any{"id": 0, "name": "scan/deps", "url": "https://scan.test/7"})
	ids, _ = mine.poll()
	if len(ids) != 3 {
		t.Fatalf("pr 1: %v", ids)
	}
	ids, _ = p.poll()
	same(t, ids, []string(nil))
}

func TestReviewCommentIsALineOfTheDiff(t *testing.T) {
	f := newFake(t)
	f.pulls = []obj{pull(1, "feature", alex, nil)}
	p := newPoller(t, f, "review.comment", nil)
	p.poll()
	f.set(func() {
		f.threads[1] = []obj{
			{"id": 40, "status": "active", "threadContext": obj{"filePath": "/main.go", "rightFileStart": obj{"line": 12, "offset": 1}},
				"comments": []any{
					obj{"id": 1, "author": dev, "content": "Rename this.", "publishedDate": at(1), "commentType": "text"},
					obj{"id": 2, "author": builder, "content": "Policy.", "publishedDate": at(1), "commentType": "text"},
				}},
			// Not on a line: a comment on the whole pull request.
			{"id": 41, "status": "active", "comments": []any{obj{"id": 1, "author": dev, "content": "LGTM", "publishedDate": at(1), "commentType": "text"}}},
			{"id": 42, "comments": []any{obj{"id": 1, "author": dev, "content": "Dev voted", "publishedDate": at(1), "commentType": "system"}}},
		}
	})
	ids, result := p.poll()
	same(t, ids, []string{"review.comment:acme/Web App/app:1:40:1"})
	same(t, data(t, result, 0)["comment"], map[string]any{"id": 1, "threadId": 40, "author": "dev@acme.test", "path": "main.go", "line": 12,
		"body": "Rename this.", "url": f.server.URL + web + "/pullrequest/1?discussionId=40"})
	ids, _ = p.poll()
	same(t, ids, []string(nil))
}

func TestReviewRequestedIsTheOwnersAndRaisedOnce(t *testing.T) {
	f := newFake(t)
	requested := newPoller(t, f, "review.requested", nil)
	requested.poll()
	f.set(func() {
		f.pulls = []obj{
			pull(1, "a", dev, obj{"reviewers": []any{merged(alex, obj{"vote": 0})}}),
			pull(2, "b", dev, obj{"reviewers": []any{merged(dev, obj{"vote": 0})}}),
			pull(3, "c", dev, obj{"reviewers": []any{merged(alex, obj{"vote": 10})}}),
		}
	})
	ids, _ := requested.poll()
	if len(ids) != 1 || !strings.HasPrefix(ids[0], "review.requested:acme/Web App/app:1:") {
		t.Fatalf("requested: %v", ids)
	}
	ids, _ = requested.poll()
	same(t, ids, []string(nil))
	// A vote, then a push that resets it: asked again.
	f.set(func() { f.pulls[0]["reviewers"] = []any{merged(alex, obj{"vote": 10})} })
	requested.poll()
	f.set(func() { f.pulls[0]["reviewers"] = []any{merged(alex, obj{"vote": 0})} })
	ids, _ = requested.poll()
	if len(ids) != 1 {
		t.Fatalf("asked again: %v", ids)
	}
}

func merged(a, b obj) obj {
	out := obj{}
	for k, v := range a {
		out[k] = v
	}
	for k, v := range b {
		out[k] = v
	}
	return out
}

func TestMineIsOnlyTheOwnersPullRequests(t *testing.T) {
	f := newFake(t)
	f.pulls = []obj{pull(1, "mine", alex, nil), pull(2, "theirs", dev, nil)}
	p := newPoller(t, f, "pr.conflicted", map[string]any{"mine": true})
	p.poll()
	f.set(func() { f.pulls[0]["mergeStatus"], f.pulls[1]["mergeStatus"] = "conflicts", "conflicts" })
	ids, _ := p.poll()
	if len(ids) != 1 || !strings.HasPrefix(ids[0], "pr.conflicted:acme/Web App/app:1:") {
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
	f.set(func() { f.status, f.signIn = 0, true })
	if _, err = p.events.Poll(context.Background(), raw); err == nil || err.Code != -32012 {
		t.Fatalf("a sign-in page: %+v", err)
	}
	raw, _ = json.Marshal(map[string]any{"name": "pr.merged", "arguments": map[string]any{"repo": "acme/app"}})
	if _, err = p.events.Poll(context.Background(), raw); err == nil || err.Code != -32602 {
		t.Fatalf("bad repo: %+v", err)
	}
	raw, _ = json.Marshal(map[string]any{"name": "issue.opened"})
	if _, err = p.events.Poll(context.Background(), raw); err == nil || err.Code != -32011 {
		t.Fatalf("no such event: %+v", err)
	}
}

func TestRepoOfRemote(t *testing.T) {
	for _, c := range []struct {
		base, remote, want string
	}{
		{"", "https://dev.azure.com/acme/Web%20App/_git/app", "acme/Web App/app"},
		{"", "https://alex@dev.azure.com/acme/Web%20App/_git/app", "acme/Web App/app"},
		{"", "git@ssh.dev.azure.com:v3/acme/Web%20App/app", "acme/Web App/app"},
		{"", "ssh://git@ssh.dev.azure.com/v3/acme/proj/app", "acme/proj/app"},
		{"", "https://acme.visualstudio.com/proj/_git/app", "acme/proj/app"},
		{"", "https://acme.visualstudio.com/DefaultCollection/proj/_git/app", "acme/proj/app"},
		{"", "acme@vs-ssh.visualstudio.com:v3/acme/proj/app", "acme/proj/app"},
		{"", "https://dev.azure.com/acme/_git/app", "acme/app/app"},
		{"https://tfs.example.com/tfs", "https://tfs.example.com/tfs/Main/proj/_git/app", "Main/proj/app"},
		{"https://tfs.example.com/tfs", "ssh://tfs.example.com:22/tfs/Main/proj/_git/app", "Main/proj/app"},
		{"https://tfs.example.com/tfs", "https://tfs.example.com/Main/proj/_git/app", ""},
		{"", "https://github.com/acme/app", ""},
		{"", "https://dev.azure.com/acme/proj/app", ""},
	} {
		got, _ := RepoOfRemote(c.base, c.remote)
		if got != c.want {
			t.Errorf("%s at %s: got %q, want %q", c.remote, c.base, got, c.want)
		}
	}
}

func TestBaseURL(t *testing.T) {
	same(t, BaseURL(""), "https://dev.azure.com/")
	same(t, BaseURL("tfs.example.com/tfs/"), "https://tfs.example.com/tfs/")
	same(t, BaseURL("http://localhost:8080"), "http://localhost:8080/")
}

func TestBuildServicesAndGroupsAreBots(t *testing.T) {
	for _, i := range []identity{
		{DisplayName: "Project Collection Build Service (acme)", UniqueName: `Build\acme`},
		{DisplayName: "app Build Service (acme)"},
		{DisplayName: "Reviewers", IsContainer: true},
		{DisplayName: "dependabot[bot]"},
		{DisplayName: "x", Descriptor: "s2s.abc"},
	} {
		if !isBot(i) {
			t.Errorf("%+v is not a bot", i)
		}
	}
	if isBot(identity{DisplayName: "Robot Smith", UniqueName: "robot@acme.test", Descriptor: "aad.x"}) {
		t.Error("a person is a bot")
	}
}
