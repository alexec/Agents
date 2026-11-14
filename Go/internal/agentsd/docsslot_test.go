package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/agentloops-dev/agents/Go/wire"
)

// The Docs slot (#3248): with no forge and no connection it reads the folder itself, its
// proof the newest doc at the top or under specs/ or docs/ (never node_modules); a docs
// connector in mcp.json fills it beside the folder; a skip is kept in .agents/folder.json;
// and it never turns on the forge's events.
func TestTheDocsSlot(t *testing.T) {
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	folder := gitFolder(t, "")
	old := time.Now().Add(-time.Hour)
	write := func(rel string, at time.Time) {
		path := filepath.Join(folder, rel)
		os.MkdirAll(filepath.Dir(path), 0o755)
		if err := os.WriteFile(path, []byte("# "+rel), 0o644); err != nil {
			t.Fatal(err)
		}
		os.Chtimes(path, at, at)
	}
	c.call(t, 1, "folders/add", map[string]any{"folder": "file://" + folder})

	var setup wire.ConnectorSetup
	json.Unmarshal(c.call(t, 2, "connectors/setup", map[string]any{"folder": folder}), &setup)
	if s := slotsByKind(setup)[wire.ConnectorSlotKindDocs]; s.State != wire.ConnectorSlotStateRead || s.Proof != nil ||
		s.Choice != "This folder" || s.Servers != nil {
		t.Fatalf("a folder with no docs: %+v", s)
	}

	write("README.md", old)
	write("specs/3248-docs/spec.md", old.Add(10*time.Minute))
	write("docs/how-to/use-docs.md", old.Add(20*time.Minute))
	write("docs/notes.txt", time.Now())
	write("docs/node_modules/x/README.md", time.Now())
	write("docs/.cache/README.md", time.Now())
	os.MkdirAll(filepath.Join(home, ".agents"), 0o755)
	os.WriteFile(filepath.Join(home, ".agents", "mcp.json"), []byte(`{"mcpServers": {
		"notion": {"type": "http", "url": "https://mcp.notion.com/mcp"},
		"team-wiki": {"command": "wiki-mcp"},
		"playwright": {"command": "npx", "args": ["@playwright/mcp"]}}}`), 0o644)

	json.Unmarshal(c.call(t, 3, "connectors/setup", map[string]any{"folder": folder, "reading": "fresh"}), &setup)
	s := slotsByKind(setup)[wire.ConnectorSlotKindDocs]
	if s.State != wire.ConnectorSlotStateRead || s.Proof == nil || s.Proof.Title != "docs/how-to/use-docs.md" || s.Proof.At == nil {
		t.Fatalf("the newest doc: %+v %+v", s, s.Proof)
	}
	slices.Sort(s.Servers)
	if s.Choice != "This folder, Notion and team-wiki" || !slices.Equal(s.Servers, []string{"notion", "team-wiki"}) {
		t.Fatalf("docs connectors: %q %v", s.Choice, s.Servers)
	}
	if setup.Events.State != wire.ConnectorEventsStateOff {
		t.Fatalf("the docs read turned on the forge's events: %+v", setup.Events)
	}

	// A fresh value each time: Unmarshal into the old one keeps the fields a slot no longer has.
	setup = wire.ConnectorSetup{}
	json.Unmarshal(c.call(t, 4, "connectors/setup/skip", map[string]any{"folder": folder, "slot": "docs", "skipped": true}), &setup)
	if s := slotsByKind(setup)[wire.ConnectorSlotKindDocs]; s.State != wire.ConnectorSlotStateSkipped || s.Servers != nil {
		t.Fatalf("skipped: %+v", s)
	}
	if b, _ := os.ReadFile(filepath.Join(folder, ".agents", "folder.json")); !strings.Contains(string(b), `"docs"`) {
		t.Fatalf("folder.json: %s", b)
	}
	json.Unmarshal(c.call(t, 5, "connectors/setup/skip", map[string]any{"folder": folder, "slot": "docs", "skipped": false}), &setup)
	if s := slotsByKind(setup)[wire.ConnectorSlotKindDocs]; s.State != wire.ConnectorSlotStateRead {
		t.Fatalf("set up again: %+v", s)
	}
}

func TestDocsKindOf(t *testing.T) {
	for _, tc := range []struct{ name, summary, want string }{
		{"atlassian", "https://mcp.atlassian.com/v1/sse", "Confluence"},
		{"confluence", "npx confluence-mcp", "Confluence"},
		{"notion", "https://mcp.notion.com/mcp", "Notion"},
		{"drive", "npx @modelcontextprotocol/server-gdrive", "Google Drive"},
		{"handbook", "https://docs.example.com/mcp", "handbook"},
	} {
		if got, ok := docsKindOf(tc.name, tc.summary); !ok || got != tc.want {
			t.Errorf("%s: %q %v", tc.name, got, ok)
		}
	}
	for _, name := range []string{"github", "linear", "playwright"} {
		if got, ok := docsKindOf(name, name+"-mcp"); ok {
			t.Errorf("%s is not a docs connector: %q", name, got)
		}
	}
}
