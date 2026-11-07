package agentsd

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// #3726: an agent's worktree goes when it is deleted, or archived with its branch merged,
// and never when it has uncommitted or untracked changes, another agent names it, or its
// branch is not merged (for an archive); an unmerged branch is never deleted. Only scratch
// repositories in a temp folder.

func sweepGit(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v %s", args, err, out)
	}
	return strings.TrimSpace(string(out))
}

// laneWorktree makes the app's worktree name on agents/name in dir, as a start in a new
// worktree does, and a seeded agent working there.
func laneWorktree(t *testing.T, d *Daemon, dir, name string) (wire.Agent, string) {
	t.Helper()
	root := filepath.Join(dir, ".agents", "worktrees", name)
	sweepGit(t, dir, "worktree", "add", "-q", "-b", branchPrefix+name, root, "HEAD")
	root = canonical(root)
	a := seeded(t, d, root, inWorktree(dir, root, branchPrefix+name))
	base := "main"
	a.Worktree.Base = &base
	d.Store.Save(a)
	return a, root
}

func hasBranch(t *testing.T, dir, branch string) bool {
	t.Helper()
	return sweepGit(t, dir, "branch", "--list", branch) != ""
}

func archiveAndSweep(t *testing.T, d *Daemon, id wire.UUID) {
	t.Helper()
	if err := d.archive(id); err != nil {
		t.Fatal(err)
	}
	d.sweeps.Wait()
}

func deleteAndSweep(t *testing.T, d *Daemon, id wire.UUID) {
	t.Helper()
	if err := d.delete(id); err != nil {
		t.Fatal(err)
	}
	d.sweeps.Wait()
}

func commitIn(t *testing.T, root, file string) {
	t.Helper()
	os.WriteFile(filepath.Join(root, file), []byte(file), 0o644)
	sweepGit(t, root, "add", file)
	sweepGit(t, root, "commit", "-q", "-m", file)
}

func TestAnArchivedAgentsMergedCleanWorktreeIsRemoved(t *testing.T) {
	d, _ := start(t, t.TempDir())
	dir := repo(t)
	a, root := laneWorktree(t, d, dir, "merged")
	commitIn(t, root, "done.txt")
	sweepGit(t, dir, "merge", "-q", "--ff-only", "agents/merged")
	archiveAndSweep(t, d, a.ID)
	if isDir(root) || hasBranch(t, dir, "agents/merged") {
		t.Fatal("the merged worktree or its branch is still there")
	}
	if n := runtimeNotes(d, a.ID); len(n) == 0 || n[len(n)-1] != "Removed the worktree merged and its branch agents/merged, as the branch is merged." {
		t.Fatal(n)
	}
}

func TestAnArchivedAgentsUnmergedWorktreeIsKept(t *testing.T) {
	d, _ := start(t, t.TempDir())
	dir := repo(t)
	a, root := laneWorktree(t, d, dir, "unmerged")
	commitIn(t, root, "work.txt")
	archiveAndSweep(t, d, a.ID)
	if !isDir(root) || !hasBranch(t, dir, "agents/unmerged") {
		t.Fatal("an unmerged worktree went on archive")
	}
}

func TestAWorktreeWithChangesIsNeverRemoved(t *testing.T) {
	d, _ := start(t, t.TempDir())
	dir := repo(t)
	untracked, uRoot := laneWorktree(t, d, dir, "untracked")
	os.WriteFile(filepath.Join(uRoot, "notes.txt"), []byte("x"), 0o644)
	commitIn(t, dir, "tracked.txt")
	edited, eRoot := laneWorktree(t, d, dir, "edited")
	os.WriteFile(filepath.Join(eRoot, "tracked.txt"), []byte("changed"), 0o644)
	staged, sRoot := laneWorktree(t, d, dir, "staged")
	os.WriteFile(filepath.Join(sRoot, "new.txt"), []byte("x"), 0o644)
	sweepGit(t, sRoot, "add", "new.txt")
	for _, a := range []wire.Agent{untracked, edited, staged} {
		archiveAndSweep(t, d, a.ID) // merged: no commits of their own
		deleteAndSweep(t, d, a.ID)
	}
	for _, root := range []string{uRoot, eRoot, sRoot} {
		if !isDir(root) {
			t.Fatalf("%s went with changes in it", root)
		}
	}
	if b, _ := os.ReadFile(filepath.Join(uRoot, "notes.txt")); string(b) != "x" {
		t.Fatal("the untracked file went")
	}
}

func TestAWorktreeAnotherAgentUsesIsKept(t *testing.T) {
	d, _ := start(t, t.TempDir())
	dir := repo(t)
	a, root := laneWorktree(t, d, dir, "shared")
	other := seeded(t, d, root, nil) // works there, with no worktree of its own
	named, nRoot := laneWorktree(t, d, dir, "named")
	archived := seeded(t, d, dir, inWorktree(dir, nRoot, "agents/named"))
	if err := d.archive(archived.ID); err != nil {
		t.Fatal(err)
	}
	for _, id := range []wire.UUID{a.ID, named.ID} {
		archiveAndSweep(t, d, id)
		deleteAndSweep(t, d, id)
	}
	if !isDir(root) || !isDir(nRoot) {
		t.Fatal("a worktree another agent names went")
	}
	if got := d.othersIn(root, named.ID); len(got) != 1 || got[0] != other.ID {
		t.Fatal(got)
	}
}

func TestADeletedAgentsWorktreeGoesButItsUnmergedBranchStays(t *testing.T) {
	d, _ := start(t, t.TempDir())
	dir := repo(t)
	a, root := laneWorktree(t, d, dir, "deleted")
	commitIn(t, root, "work.txt")
	tip := sweepGit(t, dir, "rev-parse", "agents/deleted")
	archiveAndSweep(t, d, a.ID)
	if !isDir(root) {
		t.Fatal("went on archive, unmerged")
	}
	deleteAndSweep(t, d, a.ID)
	if isDir(root) {
		t.Fatal("the deleted agent's worktree is still there")
	}
	if !hasBranch(t, dir, "agents/deleted") || sweepGit(t, dir, "rev-parse", "agents/deleted") != tip {
		t.Fatal("the unmerged branch went with the worktree")
	}
}

func TestAWorktreeNotMadeByTheAppIsKept(t *testing.T) {
	d, _ := start(t, t.TempDir())
	dir := repo(t)
	root := canonical(filepath.Join(t.TempDir(), "mine"))
	sweepGit(t, dir, "worktree", "add", "-q", "-b", "mine", root, "HEAD")
	a := seeded(t, d, root, inWorktree(dir, root, "mine"))
	archiveAndSweep(t, d, a.ID)
	deleteAndSweep(t, d, a.ID)
	if !isDir(root) || !hasBranch(t, dir, "mine") {
		t.Fatal("a worktree outside the app's folder went")
	}
}

func TestAPullRequestMergedArchiveKeepsUnpushedWork(t *testing.T) {
	d, _ := start(t, t.TempDir())
	dir := repo(t)
	a, root := laneWorktree(t, d, dir, "squashed")
	commitIn(t, root, "work.txt")
	by := wire.AgentArchivedReasonByAgent
	a.State, a.ArchivedReason = wire.AgentStateArchived, &by
	if err := d.Store.Save(a); err != nil {
		t.Fatal(err)
	}
	// A squash leaves the branch out of main, and no remote has its commit.
	if _, kept := d.sweepWorktree(a, sweepArchivedMerged); kept == "" || !isDir(root) {
		t.Fatal("unpushed work went on a merged pull request's archive")
	}
	remote := canonical(t.TempDir())
	sweepGit(t, remote, "init", "-q", "--bare")
	sweepGit(t, dir, "remote", "add", "origin", remote)
	sweepGit(t, dir, "push", "-q", "origin", "agents/squashed")
	said, kept := d.sweepWorktree(a, sweepArchivedMerged)
	if kept != "" || isDir(root) || !hasBranch(t, dir, "agents/squashed") || !strings.Contains(said, "its branch agents/squashed is kept") {
		t.Fatal(said, kept)
	}
}

func TestAnAgentUnarchivedBeforeTheSweepKeepsItsWorktree(t *testing.T) {
	d, _ := start(t, t.TempDir())
	dir := repo(t)
	a, root := laneWorktree(t, d, dir, "back")
	if _, kept := d.sweepWorktree(a, sweepArchived); kept != "no longer archived" || !isDir(root) {
		t.Fatal(kept)
	}
}
