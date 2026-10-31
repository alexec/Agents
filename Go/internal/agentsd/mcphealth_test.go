package agentsd

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// Ports MCPHealthTests: a server is checked as a session reaches it, initialize then
// tools/list; one that answers says how many tools, one that stops says so, one that asks
// for a sign-in says that, and Check Now checks again.

// fakeMCPServer is the test binary as a stdio MCP server with two tools.
func fakeMCPServer() {
	in := bufio.NewScanner(os.Stdin)
	for in.Scan() {
		var m struct {
			ID     *int   `json:"id"`
			Method string `json:"method"`
		}
		json.Unmarshal(in.Bytes(), &m)
		if m.ID == nil {
			continue
		}
		result := `{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"fake","version":"1"}}`
		// With FAKE_MCP_LEVELS it declares events and a ui:// view too (#1428).
		levels := os.Getenv("FAKE_MCP_LEVELS") == "1"
		switch {
		case m.Method == "initialize" && levels:
			result = `{"protocolVersion":"2025-06-18","capabilities":{"tools":{},"resources":{},"events":{}},"serverInfo":{"name":"fake","version":"1"}}`
		case m.Method == "tools/list" && os.Getenv("AGENTS_FAKE_MCP_VIEWS") == "1":
			// A tool with a view, and one only a view may call (#1341).
			result = `{"tools":[{"name":"board","inputSchema":{"type":"object"},"annotations":{"readOnlyHint":true},` +
				`"_meta":{"ui":{"resourceUri":"ui://fake/board","visibility":["model","app"]}}},` +
				`{"name":"merge","inputSchema":{"type":"object"},"_meta":{"ui":{"visibility":["app"]}}}]}`
		case m.Method == "resources/list":
			result = `{"resources":[{"uri":"ui://fake/board","name":"board","title":"Board","mimeType":"text/html;profile=mcp-app"}]}`
		case m.Method == "events/list":
			result = `{"events":[{"name":"pr.opened","delivery":["poll"]}]}`
		case m.Method == "tools/list":
			result = `{"tools":[{"name":"a","inputSchema":{"type":"object"}},{"name":"b","inputSchema":{"type":"object"}}]}`
		case m.Method == "tools/call":
			result = `{"content":[{"type":"text","text":"called"}]}`
		}
		fmt.Printf(`{"jsonrpc":"2.0","id":%d,"result":%s}`+"\n", *m.ID, result)
	}
}

// fakeHTTPMCP answers as streamable HTTP does: a session id, and each answer as an event.
func fakeHTTPMCP(t *testing.T) *httptest.Server {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodDelete {
			return
		}
		var m struct {
			ID     *int   `json:"id"`
			Method string `json:"method"`
		}
		json.NewDecoder(r.Body).Decode(&m)
		if m.ID == nil {
			w.WriteHeader(http.StatusAccepted)
			return
		}
		if m.Method != "initialize" && r.Header.Get("Mcp-Session-Id") != "s1" {
			http.Error(w, "no session", http.StatusBadRequest)
			return
		}
		result := `{"protocolVersion":"2025-06-18","capabilities":{}}`
		if m.Method == "tools/list" {
			result = `{"tools":[{"name":"only","inputSchema":{"type":"object"}}]}`
		}
		w.Header().Set("Mcp-Session-Id", "s1")
		w.Header().Set("Content-Type", "text/event-stream")
		fmt.Fprintf(w, "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":%d,\"result\":%s}\n\n", *m.ID, result)
	}))
	t.Cleanup(s.Close)
	return s
}

func TestMCPServersAreChecked(t *testing.T) {
	self, _ := os.Executable()
	t.Setenv("AGENTS_FAKE_MCP", "1")
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	web := fakeHTTPMCP(t)
	locked := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusUnauthorized) }))
	defer locked.Close()
	home := t.TempDir()
	d.PersonalHome = home
	os.MkdirAll(filepath.Join(home, ".agents"), 0o755)
	entries := map[string]any{
		"fake":   map[string]any{"command": self},
		"levels": map[string]any{"command": self, "env": map[string]any{"FAKE_MCP_LEVELS": "1"}},
		"web":    map[string]any{"url": web.URL},
		"locked": map[string]any{"url": locked.URL},
		"gone":   map[string]any{"command": "/bin/sh", "args": []string{"-c", "exit 0"}},
	}
	b, _ := json.Marshal(map[string]any{"mcpServers": entries})
	os.WriteFile(filepath.Join(home, ".agents", "mcp.json"), b, 0o644)

	var snap wire.MCPHealthSnapshot
	json.Unmarshal(c.call(t, 1, "mcp/health/check", map[string]any{}), &snap)
	byName := func(s wire.MCPHealthSnapshot) map[string]wire.MCPServerHealth {
		m := map[string]wire.MCPServerHealth{}
		for _, h := range s.Servers {
			m[h.Name] = h
		}
		return m
	}
	settled := func(m map[string]wire.MCPServerHealth) bool {
		for _, h := range m {
			if h.Check == wire.MCPCheckStateChecking || h.Check == wire.MCPCheckStateUnchecked {
				return false
			}
		}
		return len(m) == 5
	}
	deadline := time.Now().Add(20 * time.Second)
	for !settled(byName(snap)) && time.Now().Before(deadline) {
		time.Sleep(100 * time.Millisecond)
		json.Unmarshal(c.call(t, 2, "mcp/health", nil), &snap)
	}
	got := byName(snap)
	if h := got["fake"]; h.Check != wire.MCPCheckStateAnswered || h.Tools == nil || *h.Tools != 2 || h.CheckedAt == nil {
		t.Fatalf("fake: %+v", h)
	}
	if h := got["fake"]; h.Levels == nil || *h.Levels != (wire.MCPLevels{Tools: true}) {
		t.Fatalf("fake's levels: %+v", h.Levels)
	}
	if h := got["levels"]; h.Levels == nil || *h.Levels != (wire.MCPLevels{Tools: true, Events: true, Views: true}) {
		t.Fatalf("levels: %+v", h.Levels)
	}
	if h := got["web"]; h.Check != wire.MCPCheckStateAnswered || h.Tools == nil || *h.Tools != 1 {
		t.Fatalf("web: %+v", h)
	}
	if h := got["locked"]; h.Check != wire.MCPCheckStateSignIn {
		t.Fatalf("locked: %+v", h)
	}
	if h := got["gone"]; h.Check != wire.MCPCheckStateFailed || h.LastError == nil || !strings.Contains(*h.LastError, "stopped before it answered") {
		t.Fatalf("gone: %+v", h)
	}
	// Checked a moment ago: a look now starts nothing; Check Now checks it again.
	at := *got["fake"].CheckedAt
	json.Unmarshal(c.call(t, 3, "mcp/health", nil), &snap)
	if byName(snap)["fake"].Check != wire.MCPCheckStateAnswered {
		t.Fatal("checked again unasked")
	}
	json.Unmarshal(c.call(t, 4, "mcp/health/check", map[string]any{}), &snap)
	for time.Now().Before(deadline) {
		json.Unmarshal(c.call(t, 5, "mcp/health", nil), &snap)
		if h := byName(snap)["fake"]; h.Check == wire.MCPCheckStateAnswered && *h.CheckedAt > at {
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatal("Check Now did not check again")
}
