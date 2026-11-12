package agentsd

import (
	"fmt"
	"strings"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// Leases that follow the machine's capacity (#4579, epic #4584). A compute resource (the
// built-in capacity, and the declared or named build) is answered by count and by the
// machine's level: while the level is near or full, a new grant goes in line even when a
// place is free, and the reply says why. Holders are not disturbed: they keep and extend
// what they hold. When the level is ok again, the line is served one grant per look at
// the machine (15 s), oldest first, so a burst does not push the machine back to full at
// once. The person's booking, the browser, the screen and the simulators are not compute
// and never wait for capacity.

const (
	// capacityResource is the built-in resource to lease before heavy work that no
	// declared resource names. Its places are the level's, not a count.
	capacityResource wire.ResourceName = "capacity"
	// buildResource is the resource this folder declares for builds and tests.
	buildResource wire.ResourceName = "build"
)

// capacityRules is the capacity lease's: as many at once as any resource can have, so only
// the level holds it.
var capacityRules = leaseRules{Holders: mostHolders}

// capacityDisplay is the capacity lease's name for a person: "Capacity of this Mac".
func capacityDisplay() string { return "Capacity of " + thisMachine() }

// isCompute is whether a grant of the resource follows the machine's level.
func isCompute(name wire.ResourceName) bool {
	return name == capacityResource || name == buildResource
}

// capacityState is the lease side of capacity, kept under leaseMu.
type capacityState struct {
	// capDraining is set while a compute line waits for the machine: from when the level
	// first holds a grant back until the line is served, one grant per look, after the
	// level is ok again. While it is set, no other compute grant goes past the line.
	capDraining bool
}

// computeHeld is why a new compute grant waits now, as a sentence with no full stop, or ""
// when it does not. Under leaseMu.
func (d *Daemon) computeHeld() string {
	d.capMu.Lock()
	level, s := d.capLevel, d.capSample
	d.capMu.Unlock()
	switch level {
	case wire.CapacityLevelNear, wire.CapacityLevelFull:
		words := "near capacity"
		if level == wire.CapacityLevelFull {
			words = "at capacity"
		}
		_, signal := capacityTarget(s)
		return sentenceMachine() + " is " + words + " (" + signalWords(signal, s) + ")"
	}
	if d.capDraining {
		return fmt.Sprintf("%s has capacity again, and its line is served one agent every %d seconds",
			sentenceMachine(), int(capacityEvery.Seconds()))
	}
	return ""
}

// heldByCapacity is whether e's next grant waits for the machine, and notes that a line
// waits when it does. Under leaseMu.
func (d *Daemon) heldByCapacity(name wire.ResourceName, e *leaseEntry) bool {
	if !isCompute(name) || d.computeHeld() == "" {
		return false
	}
	if !e.full() && len(e.Line) > 0 {
		d.capDraining = true
	}
	return true
}

// noteCapacityLine sets capDraining when a compute line has a free place, as a book read
// from disk can: those waited for the machine before the restart. Under leaseMu.
func (d *Daemon) noteCapacityLine() {
	for name, e := range d.book.Entries {
		if isCompute(name) && !e.full() && len(e.Line) > 0 {
			d.capDraining = true
		}
	}
}

// serveCapacityLine is the line's side of a look at the machine: while the level is ok and
// a compute line waits, the oldest waiter with a free place gets its grant, one a look.
func (d *Daemon) serveCapacityLine() {
	if d.capacityLevel() != wire.CapacityLevelOk {
		return
	}
	d.leaseMu.Lock()
	// A book not read yet is read by the first lease call, which notes its line then.
	if d.book == nil || !d.capDraining {
		d.leaseMu.Unlock()
		return
	}
	var name wire.ResourceName
	var next *leaseEntry
	var oldest time.Time
	for n, e := range d.book.Entries {
		if !isCompute(n) || e.full() || len(e.Line) == 0 {
			continue
		}
		if at := e.Line[0].AskedAt.Time(); next == nil || at.Before(oldest) || (at.Equal(oldest) && n < name) {
			name, next, oldest = n, e, at
		}
	}
	if next == nil {
		d.capDraining = false
		d.leaseMu.Unlock()
		return
	}
	events := []leaseEvent{d.grantNext(name, next)}
	d.store(name, next)
	d.leasesChanged()
	d.leaseMu.Unlock()
	d.settle(events)
}

// capacityStateWords is the capacity lease in list_resources: what it is for, and whether
// a lease is granted now. Under leaseMu.
func (d *Daemon) capacityStateWords(s wire.ResourceState, caller wire.UUID) string {
	words := "lease it before heavy work that no declared resource names (a long test suite, a Chromium, a simulator, a script that builds) — "
	if why := d.computeHeld(); why != "" {
		words += "in line now: " + lowerFirst(why)
	} else {
		words += "granted now: " + thisMachine() + " has capacity"
	}
	held := 0
	for _, l := range s.Holds {
		if l.Holder == caller {
			words += "; you hold it until " + clock(l.ExpiresAt)
		} else {
			held++
		}
	}
	switch {
	case held == 1:
		words += "; one other agent holds it"
	case held > 1:
		words += fmt.Sprintf("; %d other agents hold it", held)
	}
	if len(s.Line) > 0 {
		words += fmt.Sprintf("; %d waiting", len(s.Line))
	}
	return words + "."
}

func lowerFirst(s string) string {
	if s == "" {
		return s
	}
	return strings.ToLower(s[:1]) + s[1:]
}

// capacityWait is why e's line waits for the machine, not for a holder, for its row in the
// lease snapshot (#4748): "this Mac is near capacity", or "this Mac has capacity again"
// while the line is served one a look. "" when it waits for a holder, or not at all. The
// words have no numbers, so the snapshot moves with the level, not with every look.
// Under leaseMu.
func (d *Daemon) capacityWait(name wire.ResourceName, e *leaseEntry) string {
	if e == nil || !isCompute(name) || e.full() || len(e.Line) == 0 || d.computeHeld() == "" {
		return ""
	}
	if w := capacityLevelWords(d.capacityLevel()); w != "" {
		return w
	}
	return thisMachine() + " has capacity again"
}

// capacityWaitMoved says resources/changed when the level moved under a compute line, so
// its reason is new (#4748).
func (d *Daemon) capacityWaitMoved() {
	d.leaseMu.Lock()
	defer d.leaseMu.Unlock()
	if d.book == nil {
		return
	}
	for name, e := range d.book.Entries {
		if isCompute(name) && !e.full() && len(e.Line) > 0 {
			d.leasesChanged()
			return
		}
	}
}
