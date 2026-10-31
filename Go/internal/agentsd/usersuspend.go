package agentsd

import (
	"encoding/json"
	"log"
	"os"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// A suspended person on their machine (#1002, spec 1002 slice 2b, FR-018). When the
// person's org provider suspends them, the control plane tells each of their machines
// user/suspended, at hello before their settings and within 5 seconds of the change. The
// machine then stops the person's running turns (as the T5 kill switch does, for its one
// user), pauses their workflows and queued prompts, refuses new work and the window's
// direct path (#1118), and keeps every agent, conversation and file. user/suspended
// {off: true} ends the pause, and starts nothing by itself.
//
// The state is kept in <root>/suspended.json, so a restart keeps it until the control
// plane says otherwise. A machine that is offline runs on until it connects (hosts never
// escalate; the control plane cannot reach it), and then hears the state before anything.

const userSuspendedFile = "suspended.json"

// suspendedWords is what the person's clients and chats show (FR-029).
const suspendedWords = "Your organisation's sign-in turned your access off."

type userSuspendState struct {
	suspendRead bool
	// suspendNow is the suspension in force here, or nil. Under orgMu.
	suspendNow *wire.UserSuspended
}

// readSuspensionLocked reads <root>/suspended.json the first time.
func (d *Daemon) readSuspensionLocked() {
	if d.suspendRead {
		return
	}
	d.suspendRead = true
	b, err := os.ReadFile(d.orgPath(userSuspendedFile))
	if err != nil {
		return
	}
	var kept wire.UserSuspended
	if json.Unmarshal(b, &kept) != nil || kept.User == "" {
		log.Printf("user/suspended: %s cannot be read; not suspended", userSuspendedFile)
		return
	}
	d.suspendNow = &kept
}

// suspension is the suspension in force here, or nil.
func (d *Daemon) suspension() *wire.UserSuspended {
	d.orgMu.Lock()
	defer d.orgMu.Unlock()
	d.readSuspensionLocked()
	return d.suspendNow
}

// toldUserSuspended is user/suspended: the person suspended, or (off) no longer.
func (d *Daemon) toldUserSuspended(params json.RawMessage) {
	var note wire.UserSuspended
	if err := json.Unmarshal(params, &note); err != nil || note.User == "" {
		log.Printf("user/suspended: %v", err)
		return
	}
	off := note.Off != nil && *note.Off
	d.orgMu.Lock()
	d.readSuspensionLocked()
	was := d.suspendNow != nil
	if off {
		d.suspendNow = nil
		if err := os.Remove(d.orgPath(userSuspendedFile)); err != nil && !os.IsNotExist(err) {
			log.Printf("user/suspended: remove %s: %v", userSuspendedFile, err)
		}
	} else {
		b, _ := json.Marshal(note)
		if err := store.WriteAtomically(d.orgPath(userSuspendedFile), b, 0o600); err != nil {
			// Applied all the same: the control plane says it again at the next hello.
			log.Printf("user/suspended: keep %s: %v", userSuspendedFile, err)
		}
		d.suspendNow = &note
	}
	d.orgMu.Unlock()
	if was == !off {
		return
	}
	if off {
		log.Printf("user/suspended: %s is no longer suspended; nothing starts by itself", note.User)
	} else {
		log.Printf("user/suspended: %s was suspended by %s; stopping their work", note.User, note.Provider)
		d.stopEveryTurn("Stopped. " + suspendedWords)
		d.closeLocalWindows()
	}
	d.markEveryAgent()
	d.tellPolicyState()
}

// suspensionRefusal is why this machine starts no work now: its person is suspended. Nil
// otherwise.
func (d *Daemon) suspensionRefusal() error {
	s := d.suspension()
	if s == nil {
		return nil
	}
	return &Error{Code: wire.FailurePersonSuspended, Message: suspendedWords, Data: map[string]string{"provider": s.Provider}}
}

// closeLocalWindows cuts off every window on the direct path (#1118).
func (d *Daemon) closeLocalWindows() {
	d.localMu.Lock()
	conns := make([]*sockConn, 0, len(d.localConns))
	for sc := range d.localConns {
		conns = append(conns, sc)
	}
	d.localMu.Unlock()
	for _, sc := range conns {
		sc.Close()
	}
}
