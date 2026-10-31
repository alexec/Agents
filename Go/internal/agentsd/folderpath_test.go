package agentsd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/agentsd/store"
)

// A folder's .agents/workflows, or its .agents, that is a link takes none of the app's
// reads, writes or removes outside the folder; nor does a workflow file that is a link.

func TestALinkedWorkflowFolderIsRefused(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	outside := t.TempDir()
	os.WriteFile(filepath.Join(outside, "CLAUDE.md"), []byte("keep\n"), 0o644)
	os.RemoveAll(workflowsFolder(dir))
	os.MkdirAll(filepath.Join(dir, ".agents"), 0o755)
	if err := os.Symlink(outside, workflowsFolder(dir)); err != nil {
		t.Fatal(err)
	}
	a := seeded(t, d, dir, nil)
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	content := "---\non:\n  - schedule:\n      at: \":30\"\n---\nWrite this.\n"
	notIn := "Workflows can only be read and written inside this folder's .agents/workflows"
	if text, isErr := m.tool(2, "manage_workflows", map[string]any{"action": "write", "id": "CLAUDE", "content": content}); !isErr || !strings.HasPrefix(text, notIn) {
		t.Fatal(text)
	}
	if text, isErr := m.tool(3, "manage_workflows", map[string]any{"action": "read", "id": "CLAUDE"}); !isErr || !strings.HasPrefix(text, notIn) {
		t.Fatal(text)
	}
	if text, isErr := m.tool(4, "manage_workflows", map[string]any{"action": "remove", "id": "CLAUDE"}); !isErr || !strings.HasPrefix(text, notIn) {
		t.Fatal(text)
	}
	if text, _ := m.tool(5, "manage_workflows", map[string]any{"action": "list"}); !strings.HasPrefix(text, "This folder has no workflows yet.") {
		t.Fatal(text)
	}
	if b, err := os.ReadFile(filepath.Join(outside, "CLAUDE.md")); err != nil || string(b) != "keep\n" {
		t.Fatalf("%s %v", b, err)
	}

	// The folder of its own again, with a workflow file that is a link out.
	os.Remove(workflowsFolder(dir))
	os.MkdirAll(workflowsFolder(dir), 0o755)
	os.Symlink(filepath.Join(outside, "CLAUDE.md"), filepath.Join(workflowsFolder(dir), "secret.md"))
	if text, isErr := m.tool(6, "manage_workflows", map[string]any{"action": "read", "id": "secret"}); !isErr || strings.Contains(text, "keep") {
		t.Fatal(text)
	}
}

func TestALinkedAgentsFolderIsRefused(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	outside := t.TempDir()
	os.RemoveAll(filepath.Join(dir, ".agents"))
	if err := os.Symlink(outside, filepath.Join(dir, ".agents")); err != nil {
		t.Fatal(err)
	}
	folder := store.FolderURL(dir)
	if e := c.callError(t, 2, "folders/setDiskSpace", map[string]any{"folder": folder, "diskSpace": map[string]any{"lowGB": 50, "criticalGB": 2}}); !strings.Contains(e.Message, "is a link or a file") {
		t.Fatal(e.Message)
	}
	if err := d.writePins(pinsFile{pins: []pinEntry{{path: "x.md"}}}, dir); err == nil || !strings.Contains(err.Error(), "is a link or a file") {
		t.Fatal(err)
	}
	if entries, _ := os.ReadDir(outside); len(entries) != 0 {
		t.Fatalf("wrote %d file(s) through the link", len(entries))
	}
	if ownFolders(dir, ".agents/workflows") || !ownFolders(t.TempDir(), ".agents/workflows") {
		t.Fatal("ownFolders")
	}
}
