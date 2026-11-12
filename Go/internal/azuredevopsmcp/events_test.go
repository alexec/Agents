package azuredevopsmcp

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/gitlabmcp"
	"github.com/alexec/agents/Go/internal/mcpevents"
)

// The events over the fake Azure DevOps: the gitlab server's names, the trust filter (#728),
// and each one raised once from what Azure DevOps says.

func TestTheEventsAreTheGitLabServersPullRequestEventsChecksPassedRunCompletedAndDeployWaiting(t *testing.T) {
	var want []string
	for _, name := range gitlabmcp.EventNames() {
		// The gitlab server's own run.completed and deploy.waiting are here after checks.passed (#4217).
		if !strings.HasPrefix(name, "issue.") && name != "run.completed" && name != "deploy.waiting" {
			want = append(want, name)
		}
		if name == "checks.failed" {
			want = append(want, "checks.passed", "run.completed", "deploy.waiting")
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
	if sub, key := envelopeOf(result, 0); sub != "azuredevops:pr:acme/web app/app#2" || key != "" {
		t.Fatalf("merged: subject %q, key %q", sub, key)
	}
	same(t, data(t, result, 0)["mergeSha"], "m2")
	ids, result = closed.poll()
	if len(ids) != 1 || !strings.HasPrefix(ids[0], "pr.closed:acme/Web App/app:3:") {
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
	same(t, ids, []string{"checks.failed:acme/Web App/app:sha1:" + mcpevents.TimeString(start.Add(60e9))})
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
	same(t, ids, []string{"checks.failed:acme/Web App/app:sha1:" + mcpevents.TimeString(start.Add(60e9))})
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
	same(t, ids, []string{"checks.failed:acme/Web App/app:sha1:" + mcpevents.TimeString(start.Add(60e9))})
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
	same(t, ids, []string{"checks.failed:acme/Web App/app:sha1:" + mcpevents.TimeString(start.Add(180e9)),
		"checks.failed:acme/Web App/app:sha3:" + mcpevents.TimeString(start.Add(180e9))})
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
	at := mcpevents.TimeString(start.Add(60e9))
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

// run.completed (#3810) is a build of any trigger and result, main's, a tag's or a manual
// run's, once per build and finish time, filtered by pipeline, branch and run; never a bot's
// or a fork's pull request's unless anyone is true.
func TestRunCompletedForABuildNoPullRequestOwns(t *testing.T) {
	f := newFake(t)
	p := newPoller(t, f, "run.completed", nil)
	release := newPoller(t, f, "run.completed", map[string]any{"pipeline": "Release", "branch": "v0.16.0"})
	anyone := newPoller(t, f, "run.completed", map[string]any{"anyone": true})
	for _, w := range []*poller{p, release, anyone} {
		w.poll()
	}
	tag := branchBuild(51, "main", "sha51", "release", "failed", 1)
	tag["sourceBranch"], tag["reason"], tag["requestedFor"] = "refs/tags/v0.16.0", "manual", alex
	scheduled := branchBuild(53, "main", "sha53", "nightly", "succeeded", 1)
	scheduled["reason"], scheduled["requestedFor"] = "schedule", builder
	forked := build(54, 7, "sha7", "ci", "canceled", 1)
	forked["triggerInfo"].(obj)["pr.isFork"] = "True"
	f.set(func() {
		f.builds = []obj{tag, branchBuild(52, "main", "sha52", "release", "partiallySucceeded", 1), scheduled, forked}
	})
	done := mcpevents.TimeString(start.Add(60e9))
	id := func(n int) string { return "run.completed:acme/Web App/app:" + strconv.Itoa(n) + ":" + done }
	ids, result := p.poll()
	same(t, ids, []string{id(51), id(52)})
	same(t, data(t, result, 0), map[string]any{"run": map[string]any{"id": 51, "name": "release", "number": "2026.11.51",
		"event": "manual", "branch": "v0.16.0", "headSha": "sha51", "url": "https://ado.test/acme/Web%20App/_build/results?buildId=51",
		"conclusion": "failed", "actor": "alex@acme.test"}, "completedAt": done, "deploys": []string{}})
	same(t, data(t, result, 1)["run"].(map[string]any)["branch"], "main")
	ids, _ = release.poll()
	same(t, ids, []string{id(51)})
	ids, _ = anyone.poll()
	same(t, ids, []string{id(51), id(52), id(53), id(54)})
	ids, _ = p.poll()
	same(t, ids, []string(nil))
	// Run again: a new finish time is a new event.
	f.set(func() { tag["finishTime"], tag["result"] = at(3), "succeeded" })
	ids, _ = release.poll()
	same(t, ids, []string{"run.completed:acme/Web App/app:51:" + mcpevents.TimeString(start.Add(180e9))})

	one := newPoller(t, f, "run.completed", map[string]any{"run": 52})
	one.poll()
	f.set(func() { f.builds[1]["finishTime"] = at(5) })
	ids, _ = one.poll()
	same(t, ids, []string{"run.completed:acme/Web App/app:52:" + mcpevents.TimeString(start.Add(300e9))})
	ids, _ = one.poll()
	same(t, ids, []string(nil))
}

func TestRunCompletedSaysWhatTheBuildDeployed(t *testing.T) {
	f := newFake(t)
	p := newPoller(t, f, "run.completed", nil)
	p.poll()
	tag := branchBuild(61, "main", "sha61", "release", "succeeded", 1)
	tag["sourceBranch"], tag["reason"], tag["requestedFor"] = "refs/tags/v1.2.0", "manual", alex
	deploy := func(message string) obj {
		return obj{"type": "warning", "message": message, "data": obj{"type": "warning", "code": "deploy"}}
	}
	f.set(func() {
		f.builds = []obj{tag}
		f.timeline[61] = []obj{
			{"id": "stage", "type": "Stage", "name": "Ship"},
			{"id": "upload", "parentId": "stage", "type": "Task", "name": "Upload", "issues": []any{
				deploy("testflight:com.example.app/42"),
				deploy("testflight:com.example.app/42"), // once
				deploy("not a ref"),
				obj{"type": "warning", "message": "appstore:com.example.app/1.2.0"}, // no code
				obj{"type": "error", "message": "cloudrun:p/r/s/s-1", "data": obj{"code": "deploy"}},
			}},
			{"id": "submit", "parentId": "stage", "type": "Task", "name": "Submit", "issues": []any{deploy(" appstore:com.example.app/1.2.0 ")}},
		}
	})
	_, result := p.poll()
	same(t, data(t, result, 0)["deploys"], []string{"testflight:com.example.app/42", "appstore:com.example.app/1.2.0"})
}

func TestDeployWaitingIsABuildHeldByAnApproval(t *testing.T) {
	f := newFake(t)
	p := newPoller(t, f, "deploy.waiting", nil)
	release := newPoller(t, f, "deploy.waiting", map[string]any{"pipeline": "Release", "branch": "v1.2.0"})
	anyone := newPoller(t, f, "deploy.waiting", map[string]any{"anyone": true})
	for _, w := range []*poller{p, release, anyone} {
		w.poll()
	}
	tag := branchBuild(71, "main", "sha71", "release", "", 0)
	tag["status"], tag["sourceBranch"], tag["reason"], tag["requestedFor"] = "inProgress", "refs/tags/v1.2.0", "manual", alex
	nightly := branchBuild(72, "main", "sha72", "nightly", "", 0)
	nightly["status"], nightly["requestedFor"] = "inProgress", builder
	other := branchBuild(73, "main", "sha73", "release", "", 0)
	other["repository"] = obj{"id": "another-repo"}
	approval := func(id string, build, created int, permissions any, approvers ...obj) obj {
		steps := []any{}
		for _, a := range approvers {
			steps = append(steps, obj{"status": "pending", "assignedApprover": a})
		}
		return obj{"id": id, "status": "pending", "createdOn": at(created), "permissions": permissions, "steps": steps,
			"pipeline": obj{"id": "1", "name": "release", "owner": obj{"id": build, "name": "2026.11.1"}}}
	}
	group := obj{"id": "g", "displayName": "[Web App]\\Release Approvers", "isContainer": true}
	f.set(func() {
		f.builds = []obj{tag, nightly, other}
		f.approvals = []obj{
			approval("AAA-1", 71, 2, "view, update", dev, group),
			approval("aaa-0", 71, 1, 3, dev),
			approval("bbb", 72, 1, "view", dev),
			approval("ccc", 73, 1, 3, dev),
		}
		f.timeline[71] = []obj{
			{"id": "s1", "type": "Stage", "name": "Staging"},
			{"id": "c1", "parentId": "s1", "type": "Checkpoint", "name": "Checkpoint"},
			{"id": "aaa-0", "parentId": "c1", "type": "Checkpoint.Approval", "name": "Checkpoint.Approval"},
			{"id": "s2", "type": "Stage", "name": "Production"},
			{"id": "c2", "parentId": "s2", "type": "Checkpoint", "name": "Checkpoint"},
			{"id": "aaa-1", "parentId": "c2", "type": "Checkpoint.Approval", "name": "Checkpoint.Approval"},
		}
	})
	ids, result := p.poll()
	key := "deploy.waiting:acme/Web App/app:71:aaa-0,AAA-1"
	same(t, ids, []string{key})
	url := "https://ado.test/acme/Web%20App/_build/results?buildId=71"
	same(t, data(t, result, 0), map[string]any{
		"run": map[string]any{"id": 71, "name": "release", "number": "2026.11.71", "event": "manual", "branch": "v1.2.0",
			"headSha": "sha71", "url": url, "actor": "alex@acme.test"},
		"environments": []any{
			map[string]any{"id": "aaa-0", "name": "Staging", "url": url},
			map[string]any{"id": "AAA-1", "name": "Production", "url": url},
		},
		"reviewers":  []string{"dev@acme.test", "[Web App]\\Release Approvers"},
		"canApprove": true, "waitingSince": mcpevents.TimeString(start.Add(120e9)),
	})
	ids, _ = release.poll()
	same(t, ids, []string{key})
	ids, result = anyone.poll()
	same(t, ids, []string{"deploy.waiting:acme/Web App/app:72:bbb", key}) // by when each began to wait
	same(t, data(t, result, 0)["canApprove"], false)
	same(t, data(t, result, 0)["environments"].([]any)[0].(map[string]any)["name"], "") // no timeline yet
	ids, _ = p.poll()
	same(t, ids, []string(nil))
	// Staging approved: the wait on Production alone is a new one.
	f.set(func() { f.approvals = f.approvals[:1]; f.approvals[0]["createdOn"] = at(4) })
	ids, _ = p.poll()
	same(t, ids, []string{"deploy.waiting:acme/Web App/app:71:AAA-1"})
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

// #3797: every event about one pull request names it by pr, branch, fixes or mine, or takes
// any; run.completed takes any too.
func TestEventsListGivesWhichArgumentsNameOne(t *testing.T) {
	named := map[string]bool{"checks.failed": true, "checks.passed": true, "pr.merged": true, "pr.closed": true,
		"pr.conflicted": true, "review.comment": true}
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
		if want := named[name] || name == "run.completed"; hasAny != want {
			t.Fatalf("%s: any %v", name, hasAny)
		}
		if strings.HasPrefix(name, "pr.") || strings.HasPrefix(name, "checks.") || name == "review.comment" {
			pr := e["payloadSchema"].(map[string]any)["properties"].(map[string]any)["pr"].(map[string]any)["properties"].(map[string]any)
			if _, ok := pr["fixes"]; !ok {
				t.Fatalf("%s: no fixes in pr", name)
			}
		}
	}
	for _, bad := range []map[string]any{{"fixes": []any{"12"}}, {"fixes": []any{}}, {"fixes": "#12"}, {"fixes": []any{"acme/app#12"}}, {"any": "yes"}} {
		raw, _ := json.Marshal(map[string]any{"name": "pr.merged", "arguments": bad})
		if _, err := (&Events{AzureDevOps: newFake(t).azureDevOps()}).Poll(context.Background(), raw); err == nil || err.Code != -32602 {
			t.Fatalf("%v: %v", bad, err)
		}
	}
}

// #3797: a lead knows the work item a lane's pull request fixes before it is opened, so fixes
// narrows by the work items a description closes; mine is the owner's pull request also once
// it is completed and no longer active.
func TestFixesAndMineNarrowMergedPullRequests(t *testing.T) {
	f := newFake(t)
	fixes := newPoller(t, f, "pr.merged", map[string]any{"fixes": []any{"#37"}})
	mine := newPoller(t, f, "pr.merged", map[string]any{"mine": true})
	all := newPoller(t, f, "pr.merged", map[string]any{"any": true})
	for _, p := range []*poller{fixes, mine, all} {
		p.poll()
	}
	f.set(func() {
		f.pulls = []obj{
			pull(1, "a", alex, obj{"description": "Fixes AB#37.", "status": "completed", "closedDate": at(1)}),
			pull(2, "b", dev, obj{"description": "Closes #38", "status": "completed", "closedDate": at(1)}),
			pull(3, "c", dev, obj{"status": "completed", "closedDate": at(1)}),
		}
	})
	id := func(n int) string { return fmt.Sprintf("pr.merged:acme/Web App/app:%d", n) }
	ids, result := fixes.poll()
	same(t, ids, []string{id(1)})
	same(t, data(t, result, 0)["pr"].(map[string]any)["fixes"], []string{"#37"})
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
