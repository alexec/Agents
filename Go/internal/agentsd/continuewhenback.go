package agentsd

import (
	"context"
	"log"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// A chat paused by a spent allowance carries on when the allowance is back (#1859): the
// person asks for it on the chat, and the chat waits (Agent.ContinueWhenBack, kept on the
// record so a restart still sends it). At the provider's reset time, or the app's next
// check when the provider gave none, it sends continueWhenBackWords in the same chat; so
// does a turn on that runtime that works, or the person marking it available. A turn of
// its own refused again waits again, until the next time. Any other message, Stop or
// Archive takes the wait away.

const continueWhenBackWords = "Your allowance is back. Continue where you left off."

// pausedBySpentAllowance is a chat the wait is for.
func pausedBySpentAllowance(a *wire.Agent) bool {
	return a.State == wire.AgentStateStopped && a.ArchivedAt == nil && a.EndedReason != nil &&
		*a.EndedReason == wire.EndedReasonAllowanceSpent
}

// backAt is when a credential's allowance (key, the agent's account) is expected back: the provider's reset time when it
// said one still ahead (known), else the app's next check, else now for a runtime that is
// not out any more.
func (d *Daemon) backAt(key string) (at time.Time, known bool) {
	d.allowMu.Lock()
	s, ok := d.allowancesLocked()[key]
	d.allowMu.Unlock()
	t := time.Now()
	if !ok || s.Status.Out == nil {
		return t, false
	}
	if u := s.Status.Out.Until; u != nil && u.Time().After(t) {
		return u.Time(), true
	}
	if r := s.Status.Out.RetryAfter; r != nil && r.Time().After(t) {
		return r.Time(), false
	}
	return t, false
}

// continueWhenBack is agents/continueWhenBack.
func (d *Daemon) continueWhenBack(id wire.UUID) (wire.Agent, error) {
	a := d.Store.Agent(id)
	if a == nil {
		return wire.Agent{}, &Error{Code: CodeNoSuchAgent, Message: "no agent " + string(id)}
	}
	if !pausedBySpentAllowance(a) {
		return wire.Agent{}, &Error{Code: CodeInvalidParams, Message: "Only a chat paused by a spent allowance can carry on when it is back."}
	}
	return d.waitForAllowance(id, agentKey(a))
}

func (d *Daemon) waitForAllowance(id wire.UUID, key string) (wire.Agent, error) {
	at, known := d.backAt(key)
	wait := &wire.ContinueWhenBack{At: wire.DateOf(at), ResetKnown: known}
	a := d.change(id, func(a *wire.Agent) { a.ContinueWhenBack = wait })
	if a == nil {
		return wire.Agent{}, &Error{Code: CodeNoSuchAgent, Message: "no agent " + string(id)}
	}
	d.armContinue(id, *wait)
	return *a, nil
}

// cancelContinue is agents/cancelContinue, and what Stop does to a waiting chat.
func (d *Daemon) cancelContinue(id wire.UUID) (wire.Agent, error) {
	a := d.Store.Agent(id)
	if a == nil {
		return wire.Agent{}, &Error{Code: CodeNoSuchAgent, Message: "no agent " + string(id)}
	}
	if a.ContinueWhenBack == nil {
		return *a, nil
	}
	if a = d.change(id, func(a *wire.Agent) { a.ContinueWhenBack = nil }); a == nil {
		return wire.Agent{}, &Error{Code: CodeNoSuchAgent, Message: "no agent " + string(id)}
	}
	return *a, nil
}

// armContinue sends the chat on at wait.At, unless by then it waits for another time or
// not at all.
func (d *Daemon) armContinue(id wire.UUID, wait wire.ContinueWhenBack) {
	safe.Go("continue when back", func() {
		select {
		case <-time.After(time.Until(wait.At.Time())):
		case <-d.ctx.Done():
			return
		}
		d.continueNow(id, &wait)
	})
}

// continueNow sends the chat on, when it still waits (for that time, when one is given).
func (d *Daemon) continueNow(id wire.UUID, expected *wire.ContinueWhenBack) {
	sent := false
	d.change(id, func(a *wire.Agent) {
		w := a.ContinueWhenBack
		if w == nil || (expected != nil && *w != *expected) {
			return
		}
		a.ContinueWhenBack = nil
		if pausedBySpentAllowance(a) {
			sent = true
		}
	})
	if !sent {
		return
	}
	if err := d.enqueue(id, wire.QueuedPrompt{ID: store.NewUUID(), Text: continueWhenBackWords, QueuedAt: now(), From: wire.PromptOriginApp}, false); err != nil {
		log.Printf("agent %s: continue when back: %v", id, err)
	}
}

// allowanceBack sends on every chat waiting for this credential's allowance, its runtime
// and account (a turn that worked, or the person marking it available).
func (d *Daemon) allowanceBack(key string) {
	for _, a := range d.Store.Agents() {
		if a.ContinueWhenBack != nil && agentKey(&a) == key {
			d.continueNow(a.ID, nil)
		}
	}
}

// resumeContinues arms every wait kept on a record over a restart; one already due goes now.
func (d *Daemon) resumeContinues() {
	for _, a := range d.Store.Agents() {
		if w := a.ContinueWhenBack; w != nil {
			d.armContinue(a.ID, *w)
		}
	}
}

// continuesByItself is whether a turn refused for a spent allowance waits at once, with
// nobody to choose Continue (#1918): a workflow's run with `continue-when-back: true`, or a
// helper in a folder whose helpers are set to (HelperLimits.continueWhenBack). A chat the
// person started waits only when the person asks.
func (d *Daemon) continuesByItself(a *wire.Agent) bool {
	folder := folderPath(a)
	if a.StartedByWorkflow != nil {
		d.workflowMu.Lock()
		defer d.workflowMu.Unlock()
		f := d.fileLocked(folder, *a.StartedByWorkflow)
		return f != nil && f.wf.ContinueWhenBack != nil && *f.wf.ContinueWhenBack
	}
	if a.StartedByAgent != nil {
		s, ok := d.summaryFor(folder)
		return ok && s.Folder.HelperLimits != nil && s.Folder.HelperLimits.ContinueWhenBack != nil && *s.Folder.HelperLimits.ContinueWhenBack
	}
	return false
}

// sentToContinue is whether the turn's prompt was the wait's own, so a refusal waits again.
func sentToContinue(sent *wire.QueuedPrompt) bool {
	return sent != nil && sent.From == wire.PromptOriginApp && sent.Text == continueWhenBackWords
}

func (d *Daemon) registerContinueWhenBack() {
	On(d, wire.CallAgentsContinueWhenBack, func(ctx context.Context, c *Client, r wire.AgentRequest) (wire.Agent, error) {
		return d.continueWhenBack(r.AgentID)
	})
	On(d, wire.CallAgentsCancelContinue, func(ctx context.Context, c *Client, r wire.AgentRequest) (wire.Agent, error) {
		return d.cancelContinue(r.AgentID)
	})
}
