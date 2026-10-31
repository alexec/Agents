package agentsd

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// The sending side of Send to ‹host›… (#1123), on this Mac's host: the window is
// sandboxed and reads no repository itself, so this host makes the bundle and the patch
// (folders/sendPack), and the window reads them in parts (folders/sendRead) and hands
// them to the receiving host (folders/receiveUpload).

const sendPartSize = 1 << 20

// transferLimit is how long a file of a send waits untouched in Outgoing or Incoming
// before it is taken as abandoned (#1531): a sheet closed mid-send, a window that quit, a
// lost link. Each part read or written touches it, so a slow send that goes on keeps it.
const transferLimit = time.Hour

// sweepTransfers removes the files in folder that nothing touched for transferLimit.
func sweepTransfers(folder string) {
	entries, _ := os.ReadDir(folder)
	before := time.Now().Add(-transferLimit)
	for _, e := range entries {
		if fi, err := e.Info(); err == nil && fi.ModTime().Before(before) {
			os.Remove(filepath.Join(folder, e.Name()))
		}
	}
}

func (d *Daemon) outgoingFolder() string { return filepath.Join(d.Store.Loc.Root, "Outgoing") }

func (d *Daemon) outgoingFile(id wire.UUID) (string, error) {
	name := string(id)
	if name == "" || strings.ContainsAny(name, "/\\.") {
		return "", Invalid("That is not a file this machine made to send.")
	}
	return filepath.Join(d.outgoingFolder(), name), nil
}

func sendRepository(folder wire.URL) (string, error) {
	path := store.FolderPath(folder)
	if _, ok := repositoryOf(path); !ok {
		return "", Invalid("%s is not a Git repository.", shortPath(path))
	}
	return path, nil
}

func (d *Daemon) sendFacts(r wire.SendFactsRequest) (wire.SendFacts, error) {
	path, err := sendRepository(r.Folder)
	if err != nil {
		return wire.SendFacts{}, err
	}
	f := wire.SendFacts{Branches: []string{}}
	if out, err := git(path, "for-each-ref", "--format=%(refname:short)", "refs/heads"); err != nil {
		return f, err
	} else if out != "" {
		f.Branches = strings.Split(out, "\n")
	}
	if cur, err := git(path, "symbolic-ref", "-q", "--short", "HEAD"); err == nil && cur != "" {
		f.Current = &cur
	}
	if origin, err := git(path, "remote", "get-url", "origin"); err == nil && origin != "" {
		f.Origin = &origin
	}
	status, err := git(path, "status", "--porcelain")
	if err != nil {
		return f, err
	}
	f.HasChanges = status != ""
	return f, nil
}

func (d *Daemon) sendPack(r wire.SendPackRequest) (wire.SendPack, error) {
	path, err := sendRepository(r.Folder)
	if err != nil {
		return wire.SendPack{}, err
	}
	if len(r.Branches) == 0 {
		return wire.SendPack{}, Invalid("Choose a branch to send.")
	}
	p := wire.SendPack{Commits: []wire.SentBranch{}}
	refs := []string{}
	for _, b := range r.Branches {
		if !validBranch(b) {
			return p, Invalid("%q is not a branch.", b)
		}
		commit, err := git(path, "rev-parse", "--verify", "refs/heads/"+b+"^{commit}")
		if err != nil {
			return p, Invalid("%s has no branch %s.", shortPath(path), b)
		}
		p.Commits = append(p.Commits, wire.SentBranch{Name: b, Commit: commit})
		refs = append(refs, "refs/heads/"+b)
	}
	sweepTransfers(d.outgoingFolder())
	os.MkdirAll(d.outgoingFolder(), 0o700)

	// Only the receiving host's commits this repository has too can be left out.
	var known []string
	if len(r.LeavingOut) > 0 {
		out, _ := gitRaw(path, []byte(strings.Join(r.LeavingOut, "\n")+"\n"), "cat-file", "--batch-check")
		for _, l := range strings.Split(string(out), "\n") {
			if f := strings.Fields(l); len(f) >= 2 && f[1] == "commit" {
				known = append(known, "^"+f[0])
			}
		}
	}
	id := store.NewUUID()
	file, _ := d.outgoingFile(id)
	args := append(append([]string{"bundle", "create", "-q", file}, refs...), known...)
	if _, err := gitRaw(path, nil, args...); err != nil {
		os.Remove(file)
		if !strings.Contains(err.Error(), "empty bundle") {
			return p, err
		}
	} else if fi, err := os.Stat(file); err == nil {
		p.Bundle = &wire.SendFile{ID: id, Size: fi.Size()}
	}

	if r.IncludeChanges {
		head, tree, err := ownTree(path)
		if err != nil {
			return p, err
		}
		id := store.NewUUID()
		file, _ := d.outgoingFile(id)
		out, err := os.OpenFile(file, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
		if err != nil {
			return p, fileError(CodeFileNotReadable, err.Error())
		}
		err = gitTo(path, out, "diff", "--binary", head, tree)
		out.Close()
		if err != nil {
			os.Remove(file)
			return p, err
		}
		if fi, err := os.Stat(file); err == nil && fi.Size() > 0 {
			p.Patch = &wire.SendFile{ID: id, Size: fi.Size()}
		} else {
			os.Remove(file)
		}
	}
	return p, nil
}

func (d *Daemon) sendRead(r wire.SendReadRequest) (wire.SendRead, error) {
	return d.readOutgoing(r, "That file is gone. Send again.")
}

// readOutgoing reads one part of a file in Outgoing (a send's, or an export's, #1001);
// gone is what to say when the file is not there.
func (d *Daemon) readOutgoing(r wire.SendReadRequest, gone string) (wire.SendRead, error) {
	path, err := d.outgoingFile(r.ID)
	if err != nil {
		return wire.SendRead{}, err
	}
	f, err := os.Open(path)
	if err != nil {
		return wire.SendRead{}, Invalid("%s", gone)
	}
	defer f.Close()
	buf := make([]byte, sendPartSize)
	n, err := f.ReadAt(buf, r.Offset)
	if err != nil && err != io.EOF {
		return wire.SendRead{}, fileError(CodeFileNotReadable, err.Error())
	}
	fi, _ := f.Stat()
	end := fi == nil || r.Offset+int64(n) >= fi.Size()
	if end {
		os.Remove(path)
	} else {
		now := time.Now()
		os.Chtimes(path, now, now)
	}
	return wire.SendRead{Data: buf[:n], End: end}, nil
}

func (d *Daemon) registerSend() {
	os.RemoveAll(d.outgoingFolder())
	On(d, wire.CallFoldersSendFacts, func(ctx context.Context, c *Client, r wire.SendFactsRequest) (wire.SendFacts, error) {
		return d.sendFacts(r)
	})
	On(d, wire.CallFoldersSendPack, func(ctx context.Context, c *Client, r wire.SendPackRequest) (wire.SendPack, error) {
		return d.sendPack(r)
	})
	On(d, wire.CallFoldersSendRead, func(ctx context.Context, c *Client, r wire.SendReadRequest) (wire.SendRead, error) {
		return d.sendRead(r)
	})
}
