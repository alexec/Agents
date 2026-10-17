package linearmcp

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"reflect"
	"testing"
	"time"
)

// The front as the Agents daemon talks to it: initialize carries the events capability, the
// events are answered here, and there are no tools (Linear's own server has them).

func equal(t *testing.T, got, want any, what string) {
	t.Helper()
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("%s: got %#v, want %#v", what, got, want)
	}
}

func TestTheFrontOffersEventsAndNoTools(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	fake := &fakeLinear{}
	front := &Front{Events: &Events{Linear: fake}, Upstream: NewServer("test"), Version: "test", Logger: logger}
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

	if tools := call(2, "tools/list", map[string]any{}); tools["error"] == nil {
		if list, _ := tools["result"].(map[string]any)["tools"].([]any); len(list) != 0 {
			t.Fatalf("tools offered: %v", list)
		}
	}

	events := call(5, "events/list", map[string]any{})["result"].(map[string]any)["events"].([]any)
	equal(t, len(events), 4, "events")
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
