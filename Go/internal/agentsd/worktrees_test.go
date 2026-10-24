package agentsd

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// Ports WorktreeTests and WorktreeNameTests: a start in a new worktree, listing, the
// checks before removing, removing, and build output cleared.

func repo(t *testing.T) string {
	t.Helper()
	dir := canonical(t.TempDir())
	for _, args := range [][]string{{"init", "-q", "-b", "main"}, {"config", "user.email", "t@example.com"}, {"config", "user.name", "T"},
		{"commit", "-q", "--allow-empty", "-m", "first"}} {
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v %s", args, err, out)
		}
	}
	return dir
}

func TestWorktreeNames(t *testing.T) {
	at := time.Date(2026, 10, 16, 9, 5, 0, 0, time.UTC)
	for prompt, want := range map[string]string{
		"Please fix the login bug on the dashboard": "fix-login-bug-dashboard",
		"Café crème":                        "cafe-creme",
		"?!":                                "agent-1016-0905",
		strings.Repeat("x", 40):             strings.Repeat("x", 32),
		"one two three four five six seven": "one-two-three-four",
	} {
		if got := worktreeName(prompt, false, at); got != want {
			t.Errorf("%q: %q, want %q", prompt, got, want)
		}
	}
	if got := worktreeName("fix the bug", true, at); got != "fix-the-bug" {
		t.Error(got)
	}
	if folderForBranch("agents/feat/x y") != "feat-x-y" || folderForBranch("..") != "branch" {
		t.Error(folderForBranch("agents/feat/x y"))
	}
	if nextName("a", map[string]bool{"a": true, "a-2": true}) != "a-3" {
		t.Error("next")
	}
}

func TestAStartInANewWorktreeAndItsRemoval(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := repo(t)
	c.call(t, 1, "folders/add", map[string]any{"folder": store.FolderURL(dir)})
	var id wire.UUID
	json.Unmarshal(c.call(t, 2, "agents/start", map[string]any{"runtimeID": "claude", "cwd": store.FolderURL(dir),
		"prompt": "Please fix the login bug", "worktree": map[string]any{"new": map[string]any{}}}), &id)
	a := d.Store.Agent(id)
	root := filepath.Join(dir, ".agents", "worktrees", "fix-login-bug")
	if a.Worktree == nil || store.FolderPath(a.Cwd) != root || *a.Worktree.Branch != "agents/fix-login-bug" ||
		*a.Worktree.Base != "main" || !a.Worktree.MadeByApp || store.FolderPath(a.Worktree.Folder) != dir {
		t.Fatalf("%+v %+v", a.Cwd, a.Worktree)
	}
	if b, _ := os.ReadFile(filepath.Join(dir, ".git", "info", "exclude")); !strings.Contains(string(b), "/.agents/worktrees/") {
		t.Fatalf("%s", b)
	}
	waitFor(t, "finished", func() bool { return d.Store.Agent(id).State == wire.AgentStateFinished })
	if k := kinds(d, id); k[0] != "runtimeNote" {
		t.Fatal(k)
	}
	waitFor(t, "a starting point", func() bool { return d.Store.Agent(id).StartingPoint != nil })
	var list wire.WorktreesListResponse
	json.Unmarshal(c.call(t, 3, "worktrees/list", map[string]any{"folder": store.FolderURL(dir)}), &list)
	if !list.IsRepository || !list.CanMakeNew || len(list.Worktrees) != 2 {
		t.Fatalf("%+v", list)
	}
	wt := list.Worktrees[1]
	if !wt.MadeByApp || wt.IsFolder || len(wt.Agents) != 1 || wt.Agents[0] != id || wt.Status == nil || *wt.Status.Unmerged != 0 {
		t.Fatalf("%+v", wt)
	}
	req := map[string]any{"folder": store.FolderURL(dir), "root": store.FolderURL(root)}
	var check wire.RemovalCheck
	json.Unmarshal(c.call(t, 4, "worktrees/check", req), &check)
	if len(check.BlockedBy) != 1 || check.Unmerged {
		t.Fatalf("%+v", check)
	}
	if e := c.callError(t, 5, "worktrees/remove", req); e.Code != wire.FailureWorktreeInUse || !strings.HasPrefix(e.Message, "Still in use by ") {
		t.Fatalf("%+v", e)
	}
	c.call(t, 6, "agents/archive", map[string]any{"agentID": id})
	os.WriteFile(filepath.Join(root, "new.txt"), []byte("x"), 0o644)
	if e := c.callError(t, 7, "worktrees/remove", req); !strings.Contains(e.Message, "would lose 1 uncommitted change. Confirm") {
		t.Fatal(e.Message)
	}
	req["confirmed"] = true
	var removed wire.WorktreeRemoved
	json.Unmarshal(c.call(t, 8, "worktrees/remove", req), &removed)
	if !removed.RemovedBranch || isDir(root) {
		t.Fatalf("%+v", removed)
	}
	if out, _ := git(dir, "branch", "--list", "agents/fix-login-bug"); out != "" {
		t.Fatal(out)
	}
}

func TestAWorktreeOutsideARepositoryIsRefused(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := t.TempDir()
	if e := c.callError(t, 1, "agents/start", map[string]any{"runtimeID": "claude", "cwd": store.FolderURL(dir), "prompt": "x",
		"worktree": map[string]any{"new": map[string]any{}}}); e.Code != wire.FailureWorktreeFailed || !strings.HasSuffix(e.Message, "is not in a git repository, so it has no worktrees.") {
		t.Fatalf("%+v", e)
	}
}

func TestBuildOutputIsCleared(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := repo(t)
	os.WriteFile(filepath.Join(dir, ".gitignore"), []byte("node_modules/\n"), 0o644)
	git(dir, "add", ".gitignore")
	git(dir, "commit", "-q", "-m", "ignore")
	wt, _, err := d.prepareWorktree(dir, wire.WorktreeChoice{Named: &wire.WorktreeChoiceNamed{Value: "Clean me"}}, "")
	if err != nil {
		t.Fatal(err)
	}
	root := store.FolderPath(wt.Root)
	if filepath.Base(root) != "clean-me" {
		t.Fatal(root)
	}
	os.MkdirAll(filepath.Join(root, "node_modules", "x"), 0o755)
	os.WriteFile(filepath.Join(root, "node_modules", "x", "big"), make([]byte, 10000), 0o644)
	os.MkdirAll(filepath.Join(root, "build"), 0o755) // not ignored: kept
	var out wire.BuildOutputRemoved
	json.Unmarshal(c.call(t, 1, "worktrees/removeBuildOutput", map[string]any{"folder": store.FolderURL(dir), "root": wt.Root}), &out)
	if len(out.Removed) != 1 || !strings.HasSuffix(out.Removed[0], "node_modules") || out.Freed.Bytes == 0 || !isDir(filepath.Join(root, "build")) {
		t.Fatalf("%+v", out)
	}
}
