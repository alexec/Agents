package azureboardsmcp

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"reflect"
	"strings"
	"testing"
	"time"
)

// The front as the Agents daemon talks to it, over the fake Azure DevOps: initialize carries
// the events capability, the events are answered here, and the tools read and write work items.

type client struct {
	t     *testing.T
	lines *bufio.Scanner
	out   io.Writer
	id    int
	init  map[string]any
}

func serve(t *testing.T, f *fakeBoards) *client {
	b := f.boards()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	t.Cleanup(cancel)
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	front := &Front{Events: &Events{Boards: b}, Upstream: NewServer("test", b), Version: "test", Logger: logger}
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
	result, ok := c.call("tools/call", map[string]any{"name": name, "arguments": args})["result"].(map[string]any)
	if !ok || result["isError"] == true {
		return map[string]any{"error": result["content"]}, false
	}
	return result["structuredContent"].(map[string]any), true
}

func equal(t *testing.T, got, want any) {
	t.Helper()
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %#v, want %#v", got, want)
	}
}

func TestTheFrontOffersEventsAndTools(t *testing.T) {
	f := newFake(t)
	f.item(1, "Open bug", "Bug", "Active", dev, 1, obj{fieldTags: "agent", fieldAssigned: alex, fieldDesc: "<p>It fails.</p>"})
	f.item(2, "Closed story", "User Story", "Closed", dev, 2, nil)
	f.item(3, "Someone else's", "Bug", "New", dev, 3, obj{fieldAssigned: dev})
	f.comment(1, 50, builder, 4, "Build 12 failed")
	c := serve(t, f)

	equal(t, c.init["capabilities"].(map[string]any)["events"], map[string]any{"listChanged": false})
	equal(t, c.init["serverInfo"].(map[string]any)["name"], "azureboards-mcp")
	equal(t, c.init["instructions"], Instructions)
	listed := c.call("events/list", map[string]any{})["result"].(map[string]any)["events"].([]any)
	if len(listed) != len(EventNames()) {
		t.Fatalf("events/list: %d", len(listed))
	}
	if polled := c.call("events/poll", map[string]any{"name": "issue.closed"})["result"].(map[string]any); polled["cursor"] == nil {
		t.Fatalf("poll: %v", polled)
	}

	var names []string
	for _, tool := range c.call("tools/list", map[string]any{})["result"].(map[string]any)["tools"].([]any) {
		names = append(names, tool.(map[string]any)["name"].(string))
	}
	same(t, names, []string{"comment_on_work_item", "get_work_item", "list_work_items"})

	ids := func(r map[string]any) []string {
		var out []string
		for _, w := range r["workItems"].([]any) {
			out = append(out, w.(map[string]any)["key"].(string))
		}
		return out
	}
	open, ok := c.tool("list_work_items", map[string]any{})
	if !ok {
		t.Fatalf("list_work_items: %v", open)
	}
	same(t, ids(open), []string{"1", "3"})
	if q := f.lastQuery(); !strings.Contains(q, "[System.State] NOT IN ('Closed', 'Removed')") {
		t.Fatalf("WIQL %s", q)
	}
	closed, _ := c.tool("list_work_items", map[string]any{"state": "closed"})
	same(t, ids(closed), []string{"2"})
	all, _ := c.tool("list_work_items", map[string]any{"state": "all"})
	same(t, ids(all), []string{"1", "3", "2"})
	mine, _ := c.tool("list_work_items", map[string]any{"mine": true, "label": "agent", "type": "Bug", "area": `Web App\Team`})
	same(t, ids(mine), []string{"1"})
	if q := f.lastQuery(); !strings.Contains(q, "[System.WorkItemType] = 'Bug'") || !strings.Contains(q, `[System.AreaPath] UNDER 'Web App\Team'`) {
		t.Fatalf("WIQL %s", q)
	}
	if _, ok := c.tool("list_work_items", map[string]any{"state": "done"}); ok {
		t.Fatal("state done worked")
	}

	one, _ := c.tool("get_work_item", map[string]any{"id": 1})
	if one["title"] != "Open bug" || one["closed"] != false || one["description"] != "<p>It fails.</p>" || one["assignee"] != "alex@acme.test" {
		t.Fatalf("get_work_item: %v", one)
	}
	equal(t, one["comments"], []any{map[string]any{"id": float64(50), "author": "Project Collection Build Service (acme)", "bot": true,
		"at": at(4), "body": "Build 12 failed"}})
	if r, ok := c.tool("get_work_item", map[string]any{"id": 99}); ok || !strings.Contains(r["error"].([]any)[0].(map[string]any)["text"].(string), "no work item 99") {
		t.Fatalf("a work item it has not: %v", r)
	}

	made, ok := c.tool("comment_on_work_item", map[string]any{"id": 1, "body": "On it."})
	if !ok || made["id"] != float64(901) || made["url"] != f.server.URL+"/acme/Web%20App/_workitems/edit/1" {
		t.Fatalf("comment_on_work_item: %v", made)
	}
	equal(t, f.postedNow(), []obj{{"text": "On it.", "format": "markdown"}})
	if _, ok := c.tool("comment_on_work_item", map[string]any{"id": 1, "body": " "}); ok {
		t.Fatal("an empty comment worked")
	}
}
