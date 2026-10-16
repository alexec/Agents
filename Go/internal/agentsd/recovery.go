package agentsd

import (
	"fmt"
	"sort"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// What a host does with the agents the last one left working (DaemonCore+Recovery): each
// is said to have stopped with the daemon, and then picked back up, most recent first and
// two at a time, with words that say what happened, unless picking it up has taken the
// daemon down three times in a row.

const pickUpsBeforeLeavingAlone = 3

// importedNote is RuntimeNote.imported.
const importedNote = "This agent was made under another Agents set-up and copied here, so it is shown but never run here: its conversation and its folder belong to that set-up."

// refuseToRun is DaemonCore.refuseToRun: an agent copied in from another set-up is never run.
func (d *Daemon) refuseToRun(a *wire.Agent) error {
	if a.MadeInRoot != nil && *a.MadeInRoot != d.Store.RootID {
		return &Error{Code: wire.FailureImportedAgent, Message: importedNote}
	}
	return nil
}

type recoveryState struct {
	resumeMu    sync.Mutex
	interrupted map[wire.UUID]wire.AgentState
	resuming    map[wire.UUID]bool
}

func pickUps(a *wire.Agent) int64 {
	if a.RestartPickUps == nil {
		return 0
	}
	return *a.RestartPickUps
}

func mayBePickedUp(a *wire.Agent) bool {
	return a.State == wire.AgentStateStopped && a.EndedReason != nil && *a.EndedReason == wire.EndedReasonDaemonGone &&
		pickUps(a) < pickUpsBeforeLeavingAlone
}

// recover is DaemonCore.recover's part for agents: called before any client connects.
func (d *Daemon) recover() {
	d.resumeMu.Lock()
	d.interrupted, d.resuming = map[wire.UUID]wire.AgentState{}, map[wire.UUID]bool{}
	d.resumeMu.Unlock()
	var left []wire.Agent
	for _, a := range d.Store.Agents() {
		// Made under another set-up and copied here: shown, never run (stampOrImport).
		if a.State != wire.AgentStateArchived && a.MadeInRoot != nil && *a.MadeInRoot != d.Store.RootID &&
			(a.EndedReason == nil || *a.EndedReason != wire.EndedReasonImported) {
			d.change(a.ID, func(a *wire.Agent) {
				a.State, a.EndedReason = wire.AgentStateStopped, reason(wire.EndedReasonImported)
				a.EventWait, a.PendingMove, a.ArchiveRequest, a.AfterTurn = nil, nil, nil, nil
			})
			d.record(a.ID, runtimeNote(importedNote))
			continue
		}
		switch a.State {
		case wire.AgentStateStarting, wire.AgentStateRunning, wire.AgentStateWaitingOnUser:
			left = append(left, a)
		}
	}
	sort.SliceStable(left, func(i, j int) bool { return left[i].LastActivityAt > left[j].LastActivityAt })
	for _, a := range left {
		if a.State == wire.AgentStateWaitingOnUser {
			d.record(a.ID, runtimeNote(questionWentUnanswered))
		}
		d.record(a.ID, runtimeNote("This agent was working when the daemon stopped, so it stopped too."))
		if n := pickUps(&a); n >= pickUpsBeforeLeavingAlone {
			d.record(a.ID, runtimeNote(fmt.Sprintf("Not picked back up: the app stopped %d times in a row while picking this conversation up, so picking it up may be what stops it. Send it a message to pick it up yourself.", n)))
		}
		after := d.change(a.ID, func(a *wire.Agent) {
			a.State, a.EndedReason, a.ArchivedReason = wire.AgentStateStopped, reason(wire.EndedReasonDaemonGone), nil
		})
		d.record(a.ID, stateChanged(wire.AgentStateStopped, reason(wire.EndedReasonDaemonGone)))
		if after != nil && mayBePickedUp(after) && after.Purpose == nil {
			d.resumeMu.Lock()
			d.interrupted[a.ID] = a.State
			d.resumeMu.Unlock()
		}
	}
}

func (d *Daemon) resumingNow() []wire.UUID {
	d.resumeMu.Lock()
	defer d.resumeMu.Unlock()
	out := []wire.UUID{}
	for id := range d.resuming {
		out = append(out, id)
	}
	return out
}

func wordsAboutTheRestart(was wire.AgentState) string {
	switch was {
	case wire.AgentStateStarting:
		return "(The app restarted before this conversation had begun, so nothing you were asked has reached you until now. There is no history above this — start the work from here.)"
	case wire.AgentStateWaitingOnUser:
		return "(The app restarted while you were waiting for an answer, so the turn you were in the middle of was cut off and the question you had asked went with it. Everything above is still yours. Ask it again if you still need it; otherwise carry on from where you left off, checking what you had actually finished rather than assuming the last thing you tried worked.)"
	}
	return "(The app restarted while you were working, so the turn you were in the middle of was cut off. Everything above is still yours. Carry on from where you left off, checking what you had actually finished rather than assuming the last thing you tried worked.)"
}

// PickUpAfterRestart picks the interrupted agents back up, once the host serves: every one
// said to be resuming at once, then two at a time, most recent first.
func (d *Daemon) PickUpAfterRestart() {
	d.resumeMu.Lock()
	var ids []wire.UUID
	for id := range d.interrupted {
		ids = append(ids, id)
		d.resuming[id] = true
	}
	d.resumeMu.Unlock()
	sort.SliceStable(ids, func(i, j int) bool {
		a, b := d.Store.Agent(ids[i]), d.Store.Agent(ids[j])
		return a != nil && b != nil && a.LastActivityAt > b.LastActivityAt
	})
	for _, id := range ids {
		Broadcast(d, wire.NotifyAgentResuming, wire.ResumingNotification{AgentID: id, IsResuming: true})
	}
	lanes := make(chan struct{}, 2)
	safe.Go("pick up", func() {
		var wg sync.WaitGroup
		for _, id := range ids {
			lanes <- struct{}{}
			wg.Add(1)
			safe.Go("pick up "+string(id), func() {
				defer func() { <-lanes; wg.Done() }()
				d.pickUp(id)
				d.leaveTheQueue(id)
			})
		}
		wg.Wait()
	})
}

func (d *Daemon) leaveTheQueue(id wire.UUID) {
	d.resumeMu.Lock()
	was := d.resuming[id]
	delete(d.resuming, id)
	d.resumeMu.Unlock()
	if was {
		Broadcast(d, wire.NotifyAgentResuming, wire.ResumingNotification{AgentID: id, IsResuming: false})
	}
}

// pickUp sends the restart words first in the agent's queue, as the person's, so what
// they queued goes with them; the count is written before the words go.
func (d *Daemon) pickUp(id wire.UUID) {
	d.resumeMu.Lock()
	was, ok := d.interrupted[id]
	delete(d.interrupted, id)
	d.resumeMu.Unlock()
	a := d.Store.Agent(id)
	if !ok || a == nil || !mayBePickedUp(a) {
		return
	}
	d.change(id, func(a *wire.Agent) {
		n := pickUps(a) + 1
		a.RestartPickUps = &n
	})
	// A sign-in lent to this host went with the last one: said, as a send would be refused.
	if err := d.needsSignIn(a.RuntimeID); err != nil {
		why := err.Error()
		if e, ok := err.(*Error); ok {
			why = e.Message
		}
		d.record(id, runtimeNote("Could not pick this agent back up: "+why+" Send it a message to pick it up yourself."))
		return
	}
	l := d.live(id)
	if was == wire.AgentStateStarting && len(a.QueuedPrompts) > 0 {
		l.kick()
	} else if err := d.enqueue(id, wire.QueuedPrompt{ID: store.NewUUID(), Text: wordsAboutTheRestart(was), QueuedAt: now(),
		From: wire.PromptOriginPerson}, true); err != nil {
		d.record(id, runtimeNote("Could not pick this agent back up: "+err.Error()+" Send it a message to pick it up yourself."))
		return
	}
	// Two at a time: this lane is free once the turn has begun, or the attempt has ended.
	for deadline := time.Now().Add(2 * time.Minute); time.Now().Before(deadline); time.Sleep(100 * time.Millisecond) {
		l.mu.Lock()
		begun, running := l.session != nil && l.inTurn, l.running
		l.mu.Unlock()
		if begun || !running {
			return
		}
	}
}

// clearPickUps is a clean shutdown's: no agent was cut off by it.
func (d *Daemon) clearPickUps() {
	for _, a := range d.Store.Agents() {
		if a.RestartPickUps != nil && *a.RestartPickUps != 0 {
			d.agentMu.Lock()
			if b := d.Store.Agent(a.ID); b != nil {
				b.RestartPickUps = nil
				d.Store.Save(*b)
			}
			d.agentMu.Unlock()
		}
	}
}
