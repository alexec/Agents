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

// US1 (#2317, FR-008, FR-009): adding a folder that names no project writes a new id
// into .agents/folder.json; one that names a project keeps it; a bad id is left as it
// is and said.
func TestAddingAFolderGivesItAProject(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()

	dir := t.TempDir()
	var s wire.FolderSummary
	json.Unmarshal(c.call(t, 1, "folders/add", map[string]any{"folder": store.FolderURL(dir)}), &s)
	if s.Project == nil || !strings.HasPrefix(*s.Project, "p-") || len(*s.Project) != 14 || s.ProjectProblem != nil {
		t.Fatalf("%+v %+v", s.Project, s.ProjectProblem)
	}
	b, _ := os.ReadFile(filepath.Join(dir, ".agents", "folder.json"))
	if string(b) != "{\n  \"project\" : \""+*s.Project+"\"\n}\n" {
		t.Fatalf("%s", b)
	}

	// A clone that names its project joins it, with nothing written.
	clone := t.TempDir()
	os.MkdirAll(filepath.Join(clone, ".agents"), 0o755)
	named := "{\"project\": \"p-agents\"}\n"
	os.WriteFile(filepath.Join(clone, ".agents", "folder.json"), []byte(named), 0o644)
	s = wire.FolderSummary{}
	json.Unmarshal(c.call(t, 2, "folders/add", map[string]any{"folder": store.FolderURL(clone)}), &s)
	if s.Project == nil || *s.Project != "p-agents" {
		t.Fatalf("%+v", s.Project)
	}
	if b, _ := os.ReadFile(filepath.Join(clone, ".agents", "folder.json")); string(b) != named {
		t.Fatalf("%s", b)
	}

	// Not an id: left alone, and said.
	bad := t.TempDir()
	os.MkdirAll(filepath.Join(bad, ".agents"), 0o755)
	os.WriteFile(filepath.Join(bad, ".agents", "folder.json"), []byte(`{"project": "not an id"}`), 0o644)
	s = wire.FolderSummary{}
	json.Unmarshal(c.call(t, 3, "folders/add", map[string]any{"folder": store.FolderURL(bad)}), &s)
	if s.Project != nil || s.ProjectProblem == nil || !strings.Contains(*s.ProjectProblem, "not valid") {
		t.Fatalf("%+v %+v", s.Project, s.ProjectProblem)
	}

	// Not an object: left alone.
	array := t.TempDir()
	os.MkdirAll(filepath.Join(array, ".agents"), 0o755)
	os.WriteFile(filepath.Join(array, ".agents", "folder.json"), []byte(`[1]`), 0o644)
	s = wire.FolderSummary{}
	json.Unmarshal(c.call(t, 4, "folders/add", map[string]any{"folder": store.FolderURL(array)}), &s)
	if b, _ := os.ReadFile(filepath.Join(array, ".agents", "folder.json")); string(b) != "[1]" || s.ProjectProblem == nil {
		t.Fatalf("%s %+v", b, s.ProjectProblem)
	}
	// The ones that name a valid project are the ones said to the control plane.
	joined := d.joined()
	if len(joined.Folders) != 2 {
		t.Fatalf("%+v", joined)
	}
}

// US2 (#2317, FR-010): folders/setProject writes the id the person picked.
func TestAFolderJoinsAnotherProject(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	folder := store.FolderURL(dir)
	if e := c.callError(t, 2, "folders/setProject", map[string]any{"folder": folder, "project": "two words"}); !strings.Contains(e.Message, "not a project id") {
		t.Fatal(e.Message)
	}
	var s wire.FolderSummary
	json.Unmarshal(c.call(t, 3, "folders/setProject", map[string]any{"folder": folder, "project": "p-shared"}), &s)
	if s.Project == nil || *s.Project != "p-shared" {
		t.Fatalf("%+v", s.Project)
	}
	if b, _ := os.ReadFile(filepath.Join(dir, ".agents", "folder.json")); !strings.Contains(string(b), `"project" : "p-shared"`) {
		t.Fatalf("%s", b)
	}
}

// US1 AS3 (#2317): a folder added before projects gets one when the machine starts.
func TestAnOlderFolderGetsAProjectAtStart(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	path := filepath.Join(dir, ".agents", "folder.json")
	os.Remove(path)
	d.approveWrite(dir, folderConfig)
	if !d.ensureProject(dir) {
		t.Fatal("no id written")
	}
	if b, _ := os.ReadFile(path); !strings.Contains(string(b), `"project" : "p-`) {
		t.Fatalf("%s", b)
	}
	// Once is enough.
	if d.ensureProject(dir) {
		t.Fatal("written again")
	}
}
