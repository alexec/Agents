package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// The editor (#2630) lists, saves and deletes Markdown files in a project's skills and
// personas, and refuses any path out of its section.
func TestTheAgentConfigEditorKeepsToItsSection(t *testing.T) {
	d, c := start(t, t.TempDir())
	folder := t.TempDir()
	anAgentIn(t, d, folder)
	url := store.FolderURL(folder)

	save := func(id int, kind, path, content string) {
		c.call(t, id, "agentConfig/editorSave", map[string]any{"folder": url, "kind": kind, "path": path, "content": content})
	}
	list := func(id int, kind string) wire.AgentConfigEditorFiles {
		var files wire.AgentConfigEditorFiles
		if err := json.Unmarshal(c.call(t, id, "agentConfig/editorFiles", map[string]any{"folder": url, "kind": kind}), &files); err != nil {
			t.Fatal(err)
		}
		return files
	}

	if files := list(1, "personas"); len(files) != 0 {
		t.Fatalf("no personas yet: %+v", files)
	}
	persona := "---\nname: reviewer\n---\nReview the change.\n"
	save(2, "personas", "reviewer.md", persona)
	save(3, "skills", "lint/SKILL.md", "---\nname: lint\n---\nRun the linter.\n")
	if files := list(4, "personas"); len(files) != 1 || files[0].Path != "reviewer.md" || files[0].Content != persona {
		t.Fatalf("personas: %+v", files)
	}
	if files := list(5, "skills"); len(files) != 1 || files[0].Path != "lint/SKILL.md" {
		t.Fatalf("skills: %+v", files)
	}

	for i, path := range []string{"../escape.md", "/tmp/abs.md", ".hidden.md", "notes.txt", "a/b.md"} {
		msg := c.callErr(t, 10+i, "agentConfig/editorSave", map[string]any{"folder": url, "kind": "personas", "path": path, "content": "x"})
		if msg == "" {
			t.Fatalf("%s was accepted", path)
		}
	}
	if _, err := os.Stat(filepath.Join(folder, ".agents", "escape.md")); err == nil {
		t.Fatal("a file was written out of its section")
	}
	if msg := c.callErr(t, 20, "agentConfig/editorFiles", map[string]any{"folder": url, "kind": "plugins"}); !strings.Contains(msg, "skills, personas or workflows") {
		t.Fatalf("other kind: %s", msg)
	}

	c.call(t, 21, "agentConfig/editorSave", map[string]any{"folder": url, "kind": "personas", "path": "reviewer.md", "content": "", "delete": true})
	if files := list(22, "personas"); len(files) != 0 {
		t.Fatalf("deleted persona listed: %+v", files)
	}
}
