package agentsd

import (
	"encoding/json"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// The person's booking (#4268): person:<name>, a lease that one agent at a time holds for a
// step only the person can do. Its minutes are the agent's estimate of the step, and its
// `by` says when the step stops mattering (a code that runs out), which puts it ahead in
// the line. While an agent holds it, its asks of the person notify as timely.
//
// Each host keeps its own book, so the booking is one per host for now; the control plane
// keeps one line across every machine later.

const personLeasePrefix = "person:"

// isPersonLease says whether an agent named the person's booking: "person", or
// "person:<anything>", as a host has one person.
func isPersonLease(name wire.ResourceName) bool {
	return name == "person" || strings.HasPrefix(string(name), personLeasePrefix)
}

// personLease is the person's booking as the book keeps it: person:<name>, lower-cased,
// with the name from Settings.
func (d *Daemon) personLease() (wire.ResourceName, string) {
	name := personName(readPerson(filepath.Join(d.SettingsDir, "person.json")).Name)
	return wire.ResourceName(personLeasePrefix + strings.ToLower(name)), name + " (the person)"
}

// notePersonHolder keeps who holds the person's booking where the needs read it without
// the lease lock. Called with leaseMu held.
func (d *Daemon) notePersonHolder() {
	var holder *wire.UUID
	for name, e := range d.book.Entries {
		if isPersonLease(name) && len(e.Leases) > 0 {
			h := e.Leases[0].Holder
			holder = &h
		}
	}
	d.personHolder.Store(holder)
}

// holdsPerson says whether this agent holds the person's booking, so its asks are timely.
func (d *Daemon) holdsPerson(agent wire.UUID) bool {
	h := d.personHolder.Load()
	return h != nil && *h == agent
}

// leaseBy is lease_resource's `by`: minutes from now ("5", or 5), a time today ("14:05"),
// or an ISO 8601 time. Nil when none was given or it cannot be read.
func leaseBy(raw json.RawMessage, at time.Time) *wire.Date {
	if len(raw) == 0 {
		return nil
	}
	var n float64
	var s string
	switch {
	case json.Unmarshal(raw, &n) == nil:
	case json.Unmarshal(raw, &s) == nil:
		s = strings.TrimSpace(s)
		if m, err := strconv.ParseFloat(s, 64); err == nil {
			n = m
			break
		}
		if t, err := time.Parse(time.RFC3339, s); err == nil {
			by := wire.DateOf(t)
			return &by
		}
		if t, err := time.ParseInLocation("15:04", s, at.Location()); err == nil {
			y, mo, day := at.Date()
			by := wire.DateOf(time.Date(y, mo, day, t.Hour(), t.Minute(), 0, 0, at.Location()))
			return &by
		}
		return nil
	default:
		return nil
	}
	if n <= 0 {
		return nil
	}
	by := wire.DateOf(at.Add(time.Duration(n * float64(time.Minute))))
	return &by
}

// lineBefore is the line's order: a wait with a `by` before one with none, the earliest
// `by` first, then whoever asked first (#4041).
func lineBefore(a, b waiter) bool {
	if (a.By != nil) != (b.By != nil) {
		return a.By != nil
	}
	if a.By != nil && *a.By != *b.By {
		return *a.By < *b.By
	}
	return a.AskedAt < b.AskedAt
}

// joinLine puts a waiter in its place in the line, and says that place (from 1).
func joinLine(e *leaseEntry, w waiter) int {
	i := 0
	for i < len(e.Line) && !lineBefore(w, e.Line[i]) {
		i++
	}
	e.Line = append(e.Line[:i], append([]waiter{w}, e.Line[i:]...)...)
	return i + 1
}
