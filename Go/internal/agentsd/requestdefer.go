package agentsd

import (
	"context"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// Later (#4233, epic #4232): a person defers an open request to a time, or until they are
// next at the Mac. It stays open and its waiters keep waiting, but it is not a need: no
// banner, no push, no widget row, until it comes back. Then it is a need again, first seen
// now, so it alerts once as a new request does, and request.opened is raised again.
// The deferral is in the record file, so a restart keeps it.

// deferRequest is requests/defer. A request deferred again takes the new deferral.
func (d *Daemon) deferRequest(r wire.RequestsDefer, by *wire.AuditActor) (wire.RequestUpdate, error) {
	atMac := r.AtMac != nil && *r.AtMac
	if r.Until == nil && !atMac {
		return wire.RequestUpdate{}, Invalid("Say when it comes back: until, atMac or both.")
	}
	at := now()
	if r.Until != nil && !r.Until.Time().After(at.Time()) {
		return wire.RequestUpdate{}, Invalid("Pick a time after now.")
	}
	d.requests.mu.Lock()
	rec := d.requests.byID[r.ID]
	if rec == nil {
		d.requests.mu.Unlock()
		return wire.RequestUpdate{}, &Error{Code: wire.FailureNoSuchAgent, Message: "There is no such request."}
	}
	if rec.State != wire.RequestStateOpen {
		c := copyRequest(rec)
		d.requests.mu.Unlock()
		return wire.RequestUpdate{}, &Error{Code: wire.FailureNoSuchAgent, Message: "That request has ended already.", Data: wire.RequestUpdate{Request: c}}
	}
	def := &wire.RequestDeferral{Until: r.Until, At: at, By: by}
	if atMac {
		def.AtMac = new(true)
	}
	rec.Deferred = def
	d.saveRequestLocked(rec)
	c := copyRequest(rec)
	d.requests.mu.Unlock()
	Broadcast(d, wire.NotifyRequestsChanged, wire.RequestUpdate{Request: c})
	extra := map[string]string{}
	if r.Until != nil {
		extra["until"] = r.Until.Time().UTC().Format(time.RFC3339)
	}
	if atMac {
		extra["atMac"] = "true"
	}
	d.raiseRequestEvent("request.deferred", c, extra, by)
	d.armRequestTimer()
	d.reconsider() // its banner and its push go
	return wire.RequestUpdate{Request: c}, nil
}

// undeferRequest is requests/undefer: Bring back now.
func (d *Daemon) undeferRequest(r wire.RequestsUndefer, by *wire.AuditActor) (wire.RequestUpdate, error) {
	rec := d.request(r.ID)
	if rec == nil {
		return wire.RequestUpdate{}, &Error{Code: wire.FailureNoSuchAgent, Message: "There is no such request."}
	}
	if rec.State != wire.RequestStateOpen {
		return wire.RequestUpdate{}, &Error{Code: wire.FailureNoSuchAgent, Message: "That request has ended already.", Data: wire.RequestUpdate{Request: *rec}}
	}
	d.bringBackRequests(func(*wire.Request) bool { return true }, &r.ID, by)
	if after := d.request(r.ID); after != nil {
		return wire.RequestUpdate{Request: *after}, nil
	}
	return wire.RequestUpdate{Request: *rec}, nil
}

// bringBackRequests clears the deferral of every open request that due says has come back
// (or only of id), and raises request.opened for each, as a new request does.
func (d *Daemon) bringBackRequests(due func(*wire.Request) bool, id *wire.UUID, by *wire.AuditActor) {
	d.requests.mu.Lock()
	var back []wire.Request
	for _, r := range d.requests.byID {
		if r.State != wire.RequestStateOpen || r.Deferred == nil || id != nil && r.ID != *id || !due(r) {
			continue
		}
		r.Deferred = nil
		d.saveRequestLocked(r)
		back = append(back, copyRequest(r))
	}
	d.requests.mu.Unlock()
	if len(back) == 0 {
		return
	}
	for _, c := range back {
		Broadcast(d, wire.NotifyRequestsChanged, wire.RequestUpdate{Request: c})
		d.raiseRequestEvent("request.opened", c, nil, by)
	}
	d.armRequestTimer()
	d.reconsider() // a need again, first seen now: it alerts once
}

// requestDeferred is whether an open request is in Later: not a need until it comes back.
func (d *Daemon) requestDeferred(id wire.UUID) bool {
	d.requests.mu.Lock()
	defer d.requests.mu.Unlock()
	r := d.requests.byID[id]
	return r != nil && r.State == wire.RequestStateOpen && r.Deferred != nil
}

// macCameBack brings back every request deferred until the person is at the Mac. Called
// when the Mac's presence changes from not here to here, so one deferred while the person
// was at the Mac waits for the next time they come back to it.
func (d *Daemon) macCameBack() {
	d.bringBackRequests(func(r *wire.Request) bool { return r.Deferred.AtMac != nil && *r.Deferred.AtMac }, nil, nil)
}

// armRequestTimer aims one timer at the earliest until of a deferred request; when it
// fires, every request whose time has come is brought back.
func (d *Daemon) armRequestTimer() {
	d.requests.mu.Lock()
	defer d.requests.mu.Unlock()
	if d.requests.timer != nil {
		d.requests.timer.Stop()
		d.requests.timer = nil
	}
	var next *time.Time
	for _, r := range d.requests.byID {
		if r.State == wire.RequestStateOpen && r.Deferred != nil && r.Deferred.Until != nil {
			if t := r.Deferred.Until.Time(); next == nil || t.Before(*next) {
				next = &t
			}
		}
	}
	if next == nil || d.ctx.Err() != nil {
		return
	}
	d.requests.timer = time.AfterFunc(max(0, time.Until(*next))+20*time.Millisecond, func() {
		if d.ctx.Err() != nil {
			return
		}
		at := time.Now()
		d.bringBackRequests(func(r *wire.Request) bool {
			return r.Deferred.Until != nil && !r.Deferred.Until.Time().After(at)
		}, nil, nil)
		d.armRequestTimer()
	})
}

func (d *Daemon) stopRequestTimer() {
	d.requests.mu.Lock()
	defer d.requests.mu.Unlock()
	if d.requests.timer != nil {
		d.requests.timer.Stop()
		d.requests.timer = nil
	}
}

func (d *Daemon) registerRequestDefer() {
	On(d, wire.CallRequestsDefer, func(ctx context.Context, c *Client, r wire.RequestsDefer) (wire.RequestUpdate, error) {
		return d.deferRequest(r, c.actor())
	})
	On(d, wire.CallRequestsUndefer, func(ctx context.Context, c *Client, r wire.RequestsUndefer) (wire.RequestUpdate, error) {
		return d.undeferRequest(r, c.actor())
	})
}
