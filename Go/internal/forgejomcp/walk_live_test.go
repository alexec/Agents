//go:build live

package forgejomcp

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

// Every event and tool on a real Forgejo (#1753), run by hand, never by CI: a scratch Forgejo
// in a container, with an owner, a collaborator with write access and a stranger, and a
// repository the owner made with a README.
//
//	AGENTS_LIVE_FORGEJO_URL=http://forgejo:3000 AGENTS_LIVE_FORGEJO_REPO=walkalex/app \
//	AGENTS_LIVE_FORGEJO_OWNER=<token> AGENTS_LIVE_FORGEJO_DEV=<token> AGENTS_LIVE_FORGEJO_STRANGER=<token> \
//	go test -tags live -run Live -v ./internal/forgejomcp/
//
// The tokens need write:repository, write:issue, read:user and read:organization. The test
// opens issues and pull requests and closes or merges them; run it on a scratch Forgejo only.

type live struct {
	t    *testing.T
	base string
	repo string
}

func (l live) as(token, method, path string, body any) map[string]any {
	l.t.Helper()
	var reader io.Reader
	if body != nil {
		data, _ := json.Marshal(body)
		reader = bytes.NewReader(data)
	}
	req, _ := http.NewRequest(method, BaseURL(l.base)+"api/v1/"+path, reader)
	req.Header.Set("Authorization", "token "+token)
	req.Header.Set("Content-Type", "application/json")
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		l.t.Fatal(err)
	}
	defer res.Body.Close()
	data, _ := io.ReadAll(res.Body)
	if res.StatusCode >= 300 {
		l.t.Fatalf("%s %s: %d %s", method, path, res.StatusCode, data)
	}
	out := map[string]any{}
	_ = json.Unmarshal(data, &out)
	return out
}

func (l live) asList(token, path string) []any {
	l.t.Helper()
	req, _ := http.NewRequest(http.MethodGet, BaseURL(l.base)+"api/v1/"+path, nil)
	req.Header.Set("Authorization", "token "+token)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		l.t.Fatal(err)
	}
	defer res.Body.Close()
	var out []any
	_ = json.NewDecoder(res.Body).Decode(&out)
	return out
}

func TestLiveForgejoWalk(t *testing.T) {
	base, owner, dev, stranger := os.Getenv("AGENTS_LIVE_FORGEJO_URL"), os.Getenv("AGENTS_LIVE_FORGEJO_OWNER"),
		os.Getenv("AGENTS_LIVE_FORGEJO_DEV"), os.Getenv("AGENTS_LIVE_FORGEJO_STRANGER")
	if base == "" || owner == "" || dev == "" || stranger == "" {
		t.Skip("AGENTS_LIVE_FORGEJO_URL, _OWNER, _DEV and _STRANGER are not set")
	}
	repo := os.Getenv("AGENTS_LIVE_FORGEJO_REPO")
	l := live{t: t, base: base, repo: repo}
	rp := repoPath(repo)
	// The owner's clock, which the test moves on so a conflict is old enough.
	var mu sync.Mutex
	var ahead time.Duration
	now := func() time.Time { mu.Lock(); defer mu.Unlock(); return time.Now().Add(ahead) }
	fixed := func(context.Context) (string, error) { return repo, nil }
	ownerFj := NewRealForgejo(base, func() string { return owner }, fixed)
	ownerFj.Now, ownerFj.sharing = now, 0
	devFj := NewRealForgejo(base, func() string { return dev }, fixed)
	devFj.sharing = 0

	// A pull request an earlier walk left open is closed first: its conflict would be new to this one.
	for _, p := range l.asList(owner, rp+"/pulls?state=open&limit=50") {
		l.as(owner, http.MethodPatch, fmt.Sprintf("%s/pulls/%v", rp, p.(map[string]any)["number"]), map[string]any{"state": "closed"})
	}
	time.Sleep(1500 * time.Millisecond) // Forgejo's times are to the second, as the first poll's cursor is

	names := EventNames()
	pollers := map[string]*poller{}
	for _, name := range names {
		clock := time.Now()
		p := &poller{t: t, name: name, clock: &clock, events: &Events{Forgejo: ownerFj, Now: now}}
		pollers[name] = p
		p.poll()
	}
	anyone := &poller{t: t, name: "issue.opened", args: map[string]any{"anyone": true}, clock: new(time.Time),
		events: &Events{Forgejo: ownerFj, Now: now}}
	anyone.poll()
	time.Sleep(1500 * time.Millisecond)

	stamp := fmt.Sprint(time.Now().Unix())
	devTools := serveForgejo(t, devFj, false)
	ownerTools := serveForgejo(t, ownerFj, true)
	tool := func(c *client, name string, args map[string]any) map[string]any {
		t.Helper()
		out, ok := c.tool(name, args)
		if !ok {
			t.Fatalf("%s: %v", name, out)
		}
		return out
	}
	// Issues: one by the collaborator, labelled, commented on and assigned to the owner; one by a stranger.
	devIssue := l.as(dev, http.MethodPost, rp+"/issues", map[string]any{"title": "Walk issue " + stamp, "body": "It breaks."})
	n := int(devIssue["number"].(float64))
	l.as(stranger, http.MethodPost, rp+"/issues", map[string]any{"title": "Stranger's issue " + stamp})
	labels := l.as(owner, http.MethodPost, rp+"/labels", map[string]any{"name": "agent-" + stamp, "color": "#00aabb"})
	l.as(dev, http.MethodPost, fmt.Sprintf("%s/issues/%d/labels", rp, n), map[string]any{"labels": []any{labels["id"]}})
	tool(devTools, "comment_on_issue", map[string]any{"number": n, "body": "Looking."})
	l.as(owner, http.MethodPatch, fmt.Sprintf("%s/issues/%d", rp, n), map[string]any{"assignees": []string{"walkalex"}})

	// A pull request from the collaborator's branch, with a failed check, a review request and a line comment.
	branch := "walk-" + stamp
	l.as(dev, http.MethodPost, rp+"/branches", map[string]any{"new_branch_name": branch, "old_branch_name": "main"})
	l.as(dev, http.MethodPost, rp+"/contents/walk-"+stamp+".txt", map[string]any{"branch": branch,
		"content": base64.StdEncoding.EncodeToString([]byte("one\ntwo\n")), "message": "walk"})
	opened := tool(devTools, "create_pull_request", map[string]any{"branch": branch, "title": "Walk " + stamp,
		"description": fmt.Sprintf("Fixes #%d", n)})
	pr := int(opened["number"].(float64))
	got := tool(devTools, "get_pull_request", map[string]any{"number": pr})
	sha := got["headSha"].(string)
	l.as(dev, http.MethodPost, fmt.Sprintf("%s/pulls/%d/requested_reviewers", rp, pr), map[string]any{"reviewers": []string{"walkalex"}})
	l.as(owner, http.MethodPost, rp+"/statuses/"+sha, map[string]any{"state": "failure", "context": "ci / test",
		"target_url": BaseURL(base) + repo + "/actions/runs/3/jobs/0", "description": "2 tests failed"})
	l.as(owner, http.MethodPost, fmt.Sprintf("%s/pulls/%d/reviews", rp, pr), map[string]any{"event": "COMMENT", "commit_id": sha,
		"comments": []any{map[string]any{"path": "walk-" + stamp + ".txt", "body": "Say three.", "new_position": 2}}})

	// A second pull request that will conflict: its branch and main both change the README.
	conflict := "walk-conflict-" + stamp
	l.as(dev, http.MethodPost, rp+"/branches", map[string]any{"new_branch_name": conflict, "old_branch_name": "main"})
	readme := func(token, br, text string) {
		f := l.as(token, http.MethodGet, rp+"/contents/README.md?ref="+br, nil)
		l.as(token, http.MethodPut, rp+"/contents/README.md", map[string]any{"branch": br, "sha": f["sha"],
			"content": base64.StdEncoding.EncodeToString([]byte(text)), "message": "walk README"})
	}
	readme(dev, conflict, "the branch's "+stamp+"\n")
	conflicted := tool(devTools, "create_pull_request", map[string]any{"branch": conflict, "title": "Walk conflict " + stamp})
	cpr := int(conflicted["number"].(float64))
	readme(owner, "main", "main's "+stamp+"\n")
	time.Sleep(5 * time.Second) // Forgejo checks the pull requests against main

	expect := func(name string, want int, check func(d map[string]any)) {
		t.Helper()
		ids, result := pollers[name].poll()
		if len(ids) != want {
			t.Fatalf("%s: %d events, want %d: %v", name, len(ids), want, ids)
		}
		if want > 0 && check != nil {
			check(data(t, result, 0))
		}
		t.Logf("%s: %v", name, ids)
	}
	expect("issue.opened", 1, func(d map[string]any) { same(t, d["issue"].(map[string]any)["number"], n) })
	if ids, _ := anyone.poll(); len(ids) != 2 {
		t.Fatalf("anyone's issues: %v", ids)
	}
	expect("issue.labelled", 1, func(d map[string]any) { same(t, d["label"], "agent-"+stamp); same(t, d["by"], "walkdev") })
	expect("issue.commented", 1, func(d map[string]any) { same(t, d["comment"].(map[string]any)["body"], "Looking.") })
	expect("issue.assigned", 1, nil)
	expect("pr.opened", 2, nil)
	expect("review.requested", 1, func(d map[string]any) { same(t, d["pr"].(map[string]any)["number"], pr) })
	expect("checks.failed", 1, func(d map[string]any) {
		same(t, d["headSha"], sha)
		same(t, d["run"].(map[string]any)["id"], 3)
		same(t, d["pr"].(map[string]any)["fixes"], []string{fmt.Sprintf("#%d", n)})
	})
	var commentID int
	expect("review.comment", 1, func(d map[string]any) {
		c := d["comment"].(map[string]any)
		same(t, c["line"], 2)
		same(t, c["author"], "walkalex")
		commentID = c["id"].(int)
	})
	expect("pr.conflicted", 0, nil) // first seen not mergeable: it may still be being checked
	mu.Lock()
	ahead = 2 * time.Minute
	mu.Unlock()
	expect("pr.conflicted", 1, func(d map[string]any) { same(t, d["pr"].(map[string]any)["number"], cpr) })

	// The tools: lists, checks, line comments and an answer in the thread.
	if prs := tool(devTools, "list_pull_requests", map[string]any{"branch": branch}); len(prs["pullRequests"].([]any)) != 1 {
		t.Fatalf("list_pull_requests: %v", prs)
	}
	if checks := tool(devTools, "get_checks", map[string]any{"number": pr}); checks["state"] != "failure" {
		t.Fatalf("get_checks: %v", checks)
	}
	if issues := tool(devTools, "list_issues", map[string]any{"label": "agent-" + stamp}); len(issues["issues"].([]any)) != 1 {
		t.Fatalf("list_issues: %v", issues)
	}
	if issue := tool(devTools, "get_issue", map[string]any{"number": n}); len(issue["comments"].([]any)) != 1 {
		t.Fatalf("get_issue: %v", issue)
	}
	tool(devTools, "reply_to_pull_request_comment", map[string]any{"number": pr, "commentId": commentID, "body": "Done: three."})
	lines := tool(devTools, "list_pull_request_comments", map[string]any{"number": pr})["comments"].([]any)
	if len(lines) != 2 || lines[1].(map[string]any)["line"] != float64(2) {
		t.Fatalf("list_pull_request_comments: %v", lines)
	}
	tool(devTools, "comment_on_pull_request", map[string]any{"number": pr, "body": "Ready."})
	expect("review.comment", 1, func(d map[string]any) { same(t, d["comment"].(map[string]any)["author"], "walkdev") })
	expect("issue.commented", 0, nil) // a pull request's comment is not an issue's

	// The person's: approve and merge; close the conflict and the issue.
	if _, ok := devTools.tool("merge_pull_request", map[string]any{"number": pr, "sha": sha}); ok {
		t.Fatal("an agent's copy merged")
	}
	l.as(owner, http.MethodPost, rp+"/statuses/"+sha, map[string]any{"state": "success", "context": "ci / test"})
	tool(ownerTools, "approve_pull_request", map[string]any{"number": pr, "sha": sha})
	tool(ownerTools, "merge_pull_request", map[string]any{"number": pr, "sha": sha, "squash": true})
	l.as(dev, http.MethodPatch, fmt.Sprintf("%s/pulls/%d", rp, cpr), map[string]any{"state": "closed"})
	time.Sleep(1500 * time.Millisecond)
	expect("pr.merged", 1, func(d map[string]any) { same(t, d["pr"].(map[string]any)["number"], pr) })
	expect("pr.closed", 1, func(d map[string]any) { same(t, d["pr"].(map[string]any)["number"], cpr) })
	// Merging closed the issue it fixes, as the owner who merged.
	expect("issue.closed", 1, func(d map[string]any) {
		same(t, d["issue"].(map[string]any)["number"], n)
		if !strings.EqualFold(d["by"].(string), "walkalex") {
			t.Fatalf("closed by %v", d["by"])
		}
	})
}
