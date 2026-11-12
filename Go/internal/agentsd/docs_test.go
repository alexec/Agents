package agentsd

import (
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

// fakeDocsServer is a docs server over streamable HTTP: kb_find searches (its words in q),
// kb_recent lists, kb_open reads (its id in key).
func fakeDocsServer(t *testing.T) *httptest.Server {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodDelete {
			return
		}
		var m struct {
			ID     *int `json:"id"`
			Method string
			Params struct {
				Name      string
				Arguments map[string]any
			}
		}
		json.NewDecoder(r.Body).Decode(&m)
		if m.ID == nil {
			w.WriteHeader(http.StatusAccepted)
			return
		}
		text := func(s string) string {
			b, _ := json.Marshal(s)
			return `{"content":[{"type":"text","text":` + string(b) + `}]}`
		}
		result := `{"protocolVersion":"2025-06-18","capabilities":{"tools":{}}}`
		switch m.Method {
		case "tools/list":
			result = `{"tools":[{"name":"kb_find"},{"name":"kb_open"},{"name":"kb_recent"}]}`
		case "tools/call":
			switch m.Params.Name {
			case "kb_recent":
				result = text(`{"pages":[{"name":"Payments: requirements","key":"P1","link":"https://kb.example.com/P1","edited":"2099-01-01T10:00:00Z"}]}`)
			case "kb_find":
				if m.Params.Arguments["q"] != "checkout" {
					result = text(`{"pages":[]}`)
					break
				}
				result = text(`{"pages":[{"name":"Checkout redesign","key":"P2","link":"https://kb.example.com/P2","hit":"the checkout flow"}]}`)
			case "kb_open":
				result = text(`{"markdown":"# Checkout redesign\n\nOne\nTwo\n"}`)
				if m.Params.Arguments["key"] != "P2" {
					result = `{"isError":true,"content":[{"type":"text","text":"no such page"}]}`
				}
			}
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"jsonrpc":"2.0","id":%d,"result":%s}`, *m.ID, result)
	}))
	t.Cleanup(s.Close)
	return s
}

// Docs (#3319, #3320): docs/list gives a folder's *.md files at its top and under specs/ and
// docs/ (none elsewhere), by a ref of its repo, and a mapped connector's recent docs, the last
// updated first; a connector with no map is a source not mapped; docs/search finds lines with
// every word in folder docs and asks the connector's search; docs/read reads a part of a doc
// by its ref, from a folder or a connector; and a folder whose Docs slot is None gives no
// source.
func TestDocsListSearchAndRead(t *testing.T) {
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	folder := gitFolder(t, "git@github.com:Alexec/Agents.git")
	c.call(t, 1, "folders/add", map[string]any{"folder": "file://" + folder})
	writeFile(t, filepath.Join(folder, "README.md"), "# Agents\n\nRun several agents.\n")
	writeFile(t, filepath.Join(folder, "specs", "3319-docs", "spec.md"), "# Docs, first-class\n\nThe Docs list.\nA docs list for every folder.\n")
	writeFile(t, filepath.Join(folder, "docs", "leases.md"), "No heading here.\n")
	writeFile(t, filepath.Join(folder, "src", "notes.md"), "# Not a doc\n")
	writeFile(t, filepath.Join(folder, "docs", "node_modules", "x.md"), "# Not a doc\n")
	old := time.Now().Add(-time.Hour)
	os.Chtimes(filepath.Join(folder, "README.md"), old, old)

	kb := fakeDocsServer(t)
	writeFile(t, filepath.Join(home, ".agents", "mcp.json"), `{"mcpServers": {
		"notion": {"type": "http", "url": "https://mcp.notion.com/mcp"},
		"kb": {"type": "http", "url": "`+kb.URL+`"}}}`)
	writeFile(t, filepath.Join(home, ".agents", docsMapsFile), `{"kb": {
		"search": {"tool": "kb_find", "query": "q"},
		"read": {"tool": "kb_open", "id": "key"},
		"recent": {"tool": "kb_recent"},
		"results": {"list": "pages", "title": "name", "id": "key", "url": "link", "snippet": "hit", "updated": "edited"}}}`)

	var list wire.DocsList
	json.Unmarshal(c.call(t, 2, "docs/list", wire.DocsListRequest{}), &list)
	var refs []string
	for _, doc := range list.Docs {
		refs = append(refs, doc.Ref+" "+doc.Title)
	}
	want := []string{
		"mcp:kb/P1 Payments: requirements",
		"github:doc:alexec/agents#docs/leases.md leases.md",
		"github:doc:alexec/agents#specs/3319-docs/spec.md Docs, first-class",
		"github:doc:alexec/agents#README.md Agents",
	}
	// The two docs written now can have the same time: check the first and the last.
	if len(refs) != len(want) || refs[0] != want[0] || refs[3] != want[3] {
		t.Fatalf("docs/list: %q", refs)
	}
	if p := list.Docs[1].Path; p == nil || list.Docs[1].Source != folder {
		t.Fatalf("a folder doc: %+v", list.Docs[1])
	}
	if u := list.Docs[0].URL; u == nil || *u != "https://kb.example.com/P1" || list.Docs[0].Source != "mcp:kb" {
		t.Fatalf("a connector doc: %+v", list.Docs[0])
	}
	states := map[string]wire.DocsSourceState{}
	for _, s := range list.Sources {
		states[s.ID] = s.State
	}
	if states[folder] != wire.DocsSourceStateRead || states["mcp:kb"] != wire.DocsSourceStateRead ||
		states["mcp:notion"] != wire.DocsSourceStateNotMapped || len(states) != 3 {
		t.Fatalf("sources: %+v", list.Sources)
	}

	// A page at a time.
	json.Unmarshal(c.call(t, 3, "docs/list", wire.DocsListRequest{Limit: new(int64(3))}), &list)
	if len(list.Docs) != 3 || list.Cursor == nil {
		t.Fatalf("a page: %+v", list)
	}
	var next wire.DocsList
	json.Unmarshal(c.call(t, 4, "docs/list", wire.DocsListRequest{Limit: new(int64(3)), Cursor: list.Cursor}), &next)
	if len(next.Docs) != 1 || next.Cursor != nil || next.Docs[0].Title != "Agents" {
		t.Fatalf("the next page: %+v", next)
	}

	var found wire.DocsSearch
	json.Unmarshal(c.call(t, 5, "docs/search", wire.DocsSearchRequest{Query: "DOCS list"}), &found)
	if len(found.Results) != 1 || found.Results[0].Doc.Title != "Docs, first-class" || len(found.Results[0].Matches) != 2 ||
		*found.Results[0].Matches[0].Line != 3 || found.Results[0].Matches[1].Snippet != "A docs list for every folder." {
		t.Fatalf("docs/search in a folder: %+v", found)
	}
	var inKB wire.DocsSearch
	json.Unmarshal(c.call(t, 6, "docs/search", wire.DocsSearchRequest{Query: "checkout", Sources: []string{"mcp:kb"}}), &inKB)
	if len(inKB.Results) != 1 || inKB.Results[0].Doc.Ref != "mcp:kb/P2" || len(inKB.Results[0].Matches) != 1 ||
		inKB.Results[0].Matches[0].Line != nil || inKB.Results[0].Matches[0].Snippet != "the checkout flow" || len(inKB.Sources) != 1 {
		t.Fatalf("docs/search in a connector: %+v", inKB)
	}

	var read wire.DocsReading
	json.Unmarshal(c.call(t, 7, "docs/read", wire.DocsReadRequest{Ref: "github:doc:alexec/agents#specs/3319-docs/spec.md", From: new(int64(3)), To: new(int64(3))}), &read)
	if read.Text != "The Docs list.\n" || read.Lines != 4 || read.From != 3 || read.To != 3 || read.Next == nil || *read.Next != 4 ||
		read.Doc.Title != "Docs, first-class" {
		t.Fatalf("docs/read of a folder doc: %+v", read)
	}
	// A ref in the form from before #4800 reads the same doc.
	var oldForm wire.DocsReading
	json.Unmarshal(c.call(t, 20, "docs/read", wire.DocsReadRequest{Ref: "github:alexec/agents/doc/specs/3319-docs/spec.md"}), &oldForm)
	if oldForm.Doc.Ref != "github:doc:alexec/agents#specs/3319-docs/spec.md" {
		t.Fatalf("docs/read in the old form: %+v", oldForm)
	}
	var page wire.DocsReading
	json.Unmarshal(c.call(t, 8, "docs/read", wire.DocsReadRequest{Ref: "mcp:kb/P2"}), &page)
	if page.Text != "# Checkout redesign\n\nOne\nTwo\n" || page.Lines != 4 || page.Next != nil || page.Doc.Title != "Checkout redesign" {
		t.Fatalf("docs/read of a connector doc: %+v", page)
	}
	for i, ref := range []string{"github:doc:alexec/agents#src/notes.md", "github:doc:alexec/agents#../x.md",
		"github:doc:alexec/agents#docs/missing.md", "mcp:kb/P9", "notion:abc", "nowhere"} {
		if e := c.callError(t, 9+i, "docs/read", wire.DocsReadRequest{Ref: ref}); e == nil {
			t.Fatalf("docs/read %s worked", ref)
		}
	}

	c.call(t, 20, "connectors/setup/skip", map[string]any{"folder": folder, "slot": "docs", "skipped": true})
	var none wire.DocsList
	json.Unmarshal(c.call(t, 21, "docs/list", wire.DocsListRequest{}), &none)
	if len(none.Docs) != 0 || len(none.Sources) != 0 {
		t.Fatalf("a folder whose Docs slot is None: %+v", none)
	}
}

// A folder with no forge remote names its docs by this machine and its name.
func TestDocsOfAFolderWithNoForge(t *testing.T) {
	t.Setenv("AGENTS_PERSONAL_HOME", t.TempDir())
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	folder := gitFolder(t, "")
	c.call(t, 1, "folders/add", map[string]any{"folder": "file://" + folder})
	writeFile(t, filepath.Join(folder, "docs", "plan.md"), "# Plan\n")
	var list wire.DocsList
	json.Unmarshal(c.call(t, 2, "docs/list", wire.DocsListRequest{Folder: &folder}), &list)
	want := "folder:doc:" + strings.ToLower(docsMachine()+"/"+filepath.Base(folder)) + "#docs/plan.md"
	if len(list.Docs) != 1 || list.Docs[0].Ref != want {
		t.Fatalf("docs/list: %+v", list.Docs)
	}
	var read wire.DocsReading
	json.Unmarshal(c.call(t, 3, "docs/read", wire.DocsReadRequest{Ref: want}), &read)
	if read.Text != "# Plan\n" {
		t.Fatalf("docs/read: %+v", read)
	}
}

func TestDocsWindow(t *testing.T) {
	var many []string
	for i := 1; i <= docsReadLines+10; i++ {
		many = append(many, fmt.Sprint(i))
	}
	r, _ := docsWindow(wire.Doc{}, strings.Join(many, "\n")+"\n", 1, 0)
	if r.To != docsReadLines || r.Next == nil || *r.Next != docsReadLines+1 || r.Lines != docsReadLines+10 {
		t.Fatalf("the line limit: to %d next %v lines %d", r.To, r.Next, r.Lines)
	}
	long := strings.Repeat("é", docsReadBytes)
	r, _ = docsWindow(wire.Doc{}, long+"\nb\n", 1, 0)
	if r.To != 1 || len(r.Text) > docsReadBytes || !strings.HasPrefix(r.Text, "é") || *r.Next != 2 {
		t.Fatalf("a line past the byte limit: to %d len %d", r.To, len(r.Text))
	}
	r, _ = docsWindow(wire.Doc{}, "", 1, 0)
	if r.Lines != 0 || r.Text != "" {
		t.Fatalf("an empty doc: %+v", r)
	}
	if _, err := docsWindow(wire.Doc{}, "a\n", 2, 0); err == nil {
		t.Fatal("from past the end worked")
	}
}

func TestDocsMarkdown(t *testing.T) {
	for _, tc := range []struct{ raw, want, problem string }{
		{raw: `{"content":[{"type":"text","text":"# T\nbody"}]}`, want: "# T\nbody"},
		{raw: `{"content":[{"type":"text","text":"a"},{"type":"resource","resource":{"text":"b"}}]}`, want: "a\n\nb"},
		{raw: `{"content":[],"structuredContent":{"body":"# B"}}`, want: "# B"},
		{raw: `{"content":[{"type":"text","text":"{\"id\":1}"}]}`, want: "```json\n{\n  \"id\": 1\n}\n```\n"},
		{raw: `{"isError":true,"content":[{"type":"text","text":"gone"}]}`, problem: "its read answered: gone"},
	} {
		got, err := docsMarkdown(json.RawMessage(tc.raw))
		if tc.problem != "" {
			if err == nil || err.Error() != tc.problem {
				t.Errorf("%s: %v", tc.raw, err)
			}
			continue
		}
		if err != nil || got != tc.want {
			t.Errorf("%s: %q %v", tc.raw, got, err)
		}
	}
}

// A ref reaches only a doc: no path out of the folder, no link, nothing outside specs/ and docs/.
func TestFolderDocFile(t *testing.T) {
	folder := t.TempDir()
	outside := t.TempDir()
	writeFile(t, filepath.Join(folder, "docs", "a.md"), "a")
	writeFile(t, filepath.Join(outside, "secret.md"), "s")
	os.Symlink(filepath.Join(outside, "secret.md"), filepath.Join(folder, "docs", "link.md"))
	os.Symlink(outside, filepath.Join(folder, "specs"))
	writeFile(t, filepath.Join(folder, "docs", ".hidden", "h.md"), "h")
	if _, ok := folderDocFile(folder, "docs/a.md"); !ok {
		t.Fatal("docs/a.md is a doc")
	}
	for _, rel := range []string{"docs/link.md", "specs/secret.md", "docs/../docs/a.md", "../x.md", "/etc/x.md",
		"docs/.hidden/h.md", "docs/a.txt", "src/a.md"} {
		if _, ok := folderDocFile(folder, rel); ok {
			t.Errorf("%s is not a doc", rel)
		}
	}
}
