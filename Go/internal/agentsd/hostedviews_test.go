package agentsd

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A hosted server's views come through its one copy, and a session is never offered, nor
// can call, a tool only a view may call (#1341).
func TestAHostedServersViewsComeThroughItsOneCopy(t *testing.T) {
	self, _ := os.Executable()
	t.Setenv("AGENTS_FAKE_MCP", "1")
	t.Setenv("AGENTS_FAKE_MCP_VIEWS", "1")
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	home := t.TempDir()
	d.PersonalHome = home
	os.MkdirAll(filepath.Join(home, ".agents"), 0o755)
	entry, _ := json.Marshal(map[string]any{"mcpServers": map[string]any{"gh": map[string]any{"command": self, "hosted": true}}})
	os.WriteFile(filepath.Join(home, ".agents", "mcp.json"), entry, 0o644)

	s, problem := d.viewServerFor("gh", t.TempDir())
	if problem != 0 || s.connect == nil {
		t.Fatalf("a hosted server shows no views: %d", problem)
	}
	catalog := d.loadViewCatalog(context.Background(), s)
	if catalog == nil || catalog.tool("board") == nil || !catalog.tool("board").feedsPins() || !catalog.appTool("merge") {
		t.Fatalf("catalog: %+v", catalog)
	}
	var called json.RawMessage
	if err := withViewSession(context.Background(), s, func(m *viewSession) error {
		var err error
		called, err = m.call("tools/call", map[string]any{"name": "merge", "arguments": map[string]any{}})
		return err
	}); err != nil || !strings.Contains(string(called), "called") {
		t.Fatalf("a view's tools/call: %s, %v", called, err)
	}

	// A session on the same copy: one process, and no merge.
	entries := d.sessionEntries(t.TempDir())
	got := d.hostedSwapped(entries, 4242, "tok", "claude")
	if len(got) != 1 || got[0].Http == nil {
		t.Fatalf("the session is not handed the copy: %+v", got)
	}
	path := got[0].Http.Url[len("http://127.0.0.1:4242"):]
	d.hostedMu.Lock()
	n := len(d.hostedByKey)
	h := d.hostedByPath(path)
	d.hostedMu.Unlock()
	if n != 1 || h == nil {
		t.Fatalf("%d copies of one server", n)
	}
	list, err := d.hostedSessionCall(h, "tools/list", json.RawMessage(`{}`))
	if err != nil || strings.Contains(string(list), `"merge"`) || !strings.Contains(string(list), `"board"`) {
		t.Fatalf("a session's tools/list: %s, %v", list, err)
	}
	if _, err := d.hostedSessionCall(h, "tools/call", json.RawMessage(`{"name":"merge","arguments":{}}`)); err == nil {
		t.Fatal("a session called a tool only a view may call")
	}
	if _, err := d.hostedSessionCall(h, "tools/call", json.RawMessage(`{"name":"board","arguments":{}}`)); err != nil {
		t.Fatalf("a session's own tool: %v", err)
	}
}

// A changed entry is a new catalog, and the old one goes; so does one too old to be read
// (#3128).
func TestAChangedEntrysOldViewCatalogIsRemoved(t *testing.T) {
	self, _ := os.Executable()
	t.Setenv("AGENTS_FAKE_MCP", "1")
	t.Setenv("AGENTS_FAKE_MCP_VIEWS", "1")
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	home := t.TempDir()
	d.PersonalHome = home
	os.MkdirAll(filepath.Join(home, ".agents"), 0o755)
	write := func(args ...string) {
		entry, _ := json.Marshal(map[string]any{"mcpServers": map[string]any{
			"gh": map[string]any{"command": self, "args": args, "hosted": true}}})
		os.WriteFile(filepath.Join(home, ".agents", "mcp.json"), entry, 0o644)
	}
	dir := filepath.Dir(d.viewCatalogPath("x"))
	old, _ := json.Marshal(viewCatalog{Version: viewCatalogVersion, Server: "gone", MadeAt: nowFunc().Add(-2 * viewCatalogFresh)})
	os.MkdirAll(dir, 0o755)
	os.WriteFile(filepath.Join(dir, "removed-entry.json"), old, 0o644)

	var last viewServer
	for _, args := range [][]string{nil, {"-test.run=^$"}} {
		write(args...)
		s, problem := d.viewServerFor("gh", t.TempDir())
		if problem != 0 {
			t.Fatalf("no views: %d", problem)
		}
		if d.loadViewCatalog(context.Background(), s) == nil {
			t.Fatal("no catalog")
		}
		last = s
	}
	files, _ := os.ReadDir(dir)
	if len(files) != 1 || files[0].Name() != last.entry+".json" {
		var names []string
		for _, f := range files {
			names = append(names, f.Name())
		}
		t.Fatalf("mcp-views/ holds %v, not only %s.json", names, last.entry)
	}
}
