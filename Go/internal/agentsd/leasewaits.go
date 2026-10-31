package agentsd

import (
	"math"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// A place in a lease's line is an event wait (#2361): lease_resource answers at once, and
// joining the line opens the agent's wait on lease.granted for itself and that resource,
// the wait wait_for_event makes. The grant's event wakes it, the wait card draws it, and
// Stop Waiting or cancel_wait takes it out of the line. The line is the book's
// (leases.json), the wait the agent's record; both outlive a restart, and
// reconcileLineWaits makes them agree after one.

// leaseLineMinutes is how long the line's wait lasts: as long as a lease may run. When it
// runs out, the agent is started again and is still in line (every wait ends).
var leaseLineMinutes = leaseMaximumMinutes

func linePattern(agent wire.UUID, name wire.ResourceName) waitPattern {
	return waitPattern{name: "lease.granted", filters: map[string][]string{"agent": {string(agent)}, "resource": {string(name)}}}
}

// lineWaitResource is the resource whose line this wait is, when it is a line's wait: one
// pattern, lease.granted, for this agent and one resource.
func lineWaitResource(w *wire.EventWait, agent wire.UUID) (wire.ResourceName, bool) {
	if w == nil || len(w.Patterns) != 1 {
		return "", false
	}
	p := patternOf(w.Patterns[0])
	res, who := p.filters["resource"], p.filters["agent"]
	if p.name != "lease.granted" || len(p.filters) != 2 || len(res) != 1 || len(who) != 1 || who[0] != string(agent) {
		return "", false
	}
	return wire.ResourceName(res[0]), true
}

// waitsForGrant is whether the agent's open wait is answered by its grant of name.
func (d *Daemon) waitsForGrant(agent wire.UUID, name wire.ResourceName) bool {
	a := d.Store.Agent(agent)
	if a == nil || a.EventWait == nil || a.EventWait.Ending != nil {
		return false
	}
	e := wire.Event{Name: "lease.granted", Position: math.MaxInt64, Scope: macScope(),
		Details: map[string]string{"agent": string(agent), "resource": string(name)}}
	return waitMatches(a.EventWait, e)
}

// openLineWait opens the agent's wait for its turn with name, replacing any other wait it
// had; one that waits for it already is kept.
func (d *Daemon) openLineWait(agent wire.UUID, name wire.ResourceName) {
	if a := d.Store.Agent(agent); a != nil {
		if r, ok := lineWaitResource(a.EventWait, agent); ok && r == name && a.EventWait.Ending == nil {
			return
		}
	}
	d.endWait(agent, "agent", true)
	d.eventMu.Lock()
	from := d.eventHead()
	d.eventMu.Unlock()
	at := now()
	deadline := wire.DateOf(at.Time().Add(time.Duration(leaseLineMinutes) * time.Minute))
	w := wire.EventWait{ID: store.NewUUID(), From: from, Deadline: &deadline, Since: at,
		Patterns: []wire.EventPattern{linePattern(agent, name).wire()}}
	d.change(agent, func(a *wire.Agent) { a.EventWait = &w })
	d.tellEvents(nil)
	d.armWaitTimer()
	// The person's view says the place has its wait now.
	d.leaseMu.Lock()
	d.leasesChanged()
	d.leaseMu.Unlock()
}

// leaveLine takes the agent out of name's line, as Stop Waiting or cancel_wait ends its wait.
func (d *Daemon) leaveLine(agent wire.UUID, name wire.ResourceName) {
	d.leaseMu.Lock()
	loaded := d.loadLeases()
	if e := d.book.Entries[name]; e != nil {
		if j := lineIndex(e, agent); j >= 0 {
			e.Line = append(e.Line[:j], e.Line[j+1:]...)
			d.store(name, e)
			d.leasesChanged()
		}
	}
	d.leaseMu.Unlock()
	d.settle(loaded)
}

// reconcileLineWaits makes the book and the waits agree after a restart: a place without
// its wait is still started when its turn comes (settle); a wait without its place ends,
// and the agent is started again and told why.
func (d *Daemon) reconcileLineWaits() {
	// The book is read on first use: only when some wait is for a line.
	found := false
	for _, a := range d.Store.Agents() {
		if _, ok := lineWaitResource(a.EventWait, a.ID); ok && a.EventWait.Ending == nil {
			found = true
		}
	}
	if !found {
		return
	}
	d.leaseMu.Lock()
	loaded := d.loadLeases()
	type orphan struct {
		agent wire.UUID
		name  wire.ResourceName
		held  bool
	}
	var orphans []orphan
	for _, a := range d.Store.Agents() {
		name, ok := lineWaitResource(a.EventWait, a.ID)
		if !ok || a.EventWait.Ending != nil || a.State == wire.AgentStateArchived {
			continue
		}
		e := d.book.Entries[name]
		if e != nil && lineIndex(e, a.ID) >= 0 {
			continue
		}
		orphans = append(orphans, orphan{a.ID, name, e != nil && holderIndex(e, a.ID) >= 0})
	}
	d.leaseMu.Unlock()
	d.settle(loaded)
	for _, o := range orphans {
		if o.held {
			// Its grant came and was told; only the wait was left.
			d.endWait(o.agent, "agent", true)
			continue
		}
		a := d.Store.Agent(o.agent)
		if a == nil || a.EventWait == nil {
			continue
		}
		prompt := wire.QueuedPrompt{ID: store.NewUUID(), Text: lostPlaceWords(o.name), QueuedAt: now(), From: wire.PromptOriginApp,
			Attachments: []wire.Attachment{}}
		ended := *a.EventWait
		ended.Ending = &wire.EventWaitEnding{Cancelled: &wire.EventWaitEndingCancelled{By: "agent"}}
		ended.ResumePromptID = &prompt.ID
		d.change(o.agent, func(a *wire.Agent) {
			a.EventWait = &ended
			a.QueuedPrompts = append(append([]wire.QueuedPrompt{}, a.QueuedPrompts...), prompt)
		})
		id := o.agent
		safe.Go("lease line lost", func() { d.sendEventResume(id, prompt.ID, nil) })
	}
	if len(orphans) > 0 {
		d.tellEvents(nil)
		d.armWaitTimer()
	}
}

func lostPlaceWords(name wire.ResourceName) string {
	return "Your wait for your turn with " + string(name) + " ended: when Agents started again, you were no longer in its line. " +
		"Call lease_resource again if you still need it."
}
