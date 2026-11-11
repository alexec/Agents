package agentsd

import (
	"strings"
	"sync"

	"github.com/alexec/agents/Go/wire"
)

// agentMu is held only for a change's read, edit and save (#4509). What a change tells
// (agent.changed, which reads the folder's project from disk, and the lineage) comes after
// the unlock, so a slow tell for one session never holds another session's change. Each
// agent's tells still go out in the order of its saves: a change takes its agent's tell
// lock before agentMu and lets it go after it has told. Lock order: an agent's tell lock,
// then agentMu; nothing that holds agentMu takes a tell lock.

type agentTellState struct {
	agentTellMu sync.Mutex
	// agentTells is each agent's tell lock while a change to it runs, and how many hold
	// or wait for it.
	agentTells map[wire.UUID]*agentTell
	// changeTold runs after a change's save and before it tells; a test's own.
	changeTold func(wire.Agent)
}

type agentTell struct {
	sync.Mutex
	users int
}

// lockAgentTell takes the agent's tell lock; the func it gives back lets it go.
func (d *Daemon) lockAgentTell(id wire.UUID) func() {
	id = wire.UUID(strings.ToUpper(string(id))) // as the store keys it
	d.agentTellMu.Lock()
	if d.agentTells == nil {
		d.agentTells = map[wire.UUID]*agentTell{}
	}
	t := d.agentTells[id]
	if t == nil {
		t = &agentTell{}
		d.agentTells[id] = t
	}
	t.users++
	d.agentTellMu.Unlock()
	t.Lock()
	return func() {
		t.Unlock()
		d.agentTellMu.Lock()
		if t.users--; t.users == 0 {
			delete(d.agentTells, id)
		}
		d.agentTellMu.Unlock()
	}
}
