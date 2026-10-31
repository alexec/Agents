package agentsd

import (
	"encoding/json"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// Agents' own lease calls, through the app's tools: lease_resource takes a resource,
// extends it, or joins its line, and answers at once; a place in line is an event wait on
// lease.granted (#2361, leasewaits.go), so the grant's event starts the agent again.
// release_resource gives it back or leaves the line; list_resources says the caller's own
// first, then the declared ones, then the rest. The words are LeaseWords'.

const (
	leaseCappedWords = " That is the longest a lease can run; extend it again before then if you need more."
	leaseEmptyName   = "Nothing was leased: say which resource."
	leaseNoCall      = "That conversation is not open any more, so nothing was leased."
)

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

func extendedWords(l wire.Lease, capped bool) string {
	s := "You still hold " + l.DisplayName + ", now until " + clock(l.ExpiresAt) + "."
	if capped {
		s += leaseCappedWords
	}
	return s
}

func inLineWords(held string, place int) string {
	return held + ". You are " + ordinal(place) + " in line. You will get a lease.granted event when it is yours. " +
		"End your turn, and you will be started again with it."
}

func notWaitingInLineWords(held string, place int) string {
	return held + ". You are " + ordinal(place) + " in line."
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
	reply := ""
	var events []leaseEvent
	queued := false
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
			queued = wait
		} else if wait {
			e.Line = append(e.Line, waiter{AgentID: agent, AskedAt: t, Minutes: minutes})
			place = len(e.Line)
			queued = true
		}
	}
	d.store(name, e)
	held := d.heldWords(name, e.DisplayName)
	switch {
	case reply != "":
	case queued:
		reply = inLineWords(held, place)
	case place > 0:
		reply = notWaitingInLineWords(held, place)
	default:
		reply = held + ". You are not in line."
	}
	if len(events) > 0 || queued {
		d.leasesChanged()
	}
	d.leaseMu.Unlock()
	d.settle(append(loaded, events...))
	if !queued {
		return told + reply, nil
	}
	d.openLineWait(agent, name)
	// Its turn may have come between joining the line and the wait opening: then it holds
	// it, has been started again with the news, and nothing is left to wait for.
	d.leaseMu.Lock()
	var granted *wire.Lease
	if e := d.book.Entries[name]; e != nil {
		if i := holderIndex(e, agent); i >= 0 {
			l := e.Leases[i]
			granted = &l
		}
	}
	d.leaseMu.Unlock()
	if granted != nil {
		if a := d.Store.Agent(agent); a != nil {
			if r, ok := lineWaitResource(a.EventWait, agent); ok && r == name && a.EventWait.Ending == nil {
				d.endWait(agent, "agent", true)
			}
		}
		return told + grantedWords(*granted, false), nil
	}
	return told + reply, nil
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
	left := false
	if e != nil {
		display = e.DisplayName
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
			left = true
			events = append(events, leaseEvent{})
		}
		d.store(name, e)
	}
	if len(events) > 0 {
		d.leasesChanged()
	}
	d.leaseMu.Unlock()
	if a := d.Store.Agent(agent); left && a != nil {
		// Out of the line, its wait for its turn goes too.
		if r, ok := lineWaitResource(a.EventWait, agent); ok && r == name && a.EventWait.Ending == nil {
			d.endWait(agent, "agent", true)
		}
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
