package azuredevopsmcp

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"strings"
	"testing"
	"time"
)

// The front as the Agents daemon talks to it, over the fake Azure DevOps: initialize carries
// the events capability, the events are answered here, and the tools read and write Azure
// DevOps.

type client struct {
	t     *testing.T
	lines *bufio.Scanner
	out   io.Writer
	id    int
	// init is the answer to initialize.
	init map[string]any
}

// serve is a client of a front over the fake, initialized.
func serve(t *testing.T, f *fakeAzureDevOps, person bool) *client {
	ado := f.azureDevOps()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	t.Cleanup(cancel)
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	front := &Front{Events: &Events{AzureDevOps: ado}, Upstream: NewServer("test", ado, person), Version: "test", Logger: logger}
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
	f.pulls = []obj{pull(1, "feature", dev, obj{"description": "Fixes #2", "labels": []any{obj{"name": "agent", "active": true}},
		"reviewers": []any{merged(alex, obj{"vote": 5, "isRequired": true})}})}
	f.builds = []obj{build(11, 1, "sha1", "ci", "succeeded", 0), build(12, 1, "sha1", "ci", "failed", 1), build(13, 1, "sha1", "lint", "succeeded", 1)}
	f.statuses[1] = []obj{{"state": "succeeded", "description": "Scanned", "targetUrl": "https://scan.test/1", "context": obj{"genre": "scan", "name": "deps"}}}
	f.timeline[12] = []obj{
		{"id": "job", "type": "Job", "name": "Test", "result": "failed"},
		{"id": "step", "parentId": "job", "type": "Task", "name": "go test", "result": "failed", "log": obj{"id": 5},
			"issues": []any{obj{"type": "error", "message": "exit code 1"}, obj{"type": "warning", "message": "slow"}}},
		{"id": "ok", "parentId": "job", "type": "Task", "name": "checkout", "result": "succeeded", "log": obj{"id": 4}},
	}
	f.logs[5] = "--- FAIL: TestIt"
	f.threads[1] = []obj{{"id": 40, "status": "fixed", "threadContext": obj{"filePath": "/main.go", "rightFileStart": obj{"line": 12}},
		"comments": []any{obj{"id": 1, "author": dev, "content": "Rename this.", "publishedDate": at(1), "commentType": "text"}}}}
	c := serve(t, f, false)

	init := c.init
	same(t, init["capabilities"].(map[string]any)["events"], map[string]any{"listChanged": false})
	same(t, init["serverInfo"].(map[string]any)["name"], "azuredevops-mcp")
	same(t, init["instructions"], Instructions)
	listed := c.call("events/list", map[string]any{})["result"].(map[string]any)["events"].([]any)
	if len(listed) != len(EventNames()) {
		t.Fatalf("events/list: %d", len(listed))
	}
	polled := c.call("events/poll", map[string]any{"name": "checks.failed"})["result"].(map[string]any)
	if polled["cursor"] == nil {
		t.Fatalf("poll: %v", polled)
	}

	same(t, toolNames(c), []string{"comment_on_pull_request", "create_pull_request", "get_build_log", "get_checks", "get_pull_request",
		"list_pull_request_comments", "list_pull_requests", "reply_to_pull_request_comment", "retry_build", "show_pull_request",
		"show_pull_request_diff", "show_pull_requests"})

	prs, ok := c.tool("list_pull_requests", map[string]any{"label": "agent"})
	if !ok || len(prs["pullRequests"].([]any)) != 1 {
		t.Fatalf("list_pull_requests: %v", prs)
	}
	if prs, _ := c.tool("list_pull_requests", map[string]any{"label": "other"}); len(prs["pullRequests"].([]any)) != 0 {
		t.Fatalf("a tag it has not: %v", prs)
	}
	pr, _ := c.tool("get_pull_request", map[string]any{"number": 1})
	if pr["headSha"] != "sha1" || pr["checks"] != "failed" || pr["fixes"].([]any)[0] != "#2" || pr["state"] != "open" {
		t.Fatalf("get_pull_request: %v", pr)
	}
	same(t, pr["reviewers"], []any{map[string]any{"name": "alex@acme.test", "vote": "approved with suggestions", "required": true}})
	if _, ok := c.tool("get_pull_request", map[string]any{"number": 1, "repo": "acme/app"}); ok {
		t.Fatal("a repo with no project worked")
	}
	checks, _ := c.tool("get_checks", map[string]any{"number": 1})
	if checks["state"] != "failed" || len(checks["checks"].([]any)) != 2 || len(checks["statuses"].([]any)) != 1 {
		t.Fatalf("get_checks: %v", checks)
	}
	same(t, checks["statuses"].([]any)[0].(map[string]any)["name"], "scan/deps")
	log, _ := c.tool("get_build_log", map[string]any{"buildId": 12})
	same(t, log["failedSteps"], []any{map[string]any{"name": "go test", "job": "Test", "errors": []any{"exit code 1"},
		"log": "start\n--- FAIL: TestIt"}})
	if _, ok := c.tool("comment_on_pull_request", map[string]any{"number": 1, "body": "On it."}); !ok {
		t.Fatal("comment_on_pull_request failed")
	}
	opened, ok := c.tool("create_pull_request", map[string]any{"branch": "fix", "title": "Fix it", "draft": true})
	if !ok || opened["target"] != "main" || opened["draft"] != true {
		t.Fatalf("create_pull_request: %v", opened)
	}
	lines, _ := c.tool("list_pull_request_comments", map[string]any{"number": 1})
	same(t, lines["comments"].([]any)[0].(map[string]any)["resolved"], true)
	if _, ok := c.tool("reply_to_pull_request_comment", map[string]any{"number": 1, "threadId": 40, "body": "Done."}); !ok {
		t.Fatal("reply failed")
	}
	if _, ok := c.tool("reply_to_pull_request_comment", map[string]any{"number": 1, "threadId": 99, "body": "Done."}); ok {
		t.Fatal("a reply to no thread worked")
	}

	f.mu.Lock()
	defer f.mu.Unlock()
	same(t, len(f.posted), 3)
	same(t, f.posted[0]["comments"], []any{map[string]any{"parentCommentId": float64(0), "content": "On it.", "commentType": "text"}})
	same(t, f.posted[1]["sourceRefName"], "refs/heads/fix")
	same(t, f.posted[1]["targetRefName"], "refs/heads/main")
	same(t, f.posted[1]["isDraft"], true)
	reply := f.posted[2]
	if !strings.HasSuffix(reply["_path"].(string), "/pullRequests/1/threads/40/comments") || reply["parentCommentId"] != float64(1) {
		t.Fatalf("reply: %v", reply)
	}
}

func TestMergeAndApproveAreOnlyThePersons(t *testing.T) {
	f := newFake(t)
	f.pulls = []obj{pull(1, "feature", dev, nil)}
	c := serve(t, f, true)
	names := toolNames(c)
	if len(names) != 14 {
		t.Fatalf("person's tools: %v", names)
	}
	if _, ok := c.tool("merge_pull_request", map[string]any{"number": 1}); ok {
		t.Fatal("a merge with no sha worked")
	}
	if _, ok := c.tool("merge_pull_request", map[string]any{"number": 1, "sha": "sha1", "squash": true}); !ok {
		t.Fatal("merge failed")
	}
	if _, ok := c.tool("merge_pull_request", map[string]any{"number": 1, "sha": "older", "auto": true}); ok {
		t.Fatal("an auto-complete at an older head worked")
	}
	if _, ok := c.tool("merge_pull_request", map[string]any{"number": 1, "sha": "sha1", "auto": true}); !ok {
		t.Fatal("auto-complete failed")
	}
	if _, ok := c.tool("approve_pull_request", map[string]any{"number": 1, "sha": "older"}); ok {
		t.Fatal("an approval at an older head worked")
	}
	if _, ok := c.tool("approve_pull_request", map[string]any{"number": 1, "sha": "sha1"}); !ok {
		t.Fatal("approve failed")
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	same(t, len(f.posted), 3)
	same(t, f.posted[0]["_method"], "PATCH")
	same(t, f.posted[0]["status"], "completed")
	same(t, f.posted[0]["lastMergeSourceCommit"], map[string]any{"commitId": "sha1"})
	same(t, f.posted[0]["completionOptions"], map[string]any{"mergeStrategy": "squash", "deleteSourceBranch": true})
	same(t, f.posted[1]["autoCompleteSetBy"], map[string]any{"id": "a1"})
	same(t, f.posted[1]["status"], nil)
	same(t, f.posted[2]["_method"], "PUT")
	same(t, f.posted[2]["_path"], gitRoot+"/pullrequests/1/reviewers/a1")
	same(t, f.posted[2]["vote"], float64(10))
}
