package agentsd

import (
	"context"
	"fmt"
	"log"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/diskjson"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// Resource leases (036), as the Swift host keeps them (LeaseBook, DaemonCore+Leases): one
// book in <root>/leases.json of who holds what and who waits, the person's declared
// resources in <root>/resources.json, and resources/changed whenever either moves.

const (
	leaseDefaultMinutes = 30
	leaseMaximumMinutes = 240
	leaseWarning        = 5 * time.Minute
	mostHolders         = 20
)

type leaseRules struct {
	Holders        int64  `json:"holders"`
	DefaultMinutes *int64 `json:"defaultMinutes,omitempty"`
	MaximumMinutes *int64 `json:"maximumMinutes,omitempty"`
}

var standardRules = leaseRules{Holders: 1}

func (r leaseRules) ceiling() int64 {
	if r.MaximumMinutes != nil {
		return min(*r.MaximumMinutes, leaseMaximumMinutes)
	}
	return leaseMaximumMinutes
}

// length is LeaseRules.length: what was asked, else the usual length, within the ceiling.
func (r leaseRules) length(minutes *int64) (time.Duration, bool) {
	asked := int64(leaseDefaultMinutes)
	if r.DefaultMinutes != nil {
		asked = *r.DefaultMinutes
	}
	asked = min(asked, r.ceiling())
	if minutes != nil {
		asked = *minutes
	}
	asked = max(1, asked)
	given := min(asked, r.ceiling())
	return time.Duration(given) * time.Minute, asked > given
}

// waiter is a place in line. Its wait is the agent's event wait (#2361); a book from
// before that has a waitID, which is read and dropped.
type waiter struct {
	AgentID wire.UUID  `json:"agentID"`
	AskedAt wire.Date  `json:"askedAt"`
	Minutes *int64     `json:"minutes,omitempty"`
	WaitID  *wire.UUID `json:"waitID,omitempty"`
}

type leaseEntry struct {
	Kind        wire.ResourceKind `json:"kind"`
	DisplayName string            `json:"displayName"`
	Leases      []wire.Lease      `json:"leases"`
	Line        []waiter          `json:"line"`
	Rules       leaseRules        `json:"rules"`
}

func (e *leaseEntry) full() bool { return int64(len(e.Leases)) >= max(1, e.Rules.Holders) }

// leaseNotice is LeaseNotice: told to its agent at its next lease call. kind is
// {"endedByPerson":{}}, {"expired":{}} or {"endingSoon":{"expiresAt":…}}.
type leaseNotice struct {
	Resource    wire.ResourceName `json:"resource"`
	DisplayName string            `json:"displayName"`
	Kind        noticeKind        `json:"kind"`
	At          wire.Date         `json:"at"`
}

type noticeKind struct {
	EndedByPerson *struct{} `json:"endedByPerson,omitempty"`
	Expired       *struct{} `json:"expired,omitempty"`
	EndingSoon    *struct {
		ExpiresAt wire.Date `json:"expiresAt"`
	} `json:"endingSoon,omitempty"`
}

type leaseBook struct {
	Entries map[wire.ResourceName]*leaseEntry `json:"entries"`
	Notices map[string][]leaseNotice          `json:"notices"`
}

// leaseEvent is what the book did, for settle to say.
type leaseEvent struct {
	granted, released, extended bool
	lease                       wire.Lease
	waiter                      *waiter
	ending                      string // released: released, expired, endedByPerson, holderStopped, holderArchived, couldNotStart
}

type leaseState struct {
	leaseMu   sync.Mutex
	book      *leaseBook
	declared  []wire.DeclaredResource
	leaseTick *time.Timer
}

func resourceName(given string) (wire.ResourceName, bool) {
	k := strings.ToLower(strings.TrimSpace(given))
	return wire.ResourceName(k), k != ""
}

func (d *Daemon) leasesFile() string    { return filepath.Join(d.Store.Loc.Root, "leases.json") }
func (d *Daemon) resourcesFile() string { return filepath.Join(d.Store.Loc.Root, "resources.json") }

// loadLeases reads the book and the declarations once. A place in line keeps its place;
// its wait is on the agent's record (reconcileLineWaits).
func (d *Daemon) loadLeases() []leaseEvent {
	if d.book != nil {
		return nil
	}
	d.book = &leaseBook{Entries: map[wire.ResourceName]*leaseEntry{}, Notices: map[string][]leaseNotice{}}
	if b, err := os.ReadFile(d.leasesFile()); err == nil {
		var raw struct {
			Entries map[wire.ResourceName]struct {
				leaseEntry
				Lease *wire.Lease `json:"lease"`
			} `json:"entries"`
			Notices map[string][]leaseNotice `json:"notices"`
		}
		if err := diskjson.Unmarshal(b, &raw); err == nil {
			for name, e := range raw.Entries {
				entry := e.leaseEntry
				if entry.Leases == nil && e.Lease != nil { // a book from before many holders
					entry.Leases = []wire.Lease{*e.Lease}
				}
				if entry.Rules.Holders < 1 {
					entry.Rules = standardRules
				}
				for i := range entry.Line {
					entry.Line[i].WaitID = nil
				}
				d.book.Entries[name] = &entry
			}
			if raw.Notices != nil {
				d.book.Notices = raw.Notices
			}
		} else {
			log.Printf("leases: could not read %s: %v", d.leasesFile(), err)
		}
	}
	if b, err := os.ReadFile(d.resourcesFile()); err == nil {
		diskjson.Unmarshal(b, &d.declared)
	}
	var events []leaseEvent
	for _, r := range d.declared {
		events = append(events, d.setRules(r.Name, rulesOf(r))...)
	}
	return append(events, d.lapse(now().Time())...)
}

func rulesOf(r wire.DeclaredResource) leaseRules {
	return leaseRules{Holders: max(1, r.Holders), DefaultMinutes: r.DefaultMinutes, MaximumMinutes: r.MaximumMinutes}
}

func (d *Daemon) saveLeases() {
	b, err := diskjson.Marshal(d.book)
	if err == nil {
		err = store.WriteAtomically(d.leasesFile(), b, 0o644)
	}
	if err != nil {
		log.Printf("leases: could not save: %v", err)
	}
}

func (d *Daemon) store(name wire.ResourceName, e *leaseEntry) {
	if len(e.Leases) == 0 && len(e.Line) == 0 {
		delete(d.book.Entries, name)
	} else {
		d.book.Entries[name] = e
	}
}

func (d *Daemon) leaveNotice(n leaseNotice, agent wire.UUID) {
	d.book.Notices[string(agent)] = append(d.book.Notices[string(agent)], n)
}

// handOn gives free places to the line, first come first served.
func (d *Daemon) handOn(name wire.ResourceName, e *leaseEntry) []leaseEvent {
	var events []leaseEvent
	for !e.full() && len(e.Line) > 0 {
		next := e.Line[0]
		e.Line = e.Line[1:]
		length, _ := e.Rules.length(next.Minutes)
		t := now()
		l := wire.Lease{Resource: name, DisplayName: e.DisplayName, Holder: next.AgentID, GrantedAt: t,
			ExpiresAt: wire.DateOf(t.Time().Add(length))}
		e.Leases = append(e.Leases, l)
		events = append(events, leaseEvent{granted: true, lease: l, waiter: &next})
	}
	return events
}

func (d *Daemon) setRules(name wire.ResourceName, rules leaseRules) []leaseEvent {
	e := d.book.Entries[name]
	if e == nil || e.Rules == rules {
		return nil
	}
	e.Rules = rules
	events := d.handOn(name, e)
	d.store(name, e)
	return events
}

// lapse ends what has run out and warns once of what is about to.
func (d *Daemon) lapse(at time.Time) []leaseEvent {
	var events []leaseEvent
	for name, e := range d.book.Entries {
		var kept []wire.Lease
		for _, l := range e.Leases {
			if !l.ExpiresAt.Time().After(at) {
				d.leaveNotice(leaseNotice{Resource: name, DisplayName: l.DisplayName, Kind: noticeKind{Expired: &struct{}{}}, At: wire.DateOf(at)}, l.Holder)
				events = append(events, leaseEvent{released: true, lease: l, ending: "expired"})
				continue
			}
			if !l.Warned && l.ExpiresAt.Time().Sub(at) <= leaseWarning {
				l.Warned = true
				k := noticeKind{EndingSoon: &struct {
					ExpiresAt wire.Date `json:"expiresAt"`
				}{l.ExpiresAt}}
				d.leaveNotice(leaseNotice{Resource: name, DisplayName: l.DisplayName, Kind: k, At: wire.DateOf(at)}, l.Holder)
			}
			kept = append(kept, l)
		}
		e.Leases = kept
		events = append(events, d.handOn(name, e)...)
		d.store(name, e)
	}
	return events
}

func (d *Daemon) nextDeadline() (time.Time, bool) {
	var next time.Time
	for _, e := range d.book.Entries {
		for _, l := range e.Leases {
			ts := []time.Time{l.ExpiresAt.Time()}
			if !l.Warned {
				ts = append(ts, l.ExpiresAt.Time().Add(-leaseWarning))
			}
			for _, t := range ts {
				if next.IsZero() || t.Before(next) {
					next = t
				}
			}
		}
	}
	return next, !next.IsZero()
}

// leasesChanged saves the book, says resources/changed and aims the timer at what is next.
// Called with leaseMu held.
func (d *Daemon) leasesChanged() {
	d.saveLeases()
	snap := d.leaseSnapshot()
	safe.Go("resources/changed", func() { Broadcast(d, wire.NotifyResourcesChanged, snap) })
	if d.leaseTick != nil {
		d.leaseTick.Stop()
		d.leaseTick = nil
	}
	if at, ok := d.nextDeadline(); ok {
		d.leaseTick = time.AfterFunc(max(0, time.Until(at))+50*time.Millisecond, func() {
			d.leaseMu.Lock()
			events := d.lapse(now().Time())
			d.leasesChanged()
			d.leaseMu.Unlock()
			d.settle(events)
		})
	}
}

func clock(d wire.Date) string { return d.Time().Local().Format("15:04") }

func leaseMinutes(from, to wire.Date) int {
	return max(1, int(math.Round(to.Time().Sub(from.Time()).Minutes())))
}

// settle is DaemonCore.settle: notes in the holders' records, and lease.granted for each
// grant, which wakes the agent's wait for it (#2361). One whose turn came while nothing
// waited for it (its wait replaced, or open over a restart without it) is started again
// with the event all the same, so a lease never sits unused until it runs out.
func (d *Daemon) settle(events []leaseEvent) {
	for _, e := range events {
		l := e.lease
		waited := e.granted && e.waiter != nil && d.waitsForGrant(l.Holder, l.Resource)
		raised := d.raiseLeaseEvent(e)
		switch {
		case e.granted && e.waiter != nil && !waited && raised != nil:
			d.record(l.Holder, runtimeNote("Leased "+l.DisplayName+" until "+clock(l.ExpiresAt)+"."))
			ev := *raised
			safe.Go("lease wake", func() { d.wake(l, ev) })
		case e.extended:
			d.record(l.Holder, runtimeNote("Extended the lease on "+l.DisplayName+" to "+clock(l.ExpiresAt)+"."))
		case e.granted:
			d.record(l.Holder, runtimeNote("Leased "+l.DisplayName+" until "+clock(l.ExpiresAt)+"."))
		case e.released:
			var note string
			switch e.ending {
			case "released":
				note = "Released " + l.DisplayName + "."
			case "expired":
				note = "The lease on " + l.DisplayName + " ran out at " + clock(now()) + "."
			case "endedByPerson":
				note = "You ended this agent's lease on " + l.DisplayName + "."
			case "holderStopped":
				note = "Let go of " + l.DisplayName + " when it was stopped."
			case "holderArchived":
				note = "Let go of " + l.DisplayName + " when it was archived."
			}
			if note != "" {
				d.record(l.Holder, runtimeNote(note))
			}
		}
	}
}

// heldNowWords is what a woken holder is told after the event: how long it is its.
func heldNowWords(l wire.Lease) string {
	return fmt.Sprintf("You hold %s until %s (%d minutes). Carry on with what you needed it for, and release it with "+
		"release_resource when you are done.", l.DisplayName, clock(l.ExpiresAt), leaseMinutes(l.GrantedAt, l.ExpiresAt))
}

// wake starts an agent whose turn came while nothing waited for it, with the event as a
// wait's wake says it. One that cannot be started passes the lease on.
func (d *Daemon) wake(l wire.Lease, e wire.Event) {
	err := d.promptFromApp(l.Holder, wakeWords(e, 0)+"\n\n"+heldNowWords(l))
	if err == nil {
		return
	}
	reason := err.Error()
	if e, ok := err.(*Error); ok {
		reason = e.Message
	}
	d.leaseMu.Lock()
	var events []leaseEvent
	if e := d.book.Entries[l.Resource]; e != nil {
		for i, held := range e.Leases {
			if held.Holder == l.Holder {
				e.Leases = append(e.Leases[:i], e.Leases[i+1:]...)
				events = append(events, leaseEvent{released: true, lease: held, ending: "couldNotStart"})
				events = append(events, d.handOn(l.Resource, e)...)
				d.store(l.Resource, e)
				break
			}
		}
	}
	d.leasesChanged()
	d.leaseMu.Unlock()
	d.record(l.Holder, runtimeNote(l.DisplayName+" came to this agent but it could not be started ("+reason+"), so it was passed on."))
	d.settle(events)
}

// promptFromApp queues the app's own words for an agent.
func (d *Daemon) promptFromApp(id wire.UUID, text string) error {
	a := d.Store.Agent(id)
	if a == nil {
		return noSuchAgent()
	}
	return d.enqueue(id, wire.QueuedPrompt{ID: store.NewUUID(), Text: text, QueuedAt: now(), From: wire.PromptOriginApp}, false)
}

// dropLeases lets go of everything an agent holds or waits for, as it stops or is archived.
func (d *Daemon) dropLeases(agent wire.UUID, ending string) {
	d.leaseMu.Lock()
	events := d.loadLeases()
	moved := false
	for name, e := range d.book.Entries {
		for i, w := range e.Line {
			if w.AgentID == agent {
				e.Line = append(e.Line[:i], e.Line[i+1:]...)
				moved = true
				break
			}
		}
		for i, l := range e.Leases {
			if l.Holder == agent {
				e.Leases = append(e.Leases[:i], e.Leases[i+1:]...)
				events = append(events, leaseEvent{released: true, lease: l, ending: ending})
				events = append(events, d.handOn(name, e)...)
				moved = true
				break
			}
		}
		d.store(name, e)
	}
	delete(d.book.Notices, string(agent))
	if moved {
		d.leasesChanged()
	}
	d.leaseMu.Unlock()
	d.settle(events)
}

// leaseSnapshot is buildLeaseSnapshot: declared resources first, then what this host
// finds (its screen), then any other the book names. Called with leaseMu held.
func (d *Daemon) leaseSnapshot() wire.LeaseSnapshot {
	at := now()
	var rows []wire.ResourceState
	drawn := map[wire.ResourceName]bool{}
	row := func(name wire.ResourceName, kind wire.ResourceKind, display string, gone bool, declared *wire.DeclaredResource) wire.ResourceState {
		e := d.book.Entries[name]
		r := wire.ResourceState{Name: name, Kind: kind, DisplayName: display, IsGone: gone, Declared: declared, Line: []wire.LineMember{}}
		places := int64(1)
		if e != nil {
			r.DisplayName = e.DisplayName
			// A copy: the snapshot is sent off this lock while the book moves on.
			r.Holds = append([]wire.Lease{}, e.Leases...)
			places = max(1, e.Rules.Holders)
			for _, w := range e.Line {
				// Open: its wait for lease.granted is open, so the event starts it (#2361).
				open := false
				if a := d.Store.Agent(w.AgentID); a != nil && a.EventWait != nil && a.EventWait.Ending == nil {
					res, ok := lineWaitResource(a.EventWait, w.AgentID)
					open = ok && res == name
				}
				r.Line = append(r.Line, wire.LineMember{AgentID: w.AgentID, AskedAt: w.AskedAt, IsCallOpen: open})
			}
			for _, l := range e.Leases {
				if l.ExpiresAt > at && l.ExpiresAt.Time().Sub(at.Time()) <= leaseWarning {
					r.EndingSoon = true
				}
			}
		}
		if declared != nil {
			r.DisplayName = declared.DisplayName
			places = declared.Holders
		}
		if len(r.Holds) > 0 {
			first := r.Holds[0]
			r.Lease = &first
		}
		p := float64(places)
		r.Places = &p
		return r
	}
	for i := range d.declared {
		dr := d.declared[i]
		rows = append(rows, row(dr.Name, "named", dr.DisplayName, false, &dr))
		drawn[dr.Name] = true
	}
	if !drawn["screen"] {
		rows = append(rows, row("screen", "screen", "Screen, mouse and keyboard", false, nil))
		drawn["screen"] = true
	}
	for name, e := range d.book.Entries {
		if !drawn[name] {
			rows = append(rows, row(name, e.Kind, e.DisplayName, e.Kind != "named", nil))
		}
	}
	order := map[wire.ResourceKind]int{"screen": 0, "simulator": 1, "browser": 2, "named": 3}
	sort.SliceStable(rows, func(i, j int) bool {
		a, b := rows[i], rows[j]
		if (a.Declared == nil) != (b.Declared == nil) {
			return a.Declared != nil
		}
		if order[a.Kind] != order[b.Kind] {
			return order[a.Kind] < order[b.Kind]
		}
		if !strings.EqualFold(a.DisplayName, b.DisplayName) {
			return strings.ToLower(a.DisplayName) < strings.ToLower(b.DisplayName)
		}
		return a.Name < b.Name
	})
	if rows == nil {
		rows = []wire.ResourceState{}
	}
	return wire.LeaseSnapshot{Resources: rows, At: at}
}

func leaseRefused(msg string) error { return &Error{Code: wire.FailureLeaseRefused, Message: msg} }

// declaredProblem is DeclaredResource.problem.
func declaredProblem(r wire.DeclaredResource) string {
	switch {
	case strings.TrimSpace(r.DisplayName) == "":
		return "Give it a name."
	case r.Name == "screen" || strings.HasPrefix(string(r.Name), "simulator:") || strings.HasPrefix(string(r.Name), "browser:"):
		return r.DisplayName + " is found on the Mac by itself; choose another name."
	case strings.TrimSpace(r.Description) == "":
		return "Say what it is for, so agents know when to take it."
	case r.Holders < 1 || r.Holders > mostHolders:
		return fmt.Sprintf("Between 1 and %d agents may hold it at once.", mostHolders)
	}
	ceiling := int64(leaseMaximumMinutes)
	if r.MaximumMinutes != nil {
		ceiling = *r.MaximumMinutes
	}
	if ceiling < 1 || ceiling > leaseMaximumMinutes {
		return fmt.Sprintf("The longest a lease can run is between 1 and %d minutes.", leaseMaximumMinutes)
	}
	if r.DefaultMinutes != nil && (*r.DefaultMinutes < 1 || *r.DefaultMinutes > ceiling) {
		return fmt.Sprintf("The usual length is between 1 minute and the longest, %d.", ceiling)
	}
	return ""
}

func (d *Daemon) registerLeases() {
	// What an agent calls through the app's tools: a token this host never gave out is
	// not a conversation it has open (the app's tools come later).
	noConversation := func() error {
		return &Error{Code: CodeNoSuchAgent, Message: "That conversation is not open any more, so nothing was leased."}
	}
	On(d, wire.CallResourcesLease, func(ctx context.Context, c *Client, _ wire.LeaseRequest) (wire.LeaseNote, error) {
		return wire.LeaseNote{}, noConversation()
	})
	On(d, wire.CallResourcesRelease, func(ctx context.Context, c *Client, _ wire.LeaseNameRequest) (wire.LeaseNote, error) {
		return wire.LeaseNote{}, noConversation()
	})
	On(d, wire.CallResourcesList, func(ctx context.Context, c *Client, _ wire.LeaseTokenRequest) (wire.LeaseNote, error) {
		return wire.LeaseNote{}, noConversation()
	})
	person := func(f func() ([]leaseEvent, error)) (wire.LeaseSnapshot, error) {
		d.leaseMu.Lock()
		loaded := d.loadLeases()
		events, err := f()
		if err == nil || len(loaded) > 0 {
			d.leasesChanged()
		}
		snap := d.leaseSnapshot()
		d.leaseMu.Unlock()
		d.settle(append(loaded, events...))
		return snap, err
	}
	On(d, wire.CallResourcesSnapshot, func(ctx context.Context, c *Client, _ wire.Empty) (wire.LeaseSnapshot, error) {
		d.leaseMu.Lock()
		loaded := d.loadLeases()
		if len(loaded) > 0 {
			d.leasesChanged()
		}
		snap := d.leaseSnapshot()
		d.leaseMu.Unlock()
		d.settle(loaded)
		return snap, nil
	})
	On(d, wire.CallResourcesEnd, func(ctx context.Context, c *Client, r wire.PersonEndRequest) (wire.LeaseSnapshot, error) {
		return person(func() ([]leaseEvent, error) {
			name, ok := resourceName(r.Name)
			if !ok {
				return nil, leaseRefused("Say which resource to end.")
			}
			var holder wire.UUID
			if r.AgentID != nil && strings.TrimSpace(*r.AgentID) != "" {
				given := strings.ToUpper(strings.TrimSpace(*r.AgentID))
				if !isUUID(given) {
					return nil, leaseRefused("Say which agent's lease to end.")
				}
				holder = wire.UUID(given)
			}
			var events []leaseEvent
			if e := d.book.Entries[name]; e != nil {
				var kept []wire.Lease
				for _, l := range e.Leases {
					if holder == "" || l.Holder == holder {
						d.leaveNotice(leaseNotice{Resource: name, DisplayName: l.DisplayName, Kind: noticeKind{EndedByPerson: &struct{}{}}, At: now()}, l.Holder)
						events = append(events, leaseEvent{released: true, lease: l, ending: "endedByPerson"})
					} else {
						kept = append(kept, l)
					}
				}
				if len(events) > 0 {
					e.Leases = kept
					events = append(events, d.handOn(name, e)...)
					d.store(name, e)
				}
			}
			if len(events) == 0 {
				if holder == "" {
					return nil, leaseRefused("Nobody holds " + r.Name + ".")
				}
				return nil, leaseRefused("That agent does not hold " + r.Name + ".")
			}
			return events, nil
		})
	})
	On(d, wire.CallResourcesRemoveWaiter, func(ctx context.Context, c *Client, r wire.PersonRemoveRequest) (wire.LeaseSnapshot, error) {
		// Out of the line, its wait for its turn ends too, as Stop Waiting's does (#2361).
		defer func() {
			name, _ := resourceName(r.Name)
			agent := wire.UUID(strings.ToUpper(strings.TrimSpace(r.AgentID)))
			if a := d.Store.Agent(agent); a != nil {
				if res, ok := lineWaitResource(a.EventWait, agent); ok && res == name && a.EventWait.Ending == nil {
					d.endWait(agent, "person", true)
				}
			}
		}()
		return person(func() ([]leaseEvent, error) {
			name, ok := resourceName(r.Name)
			agent := strings.ToUpper(strings.TrimSpace(r.AgentID))
			if !ok || !isUUID(agent) {
				return nil, leaseRefused("Say which resource and which agent.")
			}
			display := r.Name
			if e := d.book.Entries[name]; e != nil {
				display = e.DisplayName
				for i, w := range e.Line {
					if w.AgentID == wire.UUID(agent) {
						e.Line = append(e.Line[:i], e.Line[i+1:]...)
						d.store(name, e)
						return nil, nil
					}
				}
			}
			return nil, leaseRefused("That agent is not in line for " + display + ".")
		})
	})
	On(d, wire.CallResourcesDeclare, func(ctx context.Context, c *Client, r wire.DeclareResourceRequest) (wire.LeaseSnapshot, error) {
		return person(func() ([]leaseEvent, error) {
			res := r.Resource
			res.DisplayName = strings.TrimSpace(res.DisplayName)
			res.Description = strings.TrimSpace(res.Description)
			if n, ok := resourceName(string(res.Name)); ok {
				res.Name = n
			}
			if why := declaredProblem(res); why != "" {
				return nil, leaseRefused(why)
			}
			var replacing wire.ResourceName
			if r.Replacing != nil {
				replacing, _ = resourceName(*r.Replacing)
			}
			var list []wire.DeclaredResource
			for _, x := range d.declared {
				if x.Name == res.Name && res.Name != replacing {
					return nil, leaseRefused(res.DisplayName + " is declared already.")
				}
				if x.Name != res.Name && x.Name != replacing {
					list = append(list, x)
				}
			}
			list = append(list, res)
			sort.Slice(list, func(i, j int) bool { return list[i].Name < list[j].Name })
			if err := d.saveDeclared(list); err != nil {
				return nil, leaseRefused("Could not save it: " + err.Error())
			}
			return d.setRules(res.Name, rulesOf(res)), nil
		})
	})
	On(d, wire.CallResourcesRemove, func(ctx context.Context, c *Client, r wire.RemoveResourceRequest) (wire.LeaseSnapshot, error) {
		return person(func() ([]leaseEvent, error) {
			name, _ := resourceName(r.Name)
			var list []wire.DeclaredResource
			found := false
			for _, x := range d.declared {
				if x.Name == name {
					found = true
				} else {
					list = append(list, x)
				}
			}
			if !found {
				return nil, leaseRefused(r.Name + " is not declared.")
			}
			if err := d.saveDeclared(list); err != nil {
				return nil, leaseRefused("Could not save it: " + err.Error())
			}
			return nil, nil
		})
	})
	// While anything is held, the person's view is kept current every minute.
	safe.Go("lease ticker", func() {
		t := time.NewTicker(time.Minute)
		defer t.Stop()
		for {
			select {
			case <-d.ctx.Done():
				return
			case <-t.C:
				d.leaseMu.Lock()
				held := false
				if d.book != nil {
					for _, e := range d.book.Entries {
						held = held || len(e.Leases) > 0
					}
				}
				var snap wire.LeaseSnapshot
				if held {
					snap = d.leaseSnapshot()
				}
				d.leaseMu.Unlock()
				if held {
					Broadcast(d, wire.NotifyResourcesChanged, snap)
				}
			}
		}
	})
}

func (d *Daemon) saveDeclared(list []wire.DeclaredResource) error {
	if list == nil {
		list = []wire.DeclaredResource{}
	}
	b, err := diskjson.Marshal(list)
	if err == nil {
		err = store.WriteAtomically(d.resourcesFile(), b, 0o644)
	}
	if err == nil {
		d.declared = list
	}
	return err
}

func isUUID(s string) bool {
	return len(s) == 36 && strings.Count(s, "-") == 4
}
