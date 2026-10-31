package agentsd

import (
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// Ports MoveTests (#1821): move_worktree into a new worktree when the turn ends and carry
// on there, into an existing one at once, back with remove once the work is pushed, and a
// remove refused while work is not pushed or not committed.

func run(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command(args[0], args[1:]...)
	cmd.Dir = dir
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("%v: %v %s", args, err, out)
	}
}

func TestAnAgentMovesIntoANewWorktreeWhenItsTurnEnds(t *testing.T) {
	fakeRuntimes(t)
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	dir := repo(t)
	a := seeded(t, d, dir, func(a *wire.Agent) { a.State, a.EndedReason = wire.AgentStateRunning, nil })
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	text, isError := m.tool(2, "move_worktree", map[string]any{"worktree": "fix the login"})
	if isError || text != "Moving to a new worktree like fix-the-login when this turn ends. Nothing uncommitted comes with you. End your turn to move; you will be started again there to carry on." {
		t.Fatal(text)
	}
	if got := d.Store.Agent(a.ID); got.PendingMove == nil || got.Worktree != nil {
		t.Fatalf("%+v", got.PendingMove)
	}
	d.end(d.live(a.ID), wire.AgentStateFinished, wire.EndedReasonEndTurn)
	root := filepath.Join(dir, ".agents", "worktrees", "fix-the-login")
	got := d.Store.Agent(a.ID)
	if got.PendingMove != nil || got.Worktree == nil || store.FolderPath(got.Cwd) != root || *got.Worktree.Branch != "agents/fix-the-login" || !got.Worktree.MadeByApp {
		t.Fatalf("%+v %+v", got.Cwd, got.Worktree)
	}
	if !slices.Contains(notes(d, a.ID), "Moved from the folder to worktree fix-the-login on agents/fix-the-login, from main.") {
		t.Fatal(notes(d, a.ID))
	}
	// Started again there, with the app's words, and its runtime in the new folder.
	waitFor(t, "the carry-on turn", func() bool { return slices.ContainsFunc(userMessages(d, a.ID), func(m string) bool {
		return strings.HasPrefix(m, "You have moved: ") && strings.HasSuffix(m, " "+carryOn)
	}) })
	waitFor(t, "finished again", func() bool { return d.Store.Agent(a.ID).State == wire.AgentStateFinished })
	// The turn that moved is not a finish (#1955): only the carry-on turn's is heard.
	waitFor(t, "the finish on the log", func() bool { return slices.Contains(names(d), "agent.finished") })
	finishes := 0
	for _, e := range logged(d) {
		if e.Name == "agent.finished" {
			finishes++
		}
	}
	if finishes != 1 {
		t.Fatalf("%d agent.finished, want 1: %v", finishes, names(d))
	}
}

func TestAnAgentMovesIntoAnExistingWorktreeAtOnce(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	dir := repo(t)
	other := filepath.Join(canonical(t.TempDir()), "other")
	run(t, dir, "git", "worktree", "add", "-q", "-b", "feature", other)
	a := seeded(t, d, dir, nil)
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	text, isError := m.tool(2, "move_worktree", map[string]any{"worktree": other})
	if isError || text != "Moved. Now working in the worktree other on feature, at "+other+"." {
		t.Fatal(text)
	}
	got := d.Store.Agent(a.ID)
	if got.Worktree == nil || got.Worktree.MadeByApp || store.FolderPath(got.Worktree.Folder) != dir {
		t.Fatalf("%+v", got.Worktree)
	}
	// Not one of the folder's: refused, and nothing moves.
	if text, isError := m.tool(3, "move_worktree", map[string]any{"worktree": t.TempDir()}); !isError || !strings.Contains(text, "is not a worktree of") {
		t.Fatal(text)
	}
}

// inAppWorktree is an agent in a worktree the app made, with a remote to push to.
func inAppWorktree(t *testing.T, d *Daemon) (wire.Agent, string, string) {
	t.Helper()
	dir := repo(t)
	remote := canonical(t.TempDir())
	run(t, remote, "git", "init", "-q", "--bare")
	run(t, dir, "git", "remote", "add", "origin", remote)
	run(t, dir, "git", "push", "-q", "origin", "main")
	wt, cwd, err := d.prepareWorktree(dir, wire.WorktreeChoice{Named: &wire.WorktreeChoiceNamed{Value: "lane"}}, "")
	if err != nil {
		t.Fatal(err)
	}
	title := "The lane"
	a := seeded(t, d, cwd, func(a *wire.Agent) { a.Worktree, a.Title = wt, &title })
	os.WriteFile(filepath.Join(cwd, "work.txt"), []byte("work\n"), 0o644)
	run(t, cwd, "git", "add", "work.txt")
	run(t, cwd, "git", "-c", "user.email=t@example.com", "-c", "user.name=T", "commit", "-q", "-m", "work")
	return a, dir, cwd
}

func TestLeavingWithRemoveOnceTheWorkIsPushed(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	a, dir, cwd := inAppWorktree(t, d)
	run(t, cwd, "git", "push", "-q", "-u", "origin", "agents/lane")
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	text, isError := m.tool(2, "move_worktree", map[string]any{"leave_worktree": "remove"})
	if isError || text != "Moved. Now working in the folder, "+dir+"." {
		t.Fatal(text)
	}
	got := d.Store.Agent(a.ID)
	if got.Worktree != nil || store.FolderPath(got.Cwd) != dir || isDir(cwd) {
		t.Fatalf("%+v %s", got.Worktree, got.Cwd)
	}
	if n := notes(d, a.ID); !slices.Contains(n, "Moved from worktree lane to the folder. Removed the worktree lane; its branch agents/lane is kept.") {
		t.Fatal(n)
	}
}

func TestLeavingWithRemoveIsRefusedWhileWorkIsNotPushed(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	a, _, cwd := inAppWorktree(t, d)
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	text, isError := m.tool(2, "move_worktree", map[string]any{"leave_worktree": "remove"})
	if !isError || text != "lane has 1 commit on agents/lane that no remote has. Push them (git push -u origin agents/lane), or use keep." {
		t.Fatal(text)
	}
	// Pushed, but with a change not committed.
	run(t, cwd, "git", "push", "-q", "-u", "origin", "agents/lane")
	os.WriteFile(filepath.Join(cwd, "notes.txt"), []byte("x"), 0o644)
	text, isError = m.tool(3, "move_worktree", map[string]any{"leave_worktree": "remove"})
	if !isError || !strings.HasPrefix(text, "Removing lane would lose 1 uncommitted change: untracked notes.txt.") {
		t.Fatal(text)
	}
	if got := d.Store.Agent(a.ID); got.Worktree == nil || got.PendingMove != nil || !isDir(cwd) {
		t.Fatalf("%+v", got)
	}
	// discard_changes goes only with remove.
	if text, isError := m.tool(4, "move_worktree", map[string]any{"leave_worktree": "keep", "discard_changes": true}); !isError || !strings.Contains(text, "only goes with leave_worktree remove") {
		t.Fatal(text)
	}
}

func TestARuntimeThatCannotMoveIsNotOfferedTheTool(t *testing.T) {
	for _, raw := range offeredTools(runtimeCanMove("grok"), false) {
		if strings.Contains(string(raw), `"move_worktree"`) {
			t.Fatal("offered to grok")
		}
	}
	found := false
	for _, raw := range offeredTools(runtimeCanMove("claude"), false) {
		found = found || strings.Contains(string(raw), `"move_worktree"`)
	}
	if !found {
		t.Fatal("not offered to claude")
	}
}
