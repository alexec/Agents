package linearmcp

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

// The front as the Agents daemon talks to it: initialize carries the events capability, the
// events are answered here, and its tools are show_issues and show_issue_details, with its page (Linear's own
// server changes issues).

func equal(t *testing.T, got, want any, what string) {
	t.Helper()
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("%s: got %#v, want %#v", what, got, want)
	}
}

func TestTheFrontOffersEventsAndTheIssuesView(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	fake := &fakeLinear{}
	upstream := NewServer("test")
	AddViews(upstream, fakeViews{})
	front := &Front{Events: &Events{Linear: fake}, Upstream: upstream, Version: "test", Logger: logger}
	clientIn, frontOut := io.Pipe()
	frontIn, clientOut := io.Pipe()
	served := make(chan error, 1)
	go func() { served <- front.Serve(ctx, frontIn, frontOut); _ = frontOut.Close() }()

	lines := bufio.NewScanner(clientIn)
	lines.Buffer(nil, 16<<20)
	send := func(m map[string]any) {
		data, _ := json.Marshal(m)
		if _, err := clientOut.Write(append(data, '\n')); err != nil {
			t.Fatal(err)
		}
	}
	call := func(id int, method string, params any) map[string]any {
		t.Helper()
		send(map[string]any{"jsonrpc": "2.0", "id": id, "method": method, "params": params})
		for lines.Scan() {
			var reply map[string]any
			if err := json.Unmarshal(lines.Bytes(), &reply); err != nil {
				t.Fatalf("%s: %v", lines.Text(), err)
			}
			if reply["id"] == float64(id) {
				return reply
			}
		}
		t.Fatalf("%s: no answer (%v)", method, lines.Err())
		return nil
	}

	init := call(1, "initialize", map[string]any{"protocolVersion": "2025-06-18", "capabilities": map[string]any{},
		"clientInfo": map[string]any{"name": "Agents", "version": "1"}})
	result := init["result"].(map[string]any)
	capabilities := result["capabilities"].(map[string]any)
	equal(t, capabilities["events"], map[string]any{"listChanged": false}, "events capability")
	equal(t, result["serverInfo"].(map[string]any)["name"], "linear-mcp", "name")
	equal(t, result["instructions"], Instructions, "instructions")
	send(map[string]any{"jsonrpc": "2.0", "method": "notifications/initialized"})

	tools, _ := call(2, "tools/list", map[string]any{})["result"].(map[string]any)["tools"].([]any)
	if len(tools) != 2 {
		t.Fatalf("tools offered: %v", tools)
	}
	listed := map[string]bool{}
	for _, tool := range tools {
		listed[tool.(map[string]any)["name"].(string)] = true
	}
	if !listed["show_issues"] || !listed["show_issue_details"] {
		t.Fatalf("tools offered: %v", tools)
	}
	for _, tool := range tools {
		if tool.(map[string]any)["name"] == "show_issues" {
			equal(t, tool.(map[string]any)["_meta"].(map[string]any)["ui/resourceUri"], "ui://linear/issues", "the tool's view")
		}
	}
	page := call(3, "resources/read", map[string]any{"uri": "ui://linear/issues"})["result"].(map[string]any)["contents"].([]any)
	if text, _ := page[0].(map[string]any)["text"].(string); !strings.Contains(text, "const bridge") || strings.Contains(text, "/*bridge.js*/") ||
		!strings.Contains(text, "show_issue_details") || !strings.Contains(text, "issue-row") || strings.Contains(text, "Show details") {
		t.Fatal("the page does not carry its bridge and expandable issue rows")
	} else {
		for _, want := range []string{"Add a label filter", "label-tags", "removeLabel", "Promise.all"} {
			if !strings.Contains(text, want) {
				t.Errorf("issues page is missing %q", want)
			}
		}
	}
	shown := call(4, "tools/call", map[string]any{"name": "show_issues", "arguments": map[string]any{"team": "ENG"}})["result"].(map[string]any)
	issues := shown["structuredContent"].(map[string]any)["issues"].([]any)
	equal(t, issues[0].(map[string]any)["identifier"], "ENG-5", "the listed issue")
	sections := []any{}
	for _, issue := range issues {
		sections = append(sections, issue.(map[string]any)["section"])
	}
	equal(t, sections, []any{"needs_you", "yours", "team", "others"}, "each issue's section (#2453)")
	equal(t, issues[2].(map[string]any)["authorBot"], true, "an app's issue")
	equal(t, shown["structuredContent"].(map[string]any)["attention"], float64(1), "attention is the Needs you count")
	equal(t, shown["structuredContent"].(map[string]any)["viewer"], "alex", "the viewer")
	details := call(10, "tools/call", map[string]any{"name": "show_issue_details", "arguments": map[string]any{"identifier": "ENG-5"}})["result"].(map[string]any)
	equal(t, details["structuredContent"].(map[string]any)["descriptionHTML"], "<p><strong>Text</strong></p>\n", "rendered issue description")
	refused := call(9, "tools/call", map[string]any{"name": "show_issues", "arguments": map[string]any{"state": "completed"}})["result"].(map[string]any)
	equal(t, refused["isError"], true, "a closed state is refused")

	events := call(5, "events/list", map[string]any{})["result"].(map[string]any)["events"].([]any)
	equal(t, len(events), 5, "events")
	poll := call(6, "events/poll", map[string]any{"name": "issue.opened", "arguments": map[string]any{"team": "ENG"}, "cursor": nil})
	equal(t, poll["result"].(map[string]any)["events"], []any{}, "first poll")
	unknown := call(7, "events/poll", map[string]any{"name": "issue.reopened", "arguments": map[string]any{}, "cursor": nil})
	equal(t, unknown["error"].(map[string]any)["code"], float64(-32011), "unknown event")
	equal(t, call(8, "ping", map[string]any{})["result"], map[string]any{}, "ping")

	_ = clientOut.Close()
	if err := <-served; err != nil {
		t.Fatal(err)
	}
}
