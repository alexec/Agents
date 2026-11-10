package agentsd

import (
	"log"

	"github.com/alexec/agents/Go/wire"
)

// A session's state in lineage (#4274): each change of an agent's record that moves it from
// one lineage state to another is a change of its session node's state, with its time, so
// the graph says which sessions work, wait or need a person now, and for how long they did.
// The changes all go through change and the records made new (noteLineage), so a turn's
// start and end, a question or an approval, a wait, a stop and an archive each record one;
// a delete records deleted.

// sessionState is an agent's state in lineage. A finished or stopped session waits when the
// host knows it does: an event it waits on, or a block (check_again, or a wait on other
// agents) not cleared. That is so on every runtime, as the host keeps those waits, and a
// runtime that waits in its own way reads as stopped.
func sessionState(a *wire.Agent) wire.LineageSessionStateName {
	switch a.State {
	case wire.AgentStateArchived:
		return wire.LineageSessionStateNameArchived
	case wire.AgentStateWaitingOnUser:
		return wire.LineageSessionStateNameNeedsYou
	case wire.AgentStateStarting, wire.AgentStateRunning:
		return wire.LineageSessionStateNameWorking
	case wire.AgentStateQueued:
		return wire.LineageSessionStateNameWaiting
	}
	if a.EventWait != nil || isOpenBlock(a.Report) {
		return wire.LineageSessionStateNameWaiting
	}
	return wire.LineageSessionStateNameStopped
}

// noteSessionState records a's state in lineage when it is new, or not before's. A writer
// agent is not in lineage.
func (d *Daemon) noteSessionState(before *wire.Agent, a wire.Agent) {
	if a.Purpose != nil {
		return
	}
	state := sessionState(&a)
	if before != nil && sessionState(before) == state {
		return
	}
	d.recordSessionState(a.ID, state)
}

// recordSessionState writes a session's state, off the caller's thread, at the time now.
func (d *Daemon) recordSessionState(id wire.UUID, state wire.LineageSessionStateName) {
	s, at := sessionNode(id), nowFunc()
	d.lineageDo(func() {
		if _, err := d.lineage().SetState(s, state, at); err != nil {
			log.Printf("lineage: %s %s: %v", s.Ref, state, err)
		}
	})
}
