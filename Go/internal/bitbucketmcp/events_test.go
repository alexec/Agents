package bitbucketmcp

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/gitlabmcp"
	"github.com/alexec/agents/Go/internal/mcpevents"
)

// The events over the fake Bitbucket: the gitlab server's names, the trust filter (#728), and
// each one raised once from what Bitbucket says.

func TestTheEventsAreTheGitLabServersNames(t *testing.T) {
	// The gitlab server's, but for run.completed and deploy.waiting, which each forge has
	// where its API does; run.completed is after checks.failed, as there (#4217).
	without := func(names []string) []string {
		var out []string
		for _, n := range names {
			if n != "run.completed" && n != "deploy.waiting" {
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
			pull(2, "feature", dev, obj{"description": "Fixes #12 and closes other/repo#3"}),
			pull(3, "draft", alex, obj{"draft": true}),
			pull(4, "fork", alex, obj{"source": obj{"branch": obj{"name": "fork"}, "commit": obj{"hash": "s4"}, "repository": obj{"full_name": "alex/app"}}}),
			pull(5, "outside", stranger, nil),
			pull(6, "bot", renovate, nil),
			pull(7, "reader", reader, nil),
			pull(8, "app", pipelines, nil))
	})
	ids, result := own.poll()
	if len(ids) != 1 || !strings.HasPrefix(ids[0], "pr.opened:acme/app:2:") {
		t.Fatalf("own: %v", ids)
	}
	pr := data(t, result, 0)["pr"].(map[string]any)
	if pr["author"] != "dev" || pr["branch"] != "feature" || pr["number"] != 2 || pr["url"] != "https://bitbucket.org/acme/app/pull-requests/2" {
		t.Fatalf("pr %v", pr)
	}
	same(t, pr["fixes"], []string{"#12", "other/repo#3"})
	ids, _ = anyone.poll()
	if len(ids) != 6 {
		t.Fatalf("anyone: %v", ids)
	}

	// The draft marked ready is raised; nothing else again.
	f.set(func() { f.pulls[2]["draft"] = false })
	ids, _ = own.poll()
	if len(ids) != 1 || !strings.HasPrefix(ids[0], "pr.opened:acme/app:3:") {
		t.Fatalf("ready: %v", ids)
	}
	ids, _ = own.poll()
	same(t, ids, []string(nil))
}

func TestAnAdminlessTokenTrustsTheWorkspacesMembers(t *testing.T) {
	f := newFake(t)
	f.adminless = true
	f.members["a-dev"] = true
	own := newPoller(t, f, "pr.opened", nil)
	own.poll()
	f.set(func() { f.pulls = []obj{pull(1, "a", dev, nil), pull(2, "b", stranger, nil)} })
	ids, _ := own.poll()
	if len(ids) != 1 || !strings.HasPrefix(ids[0], "pr.opened:acme/app:1:") {
		t.Fatalf("adminless: %v", ids)
	}
}

func TestAPersonWithNoLineOfTheirOwnFallsToTheWorkspace(t *testing.T) {
	f := newFake(t)
	delete(f.perms, "a-dev") // given access by the workspace, not the repository
	f.members["a-dev"] = true
	own := newPoller(t, f, "pr.opened", nil)
	own.poll()
	f.set(func() { f.pulls = []obj{pull(1, "a", dev, nil), pull(2, "b", reader, nil)} })
	ids, _ := own.poll()
	// reader has a line of their own, read: not trusted, member or not.
	if len(ids) != 1 || !strings.HasPrefix(ids[0], "pr.opened:acme/app:1:") {
		t.Fatalf("workspace: %v", ids)
	}
}

func TestConflictedIsAFileInConflict(t *testing.T) {
	f := newFake(t)
	f.pulls = []obj{pull(1, "feature", dev, nil)}
	f.diffstat[1] = []obj{{"status": "modified"}}
	p := newPoller(t, f, "pr.conflicted", nil)
	p.poll()
	f.set(func() { f.diffstat[1] = []obj{{"status": "modified"}, {"status": "merge conflict"}} })
	ids, result := p.poll()
	if len(ids) != 1 || data(t, result, 0)["pr"].(map[string]any)["number"] != 1 {
		t.Fatalf("conflicted: %v", ids)
	}
	ids, _ = p.poll()
	same(t, ids, []string(nil))
	// Clean again, then in conflict anew: a new event.
	f.set(func() { f.diffstat[1] = []obj{{"status": "modified"}} })
	p.poll()
	f.set(func() { f.diffstat[1] = []obj{{"status": "local deleted"}} })
	ids, _ = p.poll()
	if len(ids) != 1 {
		t.Fatalf("conflicted anew: %v", ids)
	}
}

func TestMergedAndDeclinedAtTheirActivitysTime(t *testing.T) {
	f := newFake(t)
	f.pulls = []obj{pull(1, "old", dev, obj{"state": "MERGED", "updated_on": at(-5)})}
	merged := newPoller(t, f, "pr.merged", nil)
	closed := newPoller(t, f, "pr.closed", nil)
	merged.poll()
	closed.poll()
	f.set(func() {
		f.pulls = append(f.pulls,
			pull(2, "done", dev, obj{"state": "MERGED", "updated_on": at(1), "merge_commit": obj{"hash": "m2"}}),
			pull(3, "dropped", dev, obj{"state": "DECLINED", "updated_on": at(1)}),
			pull(4, "fork", dev, obj{"state": "MERGED", "updated_on": at(1),
				"source": obj{"branch": obj{"name": "fork"}, "commit": obj{"hash": "s4"}, "repository": obj{"full_name": "dev/app"}}}))
		f.activity[2] = []obj{{"update": obj{"state": "MERGED", "date": at(1)}}, {"update": obj{"state": "OPEN", "date": at(-9)}}}
		f.activity[3] = []obj{{"update": obj{"state": "DECLINED", "date": at(1)}}}
	})
	ids, result := merged.poll()
	same(t, ids, []string{"pr.merged:acme/app:2"})
	if sub, key := envelopeOf(result, 0); sub != "bitbucket:pr:acme/app#2" || key != "" {
		t.Fatalf("merged: subject %q, key %q", sub, key)
	}
	same(t, data(t, result, 0)["mergeSha"], "m2")
	ids, result = closed.poll()
	if len(ids) != 1 || !strings.HasPrefix(ids[0], "pr.closed:acme/app:3:") {
		t.Fatalf("closed: %v", ids)
	}
	// A comment after the merge moves updated_on, not the merge: nothing again.
	f.set(func() { f.pulls[1]["updated_on"] = at(3) })
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
	run := "https://bitbucket.org/acme/app/pipelines/results/12/steps/%7Bstep%7D"
	f.set(func() {
		f.statuses["sha1"] = []obj{
			{"key": "pipeline-1", "name": "Pipeline #12 for feature", "state": "FAILED", "url": run, "updated_on": at(1)},
			{"key": "lint", "name": "", "state": "SUCCESSFUL", "url": "https://ci.test/lint", "updated_on": at(1)},
		}
		f.statuses["sha2"] = []obj{{"key": "pipeline-2", "state": "SUCCESSFUL", "updated_on": at(1)}}
	})
	ids, result := p.poll()
	same(t, ids, []string{"checks.failed:acme/app:sha1:" + mcpevents.TimeString(start.Add(60e9))})
	d := data(t, result, 0)
	same(t, d["headSha"], "sha1")
	same(t, d["run"], map[string]any{"id": 12, "name": "Pipeline #12 for feature", "url": run})
	same(t, d["failedJobs"], []any{map[string]any{"name": "Pipeline #12 for feature", "url": run}})
	ids, _ = p.poll()
	same(t, ids, []string(nil))
	// Run again and failed again: a new one.
	f.set(func() { f.statuses["sha1"][0]["updated_on"] = at(3) })
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
			issue(1, dev, obj{"created_on": at(1), "updated_on": at(1), "component": obj{"name": "agent"}}),
			issue(2, stranger, obj{"created_on": at(1), "updated_on": at(1)}),
			issue(3, dev, obj{"state": "resolved", "created_on": at(-5), "updated_on": at(1)}),
		}
		f.issueComments[2] = []obj{
			comment(10, dev, "Seen it.", at(1), nil),
			comment(11, dev, "", at(1), nil), // a change's own comment, with no words
			comment(12, stranger, "Me too.", at(1), nil),
		}
		f.changes[1] = []obj{
			{"id": 20, "user": dev, "created_on": at(1), "changes": obj{"component": obj{"old": "", "new": "agent"}}},
			{"id": 21, "user": dev, "created_on": at(1), "changes": obj{"priority": obj{"old": "major", "new": "minor"}}},
		}
		f.changes[3] = []obj{{"id": 30, "user": alex, "created_on": at(1), "changes": obj{"state": obj{"old": "open", "new": "resolved"}}}}
	})
	ids, result := opened.poll()
	same(t, ids, []string{"issue.opened:acme/app:1"})
	same(t, data(t, result, 0)["issue"].(map[string]any)["labels"], []string{"bug", "agent"})
	ids, result = commented.poll()
	same(t, ids, []string{"issue.commented:acme/app:10"})
	same(t, data(t, result, 0)["comment"], map[string]any{"author": "dev", "url": "https://bitbucket.org/c/10", "body": "Seen it."})
	ids, result = closed.poll()
	same(t, ids, []string{"issue.closed:acme/app:3:" + mcpevents.TimeString(start.Add(60e9))})
	same(t, data(t, result, 0)["by"], "alex")
	ids, result = labelled.poll()
	same(t, ids, []string{"issue.labelled:acme/app:label:20:component"})
	same(t, data(t, result, 0)["label"], "agent")
}

func TestAnIssueTrackerThatIsOffHasNoEvents(t *testing.T) {
	f := newFake(t)
	f.noTracker = true
	p := newPoller(t, f, "issue.opened", nil)
	p.poll()
	ids, _ := p.poll()
	same(t, ids, []string(nil))
	a := newPoller(t, f, "issue.assigned", nil)
	a.poll()
	ids, _ = a.poll()
	same(t, ids, []string(nil))
}

func TestReviewCommentIsALineOfTheDiff(t *testing.T) {
	f := newFake(t)
	f.pulls = []obj{pull(1, "feature", alex, nil)}
	p := newPoller(t, f, "review.comment", nil)
	p.poll()
	f.set(func() {
		f.pulls[0]["updated_on"] = at(1)
		f.prComments[1] = []obj{
			comment(41, dev, "Rename this.", at(1), obj{"inline": obj{"path": "main.go", "to": 12}}),
			comment(42, stranger, "Spam.", at(1), obj{"inline": obj{"path": "main.go", "to": 3}}),
			comment(43, dev, "Looks good overall.", at(1), nil),
			comment(44, dev, "Old line.", at(1), obj{"inline": obj{"path": "old.go", "from": 7}}),
		}
	})
	ids, result := p.poll()
	same(t, ids, []string{"review.comment:acme/app:41", "review.comment:acme/app:44"})
	same(t, data(t, result, 0)["comment"], map[string]any{"id": 41, "author": "dev", "path": "main.go", "line": 12, "body": "Rename this.",
		"url": "https://bitbucket.org/c/41"})
	same(t, data(t, result, 1)["comment"].(map[string]any)["line"], 7)
}

func TestReviewRequestedAndAssignedAreTheOwnersAndRaisedOnce(t *testing.T) {
	f := newFake(t)
	requested := newPoller(t, f, "review.requested", nil)
	assigned := newPoller(t, f, "issue.assigned", nil)
	requested.poll()
	assigned.poll()
	f.set(func() {
		f.pulls = []obj{pull(1, "a", stranger, obj{"reviewers": []any{alex}}), pull(2, "b", dev, obj{"reviewers": []any{dev}})}
		f.issues = []obj{issue(3, stranger, obj{"assignee": alex}), issue(4, dev, obj{"assignee": dev})}
	})
	ids, _ := requested.poll()
	if len(ids) != 1 || !strings.HasPrefix(ids[0], "review.requested:acme/app:1:") {
		t.Fatalf("requested: %v", ids)
	}
	ids, result := assigned.poll()
	if len(ids) != 1 || !strings.HasPrefix(ids[0], "issue.assigned:acme/app:3:") {
		t.Fatalf("assigned: %v", ids)
	}
	same(t, data(t, result, 0)["issue"].(map[string]any)["assignees"], []string{"alex"})
	ids, _ = requested.poll()
	same(t, ids, []string(nil))
}

func TestMineIsOnlyTheOwnersPullRequests(t *testing.T) {
	f := newFake(t)
	f.pulls = []obj{pull(1, "mine", alex, nil), pull(2, "theirs", dev, nil)}
	p := newPoller(t, f, "pr.conflicted", map[string]any{"mine": true})
	p.poll()
	f.set(func() {
		f.diffstat[1], f.diffstat[2] = []obj{{"status": "merge conflict"}}, []obj{{"status": "merge conflict"}}
	})
	ids, _ := p.poll()
	if len(ids) != 1 || !strings.HasPrefix(ids[0], "pr.conflicted:acme/app:1:") {
		t.Fatalf("mine: %v", ids)
	}
}

func TestAnAPITokenSignsInWithItsEmail(t *testing.T) {
	f := newFake(t)
	f.email = "alex@example.com"
	p := newPoller(t, f, "pr.merged", nil)
	p.poll()
	if ids, _ := p.poll(); ids != nil {
		t.Fatalf("ids: %v", ids)
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
	f.set(func() { f.status = 403 })
	if _, err = p.events.Poll(context.Background(), raw); err == nil || err.Code != -32603 || !strings.Contains(err.Message, "HTTP 403: no") {
		t.Fatalf("refused: %+v", err)
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
	for _, c := range []struct{ remote, want string }{
		{"https://alex@bitbucket.org/acme/app.git", "acme/app"},
		{"https://bitbucket.org/acme/app", "acme/app"},
		{"git@bitbucket.org:acme/app.git", "acme/app"},
		{"ssh://git@bitbucket.org/acme/app.git", "acme/app"},
		{"https://github.com/acme/app", ""},
		{"https://bitbucket.org/acme/sub/app", ""},
	} {
		got, _ := RepoOfRemote(c.remote)
		if got != c.want {
			t.Errorf("%s: got %q, want %q", c.remote, got, c.want)
		}
	}
}

func TestBaseURL(t *testing.T) {
	same(t, BaseURL(""), "https://api.bitbucket.org/2.0/")
	same(t, BaseURL("http://localhost:3000"), "http://localhost:3000/")
	same(t, BaseURL("api.example.com/2.0/"), "https://api.example.com/2.0/")
}

// #3797: every event about one pull request names it by pr, branch, fixes or mine, or takes
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
		if want := named[name] || name == "issue.closed" || name == "issue.commented" || name == "issue.labelled"; hasAny != want {
			t.Fatalf("%s: any %v", name, hasAny)
		}
		if issue, ok := props["issue"].(map[string]any); ok {
			if list := fmt.Sprint(issue["type"]) == "[integer array]"; list != (name != "issue.assigned") {
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
	for _, ref := range []string{"#12", "acme/app#12"} {
		if !issueRefPattern.MatchString(ref) {
			t.Fatalf("refused %s", ref)
		}
	}
	for _, ref := range []string{"12", "app#12", "#0", "acme/app#", "a/b/c#1"} {
		if issueRefPattern.MatchString(ref) {
			t.Fatalf("took %s", ref)
		}
	}
}

func TestUnknownArgumentSaysWhatItTakes(t *testing.T) {
	f := newFake(t)
	_, err := newPoller(t, f, "pr.merged", map[string]any{"sha": "x"}).try()
	if err == nil || err.Code != -32602 || err.Message != "unknown argument sha; takes repo, branch, pr, fixes, anyone, mine, any" {
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

// #3797: a lead knows the issue a lane's pull request fixes before it is opened, so fixes
// narrows by the issues a description closes, "#12" being the repository's own; mine is the
// owner's pull request also once it is merged and no longer open.
func TestFixesAndMineNarrowMergedPullRequests(t *testing.T) {
	f := newFake(t)
	fixes := newPoller(t, f, "pr.merged", map[string]any{"fixes": []any{"#37"}})
	full := newPoller(t, f, "pr.merged", map[string]any{"fixes": []any{"ACME/App#37", "other/repo#37"}})
	mine := newPoller(t, f, "pr.merged", map[string]any{"mine": true})
	all := newPoller(t, f, "pr.merged", map[string]any{"any": true})
	for _, p := range []*poller{fixes, full, mine, all} {
		p.poll()
	}
	f.set(func() {
		f.pulls = []obj{
			pull(1, "a", alex, obj{"description": "Closes #37.", "state": "MERGED", "updated_on": at(1)}),
			pull(2, "b", dev, obj{"description": "Fixes other/repo#37", "state": "MERGED", "updated_on": at(1)}),
			pull(3, "c", dev, obj{"state": "MERGED", "updated_on": at(1)}),
		}
		for n := 1; n <= 3; n++ {
			f.activity[n] = []obj{{"update": obj{"state": "MERGED", "date": at(1)}}}
		}
	})
	id := func(n int) string { return fmt.Sprintf("pr.merged:%s:%d", repo, n) }
	ids, result := fixes.poll()
	same(t, ids, []string{id(1)})
	same(t, data(t, result, 0)["pr"].(map[string]any)["fixes"], []string{"#37"})
	ids, _ = full.poll()
	same(t, ids, []string{id(1), id(2)})
	ids, _ = mine.poll()
	same(t, ids, []string{id(1)})
	ids, _ = all.poll()
	same(t, ids, []string{id(1), id(2), id(3)})
}

// #3797: a lead waits on all its open children at once.
func TestIssueTakesAList(t *testing.T) {
	f := newFake(t)
	listed := newPoller(t, f, "issue.closed", map[string]any{"issue": []any{3, 4}, "anyone": true})
	notListed := newPoller(t, f, "issue.closed", map[string]any{"issue": 2, "anyone": true})
	listed.poll()
	notListed.poll()
	f.set(func() {
		f.issues = []obj{issue(3, dev, obj{"state": "resolved", "created_on": at(-5), "updated_on": at(1)})}
		f.changes[3] = []obj{{"id": 30, "user": alex, "created_on": at(1), "changes": obj{"state": obj{"old": "open", "new": "resolved"}}}}
	})
	ids, _ := listed.poll()
	same(t, ids, []string{"issue.closed:acme/app:3:" + mcpevents.TimeString(start.Add(60e9))})
	ids, _ = notListed.poll()
	same(t, ids, []string(nil))
}

// envelopeOf is a polled event's subject and key (#4728).
func envelopeOf(result map[string]any, i int) (subject, key string) {
	e := result["events"].([]any)[i].(map[string]any)
	subject, _ = e["subject"].(string)
	key, _ = e["key"].(string)
	return subject, key
}
