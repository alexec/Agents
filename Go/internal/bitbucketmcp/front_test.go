package bitbucketmcp

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"testing"
	"time"
)

// The front as the Agents daemon talks to it, over the fake Bitbucket: initialize carries the
// events capability, the events are answered here, and the tools read and write Bitbucket.

type client struct {
	t     *testing.T
	lines *bufio.Scanner
	out   io.Writer
	id    int
	// init is the answer to initialize.
	init map[string]any
}

func serve(t *testing.T, f *fakeBitbucket, person bool) *client {
	return serveBitbucket(t, f.bitbucket(), person)
}

// serveBitbucket is a client of a front over bb, initialized.
func serveBitbucket(t *testing.T, bb *RealBitbucket, person bool) *client {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	t.Cleanup(cancel)
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	front := &Front{Events: &Events{Bitbucket: bb}, Upstream: NewServer("test", bb, person), Version: "test", Logger: logger}
	clientIn, frontOut := io.Pipe()
	frontIn, clientOut := io.Pipe()
	go func() { _ = front.Serve(ctx, frontIn, frontOut); _ = frontOut.Close() }()
	t.Cleanup(func() { _ = clientOut.Close() })
	lines := bufio.NewScanner(clientIn)
	lines.Buffer(nil, 16<<20)
	c := &client{t: t, lines: lines, out: clientOut}
	c.init = c.call("initialize", map[string]any{"protocolVersion": "2025-06-18", "capabilities": map[string]any{},
		"clientInfo": map[string]any{"name": "Agents", "version": "1"}})["result"].(map[string]any)
	c.send(map[string]any{"jsonrpc": "2.0", "method": "notifications/initialized"})
	return c
}

func (c *client) send(m map[string]any) {
	data, _ := json.Marshal(m)
	if _, err := c.out.Write(append(data, '\n')); err != nil {
		c.t.Fatal(err)
	}
}

func (c *client) call(method string, params any) map[string]any {
	c.t.Helper()
	c.id++
	c.send(map[string]any{"jsonrpc": "2.0", "id": c.id, "method": method, "params": params})
	for c.lines.Scan() {
		var reply map[string]any
		if err := json.Unmarshal(c.lines.Bytes(), &reply); err != nil {
			c.t.Fatalf("%s: %v", c.lines.Text(), err)
		}
		if reply["id"] == float64(c.id) {
			return reply
		}
	}
	c.t.Fatalf("%s: no answer (%v)", method, c.lines.Err())
	return nil
}

func (c *client) tool(name string, args map[string]any) (map[string]any, bool) {
	c.t.Helper()
	reply := c.call("tools/call", map[string]any{"name": name, "arguments": args})
	result, ok := reply["result"].(map[string]any)
	if !ok {
		return map[string]any{"error": reply["error"]}, false
	}
	if result["isError"] == true {
		return map[string]any{"error": result["content"]}, false
	}
	return result["structuredContent"].(map[string]any), true
}

func toolNames(c *client) []string {
	var names []string
	for _, t := range c.call("tools/list", map[string]any{})["result"].(map[string]any)["tools"].([]any) {
		names = append(names, t.(map[string]any)["name"].(string))
	}
	return names
}

func TestTheFrontOffersEventsAndTools(t *testing.T) {
	f := newFake(t)
	f.pulls = []obj{pull(1, "feature", dev, obj{"description": "Fixes #2", "reviewers": []any{alex}})}
	f.issues = []obj{issue(2, dev, obj{"content": obj{"raw": "It breaks."}, "component": obj{"name": "agent"}})}
	f.issueComments[2] = []obj{comment(5, dev, "Me too.", at(1), nil), comment(6, dev, "", at(1), nil)}
	f.statuses["sha1"] = []obj{{"key": "test", "state": "FAILED", "url": "https://bitbucket.org/acme/app/pipelines/results/3", "updated_on": at(1)}}
	f.prComments[1] = []obj{
		comment(41, dev, "Rename this.", at(1), obj{"inline": obj{"path": "main.go", "to": 12}}),
		comment(42, dev, "Not on a line.", at(2), nil),
	}
	c := serve(t, f, false)

	init := c.init
	same(t, init["capabilities"].(map[string]any)["events"], map[string]any{"listChanged": false})
	same(t, init["serverInfo"].(map[string]any)["name"], "bitbucket-mcp")
	same(t, init["instructions"], Instructions)
	listed := c.call("events/list", map[string]any{})["result"].(map[string]any)["events"].([]any)
	if len(listed) != len(EventNames()) {
		t.Fatalf("events/list: %d", len(listed))
	}
	polled := c.call("events/poll", map[string]any{"name": "checks.failed"})["result"].(map[string]any)
	if polled["cursor"] == nil {
		t.Fatalf("poll: %v", polled)
	}

	same(t, toolNames(c), []string{"comment_on_issue", "comment_on_pull_request", "create_pull_request", "failed_log", "get_checks",
		"get_issue", "get_pull_request", "list_issues", "list_pull_request_comments", "list_pull_requests", "reply_to_pull_request_comment"})

	prs, ok := c.tool("list_pull_requests", map[string]any{})
	if !ok || len(prs["pullRequests"].([]any)) != 1 || prs["pullRequests"].([]any)[0].(map[string]any)["state"] != "open" {
		t.Fatalf("list_pull_requests: %v", prs)
	}
	if _, ok := c.tool("list_pull_requests", map[string]any{"state": "shut"}); ok {
		t.Fatal("a state that is none worked")
	}
	pr, _ := c.tool("get_pull_request", map[string]any{"number": 1})
	if pr["headSha"] != "sha1" || pr["checks"] != "failure" || pr["fixes"].([]any)[0] != "#2" || pr["reviewers"].([]any)[0] != "alex" {
		t.Fatalf("get_pull_request: %v", pr)
	}
	checks, _ := c.tool("get_checks", map[string]any{"number": 1})
	if checks["state"] != "failure" || len(checks["checks"].([]any)) != 1 {
		t.Fatalf("get_checks: %v", checks)
	}
	issues, _ := c.tool("list_issues", map[string]any{"label": "agent"})
	if len(issues["issues"].([]any)) != 1 {
		t.Fatalf("list_issues: %v", issues)
	}
	got, _ := c.tool("get_issue", map[string]any{"number": 2})
	if got["description"] != "It breaks." || len(got["comments"].([]any)) != 1 || got["component"] != "agent" {
		t.Fatalf("get_issue: %v", got)
	}
	if _, ok := c.tool("comment_on_issue", map[string]any{"number": 2, "body": "On it."}); !ok {
		t.Fatal("comment_on_issue failed")
	}
	if _, ok := c.tool("comment_on_pull_request", map[string]any{"number": 1, "body": "Pushed."}); !ok {
		t.Fatal("comment_on_pull_request failed")
	}
	opened, ok := c.tool("create_pull_request", map[string]any{"branch": "fix", "title": "Fix it", "draft": true})
	if !ok || opened["target"] != "main" || opened["draft"] != true {
		t.Fatalf("create_pull_request: %v", opened)
	}
	lines, _ := c.tool("list_pull_request_comments", map[string]any{"number": 1})
	if len(lines["comments"].([]any)) != 1 {
		t.Fatalf("list_pull_request_comments: %v", lines)
	}
	if _, ok := c.tool("reply_to_pull_request_comment", map[string]any{"number": 1, "commentId": 41, "body": "Done."}); !ok {
		t.Fatal("reply failed")
	}
	for _, id := range []int{42, 99} {
		if _, ok := c.tool("reply_to_pull_request_comment", map[string]any{"number": 1, "commentId": id, "body": "Done."}); ok {
			t.Fatalf("a reply to %d worked", id)
		}
	}

	f.mu.Lock()
	defer f.mu.Unlock()
	same(t, len(f.posted), 4)
	same(t, f.posted[0]["_path"], root+"/issues/2/comments")
	same(t, f.posted[0]["content"], map[string]any{"raw": "On it."})
	same(t, f.posted[1]["_path"], root+"/pullrequests/1/comments")
	same(t, f.posted[2]["title"], "Fix it")
	same(t, f.posted[2]["draft"], true)
	same(t, f.posted[2]["destination"], nil)
	same(t, f.posted[3]["parent"], map[string]any{"id": float64(41)})
}

func TestMergeAndApproveAreOnlyThePersons(t *testing.T) {
	f := newFake(t)
	f.pulls = []obj{pull(1, "feature", dev, obj{"source": obj{"branch": obj{"name": "feature"}, "commit": obj{"hash": "0123456789ab"},
		"repository": obj{"full_name": repo}}})}
	c := serve(t, f, true)
	names := toolNames(c)
	if len(names) != 13 {
		t.Fatalf("person's tools: %v", names)
	}
	if _, ok := c.tool("merge_pull_request", map[string]any{"number": 1}); ok {
		t.Fatal("a merge with no sha worked")
	}
	if _, ok := c.tool("merge_pull_request", map[string]any{"number": 1, "sha": "fedcba9876543210"}); ok {
		t.Fatal("a merge at another head worked")
	}
	if _, ok := c.tool("merge_pull_request", map[string]any{"number": 1, "sha": "0123456789abcdef0123", "squash": true}); !ok {
		t.Fatal("merge failed")
	}
	if _, ok := c.tool("approve_pull_request", map[string]any{"number": 1, "sha": "0123456789ab"}); !ok {
		t.Fatal("approve failed")
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	same(t, len(f.posted), 2)
	same(t, f.posted[0]["merge_strategy"], "squash")
	same(t, f.posted[0]["close_source_branch"], true)
	same(t, f.posted[1]["_path"], root+"/pullrequests/1/approve")
}
