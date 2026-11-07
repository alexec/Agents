package forgejomcp

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"testing"
	"time"
)

// The front as the Agents daemon talks to it, over the fake Forgejo: initialize carries the
// events capability, the events are answered here, and the tools read and write Forgejo.

type client struct {
	t     *testing.T
	lines *bufio.Scanner
	out   io.Writer
	id    int
	// init is the answer to initialize.
	init map[string]any
}

func serve(t *testing.T, f *fakeForgejo, person bool) *client {
	return serveForgejo(t, f.forgejo(nil), person)
}

// serveForgejo is a client of a front over fj, initialized.
func serveForgejo(t *testing.T, fj *RealForgejo, person bool) *client {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	t.Cleanup(cancel)
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	front := &Front{Events: &Events{Forgejo: fj}, Upstream: NewServer("test", fj, person), Version: "test", Logger: logger}
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
	f.pulls = []obj{pull(1, "feature", dev, obj{"body": "Fixes #2"})}
	f.issues = []obj{issue(2, dev, obj{"body": "It breaks."})}
	f.statuses["sha1"] = obj{"state": "failure", "sha": "sha1", "statuses": []any{
		obj{"context": "test", "status": "failure", "target_url": "https://forgejo.test/r/1", "updated_at": at(1)}}}
	f.reviews[1] = []obj{{"id": 40, "user": dev, "comments_count": 1, "submitted_at": at(1), "updated_at": at(1)}}
	f.lines[40] = []obj{{"id": 41, "body": "Rename this.", "user": dev, "path": "main.go", "position": 12, "commit_id": "sha1", "created_at": at(1)}}
	c := serve(t, f, false)

	init := c.init
	same(t, init["capabilities"].(map[string]any)["events"], map[string]any{"listChanged": false})
	same(t, init["serverInfo"].(map[string]any)["name"], "forgejo-mcp")
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
		"get_issue", "get_pull_request", "list_issues", "list_pull_request_comments", "list_pull_requests", "reply_to_pull_request_comment",
		"retry_pipeline", "show_issue_details", "show_issues", "show_pull_request", "show_pull_request_diff", "show_pull_requests"})

	prs, ok := c.tool("list_pull_requests", map[string]any{})
	if !ok || len(prs["pullRequests"].([]any)) != 1 {
		t.Fatalf("list_pull_requests: %v", prs)
	}
	pr, _ := c.tool("get_pull_request", map[string]any{"number": 1})
	if pr["headSha"] != "sha1" || pr["checks"] != "failure" || pr["fixes"].([]any)[0] != "#2" {
		t.Fatalf("get_pull_request: %v", pr)
	}
	checks, _ := c.tool("get_checks", map[string]any{"number": 1})
	if checks["state"] != "failure" || len(checks["checks"].([]any)) != 1 {
		t.Fatalf("get_checks: %v", checks)
	}
	got, _ := c.tool("get_issue", map[string]any{"number": 2})
	if got["description"] != "It breaks." {
		t.Fatalf("get_issue: %v", got)
	}
	if _, ok := c.tool("comment_on_issue", map[string]any{"number": 2, "body": "On it."}); !ok {
		t.Fatal("comment_on_issue failed")
	}
	opened, ok := c.tool("create_pull_request", map[string]any{"branch": "fix", "title": "Fix it", "draft": true})
	if !ok || opened["target"] != "main" {
		t.Fatalf("create_pull_request: %v", opened)
	}
	lines, _ := c.tool("list_pull_request_comments", map[string]any{"number": 1})
	if len(lines["comments"].([]any)) != 1 {
		t.Fatalf("list_pull_request_comments: %v", lines)
	}
	if _, ok := c.tool("reply_to_pull_request_comment", map[string]any{"number": 1, "commentId": 41, "body": "Done."}); !ok {
		t.Fatal("reply failed")
	}
	if _, ok := c.tool("reply_to_pull_request_comment", map[string]any{"number": 1, "commentId": 99, "body": "Done."}); ok {
		t.Fatal("a reply to no comment worked")
	}

	f.mu.Lock()
	defer f.mu.Unlock()
	same(t, len(f.posted), 3)
	same(t, f.posted[0]["body"], "On it.")
	same(t, f.posted[1]["title"], "WIP: Fix it")
	same(t, f.posted[1]["base"], "main")
	reply := f.posted[2]
	same(t, reply["event"], "COMMENT")
	same(t, reply["commit_id"], "sha1")
	same(t, reply["comments"], []any{map[string]any{"path": "main.go", "body": "Done.", "new_position": float64(12)}})
}

func TestMergeAndApproveAreOnlyThePersons(t *testing.T) {
	f := newFake(t)
	f.pulls = []obj{pull(1, "feature", dev, nil)}
	c := serve(t, f, true)
	names := toolNames(c)
	if len(names) != 19 {
		t.Fatalf("person's tools: %v", names)
	}
	if _, ok := c.tool("merge_pull_request", map[string]any{"number": 1}); ok {
		t.Fatal("a merge with no sha worked")
	}
	if _, ok := c.tool("merge_pull_request", map[string]any{"number": 1, "sha": "sha1", "squash": true}); !ok {
		t.Fatal("merge failed")
	}
	if _, ok := c.tool("approve_pull_request", map[string]any{"number": 1, "sha": "sha1"}); !ok {
		t.Fatal("approve failed")
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	same(t, f.posted[0]["Do"], "squash")
	same(t, f.posted[0]["head_commit_id"], "sha1")
	same(t, f.posted[1]["event"], "APPROVED")
}
