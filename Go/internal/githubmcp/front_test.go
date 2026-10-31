package githubmcp

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

// The front over the official server, as the Agents daemon talks to it: initialize carries
// the events capability, the events are answered here, and everything else is the official
// server's, without the tools a person keeps (#1232).

func TestTheFrontAddsEventsToTheOfficialServer(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	upstream, err := NewUpstream(ctx, UpstreamConfig{Version: "test", Token: func() string { return "" }, Logger: logger})
	if err != nil {
		t.Fatal(err)
	}
	front := &Front{Events: &Events{GitHub: newFake()}, Upstream: upstream, Version: "test", Logger: logger}
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
	if capabilities["tools"] == nil {
		t.Fatal("the official server's tools capability is gone")
	}
	equal(t, result["serverInfo"].(map[string]any)["name"], "github-mcp", "name")
	if !strings.HasPrefix(result["instructions"].(string), Instructions) {
		t.Fatal("the events' words are not first")
	}
	send(map[string]any{"jsonrpc": "2.0", "method": "notifications/initialized"})

	tools := call(2, "tools/list", map[string]any{})["result"].(map[string]any)["tools"].([]any)
	names := map[string]bool{}
	for _, tool := range tools {
		names[tool.(map[string]any)["name"].(string)] = true
	}
	for _, want := range []string{"list_pull_requests", "pull_request_read", "issue_read", "issue_write", "actions_list", "get_job_logs", "get_me"} {
		if !names[want] {
			t.Errorf("no %s among %d tools", want, len(names))
		}
	}
	for _, hidden := range HiddenTools {
		if names[hidden] {
			t.Errorf("%s is offered to the model", hidden)
		}
	}

	events := call(3, "events/list", map[string]any{})["result"].(map[string]any)["events"].([]any)
	equal(t, len(events), 14, "events")
	poll := call(4, "events/poll", map[string]any{"name": "pr.merged", "arguments": map[string]any{"repo": repo}, "cursor": nil})
	equal(t, poll["result"].(map[string]any)["events"], []any{}, "first poll")
	unknown := call(5, "events/poll", map[string]any{"name": "checks.unknown", "arguments": map[string]any{}, "cursor": nil})
	equal(t, unknown["error"].(map[string]any)["code"], float64(-32011), "unknown event")
	other := call(6, "events/nope", map[string]any{})
	equal(t, other["error"].(map[string]any)["code"], float64(-32601), "unknown method")
	equal(t, call(7, "ping", map[string]any{})["result"], map[string]any{}, "ping")

	_ = clientOut.Close()
	if err := <-served; err != nil {
		t.Fatal(err)
	}
}
