package agentsd

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// A v0.11 machine kept its folder list in <root>/projects.json. The project's tools go in a
// file of their own, so that list is never written over and can still be moved to
// folders.json by hand (#2707).
func TestHeardProjectsLeavesAV011FolderListAlone(t *testing.T) {
	t.Setenv("AGENTS_PERSONAL_HOME", t.TempDir())
	root := t.TempDir()
	old := filepath.Join(root, "projects.json")
	v011 := []byte(`[{"path":"/Users/alex/src/agents","archived":true,"helperLimits":{"running":3,"kept":5}}]`)
	if err := os.WriteFile(old, v011, 0o600); err != nil {
		t.Fatal(err)
	}
	d, _ := start(t, root)
	defer d.Shutdown()

	forge, repo := wire.ConnectionProviderGithub, "alexec/agents"
	d.heardProjects(wire.MachineProjects{Projects: []wire.ProjectTools{{ID: "P1", Name: "Agents", Slots: []wire.ProjectSlot{
		{Slot: wire.ConnectorSlotKindCodeReview, Forge: &forge, Repository: &repo},
	}}}})

	if b, err := os.ReadFile(old); err != nil || string(b) != string(v011) {
		t.Fatalf("projects.json changed: %q %v", b, err)
	}
	if _, err := os.Stat(filepath.Join(root, "project-tools.json")); err != nil {
		t.Fatalf("the project's tools were not kept: %v", err)
	}
}
