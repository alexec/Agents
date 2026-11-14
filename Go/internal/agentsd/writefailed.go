package agentsd

import (
	"errors"
	"io/fs"
	"log"
	"syscall"

	"github.com/agentloops-dev/agents/Go/internal/agentsd/store"
	"github.com/agentloops-dev/agents/Go/wire"
)

// MARK: chat lines the disk refused (#212, #3245)

// writeFailure is WriteFailure.init(_:keeping:): the sentence for a write the disk refused,
// when the cause is one a person can do something about. Anything else is not, so a bug is
// never dressed up as advice to free some space.
func writeFailure(err error, what string) (wire.WriteFailure, bool) {
	var cause wire.WriteFailureCause
	switch {
	case errors.Is(err, syscall.ENOSPC), errors.Is(err, syscall.EDQUOT):
		cause = wire.WriteFailureCauseDiskFull
	case errors.Is(err, syscall.EACCES), errors.Is(err, syscall.EPERM):
		cause = wire.WriteFailureCauseNotAllowed
	case errors.Is(err, syscall.EROFS):
		cause = wire.WriteFailureCauseReadOnly
	default:
		return wire.WriteFailure{}, false
	}
	f := wire.WriteFailure{Cause: cause, What: what}
	var pe *fs.PathError
	if errors.As(err, &pe) {
		f.Path = &pe.Path
	}
	machine := "Your Mac"
	if serverToolsets {
		machine = "The server"
	}
	folder := "that folder"
	if f.Path != nil {
		folder = "“" + *f.Path + "”"
	}
	switch cause {
	case wire.WriteFailureCauseDiskFull:
		f.Message = machine + " is out of disk space, so " + what + " could not be saved. Free some space, then try again."
	case wire.WriteFailureCauseNotAllowed:
		f.Message = "Agents is not allowed to write to " + folder + ", so " + what + " could not be saved. Check who owns it and its permissions, then try again."
	default:
		f.Message = "The disk " + folder + " is on cannot be written to, so " + what + " could not be saved. Use a folder on another disk."
	}
	return f, true
}

// tellRefused tells every client, once an outage, that the disk refused an agent's chat
// lines (storage/writeFailed), so a person sees the disk is full and not only a log does.
func (d *Daemon) tellRefused(id wire.UUID, err error) {
	what := "the newest lines of a chat"
	if a := d.Store.Agent(id); a != nil && a.Title != nil && *a.Title != "" {
		what = "the newest lines of " + *a.Title + "’s chat"
	}
	if errors.Is(err, store.ErrHeld) {
		what += " (held until there is space)"
	}
	f, ok := writeFailure(err, what)
	if !ok || !d.toldRefused.CompareAndSwap(false, true) {
		return
	}
	Broadcast(d, wire.NotifyStorageWriteFailed, f)
}

// refusalsOver lets the next refusal be told again once nothing is held.
func (d *Daemon) refusalsOver() {
	if d.toldRefused.Load() && !d.Store.Holding() {
		d.toldRefused.Store(false)
	}
}

// writeHeld writes the chat lines the disk refused, oldest first, if there is space now:
// at each disk check (mac.disk_ok's look) and as the host stops.
func (d *Daemon) writeHeld() {
	still, err := d.Store.WriteHeld()
	if err != nil {
		log.Printf("%d chats still hold lines the disk refused: %v", still, err)
	}
	d.refusalsOver()
}
