package agentsd

import (
	"context"
	"os"
	"strings"
	"sync"

	"github.com/alexec/agents/Go/wire"
)

// Bring back from ‹host›… (#1473), the reverse of Send to ‹host›… (#1123): the host packs
// its branches with folders/sendPack, less the commits this Mac has, the window carries the
// parts here with folders/receiveUpload, and folders/bringBack moves this Mac's branches
// forward to the host's. It never overwrites work done here: a branch with commits of its
// own, or uncommitted changes where a branch that moves is checked out, stops it before
// anything is changed. The host's uncommitted changes come back as a patch only when asked.

func (d *Daemon) bringBack(r wire.BringBackRequest) (wire.BringBack, error) {
	done := wire.BringBack{Moved: []string{}}
	// The uploads go whatever the answer, also when a check below refuses (#1531).
	var bundle, patch string
	var err error
	if r.Bundle != nil {
		if bundle, err = d.incomingFile(*r.Bundle); err != nil {
			return done, err
		}
		defer os.Remove(bundle)
	}
	if r.Patch != nil {
		if patch, err = d.incomingFile(*r.Patch); err != nil {
			return done, err
		}
		defer os.Remove(patch)
	}
	path, err := sendRepository(r.Folder)
	if err != nil {
		return done, err
	}
	if len(r.Branches) == 0 {
		return done, Invalid("Choose a branch to bring back.")
	}
	patchOn := ""
	if r.PatchOn != nil {
		patchOn = *r.PatchOn
	}
	patchSent := false
	for _, b := range r.Branches {
		if !validBranch(b.Name) || len(b.Commit) < 40 || strings.HasPrefix(b.Commit, "-") {
			return done, Invalid("%q is not a branch this Mac can take.", b.Name)
		}
		patchSent = patchSent || b.Name == patchOn
	}
	if patch != "" && !patchSent {
		return done, Invalid("The uncommitted changes come back only with the branch they are on.")
	}
	repo, _ := repositoryOf(path)
	m, _ := receiveLocks.LoadOrStore(canonical(repo.commonDir), &sync.Mutex{})
	m.(*sync.Mutex).Lock()
	defer m.(*sync.Mutex).Unlock()
	here := shortPath(path)

	if bundle != "" {
		if _, err := git(path, "fetch", "-q", "--no-tags", "--", bundle, "+refs/heads/*:refs/agents-back/*"); err != nil {
			if strings.Contains(err.Error(), "prerequisite") {
				return done, Invalid("%s is not what the machine expected. Bring back again. Nothing was changed.", here)
			}
			return done, err
		}
	}
	defer func() {
		if out, _ := git(path, "for-each-ref", "--format=%(refname)", "refs/agents-back"); out != "" {
			for _, ref := range strings.Split(out, "\n") {
				git(path, "update-ref", "-d", ref)
			}
		}
	}()

	// Where each branch is checked out on this Mac, so it moves there with its files.
	checkedOut := map[string]string{}
	trees, err := worktreeList(path)
	if err != nil {
		return done, err
	}
	for _, w := range trees {
		if w.branch != "" && !w.prunable {
			checkedOut[w.branch] = w.root
		}
	}

	// Every branch moves forward, or nothing moves.
	type move struct{ name, from, to string }
	var moves []move
	for _, b := range r.Branches {
		if _, err := git(path, "cat-file", "-e", b.Commit+"^{commit}"); err != nil {
			return done, Invalid("This Mac does not have the commits of %s. Bring back again. Nothing was changed.", b.Name)
		}
		have, _ := git(path, "rev-parse", "-q", "--verify", "refs/heads/"+b.Name)
		switch {
		case have == b.Commit:
			continue
		case have != "":
			if _, err := git(path, "merge-base", "--is-ancestor", have, b.Commit); err != nil {
				return done, &Error{Code: wire.FailureFolderInTheWay, Message: b.Name + " has commits of its own on this Mac that the machine does not have. Nothing was changed."}
			}
		}
		if root, ok := checkedOut[b.Name]; ok {
			if status, err := git(root, "status", "--porcelain"); err != nil {
				return done, err
			} else if status != "" {
				return done, &Error{Code: wire.FailureFolderInTheWay, Message: b.Name + " is checked out in " + shortPath(root) + " with uncommitted changes. Commit or remove them, then bring back again. Nothing was changed."}
			}
		}
		moves = append(moves, move{b.Name, have, b.Commit})
	}

	if patch != "" {
		cur, _ := git(path, "symbolic-ref", "-q", "--short", "HEAD")
		if cur != patchOn {
			return done, Invalid("The uncommitted changes are on %s, and %s has %s checked out. Nothing was changed.", patchOn, here, cur)
		}
		if status, err := git(path, "status", "--porcelain"); err != nil {
			return done, err
		} else if status != "" {
			return done, &Error{Code: wire.FailureFolderInTheWay, Message: here + " has uncommitted changes. Commit or remove them to take the machine's, then bring back again. Nothing was changed."}
		}
		if err := patchApplies(path, patchOn, r.Branches, patch); err != nil {
			return done, Invalid("The machine's uncommitted changes do not apply here: %s Nothing was changed.", err.Error())
		}
	}

	for _, m := range moves {
		if root, ok := checkedOut[m.name]; ok {
			if _, err := git(root, "merge", "-q", "--ff-only", m.to); err != nil {
				return done, err
			}
		} else {
			args := []string{"update-ref", "-m", "Bring back from host", "refs/heads/" + m.name, m.to}
			if m.from != "" {
				args = append(args, m.from)
			}
			if _, err := git(path, args...); err != nil {
				return done, err
			}
		}
		done.Moved = append(done.Moved, m.name)
	}
	if patch != "" {
		if fi, err := os.Stat(patch); err == nil && fi.Size() > 0 {
			if _, err := git(path, "apply", "--binary", "--whitespace=nowarn", patch); err != nil {
				return done, Invalid("The commits came back, but the uncommitted changes did not apply: %s", err.Error())
			}
			done.Applied = true
		}
	}
	return done, nil
}

// patchApplies checks the patch against the commit patchOn moves to, in an index of its
// own, so no file or index here changes.
func patchApplies(dir, patchOn string, branches []wire.SentBranch, patch string) error {
	commit := ""
	for _, b := range branches {
		if b.Name == patchOn {
			commit = b.Commit
		}
	}
	tmp, err := os.CreateTemp("", "agents-back-index-")
	if err != nil {
		return err
	}
	tmp.Close()
	defer os.Remove(tmp.Name())
	env := []string{"GIT_INDEX_FILE=" + tmp.Name()}
	if _, err := gitRawEnv(dir, env, nil, "read-tree", commit); err != nil {
		return err
	}
	_, err = gitRawEnv(dir, env, nil, "apply", "--cached", "--check", "--binary", "--whitespace=nowarn", patch)
	return err
}

func (d *Daemon) registerBringBack() {
	On(d, wire.CallFoldersBringBack, func(ctx context.Context, c *Client, r wire.BringBackRequest) (wire.BringBack, error) {
		return d.bringBack(r)
	})
}
