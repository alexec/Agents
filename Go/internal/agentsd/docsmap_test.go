package agentsd

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// fakeDocsMCP is a docs server over streamable HTTP whose name says nothing about docs: kb_find
// searches, kb_open reads. What each search was sent is kept in asked.
func fakeDocsMCP(t *testing.T, asked *[]map[string]any, mu *sync.Mutex) *httptest.Server {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodDelete {
			return
		}
		var m struct {
			ID     *int            `json:"id"`
			Method string          `json:"method"`
			Params json.RawMessage `json:"params"`
		}
		json.NewDecoder(r.Body).Decode(&m)
		if m.ID == nil {
			w.WriteHeader(http.StatusAccepted)
			return
		}
		result := `{"protocolVersion":"2025-06-18","capabilities":{"tools":{}}}`
		switch m.Method {
		case "tools/list":
			result = `{"tools":[{"name":"kb_find","inputSchema":{"type":"object"}},{"name":"kb_open","inputSchema":{"type":"object"}}]}`
		case "tools/call":
			var p struct {
				Arguments map[string]any `json:"arguments"`
			}
			json.Unmarshal(m.Params, &p)
			mu.Lock()
			*asked = append(*asked, p.Arguments)
			mu.Unlock()
			found, _ := json.Marshal(`{"data":{"pages":[{"name":"Design of the docs slot","key":"P1","link":"https://kb.example.com/P1"}]}}`)
			result = `{"content":[{"type":"text","text":` + string(found) + `}]}`
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"jsonrpc":"2.0","id":%d,"result":%s}`, *m.ID, result)
	}))
	t.Cleanup(s.Close)
	return s
}

// A docs connector proves itself with one real search through the map an agent wrote
// (#3307): with no map it is named only when its name says docs, and says it has no map; a
// server whose name says nothing fills the slot once its map says it searches and reads; the
// search sends the folder's name and the slot shows the first doc found; a changed map is
// searched again at once; and a map that names a tool the server lacks says so.
func TestADocsConnectorProvesItselfWithOneSearch(t *testing.T) {
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	folder := gitFolder(t, "")
	c.call(t, 1, "folders/add", map[string]any{"folder": "file://" + folder})
	var asked []map[string]any
	var mu sync.Mutex
	kb := fakeDocsMCP(t, &asked, &mu)
	os.MkdirAll(filepath.Join(home, ".agents"), 0o755)
	os.WriteFile(filepath.Join(home, ".agents", "mcp.json"), []byte(`{"mcpServers": {
		"notion": {"type": "http", "url": "https://mcp.notion.com/mcp"},
		"kb": {"type": "http", "url": "`+kb.URL+`"}}}`), 0o644)
	read := func(id int, reading string) wire.ConnectorSlot {
		var setup wire.ConnectorSetup
		json.Unmarshal(c.call(t, id, "connectors/setup", map[string]any{"folder": folder, "reading": reading}), &setup)
		return slotsByKind(setup)[wire.ConnectorSlotKindDocs]
	}

	s := read(2, "fresh")
	if !slices.Equal(s.Servers, []string{"notion"}) || len(s.DocsServers) != 1 ||
		s.DocsServers[0] != (wire.DocsServer{Name: "notion", State: wire.DocsServerStateNoMap}) {
		t.Fatalf("no maps: %v %+v", s.Servers, s.DocsServers)
	}

	maps := filepath.Join(home, ".agents", docsMapsFile)
	os.WriteFile(maps, []byte(`{"kb": {
		"search": {"tool": "kb_find", "query": "q", "arguments": {"limit": 3}},
		"read": {"tool": "kb_open", "id": "key"},
		"results": {"list": "data.pages", "title": "name", "id": "key", "url": "link"}}}`), 0o644)
	s = read(3, "cached")
	if !slices.Equal(s.Servers, []string{"notion", "kb"}) || s.Choice != "This folder, Notion and kb" || len(s.DocsServers) != 2 {
		t.Fatalf("mapped: %q %v %+v", s.Choice, s.Servers, s.DocsServers)
	}
	got := s.DocsServers[1]
	if got.State != wire.DocsServerStateRead || got.Proof == nil || got.Proof.Title != "Design of the docs slot" ||
		got.Proof.URL == nil || *got.Proof.URL != "https://kb.example.com/P1" || got.Proof.At == nil {
		t.Fatalf("the search's proof: %+v %+v", got, got.Proof)
	}
	mu.Lock()
	if len(asked) != 1 || asked[0]["q"] != filepath.Base(folder) || asked[0]["limit"] != float64(3) {
		t.Fatalf("the search sent %v", asked)
	}
	mu.Unlock()

	// Read again within five minutes: the search is not made again.
	if s = read(4, "cached"); s.DocsServers[1].State != wire.DocsServerStateRead {
		t.Fatalf("kept: %+v", s.DocsServers[1])
	}
	mu.Lock()
	if len(asked) != 1 {
		t.Fatalf("searched again with the same map: %v", asked)
	}
	mu.Unlock()

	os.WriteFile(maps, []byte(`{"kb": {"search": {"tool": "kb_search", "query": "q"}, "read": {"tool": "kb_open", "id": "key"}}}`), 0o644)
	s = read(5, "cached")
	if f := s.DocsServers[1]; f.State != wire.DocsServerStateFailed || f.Message == nil ||
		*f.Message != "Its map names kb_search, a tool it doesn't have." {
		t.Fatalf("a wrong map: %+v", f)
	}
}

func TestFirstDoc(t *testing.T) {
	text := func(s string) string {
		b, _ := json.Marshal(s)
		return `{"content":[{"type":"text","text":` + string(b) + `}]}`
	}
	for _, tc := range []struct {
		name, raw string
		r         docsResults
		title     string
		url       string
		problem   string
	}{
		{name: "structured", raw: `{"content":[],"structuredContent":{"results":[{"title":"Spec","url":"https://n.so/1"}]}}`,
			r: docsResults{List: "results"}, title: "Spec", url: "https://n.so/1"},
		{name: "text as a list", raw: text(`[{"id":"42"}]`), title: "42"},
		{name: "none found", raw: text(`{"results":[]}`), r: docsResults{List: "results"}},
		{name: "not an address", raw: text(`[{"title":"T","url":"javascript:x"}]`), title: "T"},
		{name: "resource link", raw: `{"content":[{"type":"resource_link","uri":"https://d.example/a","name":"a.md","title":"Plan"}]}`,
			title: "Plan", url: "https://d.example/a"},
		{name: "plain text", raw: text("\n  Found: Roadmap 2027\nmore"), title: "Found: Roadmap 2027"},
		{name: "nothing", raw: `{"content":[]}`},
		{name: "an error", raw: `{"isError":true,"content":[{"type":"text","text":"bad query"}]}`, problem: "Its search answered: bad query"},
		{name: "a wrong list", raw: text(`{"results":{}}`), r: docsResults{List: "results"},
			problem: "Its map's results.list is not a list in what the search answered."},
		{name: "a wrong title", raw: text(`[{"x":1}]`), r: docsResults{Title: "name"},
			problem: "Its map's results.title is not in the first doc the search found."},
		{name: "a long title", raw: text(`[{"title":"` + strings.Repeat("a", 200) + `"}]`), title: strings.Repeat("a", 119) + "…"},
	} {
		p, err := firstDoc(json.RawMessage(tc.raw), tc.r)
		switch {
		case tc.problem != "":
			if err == nil || err.Error() != tc.problem {
				t.Errorf("%s: %v", tc.name, err)
			}
		case err != nil:
			t.Errorf("%s: %v", tc.name, err)
		case tc.title == "":
			if p != nil {
				t.Errorf("%s: %+v", tc.name, p)
			}
		case p == nil || p.Title != tc.title || (tc.url == "") != (p.URL == nil) || (p.URL != nil && *p.URL != tc.url):
			t.Errorf("%s: %+v", tc.name, p)
		}
	}
}
