package agentsd

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// Send to ‹host›… (#1123): a Mac sends its repository here as a git bundle of the branches
// it chose, plus a patch of its uncommitted changes, in parts of at most 16 MB
// (folders/receiveUpload). folders/receive then makes the copy, or brings it up to date.
// It never overwrites work done here: changes or commits of the host's own stop it before
// anything is changed. Changes that the last send put here are not the host's own: a
// fingerprint of them is kept in .git/agents-sent, and the next send replaces them.

const receivePartLimit = 16 << 20

// receiveLimit is the most one upload may hold: a bundle of a large history.
const receiveLimit = 8 << 30

var receiveLocks sync.Map

func (d *Daemon) incomingFolder() string { return filepath.Join(d.Store.Loc.Root, "Incoming") }

func (d *Daemon) incomingFile(id wire.UUID) (string, error) {
	name := string(id)
	if name == "" || strings.ContainsAny(name, "/\\.") {
		return "", Invalid("That is not an upload.")
	}
	return filepath.Join(d.incomingFolder(), name), nil
}

func (d *Daemon) receiveUpload(r wire.ReceiveUploadRequest) error {
	if len(r.Data) > receivePartLimit {
		return Invalid("A part is more than 16 MB.")
	}
	path, err := d.incomingFile(r.Upload)
	if err != nil {
		return err
	}
	if r.Offset+int64(len(r.Data)) > receiveLimit {
		return Invalid("That is more than 8 GB.")
	}
	if r.Offset == 0 {
		sweepTransfers(d.incomingFolder())
		os.Remove(path)
	}
	os.MkdirAll(d.incomingFolder(), 0o700)
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return fileError(CodeFileNotReadable, err.Error())
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return fileError(CodeFileNotReadable, err.Error())
	}
	if fi.Size() != r.Offset {
		return Invalid("A part of the upload is missing. Send again.")
	}
	if _, err := f.WriteAt(r.Data, r.Offset); err != nil {
		return fileError(CodeFileNotReadable, err.Error())
	}
	return nil
}

// receiveFolder is the folder a send names: absolute, or under the home with ~/.
func receiveFolder(p string) (string, error) {
	path := filepath.Clean(expandHome(strings.TrimSpace(p)))
	if !filepath.IsAbs(path) {
		return "", Invalid("Give a folder that starts with / or ~/.")
	}
	return path, nil
}

// ownTree is the commit dir is on and the tree of everything in it that git does not
// ignore, made with an index of its own so the folder's index is not changed.
func ownTree(dir string) (head, tree string, err error) {
	index, err := git(dir, "rev-parse", "--path-format=absolute", "--git-path", "index")
	if err != nil {
		return "", "", err
	}
	tmp, err := os.CreateTemp("", "agents-send-index-")
	if err != nil {
		return "", "", err
	}
	tmp.Close()
	defer os.Remove(tmp.Name())
	if b, err := os.ReadFile(index); err == nil {
		os.WriteFile(tmp.Name(), b, 0o600)
	} else {
		os.Remove(tmp.Name())
	}
	env := []string{"GIT_INDEX_FILE=" + tmp.Name()}
	if _, err := gitRawEnv(dir, env, nil, "add", "-A"); err != nil {
		return "", "", err
	}
	out, err := gitRawEnv(dir, env, nil, "write-tree")
	if err != nil {
		return "", "", err
	}
	head, _ = git(dir, "rev-parse", "-q", "--verify", "HEAD")
	return head, strings.TrimSpace(string(out)), nil
}

// worktreeFingerprint is ownTree as one line, for .git/agents-sent.
func worktreeFingerprint(dir string) (string, error) {
	head, tree, err := ownTree(dir)
	return head + " " + tree, err
}

func sentMark(dir string) string {
	p, _ := git(dir, "rev-parse", "--path-format=absolute", "--git-path", "agents-sent")
	return p
}

// changes is whether dir has uncommitted changes, and whether they are the host's own:
// not the ones the last send left.
func changes(dir string) (changed, own bool, err error) {
	status, err := git(dir, "status", "--porcelain")
	if err != nil {
		return false, false, err
	}
	if status == "" {
		return false, false, nil
	}
	mark, _ := os.ReadFile(sentMark(dir))
	now, err := worktreeFingerprint(dir)
	if err != nil {
		return true, true, err
	}
	return true, strings.TrimSpace(string(mark)) != now, nil
}

func (d *Daemon) receiveState(r wire.ReceiveStateRequest) (wire.ReceiveState, error) {
	path, err := receiveFolder(r.Folder)
	if err != nil {
		return wire.ReceiveState{}, err
	}
	s := wire.ReceiveState{Folder: store.FolderURL(path), Heads: []string{}}
	fi, err := os.Stat(path)
	if err != nil {
		return s, nil
	}
	s.Exists = fi.IsDir()
	repo, ok := repositoryOf(path)
	if !ok || canonical(repo.toplevel) != canonical(path) {
		return s, nil
	}
	s.Repository = true
	_, own, err := changes(path)
	if err != nil {
		return s, err
	}
	s.OwnChanges = own
	if out, err := git(path, "for-each-ref", "--format=%(objectname)", "refs/heads"); err == nil && out != "" {
		s.Heads = strings.Split(out, "\n")
	}
	return s, nil
}

func validBranch(name string) bool {
	if name == "" || strings.HasPrefix(name, "-") {
		return false
	}
	_, err := git(os.TempDir(), "check-ref-format", "refs/heads/"+name)
	return err == nil
}

func (d *Daemon) receive(r wire.ReceiveRequest) (summary wire.FolderSummary, err error) {
	// The uploads go whatever the answer, also when a check below refuses (#1531).
	var bundle, patch string
	if r.Bundle != nil {
		if bundle, err = d.incomingFile(*r.Bundle); err != nil {
			return summary, err
		}
		defer os.Remove(bundle)
	}
	if r.Patch != nil {
		if patch, err = d.incomingFile(*r.Patch); err != nil {
			return summary, err
		}
		defer os.Remove(patch)
	}
	path, err := receiveFolder(r.Folder)
	if err != nil {
		return summary, err
	}
	if len(r.Branches) == 0 {
		return summary, Invalid("Choose a branch to send.")
	}
	checkoutSent := false
	for _, b := range r.Branches {
		if !validBranch(b.Name) || len(b.Commit) < 40 || strings.HasPrefix(b.Commit, "-") {
			return summary, Invalid("%q is not a branch this machine can take.", b.Name)
		}
		checkoutSent = checkoutSent || b.Name == r.Checkout
	}
	if !checkoutSent {
		return summary, Invalid("The branch to check out is not one of those sent.")
	}
	m, _ := receiveLocks.LoadOrStore(path, &sync.Mutex{})
	m.(*sync.Mutex).Lock()
	defer m.(*sync.Mutex).Unlock()

	here := shortPath(path)
	fresh, made := false, false
	if fi, err := os.Stat(path); err != nil {
		if err := os.MkdirAll(path, 0o755); err != nil {
			return summary, &Error{Code: wire.FailureFolderInTheWay, Message: "Could not make " + here + ": " + err.Error()}
		}
		fresh, made = true, true
	} else if !fi.IsDir() {
		return summary, &Error{Code: wire.FailureFolderInTheWay, Message: here + " is a file. Nothing in it was changed."}
	} else if repo, ok := repositoryOf(path); !ok || canonical(repo.toplevel) != canonical(path) {
		if entries, _ := os.ReadDir(path); len(entries) > 0 {
			return summary, &Error{Code: wire.FailureFolderInTheWay, Message: here + " is already there and is not a Git repository. Nothing in it was changed."}
		}
		fresh = true
	}
	defer func() {
		switch {
		case err == nil:
		case made:
			os.RemoveAll(path)
		case fresh:
			os.RemoveAll(filepath.Join(path, ".git"))
		}
	}()
	if fresh {
		if _, err := git(path, "init", "-q"); err != nil {
			return summary, err
		}
	} else {
		_, own, err := changes(path)
		if err != nil {
			return summary, err
		}
		if own {
			return summary, &Error{Code: wire.FailureFolderInTheWay, Message: here + " has changes of its own on this machine. Commit or remove them there, then send again. Nothing was changed."}
		}
	}

	if bundle != "" {
		if _, err := git(path, "fetch", "-q", "--no-tags", "--", bundle, "+refs/heads/*:refs/agents-send/*"); err != nil {
			if strings.Contains(err.Error(), "prerequisite") {
				return summary, Invalid("The copy on this machine is not what the Mac expected. Send again. Nothing was changed.")
			}
			return summary, err
		}
	}
	defer func() {
		if out, _ := git(path, "for-each-ref", "--format=%(refname)", "refs/agents-send"); out != "" {
			for _, ref := range strings.Split(out, "\n") {
				git(path, "update-ref", "-d", ref)
			}
		}
	}()

	// Every branch moves forward, or the send stops before any moves.
	type move struct{ ref, from, to string }
	var moves []move
	for _, b := range r.Branches {
		if _, err := git(path, "cat-file", "-e", b.Commit+"^{commit}"); err != nil {
			return summary, Invalid("This machine does not have the commits of %s. Send again. Nothing was changed.", b.Name)
		}
		ref := "refs/heads/" + b.Name
		have, _ := git(path, "rev-parse", "-q", "--verify", ref)
		switch {
		case have == b.Commit:
		case have == "":
			moves = append(moves, move{ref, "", b.Commit})
		default:
			if _, err := git(path, "merge-base", "--is-ancestor", have, b.Commit); err != nil {
				return summary, &Error{Code: wire.FailureFolderInTheWay, Message: b.Name + " in " + here + " has commits of its own on this machine. Nothing was changed."}
			}
			moves = append(moves, move{ref, have, b.Commit})
		}
	}

	if !fresh {
		// What is left is the last send's changes, or nothing: clear it for this send.
		if _, err := git(path, "reset", "-q", "--hard"); err != nil {
			return summary, err
		}
		if _, err := git(path, "clean", "-fdq"); err != nil {
			return summary, err
		}
	}
	for _, m := range moves {
		args := []string{"update-ref", "-m", "Send to host", m.ref, m.to}
		if m.from != "" {
			args = append(args, m.from)
		}
		if _, err := git(path, args...); err != nil {
			return summary, err
		}
	}
	if _, err := git(path, "symbolic-ref", "HEAD", "refs/heads/"+r.Checkout); err != nil {
		return summary, err
	}
	if _, err := git(path, "reset", "-q", "--hard"); err != nil {
		return summary, err
	}
	if r.Origin != nil && *r.Origin != "" {
		// err is the named result. := here would hide it, and the check below would
		// not see a failed set-url or add.
		if _, err = git(path, "remote", "get-url", "origin"); err == nil {
			_, err = git(path, "remote", "set-url", "origin", *r.Origin)
		} else {
			_, err = git(path, "remote", "add", "origin", *r.Origin)
		}
		if err != nil {
			return summary, err
		}
	}
	os.Remove(sentMark(path))
	if patch != "" {
		if fi, err := os.Stat(patch); err == nil && fi.Size() > 0 {
			if _, err := git(path, "apply", "--binary", "--whitespace=nowarn", patch); err != nil {
				return summary, Invalid("The commits arrived, but the uncommitted changes did not apply: %s", err.Error())
			}
			if now, err := worktreeFingerprint(path); err == nil {
				os.WriteFile(sentMark(path), []byte(now+"\n"), 0o600)
			}
		}
	}
	return d.addFolderOf(store.FolderURL(path), false, "")
}

func (d *Daemon) registerReceive() {
	os.RemoveAll(d.incomingFolder())
	On(d, wire.CallFoldersReceiveUpload, func(ctx context.Context, c *Client, r wire.ReceiveUploadRequest) (wire.Empty, error) {
		return wire.Empty{}, d.receiveUpload(r)
	})
	On(d, wire.CallFoldersReceiveState, func(ctx context.Context, c *Client, r wire.ReceiveStateRequest) (wire.ReceiveState, error) {
		return d.receiveState(r)
	})
	On(d, wire.CallFoldersReceive, func(ctx context.Context, c *Client, r wire.ReceiveRequest) (wire.FolderSummary, error) {
		return d.receive(r)
	})
}
