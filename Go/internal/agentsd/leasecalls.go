package agentsd

import (
	"encoding/json"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// Agents' own lease calls, through the app's tools, as DaemonCore+Leases makes them on the
// Swift host: lease_resource takes a resource, extends it, or waits in line for it, the
// call kept open up to leaseWaitLimit and then answered with the place kept (the agent is
// started again when its turn comes); release_resource gives it back or leaves the line;
// list_resources says the caller's own first, then the declared ones, then the rest. The
// words are LeaseWords'.

// leaseWaitLimit is LeaseLimits.waitLimit: how long a lease call may wait in line.
var leaseWaitLimit = 45 * time.Second

const (
	leaseCappedWords = " That is the longest a lease can run; extend it again before then if you need more."
	leaseEmptyName   = "Nothing was leased: say which resource."
	leaseNoCall      = "That conversation is not open any more, so nothing was leased."
)

type openLeaseCall struct {
	answer  chan string
	started time.Time
}

func ordinal(n int) string {
	tens, units := (n/10)%10, n%10
	suffix := "th"
	if tens != 1 {
		switch units {
		case 1:
			suffix = "st"
		case 2:
			suffix = "nd"
		case 3:
			suffix = "rd"
		}
	}
	return strconv.Itoa(n) + suffix
}

func placesWords(n int64) string {
	if n == 1 {
		return "one at a time"
	}
	return fmt.Sprintf("%d at once", n)
}

func grantedWords(l wire.Lease, capped bool) string {
	s := fmt.Sprintf("You hold %s until %s (%d minutes). Release it with release_resource when you are done.",
		l.DisplayName, clock(l.ExpiresAt), leaseMinutes(l.GrantedAt, l.ExpiresAt))
	if capped {
		s += leaseCappedWords
	}
	return s
}

func grantedAfterWaitingWords(l wire.Lease, waited int, capped bool) string {
	s := fmt.Sprintf("%s is yours now, until %s (%d minutes). You waited %d seconds.",
		l.DisplayName, clock(l.ExpiresAt), leaseMinutes(l.GrantedAt, l.ExpiresAt), waited)
	if capped {
		s += leaseCappedWords
	}
	return s
}

func extendedWords(l wire.Lease, capped bool) string {
	s := "You still hold " + l.DisplayName + ", now until " + clock(l.ExpiresAt) + "."
	if capped {
		s += leaseCappedWords
	}
	return s
}

func stillInLineWords(held string, place int) string {
	return held + ". You are " + ordinal(place) + " in line and keep your place. Call lease_resource again to go on waiting, " +
		"or end your turn — you will be started again when it is yours."
}

func leftLineWords(display string) string { return "You left the line for " + display + "." }

func noticeWords(n leaseNotice) string {
	switch {
	case n.Kind.EndedByPerson != nil:
		return "You no longer hold " + n.DisplayName + ": the person ended your lease at " + clock(n.At) + "."
	case n.Kind.Expired != nil:
		return "You no longer hold " + n.DisplayName + ": your lease ran out at " + clock(n.At) + "."
	case n.Kind.EndingSoon != nil:
		return "Your lease on " + n.DisplayName + " ends at " + clock(n.Kind.EndingSoon.ExpiresAt) +
			". Extend it with lease_resource if you still need it."
	}
	return ""
}

func (d *Daemon) holderName(id wire.UUID) string {
	if a := d.Store.Agent(id); a != nil {
		return agentName(a.Title)
	}
	return agentName(nil)
}

// heldWords is DaemonCore.heldWords and LeaseWords.heldBy: who holds a resource, as one in
// its line is told it. Under leaseMu.
func (d *Daemon) heldWords(name wire.ResourceName, display string) string {
	e := d.book.Entries[name]
	var leases []wire.Lease
	places := int64(1)
	if e != nil {
		leases = append(leases, e.Leases...)
		places = max(1, e.Rules.Holders)
	}
	sort.SliceStable(leases, func(i, j int) bool { return leases[i].ExpiresAt < leases[j].ExpiresAt })
	if places <= 1 || len(leases) <= 1 {
		who, until := "another agent", now()
		if len(leases) > 0 {
			who, until = d.holderName(leases[0].Holder), leases[0].ExpiresAt
		}
		return display + " is held by " + who + " until " + clock(until)
	}
	var each []string
	for _, l := range leases {
		each = append(each, d.holderName(l.Holder)+" until "+clock(l.ExpiresAt))
	}
	return fmt.Sprintf("All %d places on %s are held: by %s", places, display, listWords(each))
}

func listWords(each []string) string {
	if len(each) <= 2 {
		return strings.Join(each, " and ")
	}
	return strings.Join(each[:len(each)-1], ", ") + " and " + each[len(each)-1]
}

// takeNotices is what the agent has been left to be told, as the head of its reply.
// Under leaseMu.
func (d *Daemon) takeNotices(agent wire.UUID) string {
	ns := d.book.Notices[string(agent)]
	if len(ns) == 0 {
		return ""
	}
	delete(d.book.Notices, string(agent))
	var lines []string
	for _, n := range ns {
		lines = append(lines, noticeWords(n))
	}
	return strings.Join(lines, "\n") + "\n\n"
}

// resolveResource is ResourceCatalog.resolve on a server: a declared name, the screen, or
// a name of the agent's own. Under leaseMu.
func (d *Daemon) resolveResource(given string) (wire.ResourceName, wire.ResourceKind, string, bool) {
	name, ok := resourceName(given)
	if !ok {
		return "", "", "", false
	}
	for _, r := range d.declared {
		if r.Name == name {
			return name, "named", r.DisplayName, true
		}
	}
	if name == "screen" {
		return name, "screen", "Screen, mouse and keyboard", true
	}
	return name, "named", strings.TrimSpace(given), true
}

func (e *leaseEntry) nextToEnd() *wire.Lease {
	var next *wire.Lease
	for i := range e.Leases {
		if next == nil || e.Leases[i].ExpiresAt < next.ExpiresAt {
			next = &e.Leases[i]
		}
	}
	return next
}

// leaseResource is lease_resource.
func (d *Daemon) leaseResource(agent wire.UUID, args map[string]json.RawMessage) (string, error) {
	given := argString(args, "name")
	if strings.TrimSpace(given) == "" {
		return "", leaseRefused(leaseEmptyName)
	}
	if d.Store.Agent(agent) == nil {
		return "", &Error{Code: CodeNoSuchAgent, Message: leaseNoCall}
	}
	var minutes *int64
	if raw, ok := args["minutes"]; ok {
		var n float64
		var s string
		if json.Unmarshal(raw, &n) == nil {
			m := int64(n)
			minutes = &m
		} else if json.Unmarshal(raw, &s) == nil {
			if m, err := strconv.ParseInt(strings.TrimSpace(s), 10, 64); err == nil {
				minutes = &m
			}
		}
	}
	wait := true
	if raw, ok := args["wait"]; ok {
		json.Unmarshal(raw, &wait)
	}

	d.leaseMu.Lock()
	loaded := d.loadLeases()
	name, kind, display, ok := d.resolveResource(given)
	if !ok {
		d.leaseMu.Unlock()
		return "", leaseRefused(leaseEmptyName)
	}
	told := d.takeNotices(agent)
	e := d.book.Entries[name]
	if e == nil {
		e = &leaseEntry{Kind: kind, DisplayName: display, Rules: standardRules, Line: []waiter{}, Leases: []wire.Lease{}}
		for _, r := range d.declared {
			if r.Name == name {
				e.Rules = rulesOf(r)
			}
		}
	}
	length, capped := e.Rules.length(minutes)
	t := now()
	var waitID *wire.UUID
	if wait {
		id := store.NewUUID()
		waitID = &id
	}
	reply := ""
	var events []leaseEvent
	var superseded *wire.UUID
	park := false
	place := 0
	switch i := holderIndex(e, agent); {
	case i >= 0:
		// Forward only: asking for less than is left does not shorten a lease.
		l := e.Leases[i]
		wanted := t.Time().Add(length)
		if l.ExpiresAt.Time().After(wanted) {
			wanted = l.ExpiresAt.Time()
		}
		ceiling := t.Time().Add(time.Duration(e.Rules.ceiling()) * time.Minute)
		l.ExpiresAt, l.Warned = wire.DateOf(minTime(wanted, ceiling)), false
		e.Leases[i] = l
		events = append(events, leaseEvent{extended: true, lease: l})
		reply = extendedWords(l, capped || wanted.After(ceiling))
	case !e.full() && len(e.Line) == 0:
		l := wire.Lease{Resource: name, DisplayName: e.DisplayName, Holder: agent, GrantedAt: t, ExpiresAt: wire.DateOf(t.Time().Add(length))}
		e.Leases = append(e.Leases, l)
		events = append(events, leaseEvent{granted: true, lease: l})
		reply = grantedWords(l, capped)
	default:
		if j := lineIndex(e, agent); j >= 0 {
			place = j + 1
			if wait {
				superseded = e.Line[j].WaitID
				e.Line[j].WaitID = waitID
				park = true
			}
		} else if wait {
			e.Line = append(e.Line, waiter{AgentID: agent, AskedAt: t, Minutes: minutes, WaitID: waitID})
			place = len(e.Line)
			park = true
		}
	}
	d.store(name, e)
	held := d.heldWords(name, e.DisplayName)
	if !park && reply == "" {
		if place > 0 {
			reply = stillInLineWords(held, place)
		} else {
			reply = held + ". You are not in line."
		}
	}
	var call *openLeaseCall
	if park {
		call = &openLeaseCall{answer: make(chan string, 1), started: time.Now()}
		if d.openLeaseCalls == nil {
			d.openLeaseCalls = map[wire.UUID]*openLeaseCall{}
		}
		d.openLeaseCalls[*waitID] = call
	}
	if len(events) > 0 || park {
		d.leasesChanged()
	}
	var supersededCall *openLeaseCall
	if superseded != nil {
		supersededCall = d.openLeaseCalls[*superseded]
		delete(d.openLeaseCalls, *superseded)
	}
	d.leaseMu.Unlock()
	if supersededCall != nil {
		supersededCall.answer <- stillInLineWords(held, place)
	}
	d.settle(append(loaded, events...))
	if !park {
		return told + reply, nil
	}
	timer := time.AfterFunc(leaseWaitLimit, func() { d.leaseWaitLimitReached(*waitID) })
	defer timer.Stop()
	select {
	case text := <-call.answer:
		return told + text, nil
	case <-d.ctx.Done():
		return told + stillInLineWords(held, place), nil
	}
}

func minTime(a, b time.Time) time.Time {
	if a.Before(b) {
		return a
	}
	return b
}

func holderIndex(e *leaseEntry, agent wire.UUID) int {
	for i, l := range e.Leases {
		if l.Holder == agent {
			return i
		}
	}
	return -1
}

func lineIndex(e *leaseEntry, agent wire.UUID) int {
	for i, w := range e.Line {
		if w.AgentID == agent {
			return i
		}
	}
	return -1
}

// leaseWaitLimitReached is waitLimitReached: the call has waited as long as a call may. It
// answers with the place, which is kept.
func (d *Daemon) leaseWaitLimitReached(waitID wire.UUID) {
	d.leaseMu.Lock()
	call := d.openLeaseCalls[waitID]
	if call == nil {
		d.leaseMu.Unlock()
		return
	}
	delete(d.openLeaseCalls, waitID)
	text := ""
	for name, e := range d.book.Entries {
		for i := range e.Line {
			if e.Line[i].WaitID != nil && *e.Line[i].WaitID == waitID {
				e.Line[i].WaitID = nil
				text = stillInLineWords(d.heldWords(name, e.DisplayName), i+1)
			}
		}
	}
	d.leasesChanged()
	d.leaseMu.Unlock()
	if text == "" {
		text = leftLineWords("It")
	}
	call.answer <- text
}

// answerLeaseCall answers an open call with a grant: true when there was one to answer.
func (d *Daemon) answerLeaseCall(w *waiter, l wire.Lease, capped bool) bool {
	if w == nil || w.WaitID == nil {
		return false
	}
	d.leaseMu.Lock()
	call := d.openLeaseCalls[*w.WaitID]
	delete(d.openLeaseCalls, *w.WaitID)
	d.leaseMu.Unlock()
	if call == nil {
		return false
	}
	call.answer <- grantedAfterWaitingWords(l, int(time.Since(call.started).Round(time.Second).Seconds()), capped)
	return true
}

// releaseResource is release_resource: give it back, or leave the line.
func (d *Daemon) releaseResource(agent wire.UUID, args map[string]json.RawMessage) (string, error) {
	given := argString(args, "name")
	if strings.TrimSpace(given) == "" {
		return "", leaseRefused("Nothing was released: say which resource, in `name`.")
	}
	if d.Store.Agent(agent) == nil {
		return "", &Error{Code: CodeNoSuchAgent, Message: leaseNoCall}
	}
	d.leaseMu.Lock()
	loaded := d.loadLeases()
	name, _, display, _ := d.resolveResource(given)
	told := d.takeNotices(agent)
	e := d.book.Entries[name]
	var events []leaseEvent
	reply := "You neither hold nor are waiting for " + display + "; nothing changed."
	var own *openLeaseCall
	if e != nil {
		display = e.DisplayName
		if j := lineIndex(e, agent); j >= 0 && e.Line[j].WaitID != nil {
			own = d.openLeaseCalls[*e.Line[j].WaitID]
			delete(d.openLeaseCalls, *e.Line[j].WaitID)
		}
		if i := holderIndex(e, agent); i >= 0 {
			l := e.Leases[i]
			e.Leases = append(e.Leases[:i], e.Leases[i+1:]...)
			events = append(events, leaseEvent{released: true, lease: l, ending: "released"})
			handed := d.handOn(name, e)
			events = append(events, handed...)
			reply = "Released " + l.DisplayName + "."
			if len(handed) > 0 {
				reply = "Released " + l.DisplayName + ". It has gone to " + d.holderName(handed[0].lease.Holder) + "."
			}
		} else if j := lineIndex(e, agent); j >= 0 {
			e.Line = append(e.Line[:j], e.Line[j+1:]...)
			reply = leftLineWords(display)
			events = append(events, leaseEvent{})
		}
		d.store(name, e)
	}
	if len(events) > 0 {
		d.leasesChanged()
	}
	d.leaseMu.Unlock()
	if own != nil {
		own.answer <- leftLineWords(display)
	}
	var said []leaseEvent
	for _, ev := range append(loaded, events...) {
		if ev.granted || ev.released || ev.extended {
			said = append(said, ev)
		}
	}
	d.settle(said)
	return told + reply, nil
}

// stateWords is "free.", "held by you until 14:05.", "2 of 3 held: by you until 14:05 and
// “Fix login” until 14:20; 1 waiting."
func (d *Daemon) stateWords(s wire.ResourceState, caller wire.UUID) string {
	places := int64(1)
	if s.Places != nil {
		places = int64(*s.Places)
	}
	if len(s.Holds) == 0 {
		if places > 1 {
			return fmt.Sprintf("free (0 of %d held).", places)
		}
		return "free."
	}
	var who []string
	for _, l := range s.Holds {
		name := d.holderName(l.Holder)
		if l.Holder == caller {
			name = "you"
		}
		who = append(who, name+" until "+clock(l.ExpiresAt))
	}
	count := "held by "
	if places > 1 {
		count = fmt.Sprintf("%d of %d held: by ", len(s.Holds), places)
	}
	tail := "."
	if len(s.Line) > 0 {
		tail = fmt.Sprintf("; %d waiting.", len(s.Line))
	}
	return count + listWords(who) + tail
}

// listResources is list_resources: the caller's own first, then everything this host has.
func (d *Daemon) listResources(agent wire.UUID, _ map[string]json.RawMessage) (string, error) {
	if d.Store.Agent(agent) == nil {
		return "", &Error{Code: CodeNoSuchAgent, Message: leaseNoCall}
	}
	d.leaseMu.Lock()
	loaded := d.loadLeases()
	told := d.takeNotices(agent)
	var lines []string
	var held, waits []string
	names := make([]string, 0, len(d.book.Entries))
	for n := range d.book.Entries {
		names = append(names, string(n))
	}
	sort.Strings(names)
	for _, n := range names {
		e := d.book.Entries[wire.ResourceName(n)]
		if i := holderIndex(e, agent); i >= 0 {
			l := e.Leases[i]
			held = append(held, "- Holding "+l.DisplayName+" ("+n+") until "+clock(l.ExpiresAt)+".")
		}
		if j := lineIndex(e, agent); j >= 0 {
			waits = append(waits, "- Waiting for "+e.DisplayName+" ("+n+"): "+d.heldWords(wire.ResourceName(n), e.DisplayName)+
				"; you are "+ordinal(j+1)+".")
		}
	}
	if len(held)+len(waits) > 0 {
		lines = append(append(append([]string{"Yours:"}, held...), waits...), "")
	}
	states := d.leaseSnapshot().Resources
	var declared []string
	for _, s := range states {
		if s.Declared != nil {
			declared = append(declared, "- "+string(s.Name)+" ("+placesWords(s.Declared.Holders)+"): "+s.Declared.Description+
				" — "+d.stateWords(s, agent))
		}
	}
	if len(declared) > 0 {
		lines = append(append(append(lines, "Declared by the person. Lease one whenever its description applies to what you are about to do:"),
			declared...), "")
	}
	lines = append(lines, "On this Mac:")
	for _, s := range states {
		if s.Declared != nil {
			continue
		}
		label := string(s.Name) + " — " + s.DisplayName
		if s.Kind == "named" {
			label = s.DisplayName + " (named by an agent)"
		}
		gone := ""
		if s.IsGone {
			gone = " (gone from this Mac)"
		}
		lines = append(lines, "- "+label+gone+": "+d.stateWords(s, agent))
	}
	d.leaseMu.Unlock()
	d.settle(loaded)
	return told + strings.Join(lines, "\n"), nil
}

// argString is a tool's string argument, or "".
func argString(args map[string]json.RawMessage, key string) string {
	var s string
	json.Unmarshal(args[key], &s)
	return s
}
