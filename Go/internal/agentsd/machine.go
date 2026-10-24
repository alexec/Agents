package agentsd

import (
	"strings"
	"sync"

	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// mac.sleep, mac.wake, person.away and person.back (042 US5, #1368), as
// DaemonCore+EventSources raises them: from agents-watch --machine on a Mac
// (machine_darwin.go), and from nothing elsewhere, where there is no Mac to watch.

// machineChange is MachineChange: "sleep", "wake", or "away"/"back" with why ("locked",
// "idle").
type machineChange struct {
	kind string
	why  string
}

// parseMachineChange reads one of agents-watch's words.
func parseMachineChange(word string) (machineChange, bool) {
	kind, why, _ := strings.Cut(word, ":")
	switch kind {
	case "sleep", "wake":
		return machineChange{kind: kind}, why == ""
	case "away", "back":
		return machineChange{kind: kind, why: why}, why == "locked" || why == "idle"
	}
	return machineChange{}, false
}

type machineBook struct {
	machineMu sync.Mutex
	// machineAfterRestart marks the first look after a restart (#1219): what it hears
	// changed while no host ran, and says so.
	machineAfterRestart bool
	machineStop         func()
}

// personAway is how the person stood when this host last heard, for the next first look.
func (d *Daemon) personAway() string {
	d.eventMu.Lock()
	defer d.eventMu.Unlock()
	if d.eventStateNow.PersonAway == nil {
		return ""
	}
	return *d.eventStateNow.PersonAway
}

// machineFirstLookDone ends the first look: what is heard from now on happened now.
func (d *Daemon) machineFirstLookDone() {
	d.machineMu.Lock()
	d.machineAfterRestart = false
	d.machineMu.Unlock()
}

// machineChanged is DaemonCore.machineChanged: one change, as its event, for every
// folder to hear.
func (d *Daemon) machineChanged(c machineChange) {
	if c.kind == "wake" {
		safe.Go("disk check", d.checkDisk)
	}
	// Kept, so the next host's first look is against it (#1219).
	if c.kind == "away" || c.kind == "back" {
		d.eventMu.Lock()
		if c.kind == "away" {
			why := c.why
			d.eventStateNow.PersonAway = &why
		} else {
			d.eventStateNow.PersonAway = nil
		}
		d.saveEventStateLocked()
		d.eventMu.Unlock()
	}
	d.machineMu.Lock()
	noticed := d.machineAfterRestart
	d.machineMu.Unlock()
	details := map[string]string{}
	if c.why != "" {
		details["why"] = c.why
		if noticed {
			details["noticed"] = "after_restart"
		}
	}
	draft := wire.EventDraft{At: now(), Scope: wire.EventScope{Mac: &struct{}{}}, Details: details}
	locked := c.why == "locked"
	switch {
	case c.kind == "sleep":
		draft.Name, draft.Sentence = "mac.sleep", "This Mac went to sleep."
	case c.kind == "wake":
		draft.Name, draft.Sentence = "mac.wake", "This Mac woke up."
	case c.kind == "away" && locked:
		draft.Name, draft.Sentence = "person.away", "You locked the screen."
	case c.kind == "away":
		draft.Name, draft.Sentence = "person.away", "You stepped away."
	case locked:
		draft.Name, draft.Sentence = "person.back", "You unlocked the screen."
	default:
		draft.Name, draft.Sentence = "person.back", "You came back."
	}
	d.raise(draft)
}
