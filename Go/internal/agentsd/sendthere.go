package agentsd

import (
	"encoding/json"
	"io"
	"os"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// start_session with send (#2929): before the session starts on another machine, the
// branch the agent is on, with its uncommitted changes, goes to the folder there, as the
// window's Send to ‹machine›… does (send.go, receive.go). This host packs it and sends each
// part through the control plane (machines/sendFolder), which hands it to that machine's
// folders/receiveUpload; folders/receive there then makes the copy, or brings it up to
// date. It never overwrites work done there: receive refuses first.

const sendFolderMethod = "machines/sendFolder"

// sendThereParts is the most of a file one machines/sendFolder carries: well under the
// control plane's message limit once it is base64.
const sendThereParts = 4 << 20

// sendingBranch is what start_session sends: the repository the agent works in, the
// branch it is on and its origin, and the heads the folder there has already.
type sendingBranch struct {
	path, branch string
	origin       *string
	heads        []string
}

// branchToSend is the branch the agent works on, or why it can't be sent.
func (d *Daemon) branchToSend(me *wire.Agent) (sendingBranch, error) {
	cwd := store.PathURL(store.FolderPath(me.Cwd))
	path, err := sendRepository(cwd)
	if err != nil {
		return sendingBranch{}, err
	}
	facts, err := d.sendFacts(wire.SendFactsRequest{Folder: cwd})
	if err != nil {
		return sendingBranch{}, err
	}
	if facts.Current == nil || *facts.Current == "" {
		return sendingBranch{}, Invalid("%s is on no branch. Check out a branch to send.", shortPath(path))
	}
	return sendingBranch{path: path, branch: *facts.Current, origin: facts.Origin}, nil
}

// readyThere is the heads folder on machine has, which the send can leave out, or why
// it can't take b: it is offline, or the folder has work of its own. Asked before the
// person is, so they are never asked about what can't be done (#855).
func (d *Daemon) readyThere(me *wire.Agent, machine, folder string) ([]string, error) {
	var state wire.MachineFolderSent
	if err := d.askSend(me, wire.MachineFolderSend{Host: machine, State: &wire.ReceiveStateRequest{Folder: folder}}, &state); err != nil {
		return nil, err
	}
	if state.State == nil {
		return nil, nil
	}
	if state.State.Exists && !state.State.Repository {
		return nil, &Error{Code: wire.FailureFolderInTheWay, Message: folder + " is already there and is not a Git repository."}
	}
	if state.State.OwnChanges {
		return nil, &Error{Code: wire.FailureFolderInTheWay, Message: folder + " has changes of its own there."}
	}
	return state.State.Heads, nil
}

// sendThere sends b to folder on machine, leaving out the commits it has; me asks.
func (d *Daemon) sendThere(me *wire.Agent, machine, folder string, b sendingBranch) error {
	pack, err := d.sendPack(wire.SendPackRequest{Folder: store.PathURL(b.path), Branches: []string{b.branch}, LeavingOut: b.heads, IncludeChanges: true})
	for _, f := range []*wire.SendFile{pack.Bundle, pack.Patch} {
		if f != nil {
			defer func(id wire.UUID) {
				if file, err := d.outgoingFile(id); err == nil {
					os.Remove(file)
				}
			}(f.ID)
		}
	}
	if err != nil {
		return err
	}
	receive := wire.ReceiveRequest{Folder: folder, Branches: pack.Commits, Checkout: b.branch, Origin: b.origin}
	if pack.Bundle != nil {
		id, err := d.uploadThere(me, machine, pack.Bundle.ID)
		if err != nil {
			return err
		}
		receive.Bundle = &id
	}
	if pack.Patch != nil {
		id, err := d.uploadThere(me, machine, pack.Patch.ID)
		if err != nil {
			return err
		}
		receive.Patch = &id
	}
	return d.askSend(me, wire.MachineFolderSend{Host: machine, Receive: &receive}, nil)
}

// uploadThere sends the outgoing file id to machine in parts, and is the upload's id there.
func (d *Daemon) uploadThere(me *wire.Agent, machine string, id wire.UUID) (wire.UUID, error) {
	file, err := d.outgoingFile(id)
	if err != nil {
		return "", err
	}
	f, err := os.Open(file)
	if err != nil {
		return "", fileError(CodeFileNotReadable, err.Error())
	}
	defer f.Close()
	upload := store.NewUUID()
	buf := make([]byte, sendThereParts)
	for offset := int64(0); ; {
		n, err := io.ReadFull(f, buf)
		if n > 0 {
			part := wire.ReceiveUploadRequest{Upload: upload, Offset: offset, Data: buf[:n]}
			if err := d.askSend(me, wire.MachineFolderSend{Host: machine, Upload: &part}, nil); err != nil {
				return "", err
			}
			offset += int64(n)
		}
		if err == io.EOF || err == io.ErrUnexpectedEOF {
			return upload, nil
		}
		if err != nil {
			return "", fileError(CodeFileNotReadable, err.Error())
		}
	}
}

// askSend is one machines/sendFolder; out, when not nil, takes its answer.
func (d *Daemon) askSend(me *wire.Agent, step wire.MachineFolderSend, out *wire.MachineFolderSent) error {
	raw, err := d.askWorkspaces(me.ID, sendFolderMethod, step)
	if err != nil || out == nil {
		return err
	}
	if json.Unmarshal(raw, out) != nil {
		return &Error{Code: wire.FailureNotSupported, Message: "the control plane's answer could not be read."}
	}
	return nil
}
