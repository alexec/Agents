package agentsd

import (
	"fmt"

	"github.com/alexec/agents/Go/wire"
)

// Start now (#5156): a person starts a queued session at once, as Send now sends a queued
// prompt at once. It is the person's own click, so it goes past the folder's running limit
// (the queue does not move again until running is under it), and past the machine's
// capacity hold too, but never past the total: a not-archived place must be free. The rest
// of the queue keeps its order. An agent never gets it: agents/startNow is not in
// agentMethods, and no app tool calls it.

// startNow holds the session's place at once and starts it off this call, as the queue
// does; the chat says how it went.
func (d *Daemon) startNow(id wire.UUID) error {
	a := d.Store.Agent(id)
	if a == nil {
		return noSuchAgent()
	}
	if a.State != wire.AgentStateQueued || a.StartedByAgent == nil {
		return nil // started already, or taken off the queue: nothing to do
	}
	folder := folderPath(a)
	q, err := d.holdStartNow(*a, folder)
	if err != nil || q == nil {
		return err
	}
	d.record(q.ID, runtimeNote("You started it now, ahead of the queue."))
	if !d.goAfterTurn("start now", func() { d.startQueued(*q, folder) }) {
		d.startQueued(*q, folder)
	}
	return nil
}

// holdStartNow is nextFromQueue for one session the person names: its place held, or why
// not. Nil with no error when the queue is starting it already.
func (d *Daemon) holdStartNow(a wire.Agent, folder string) (*wire.Agent, error) {
	d.countProject(folder)
	_, notArchived, _ := d.helperLimitsIn(folder)
	d.queueMu.Lock()
	defer d.queueMu.Unlock()
	if d.startingFromQueue[a.ID] {
		return nil, nil
	}
	scope := limitScope(folder)
	reserved := d.reservedHelpers[scope]
	if have := len(d.helpersIn(folder)) + reserved; int64(have) >= notArchived {
		// Said after the client's "Could not start it now — ".
		return nil, &Error{Code: wire.FailureNotAllowed, Message: fmt.Sprintf(
			"%s has %d of %d sessions not archived, and Send now never starts a session past that. "+
				"Archive one of the sessions agents started, or raise the limit in Project Settings.", scopeTitle(folder), have, notArchived)}
	}
	if d.startingFromQueue == nil {
		d.startingFromQueue = map[wire.UUID]bool{}
	}
	if d.reservedHelpers == nil {
		d.reservedHelpers = map[string]int{}
	}
	d.startingFromQueue[a.ID] = true
	d.reservedHelpers[scope]++
	return &a, nil
}
