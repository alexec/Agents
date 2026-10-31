package agentsd

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// bring_back (#2947), the reverse of start_session with send (sendthere.go, #2929): a
// branch of a folder on another machine comes back into the repository the agent works in,
// as the window's Bring Back from ‹machine›… does (bringback.go), but with no window. The
// other machine packs it (folders/sendPack), less the commits this one has, this host reads
// it in parts (folders/sendRead), each through the control plane (machines/sendFolder), and
// folders/bringBack here moves the branch forward. The person says yes first, every time.

// bringingBranch is what bring_back brings: the branch, from folder on machine, into the
// repository at path here, with the uncommitted changes there when changes.
type bringingBranch struct {
	machine, folder, path, branch string
	changes                       bool
}

// bringBackTool is bring_back.
func (d *Daemon) bringBackTool(caller wire.UUID, args map[string]json.RawMessage) (string, error) {
	me := d.Store.Agent(caller)
	if me == nil {
		return "", &Error{Code: CodeNoSuchAgent, Message: "That conversation is not open any more, so nothing was changed."}
	}
	b, err := d.branchToBring(me, args)
	if err != nil {
		code, msg := errMessage(err)
		if !strings.HasPrefix(msg, "Nothing") {
			msg = "Nothing was brought back: " + msg
		}
		return "", &Error{Code: code, Message: msg}
	}
	what := b.branch
	if b.changes {
		what += ", with its uncommitted changes,"
	}
	yes, err := d.personSaysYes(me.ID, d.agentWho(me.ID)+" wants to bring back a branch from "+b.machine,
		fmt.Sprintf("Bring %s back from %s on %s into %s?", what, b.folder, b.machine, shortPath(b.path)), "Bring it back")
	if err != nil {
		return "", err
	}
	if !yes {
		return "Nothing was brought back: the person said no, or didn’t answer.", nil
	}
	done, err := d.bringFromThere(me, b)
	if err != nil {
		code, msg := errMessage(err)
		return "", &Error{Code: code, Message: b.branch + " was not brought back from " + b.machine + ": " + msg}
	}
	out := fmt.Sprintf("%s already had every commit of %s on %s.", shortPath(b.path), b.branch, b.machine)
	if len(done.Moved) > 0 {
		out = fmt.Sprintf("Brought %s back from %s on %s: it moved forward in %s.", b.branch, b.folder, b.machine, shortPath(b.path))
	}
	if done.Applied {
		out += " The uncommitted changes from " + b.machine + " are in " + shortPath(b.path) + "."
	} else if b.changes {
		out += " " + b.folder + " had no uncommitted changes."
	}
	return out, nil
}

// branchToBring is what bring_back is to bring, or why it can't: checked before the card,
// so the person is never asked about what can't be done (#855).
func (d *Daemon) branchToBring(me *wire.Agent, args map[string]json.RawMessage) (bringingBranch, error) {
	b := bringingBranch{
		machine: strings.TrimSpace(argString(args, "machine")),
		folder:  strings.TrimSpace(argString(args, "folder")),
		branch:  strings.TrimSpace(argString(args, "branch")),
		changes: argBool(args, "changes"),
	}
	if b.machine == "" {
		return b, Invalid("Nothing was brought back: say which machine, by its name as list_machines gives it.")
	}
	if !strings.HasPrefix(b.folder, "/") {
		return b, Invalid("Nothing was brought back: say which folder on %s, as an absolute path, such as /home/me/project.", b.machine)
	}
	b.folder = filepath.Clean(b.folder)
	if d.askControl.Load() == nil {
		return b, &Error{Code: wire.FailureNotSupported, Message: "Nothing was brought back: this machine isn’t on a control plane, so it has no other machines."}
	}
	cwd := store.PathURL(store.FolderPath(me.Cwd))
	var err error
	if b.path, err = sendRepository(cwd); err != nil {
		return b, err
	}
	here, err := d.sendFacts(wire.SendFactsRequest{Folder: cwd})
	if err != nil {
		return b, err
	}
	var sent wire.MachineFolderSent
	if err := d.askSend(me, wire.MachineFolderSend{Host: b.machine, Facts: &wire.SendFactsRequest{Folder: store.PathURL(b.folder)}}, &sent); err != nil {
		code, msg := errMessage(err)
		if code == wire.FailureHostOffline {
			msg += " Start it with start_machine, then try again."
		}
		return b, &Error{Code: code, Message: "Nothing was brought back from " + b.machine + ": " + msg}
	}
	there := sent.Facts
	if there == nil {
		return b, &Error{Code: wire.FailureNotSupported, Message: "the control plane's answer could not be read."}
	}
	current := ""
	if there.Current != nil {
		current = *there.Current
	}
	if b.branch == "" {
		if current == "" {
			return b, Invalid("%s on %s is on no branch. Say which branch to bring back.", b.folder, b.machine)
		}
		b.branch = current
	}
	if !slices.Contains(there.Branches, b.branch) {
		return b, Invalid("%s on %s has no branch %s.", b.folder, b.machine, b.branch)
	}
	if b.changes {
		if b.branch != current {
			return b, Invalid("the uncommitted changes there are on %s, not %s.", current, b.branch)
		}
		if here.Current == nil || *here.Current != b.branch {
			return b, Invalid("the uncommitted changes come only to a folder that has %s checked out, and %s has not.", b.branch, shortPath(b.path))
		}
		if here.HasChanges {
			return b, &Error{Code: wire.FailureFolderInTheWay, Message: shortPath(b.path) + " has uncommitted changes. Commit or remove them to take the machine's."}
		}
	}
	return b, nil
}

// bringFromThere has machine pack b, less the commits here, reads it here in parts and
// brings it into b.path.
func (d *Daemon) bringFromThere(me *wire.Agent, b bringingBranch) (wire.BringBack, error) {
	var heads []string
	if out, err := git(b.path, "for-each-ref", "--format=%(objectname)", "refs/heads"); err == nil && out != "" {
		heads = strings.Split(out, "\n")
	}
	var sent wire.MachineFolderSent
	pack := wire.SendPackRequest{Folder: store.PathURL(b.folder), Branches: []string{b.branch}, LeavingOut: heads, IncludeChanges: b.changes}
	if heads == nil {
		pack.LeavingOut = []string{}
	}
	if err := d.askSend(me, wire.MachineFolderSend{Host: b.machine, Pack: &pack}, &sent); err != nil {
		return wire.BringBack{}, err
	}
	if sent.Pack == nil {
		return wire.BringBack{}, &Error{Code: wire.FailureNotSupported, Message: "the control plane's answer could not be read."}
	}
	r := wire.BringBackRequest{Folder: store.PathURL(b.path), Branches: sent.Pack.Commits}
	// What was read here goes whatever the answer; bringBack removes what it is given.
	var read []wire.UUID
	defer func() {
		for _, id := range read {
			if file, err := d.incomingFile(id); err == nil {
				os.Remove(file)
			}
		}
	}()
	for _, f := range []*wire.SendFile{sent.Pack.Bundle, sent.Pack.Patch} {
		if f == nil {
			continue
		}
		id := store.NewUUID()
		read = append(read, id)
		if err := d.readThere(me, b.machine, f.ID, id); err != nil {
			return wire.BringBack{}, err
		}
		if f == sent.Pack.Bundle {
			r.Bundle = &id
		} else {
			r.Patch, r.PatchOn = &id, &b.branch
		}
	}
	return d.bringBack(r)
}

// readThere reads machine's outgoing file id, in parts, into the upload here.
func (d *Daemon) readThere(me *wire.Agent, machine string, id, upload wire.UUID) error {
	for offset := int64(0); ; {
		var sent wire.MachineFolderSent
		if err := d.askSend(me, wire.MachineFolderSend{Host: machine, Read: &wire.SendReadRequest{ID: id, Offset: offset}}, &sent); err != nil {
			return err
		}
		if sent.Read == nil {
			return &Error{Code: wire.FailureNotSupported, Message: "the control plane's answer could not be read."}
		}
		if len(sent.Read.Data) > 0 || offset == 0 {
			if err := d.receiveUpload(wire.ReceiveUploadRequest{Upload: upload, Offset: offset, Data: sent.Read.Data}); err != nil {
				return err
			}
			offset += int64(len(sent.Read.Data))
		}
		if sent.Read.End {
			return nil
		}
		if len(sent.Read.Data) == 0 {
			return &Error{Code: wire.FailureNotSupported, Message: machine + " sent an empty part."}
		}
	}
}
