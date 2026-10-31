package agentsd

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// #2033: a server's list view row ends in the count its feeding tool says.

func TestAViewsCountIsReadFromItsAnswer(t *testing.T) {
	for _, tc := range []struct {
		result          string
		count, attended int64 // -1: none
		failed          bool
	}{
		{`{"structuredContent":{"count":4,"attention":1}}`, 4, 1, false},
		{`{"structuredContent":{"prs":[]},"_meta":{"count":2}}`, 2, -1, false},
		{`{"structuredContent":{"prs":[]}}`, -1, -1, false},
		{`{"structuredContent":{"attention":3}}`, -1, -1, false},
		{`{"structuredContent":{"count":-1}}`, -1, -1, false},
		{`{"isError":true,"content":[]}`, -1, -1, true},
	} {
		count, attention, failed := viewCountOf(json.RawMessage(tc.result))
		got := func(p *int64) int64 {
			if p == nil {
				return -1
			}
			return *p
		}
		if got(count) != tc.count || got(attention) != tc.attended || failed != tc.failed {
			t.Errorf("%s: %v %v %v", tc.result, got(count), got(attention), failed)
		}
	}
}

// countServer is an http MCP server with one list view, whose tool says count; down
// makes every call fail.
func countServer(t *testing.T, count *atomic.Int32, down *atomic.Bool) *httptest.Server {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			return
		}
		if down.Load() {
			http.Error(w, "down", http.StatusBadGateway)
			return
		}
		b, _ := io.ReadAll(r.Body)
		var m struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
		}
		json.Unmarshal(b, &m)
		var result any
		switch m.Method {
		case "notifications/initialized":
			w.WriteHeader(http.StatusAccepted)
			return
		case "initialize":
			result = map[string]any{"protocolVersion": "2025-06-18", "capabilities": map[string]any{}, "serverInfo": map[string]any{"name": "gh", "title": "GitHub"}}
		case "tools/list":
			result = map[string]any{"tools": []any{map[string]any{"name": "show_issues",
				"_meta": map[string]any{"ui": map[string]any{"resourceUri": "ui://gh/issues"}}, "annotations": map[string]any{"readOnlyHint": true}}}}
		case "resources/list":
			result = map[string]any{"resources": []any{map[string]any{"uri": "ui://gh/issues", "name": "issues", "title": "Issues"}}}
		case "tools/call":
			result = map[string]any{"content": []any{}, "structuredContent": map[string]any{"count": count.Load()}}
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"jsonrpc": "2.0", "id": m.ID, "result": result})
	}))
	t.Cleanup(s.Close)
	return s
}

func TestAViewRowsCountFollowsItsListAndGoesStale(t *testing.T) {
	var count atomic.Int32
	var down atomic.Bool
	count.Store(23)
	server := countServer(t, &count, &down)
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	os.MkdirAll(filepath.Join(home, ".agents"), 0o755)
	os.WriteFile(filepath.Join(home, ".agents", "mcp.json"), []byte(`{"mcpServers":{"gh":{"url":"`+server.URL+`"}}}`), 0o644)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)

	views := func() []wire.PinView {
		var all []wire.FolderPins
		json.Unmarshal(c.call(t, 2, "pins/list", nil), &all)
		if len(all) != 1 {
			return nil
		}
		return all[0].Views
	}
	waitFor(t, "the catalog", func() bool { return len(views()) == 1 })
	if v := views()[0]; v.Title != "GitHub · Issues" || v.Count != nil {
		t.Fatalf("%+v", v)
	}
	d.countViewsOnce(context.Background())
	if v := views()[0]; v.Count == nil || *v.Count != 23 || v.CountStale != nil || v.CountAt == nil {
		t.Fatalf("%+v", v)
	}
	// The list changes: so does the count, and the clients are told.
	count.Store(24)
	d.countViewsOnce(context.Background())
	c.until(t, "pins/changed with 24", func(method string, p json.RawMessage) bool {
		var n wire.PinsChangedNotification
		json.Unmarshal(p, &n)
		return method == "pins/changed" && len(n.Views) == 1 && n.Views[0].Count != nil && *n.Views[0].Count == 24
	})
	// A failed poll keeps the last count, marked stale.
	down.Store(true)
	d.countViewsOnce(context.Background())
	if v := views()[0]; v.Count == nil || *v.Count != 24 || v.CountStale == nil || !*v.CountStale {
		t.Fatalf("%+v", v)
	}
	// A hidden view is not polled, and its count goes.
	down.Store(false)
	c.call(t, 3, "pins/hideView", map[string]any{"folder": store.FolderURL(dir), "uri": "ui://gh/issues", "hidden": true})
	d.countViewsOnce(context.Background())
	if v := views()[0]; v.Count != nil {
		t.Fatalf("%+v", v)
	}
}
