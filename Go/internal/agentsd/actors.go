package agentsd

import (
	"sync"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/wire"
)

// Who did it (#1751, spec 736 FR-040): the control plane gives each channel the actor of
// the client it opened it for (ChannelOpen.actor, #996), and the events a person's call
// raises carry it into events.jsonl. A client's own word for who it is is never read.
// What an agent, a workflow or the machine does carries none.

// actorOf is the actor the control plane gave a connection; nil on daemon.sock, and from
// a control plane before #996.
func actorOf(conn any) *wire.AuditActor {
	if a, ok := conn.(controllink.Actored); ok {
		return a.Actor()
	}
	return nil
}

// actorBook is the person whose call acted on an agent, until the event it raises (now,
// or later from its turn: agent.started, agent.stopped) takes it.
type actorBook struct {
	actorMu sync.Mutex
	actedBy map[wire.UUID]*wire.AuditActor
	// adminStops are the agents an admin stopped from the Console (#2435), until the
	// turn's ending takes it.
	adminStops map[wire.UUID]bool
}

// noteAdminStop notes whether a stop was an admin's from the Console; a stop that is not
// clears an older one, so the owner's own stop never reads as an admin's.
func (d *Daemon) noteAdminStop(id wire.UUID, byAdmin bool) {
	d.actorMu.Lock()
	defer d.actorMu.Unlock()
	if !byAdmin {
		delete(d.adminStops, id)
		return
	}
	if d.adminStops == nil {
		d.adminStops = map[wire.UUID]bool{}
	}
	d.adminStops[id] = true
}

// takeAdminStop is whether an admin stopped the agent, once.
func (d *Daemon) takeAdminStop(id wire.UUID) bool {
	d.actorMu.Lock()
	defer d.actorMu.Unlock()
	byAdmin := d.adminStops[id]
	delete(d.adminStops, id)
	return byAdmin
}

// actedOn notes that a person's call acted on an agent; a nil actor clears an older one.
func (d *Daemon) actedOn(id wire.UUID, actor *wire.AuditActor) {
	d.actorMu.Lock()
	defer d.actorMu.Unlock()
	if actor == nil {
		delete(d.actedBy, id)
		return
	}
	if d.actedBy == nil {
		d.actedBy = map[wire.UUID]*wire.AuditActor{}
	}
	d.actedBy[id] = actor
}

// takeActor is who acted on an agent by a call, once: the event it raised has it now, so
// a later stop by an agent's tool is never put down to them.
func (d *Daemon) takeActor(id wire.UUID) *wire.AuditActor {
	d.actorMu.Lock()
	defer d.actorMu.Unlock()
	a := d.actedBy[id]
	delete(d.actedBy, id)
	return a
}

// personMade is whether an agent's event is a person's doing, so it names who acted on
// the agent: its start, and a stop, archive or deletion by "you".
func personMade(name string, details map[string]string) bool {
	switch name {
	case "agent.started":
		return true
	case "agent.stopped", "agent.archived":
		return details["by"] == "you"
	case "agent.deleted":
		return details["because"] == "person"
	}
	return false
}

func sameActor(a, b *wire.AuditActor) bool {
	if a == nil || b == nil {
		return a == b
	}
	return a.User == b.User && sameUUID(a.Client, b.Client) && (a.Event == nil) == (b.Event == nil) &&
		(a.Event == nil || *a.Event == *b.Event)
}

func sameUUID(a, b *wire.UUID) bool {
	return a == nil && b == nil || a != nil && b != nil && *a == *b
}
