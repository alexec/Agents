package agentsd

import (
	"context"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"sync"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// Bring Back from ‹machine›… from a client (#4640), as Send to ‹machine›… is (foldersend.go,
// #4613): this host brings the branches back itself, through the control plane, as
// bring_back does (bringthere.go), and the client only starts it and watches
// bringBack/changed. The window was the relay before (#1473): a modal sheet for the whole
// bring-back, and a bring-back lost with the window.

type bringBackState struct {
	bringMu sync.Mutex
	// bringing are the bring-backs under way, by id.
	bringing map[wire.UUID]*wire.BringBackNotification
	// bringingInto are the repositories here that a bring-back is checking or bringing into:
	// one at a time.
	bringingInto map[string]bool
}

// startBringBack checks r, answers with the bring-back it starts, and brings back in the
// background.
func (d *Daemon) startBringBack(r wire.BringBackFromRequest) (wire.BringBackSummary, error) {
	machine := strings.TrimSpace(r.Machine)
	if machine == "" {
		return wire.BringBackSummary{}, Invalid("Nothing was brought back: say which machine.")
	}
	name := machine
	if r.MachineName != nil && strings.TrimSpace(*r.MachineName) != "" {
		name = strings.TrimSpace(*r.MachineName)
	}
	nothing := "Nothing was brought back from " + name + ": "
	if d.askControl.Load() == nil {
		return wire.BringBackSummary{}, &Error{Code: wire.FailureNotSupported, Message: nothing + "this machine isn’t on a control plane, so it has no other machines."}
	}
	if strings.EqualFold(machine, d.ownName()) || strings.EqualFold(machine, d.ownHostID()) {
		return wire.BringBackSummary{}, Invalid("%sthe folder is on this machine.", nothing)
	}
	source := strings.TrimSpace(r.Source)
	if source == "" {
		return wire.BringBackSummary{}, Invalid("%ssay which folder there.", nothing)
	}
	path, err := sendRepository(r.Folder)
	if err != nil {
		return wire.BringBackSummary{}, err
	}
	if len(r.Branches) == 0 {
		return wire.BringBackSummary{}, Invalid("Choose a branch to bring back.")
	}
	d.bringMu.Lock()
	if d.bringingInto[path] {
		d.bringMu.Unlock()
		return wire.BringBackSummary{}, &Error{Code: wire.FailureFolderInTheWay, Message: shortPath(path) + " is already bringing back."}
	}
	if d.bringingInto == nil {
		d.bringingInto, d.bringing = map[string]bool{}, map[wire.UUID]*wire.BringBackNotification{}
	}
	d.bringingInto[path] = true
	d.bringMu.Unlock()
	done := func() {
		d.bringMu.Lock()
		delete(d.bringingInto, path)
		d.bringMu.Unlock()
	}
	// Asked before the bring-back starts, so an offline machine, or a folder there that is
	// not what the sheet saw, says so at once (#855).
	var sent wire.MachineFolderSent
	if err := d.askSend(personSending, wire.MachineFolderSend{Host: machine, Facts: &wire.SendFactsRequest{Folder: store.PathURL(source)}}, &sent); err != nil {
		done()
		code, msg := errMessage(err)
		return wire.BringBackSummary{}, &Error{Code: code, Message: nothing + msg}
	}
	if sent.Facts == nil {
		done()
		return wire.BringBackSummary{}, &Error{Code: wire.FailureNotSupported, Message: nothing + "the control plane's answer could not be read."}
	}
	there := *sent.Facts
	for _, b := range r.Branches {
		if !slices.Contains(there.Branches, b) {
			done()
			return wire.BringBackSummary{}, Invalid("%s%s on %s has no branch %s.", nothing, source, name, b)
		}
	}
	patchOn := ""
	if there.Current != nil {
		patchOn = *there.Current
	}
	changes := r.IncludeChanges
	if changes && !slices.Contains(r.Branches, patchOn) {
		done()
		return wire.BringBackSummary{}, Invalid("%sthe uncommitted changes there come only with %s, the branch checked out there.", nothing, patchOn)
	}

	s := wire.BringBackSummary{ID: store.NewUUID(), Folder: store.PathURL(path), Machine: machine, MachineName: name,
		Source: source, StartedAt: now()}
	n := &wire.BringBackNotification{BringBack: s}
	d.bringMu.Lock()
	d.bringing[s.ID] = n
	d.bringMu.Unlock()
	Broadcast(d, wire.NotifyBringBackChanged, *n)

	branches := slices.Clone(r.Branches)
	safe.Go("bring back "+path+" from "+name, func() {
		result, err := d.bringPack(personSending, machine, source, path, branches, changes, patchOn, func(done, total int64) {
			d.bringMu.Lock()
			n.Read, n.Total = done, total
			copied := *n
			d.bringMu.Unlock()
			Broadcast(d, wire.NotifyBringBackChanged, copied)
		})
		d.bringMu.Lock()
		delete(d.bringing, s.ID)
		delete(d.bringingInto, path)
		n.Finished = true
		if err != nil {
			_, msg := errMessage(err)
			msg = "Nothing came back into " + filepath.Base(path) + " from " + name + ": " + msg
			n.Problem = &msg
		} else {
			n.Result = &result
		}
		copied := *n
		d.bringMu.Unlock()
		Broadcast(d, wire.NotifyBringBackChanged, copied)
	})
	return s, nil
}

// bringingBack are the bring-backs this host is making, the oldest first, for a client that
// connects mid-way.
func (d *Daemon) bringingBack() []wire.BringBackNotification {
	d.bringMu.Lock()
	out := []wire.BringBackNotification{}
	for _, n := range d.bringing {
		out = append(out, *n)
	}
	d.bringMu.Unlock()
	sort.Slice(out, func(i, j int) bool { return out[i].BringBack.StartedAt < out[j].BringBack.StartedAt })
	return out
}

func (d *Daemon) registerFolderBringBack() {
	On(d, wire.CallFoldersBringBackFrom, func(ctx context.Context, c *Client, r wire.BringBackFromRequest) (wire.BringBackSummary, error) {
		return d.startBringBack(r)
	})
	On(d, wire.CallFoldersBringingBack, func(ctx context.Context, c *Client, _ wire.Empty) ([]wire.BringBackNotification, error) {
		return d.bringingBack(), nil
	})
}
