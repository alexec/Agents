package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/agentloops-dev/agent-loops/Go/internal/agentsd/store"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

func TestNotCommittedIsWhatGitIgnoresInAgents(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	folder := store.FolderURL(dir)
	var r wire.NotCommittedResponse
	json.Unmarshal(c.call(t, 2, "folders/notCommitted", map[string]any{"folder": folder}), &r)
	if r.IsRepository || len(r.Paths) != 0 {
		t.Fatalf("not a repository: %+v", r)
	}
	run(t, dir, "git", "init", "-q")
	os.WriteFile(filepath.Join(dir, ".gitignore"), []byte(".agents/worktrees/\n*.local.json\nbuild/\n"), 0o644)
	os.MkdirAll(filepath.Join(dir, ".agents", "worktrees", "a", "src"), 0o755)
	os.WriteFile(filepath.Join(dir, ".agents", "worktrees", "a", "src", "x.go"), []byte("x"), 0o644)
	os.WriteFile(filepath.Join(dir, ".agents", "settings.local.json"), []byte("{}"), 0o644)
	os.WriteFile(filepath.Join(dir, ".agents", "kept.md"), []byte("kept"), 0o644)
	os.MkdirAll(filepath.Join(dir, "build"), 0o755)
	os.WriteFile(filepath.Join(dir, "build", "out"), []byte("out"), 0o644) // ignored, but not in .agents
	r = wire.NotCommittedResponse{}
	json.Unmarshal(c.call(t, 3, "folders/notCommitted", map[string]any{"folder": folder}), &r)
	if want := []string{".agents/settings.local.json", ".agents/worktrees/"}; !r.IsRepository || !reflect.DeepEqual(r.Paths, want) || r.More != 0 {
		t.Fatalf("%+v", r)
	}
	if e := c.callError(t, 4, "folders/notCommitted", map[string]any{"folder": store.FolderURL(filepath.Join(dir, "gone"))}); e.Code != wire.FailureFolderGone {
		t.Fatalf("%+v", e)
	}
}
