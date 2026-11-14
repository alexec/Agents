package agentsd

import (
	"log"
	"path/filepath"
	"strings"

	"github.com/agentloops-dev/agents/Go/internal/agentsd/store"
	"github.com/agentloops-dev/agents/Go/internal/safe"
	"github.com/agentloops-dev/agents/Go/wire"
)

// The bound on agents' worktrees (#3726, #3877): an agent's worktree goes when the agent
// is archived or deleted, merged or not, with its uncommitted and untracked changes too
// (Alex, 2026-11-07). Only a worktree this app made, on a branch that is still there, that
// no agent not archived works in or names. Its branch goes only when it is merged into the
// base; otherwise it stays and holds the commits. A locked worktree is kept: one --force
// does not remove it.

type worktreeSweep int

const (
	// sweepArchived is an archive: the agent must still be archived when the sweep runs.
	sweepArchived worktreeSweep = iota
	// sweepDeleted is a delete.
	sweepDeleted
)

// sweepWorktreeSoon removes a's worktree off the caller, one sweep at a time.
func (d *Daemon) sweepWorktreeSoon(a wire.Agent, why worktreeSweep) {
	if a.Worktree == nil || !a.Worktree.MadeByApp || a.Worktree.Branch == nil {
		return
	}
	d.sweeps.Add(1)
	safe.Go("worktree sweep", func() {
		defer d.sweeps.Done()
		d.sweepMu.Lock()
		defer d.sweepMu.Unlock()
		said, err := d.sweepWorktree(a, why)
		if err != "" {
			log.Printf("worktree sweep: %s kept: %s", a.ID, err)
			return
		}
		log.Printf("worktree sweep: %s: %s", a.ID, said)
		if why != sweepDeleted {
			d.record(a.ID, runtimeNote(said))
		}
	})
}

// sweepWorktree removes a's worktree, and its branch when merged, saying what it did; or
// says why it kept it.
func (d *Daemon) sweepWorktree(a wire.Agent, why worktreeSweep) (said, kept string) {
	wt := *a.Worktree
	if why != sweepDeleted {
		if now := d.Store.Agent(a.ID); now == nil || now.State != wire.AgentStateArchived {
			return "", "no longer archived"
		}
	}
	f, err := d.removalFacts(wire.WorktreeRemovalRequest{Folder: wt.Folder, Root: wt.Root})
	if err != nil {
		return "", err.Error()
	}
	name := filepath.Base(f.root)
	branch := f.entry.branch
	if !f.madeByApp || branch == "" {
		return "", name + " was not made by this app on a branch"
	}
	if others := d.othersIn(f.root, a.ID); len(others) > 0 {
		return "", name + " is used by another agent that is not archived"
	}
	folder := store.FolderPath(wt.Folder)
	if _, err := git(folder, "show-ref", "--verify", "-q", "refs/heads/"+branch); err != nil {
		return "", name + "'s branch " + branch + " is not there, so its commits would be on no branch"
	}
	lost := ""
	if isDir(f.root) && !f.entry.prunable {
		if out, _ := git(f.root, "status", "--porcelain"); out != "" {
			lines := strings.Split(out, "\n")
			lost = " It had " + uncommittedWords(lines, int64(len(lines))) + "."
		}
		if _, err := git(folder, "worktree", "remove", "--force", f.root); err != nil {
			return "", "git worktree remove: " + err.Error()
		}
	} else if _, err := git(folder, "worktree", "prune"); err != nil {
		return "", "git worktree prune: " + err.Error()
	}
	d.sizeMu.Lock()
	delete(d.sizes, f.root)
	d.sizeMu.Unlock()
	d.noteFolders()
	d.folderChanged(folder)
	if mergedInto(folder, branch, wt.Base, f.base) && strings.HasPrefix(branch, branchPrefix) {
		if _, err := git(folder, "branch", "-d", branch); err == nil {
			return "Removed the worktree " + name + " and its branch " + branch + ", as the branch is merged." + lost, ""
		}
	}
	return "Removed the worktree " + name + "; its branch " + branch + " is kept." + lost, ""
}

// othersIn is the agents not archived, other than id, that work in root or name it as
// their worktree. An archived agent's record does not keep a worktree (#3877).
func (d *Daemon) othersIn(root string, id wire.UUID) []wire.UUID {
	var out []wire.UUID
	for _, a := range d.Store.Agents() {
		if a.ID == id || a.State == wire.AgentStateArchived {
			continue
		}
		if inside(root, canonical(store.FolderPath(a.Cwd))) ||
			a.Worktree != nil && canonical(store.FolderPath(a.Worktree.Root)) == root {
			out = append(out, a.ID)
		}
	}
	return out
}

// mergedInto is whether branch is in the agent's base (or, without one, the folder's), or
// in that base's upstream.
func mergedInto(folder, branch string, agentBase *string, folderBase string) bool {
	base := folderBase
	if agentBase != nil && *agentBase != "" {
		base = *agentBase
	}
	if base == "" || base == branch {
		return false
	}
	if _, err := git(folder, "merge-base", "--is-ancestor", "refs/heads/"+branch, base); err == nil {
		return true
	}
	if up, err := git(folder, "rev-parse", "--abbrev-ref", "--symbolic-full-name", base+"@{upstream}"); err == nil && up != "" {
		_, err := git(folder, "merge-base", "--is-ancestor", "refs/heads/"+branch, up)
		return err == nil
	}
	return false
}
