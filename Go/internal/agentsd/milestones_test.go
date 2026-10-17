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

// Ports MilestoneTests: the first agent to run a turn and the first workflow are earned
// once, said to the clients and kept.

func TestMilestonesEarned(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	var id wire.UUID
	json.Unmarshal(c.call(t, 1, "agents/start", map[string]any{"runtimeID": "claude", "cwd": "file://" + t.TempDir(), "prompt": "hello"}), &id)
	c.until(t, "the first agent earned", func(m string, p json.RawMessage) bool {
		return m == "milestones/changed" && strings.Contains(string(p), `"firstAgent"`)
	})
	dir := project(t, c, 2)
	os.MkdirAll(workflowsFolder(dir), 0o755)
	os.WriteFile(filepath.Join(workflowsFolder(dir), "tidy.md"), []byte("---\non: agent.finished\n---\nTidy.\n"), 0o644)
	c.call(t, 3, "workflows/list", map[string]any{"folder": store.FolderURL(dir)})
	waitFor(t, "the first workflow", func() bool {
		var m wire.Milestones
		json.Unmarshal(c.call(t, 4, "milestones/state", map[string]any{}), &m)
		return hasMilestone(&m, firstWorkflow) && hasMilestone(&m, firstAgent)
	})
	b, _ := os.ReadFile(d.achievementsPath())
	if strings.Count(string(b), `"firstAgent"`) != 1 {
		t.Fatalf("%s", b)
	}
}
