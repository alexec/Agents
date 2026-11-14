package agentsd

import (
	"context"
	"path/filepath"
	"sort"
	"strings"
	"sync"

	"github.com/agentloops-dev/agents/Go/internal/agentsd/store"
	"github.com/agentloops-dev/agents/Go/internal/safe"
	"github.com/agentloops-dev/agents/Go/wire"
)

// Send to ‹machine›… from a client (#4613): this host sends the folder itself, through the
// control plane, as start_session with send does (sendthere.go), and the client only starts
// it and watches send/changed, as it watches a clone (027). The window was the relay before
// (#1123): a modal sheet for the whole send, and a send lost with the window.

type sendState struct {
	sendMu sync.Mutex
	// sends are the sends under way, by id.
	sends map[wire.UUID]*wire.SendNotification
	// sendsTo are the folders there, by machine and folder, that a send is checking or
	// making: one at a time.
	sendsTo map[string]bool
}

// personSending asks the control plane for a send no agent asked for: agentWho says You.
var personSending = &wire.Agent{}

// startSend checks r, answers with the send it starts, and sends in the background.
func (d *Daemon) startSend(r wire.SendRequest) (wire.SendSummary, error) {
	machine := strings.TrimSpace(r.Machine)
	if machine == "" {
		return wire.SendSummary{}, Invalid("Nothing was sent: say which machine.")
	}
	name := machine
	if r.MachineName != nil && strings.TrimSpace(*r.MachineName) != "" {
		name = strings.TrimSpace(*r.MachineName)
	}
	nothing := "Nothing was sent to " + name + ": "
	if d.askControl.Load() == nil {
		return wire.SendSummary{}, &Error{Code: wire.FailureNotSupported, Message: nothing + "this machine isn’t on a control plane, so it has no other machines."}
	}
	if strings.EqualFold(machine, d.ownName()) || strings.EqualFold(machine, d.ownHostID()) {
		return wire.SendSummary{}, Invalid("%sthe folder is on %s already.", nothing, name)
	}
	destination := strings.TrimSpace(r.Destination)
	if destination == "" {
		return wire.SendSummary{}, Invalid("%ssay which folder there.", nothing)
	}
	path, err := sendRepository(r.Folder)
	if err != nil {
		return wire.SendSummary{}, err
	}
	if len(r.Branches) == 0 {
		return wire.SendSummary{}, Invalid("Choose a branch to send.")
	}
	to := machine + "\x00" + destination
	d.sendMu.Lock()
	if d.sendsTo[to] {
		d.sendMu.Unlock()
		return wire.SendSummary{}, &Error{Code: wire.FailureFolderInTheWay, Message: destination + " on " + name + " is already being sent."}
	}
	if d.sendsTo == nil {
		d.sendsTo, d.sends = map[string]bool{}, map[wire.UUID]*wire.SendNotification{}
	}
	d.sendsTo[to] = true
	d.sendMu.Unlock()
	done := func() {
		d.sendMu.Lock()
		delete(d.sendsTo, to)
		d.sendMu.Unlock()
	}
	// Asked before the send starts, so a folder there with work of its own, or a machine
	// that is offline, says so at once (#855).
	heads, err := d.readyThere(personSending, machine, destination)
	if err != nil {
		done()
		code, msg := errMessage(err)
		return wire.SendSummary{}, &Error{Code: code, Message: nothing + msg}
	}
	s := wire.SendSummary{ID: store.NewUUID(), Folder: store.PathURL(path), Machine: machine, MachineName: name,
		Destination: destination, StartedAt: now()}
	n := &wire.SendNotification{Send: s}
	d.sendMu.Lock()
	d.sends[s.ID] = n
	d.sendMu.Unlock()
	Broadcast(d, wire.NotifySendChanged, *n)

	pack := wire.SendPackRequest{Folder: s.Folder, Branches: r.Branches, LeavingOut: heads, IncludeChanges: r.IncludeChanges}
	receive := wire.ReceiveRequest{Folder: destination, Checkout: r.Checkout, Origin: r.Origin}
	safe.Go("send "+path+" to "+name, func() {
		made, err := d.packThere(personSending, machine, pack, receive, func(done, total int64) {
			d.sendMu.Lock()
			n.Sent, n.Total = done, total
			copied := *n
			d.sendMu.Unlock()
			Broadcast(d, wire.NotifySendChanged, copied)
		})
		d.sendMu.Lock()
		delete(d.sends, s.ID)
		delete(d.sendsTo, to)
		n.Finished = true
		if err != nil {
			_, msg := errMessage(err)
			msg = filepath.Base(path) + " did not reach " + name + ": " + msg
			n.Problem = &msg
		} else {
			n.Received = &made
		}
		copied := *n
		d.sendMu.Unlock()
		Broadcast(d, wire.NotifySendChanged, copied)
	})
	return s, nil
}

// sendsUnderWay are the sends this host is making, the oldest first, for a client that
// connects mid-send.
func (d *Daemon) sendsUnderWay() []wire.SendNotification {
	d.sendMu.Lock()
	out := []wire.SendNotification{}
	for _, n := range d.sends {
		out = append(out, *n)
	}
	d.sendMu.Unlock()
	sort.Slice(out, func(i, j int) bool { return out[i].Send.StartedAt < out[j].Send.StartedAt })
	return out
}

func (d *Daemon) registerFolderSend() {
	On(d, wire.CallFoldersSend, func(ctx context.Context, c *Client, r wire.SendRequest) (wire.SendSummary, error) {
		return d.startSend(r)
	})
	On(d, wire.CallFoldersSends, func(ctx context.Context, c *Client, _ wire.Empty) ([]wire.SendNotification, error) {
		return d.sendsUnderWay(), nil
	})
}
