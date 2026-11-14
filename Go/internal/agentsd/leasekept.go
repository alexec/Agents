package agentsd

import (
	"time"

	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// A kept place (#4041): an agent that lost its place in a line through no act of its own
// goes back in at its first askedAt when it asks again in time. The line stays first come,
// first served; only the time it came is kept.
//
//   - A restart that lost its place keeps the askedAt of its wait (EventWait.Since), until
//     that wait's deadline or leaseKeptWindow from now, whichever is later.
//   - A lease that ran out keeps askedAt = the time it ran out, for leaseKeptWindow: it goes
//     after the agents that were waiting then, and before those that came later.
//
// The book keeps them (leases.json), at most one per agent and resource.

// leaseKeptWindow is how long an agent has to ask again after its lease ran out.
const leaseKeptWindow = 5 * time.Minute

type keptPlace struct {
	Resource wire.ResourceName `json:"resource"`
	AskedAt  wire.Date         `json:"askedAt"`
	Until    wire.Date         `json:"until"`
}

// keepPlace notes a kept place, replacing any other for the same resource. Called with
// leaseMu held.
func (d *Daemon) keepPlace(agent wire.UUID, k keptPlace) {
	if d.book.Kept == nil {
		d.book.Kept = map[string][]keptPlace{}
	}
	list := d.book.Kept[string(agent)]
	for i, x := range list {
		if x.Resource == k.Resource {
			list[i] = k
			return
		}
	}
	d.book.Kept[string(agent)] = append(list, k)
}

// takeKept is the askedAt an agent kept for name, still in time at t, and forgets it.
// Called with leaseMu held.
func (d *Daemon) takeKept(agent wire.UUID, name wire.ResourceName, t wire.Date) (wire.Date, bool) {
	list := d.book.Kept[string(agent)]
	for i, x := range list {
		if x.Resource != name {
			continue
		}
		d.forgetKept(agent, i)
		return x.AskedAt, x.Until.Time().After(t.Time())
	}
	return 0, false
}

func (d *Daemon) forgetKept(agent wire.UUID, i int) {
	list := d.book.Kept[string(agent)]
	list = append(list[:i:i], list[i+1:]...)
	if len(list) == 0 {
		delete(d.book.Kept, string(agent))
	} else {
		d.book.Kept[string(agent)] = list
	}
}

// pruneKept forgets the kept places that are out of time at t. Called with leaseMu held.
func (d *Daemon) pruneKept(at time.Time) {
	for agent, list := range d.book.Kept {
		var kept []keptPlace
		for _, x := range list {
			if x.Until.Time().After(at) {
				kept = append(kept, x)
			}
		}
		if len(kept) == 0 {
			delete(d.book.Kept, agent)
		} else {
			d.book.Kept[agent] = kept
		}
	}
}

// keptUntil is how long a restart's lost place is kept: as long as its wait would have
// lasted, and at least leaseKeptWindow from now.
func keptUntil(w *wire.EventWait, at time.Time) wire.Date {
	until := at.Add(leaseKeptWindow)
	if w != nil && w.Deadline != nil && w.Deadline.Time().After(until) {
		until = w.Deadline.Time()
	}
	return wire.DateOf(until)
}
