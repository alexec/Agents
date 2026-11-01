package agentsd

import (
	"encoding/json"
	"fmt"
	"math"
	"sort"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// Waiting on other agents (039, #481, #1915), as DaemonCore+Blocks keeps it on the Swift host:
// wait_for_agents ends the turn waiting, with a block naming them on the report;
// as each ends its wait closes, and when they have (all, or any with wake_on any) or the
// time to check again comes, the agent is started again with what they said.

const (
	blockMinutesLow  = 1
	blockMinutesHigh = 1440
)

func isOpenBlock(r *wire.WorkReport) bool {
	return r != nil && r.Outcome == wire.WorkOutcomeWaiting && (r.Block == nil || r.Block.ClearedAt == nil)
}

func blockRefusal(why string) error { return Invalid("Nothing was recorded: %s", why) }

// hasEnded is DaemonCore.hasEnded: how an agent has already ended, or "".
func (d *Daemon) hasEnded(a *wire.Agent) string {
	switch a.State {
	case wire.AgentStateStarting, wire.AgentStateRunning, wire.AgentStateWaitingOnUser, wire.AgentStateQueued:
		return ""
	case wire.AgentStateArchived:
		return "archived"
	case wire.AgentStateStopped:
		if a.EndedReason != nil {
			if s, ok := endedSummary[*a.EndedReason]; ok {
				return strings.ToLower(s)
			}
		}
		return "stopped"
	}
	l := d.live(a.ID)
	l.mu.Lock()
	busy := l.running || l.inTurn
	l.mu.Unlock()
	if isOpenBlock(a.Report) || len(a.QueuedPrompts) > 0 || busy {
		return ""
	}
	if a.Report == nil {
		return "finished without saying how it went"
	}
	return strings.ToLower(headings[a.Report.Outcome]) + " — " + a.Report.Message
}

func agentListing(as []wire.Agent) string {
	var each []string
	for _, a := range as {
		each = append(each, string(a.ID)+": "+quotedTitle(a.Title))
	}
	return strings.Join(each, ", ")
}

// waitTarget is the agent a name means, in the caller's folder.
func (d *Daemon) waitTarget(name string, caller *wire.Agent) (*wire.Agent, error) {
	folder := folderPath(caller)
	var target *wire.Agent
	if isUUID(name) {
		if found := d.Store.Agent(wire.UUID(strings.ToUpper(name))); found != nil {
			if folderPath(found) != folder {
				return nil, blockRefusal(name + " is in another folder. You can only wait on agents in this one.")
			}
			target = found
		}
	}
	// One it started on another machine (#2927).
	if target == nil && (!isUUID(name) || d.Store.Agent(wire.UUID(strings.ToUpper(name))) == nil) {
		if there, err := d.waitThere(name, caller.ID); there != nil || err != nil {
			return there, err
		}
	}
	if target == nil {
		var here, matches []wire.Agent
		for _, a := range d.Store.Agents() {
			if folderPath(&a) == folder && a.State != wire.AgentStateArchived {
				here = append(here, a)
				if a.Title != nil && strings.EqualFold(strings.TrimSpace(*a.Title), name) {
					matches = append(matches, a)
				}
			}
		}
		byAge := func(as []wire.Agent) []wire.Agent {
			sort.SliceStable(as, func(i, j int) bool { return as[i].CreatedAt < as[j].CreatedAt })
			return as
		}
		switch len(matches) {
		case 1:
			target = &matches[0]
		case 0:
			var known []wire.Agent
			for _, a := range here {
				if a.ID != caller.ID {
					known = append(known, a)
				}
			}
			if len(known) == 0 {
				return nil, blockRefusal("no agent in this folder is called “" + name + "”. There are no other agents here.")
			}
			return nil, blockRefusal("no agent in this folder is called “" + name + "”. The agents here are: " + agentListing(byAge(known)) + ".")
		default:
			return nil, blockRefusal("“" + name + "” could be any of " + agentListing(byAge(matches)) + ". Use the id.")
		}
	}
	if target.ID == caller.ID {
		return nil, blockRefusal("you can't wait on yourself.")
	}
	if how := d.hasEnded(target); how != "" {
		return nil, blockRefusal(quotedTitle(target.Title) + " has already ended (" + how + "). Use what it said rather than waiting on it.")
	}
	return target, nil
}

// circle is a path from the targets back to the caller through open blocks, or nil.
func (d *Daemon) circle(caller wire.UUID, targets []wire.UUID) []wire.UUID {
	open := func(id wire.UUID) []wire.UUID {
		a := d.Store.Agent(id)
		if id == caller || a == nil || !isOpenBlock(a.Report) || a.Report.Block == nil {
			return nil
		}
		var out []wire.UUID
		for _, w := range a.Report.Block.Waits {
			if w.Ending == nil {
				out = append(out, w.AgentID)
			}
		}
		return out
	}
	for _, start := range targets {
		seen := map[wire.UUID]bool{}
		stack := [][]wire.UUID{{start}}
		for len(stack) > 0 {
			path := stack[len(stack)-1]
			stack = stack[:len(stack)-1]
			for _, next := range open(path[len(path)-1]) {
				if next == caller {
					return path
				}
				if !seen[next] {
					seen[next] = true
					stack = append(stack, append(append([]wire.UUID{}, path...), next))
				}
			}
		}
	}
	return nil
}

func (d *Daemon) waitName(w wire.Wait) string {
	if a := d.Store.Agent(w.AgentID); a != nil && a.Title != nil && strings.TrimSpace(*a.Title) != "" {
		return strings.TrimSpace(*a.Title)
	}
	return w.NameAtReport
}

// blockedNote is what the agent is told of the block it recorded.
func (d *Daemon) blockedNote(b *wire.Block) string {
	var named []string
	for _, w := range b.Waits {
		named = append(named, "“"+d.waitName(w)+"”")
	}
	// Every new block names agents or a time (until_minutes is required), so it is always
	// under Waiting (#2045).
	note := "Recorded. The person will see this conversation under \"Waiting\"."
	switch {
	case len(named) == 1:
		note += " You will be resumed when " + named[0] + " has finished"
	case len(named) > 1 && b.WakeOn != nil && *b.WakeOn == wire.BlockWakeOnAny:
		note += " You will be resumed once, when the first of " + strings.Join(named[:len(named)-1], ", ") + " or " + named[len(named)-1] + " has finished"
	case len(named) > 1:
		note += " You will be resumed when " + strings.Join(named[:len(named)-1], ", ") + " and " + named[len(named)-1] + " have all finished"
	}
	if b.CheckAgainAt != nil {
		minutes := max(1, int(math.Round(time.Until(b.CheckAgainAt.Time()).Minutes())))
		if len(named) == 0 {
			note += fmt.Sprintf(" You will be resumed in %d minutes.", minutes)
		} else {
			note += fmt.Sprintf(", or in %d minutes, whichever comes first.", minutes)
		}
	} else if len(named) > 0 {
		note += "."
	}
	if len(named) == 0 && b.CheckAgainAt == nil {
		note += " Nothing will resume you until the person carries you on."
	}
	return note
}

// waitForAgents is wait_for_agents: the turn ends waiting on the named sessions.
func (d *Daemon) waitForAgents(caller wire.UUID, args map[string]json.RawMessage) (string, error) {
	list, err := stringList(args, "agents")
	if err != nil {
		return "", err
	}
	var names []string
	for _, n := range list {
		if n = strings.TrimSpace(n); n != "" {
			names = append(names, n)
		}
	}
	if len(names) == 0 {
		return "", Invalid("Nothing is waited for: name the sessions in agents, by id or exact title.")
	}
	var minutes *int
	if n, ok := argInt(args, "until_minutes"); ok {
		minutes = &n
	}
	return d.waitOn(caller, names, argString(args, "wake_on"), minutes, argString(args, "message"), "until_minutes")
}

// checkAgain is check_again: the turn ends waiting until in_minutes.
func (d *Daemon) checkAgain(caller wire.UUID, args map[string]json.RawMessage) (string, error) {
	var minutes *int
	if n, ok := argInt(args, "in_minutes"); ok {
		minutes = &n
	}
	return d.waitOn(caller, nil, "", minutes, argString(args, "message"), "in_minutes")
}

// waitOn ends the turn waiting on named sessions, or on a time alone.
func (d *Daemon) waitOn(caller wire.UUID, names []string, wakeOn string, minutes *int, message, minutesKey string) (string, error) {
	me := d.Store.Agent(caller)
	if me == nil {
		return "", &Error{Code: CodeNoSuchAgent, Message: "That conversation is not open any more, so nothing is waited for."}
	}
	if minutes == nil {
		if minutesKey == "in_minutes" {
			return "", Invalid("Nothing is waited for: in_minutes is required: say how many minutes until you resume, from %d to %d.", blockMinutesLow, blockMinutesHigh)
		}
		return "", Invalid("Nothing is waited for: %s", deadlineRequiredWords())
	}
	if *minutes < blockMinutesLow || *minutes > blockMinutesHigh {
		return "", Invalid("Nothing is waited for: %s has to be a whole number from %d to %d.", minutesKey, blockMinutesLow, blockMinutesHigh)
	}
	var wake *wire.BlockWakeOn
	switch wakeOn {
	case "":
	case "any", "all":
		w := wire.BlockWakeOn(wakeOn)
		wake = &w
	default:
		return "", Invalid("Nothing was recorded: wake_on has to be any or all.")
	}
	if a := me.AfterTurn; a != nil && *a == wire.AfterTurnArchive {
		return "", Invalid("Nothing is waited for: you asked to be archived once this turn ends, and an archived run is never woken.")
	}
	l := d.live(caller)
	if l.asking() {
		return "", Invalid("Nothing was recorded: you have a question waiting to be answered, so this work is not over. Answer it first, or let it be answered.")
	}
	if strings.TrimSpace(message) == "" {
		if len(names) == 0 {
			message = fmt.Sprintf("Waiting, to check again in %d minutes.", *minutes)
		} else {
			message = "Waiting for other agents to finish."
		}
	}
	at := now()
	block := wire.Block{Waits: []wire.Wait{}}
	for _, n := range names {
		if n = strings.TrimSpace(n); n == "" {
			continue
		}
		t, err := d.waitTarget(n, me)
		if err != nil {
			return "", err
		}
		dup := false
		for _, w := range block.Waits {
			dup = dup || w.AgentID == t.ID
		}
		if !dup {
			name := "Untitled"
			if t.Title != nil {
				name = *t.Title
			}
			block.Waits = append(block.Waits, wire.Wait{AgentID: t.ID, NameAtReport: name})
		}
	}
	var ids []wire.UUID
	for _, w := range block.Waits {
		ids = append(ids, w.AgentID)
	}
	if path := d.circle(caller, ids); path != nil {
		var ns []string
		for _, id := range path {
			if a := d.Store.Agent(id); a != nil {
				ns = append(ns, quotedTitle(a.Title))
			}
		}
		return "", blockRefusal("waiting on " + ns[0] + " would close a circle: " + strings.Join(ns, " waits on ") + " waits on you.")
	}
	check := wire.DateOf(at.Time().Add(time.Duration(*minutes) * time.Minute))
	block.CheckAgainAt = &check
	if wake != nil && *wake == wire.BlockWakeOnAny && len(block.Waits) > 0 {
		block.WakeOn = wake
	}
	// Only one of EventWait and an open Block is ever current (#3094): the chat draws one
	// card at the foot of the chat, not both.
	prevWait := d.endWait(caller, "agent", true)
	report := wire.WorkReport{Outcome: wire.WorkOutcomeWaiting, Message: strings.TrimSpace(message), At: at, Block: &block}
	d.record(caller, wire.TranscriptEntryKind{WorkReported: &wire.TranscriptEntryKindWorkReported{Value: report}})
	l.mu.Lock()
	l.reported = true
	l.mu.Unlock()
	d.change(caller, func(a *wire.Agent) { a.Report = &report })
	d.reconsider()
	var waiting []string
	for _, w := range block.Waits {
		waiting = append(waiting, "“"+d.waitName(w)+"”")
	}
	if len(waiting) == 0 {
		d.raiseAgentEvent("agent.waiting", caller, "is waiting.", nil)
	} else {
		anyOf := ""
		if block.WakeOn != nil && len(block.Waits) > 1 {
			anyOf = "any of "
		}
		joined := strings.Join(waiting, ", ")
		d.raiseAgentEvent("agent.waiting", caller, "is waiting for "+anyOf+joined+" to finish.", map[string]string{"waiting_on": joined})
	}
	d.armBlockTimer()
	note := d.blockedNote(&block)
	if prevWait != nil {
		note = replacedWords(prevWait) + note
	}
	return note, nil
}

// waitEndingHow is how an agent's end closes the waits on it, or nil while it goes on.
func waitEndingHow(a *wire.Agent) *wire.WaitEndingHow {
	switch a.State {
	case wire.AgentStateFinished:
		if isOpenBlock(a.Report) {
			return nil
		}
		f := &wire.WaitEndingHowFinished{}
		if a.Report != nil {
			o, m := a.Report.Outcome, a.Report.Message
			f.Outcome, f.Message = &o, &m
		}
		return &wire.WaitEndingHow{Finished: f}
	case wire.AgentStateStopped:
		return &wire.WaitEndingHow{Stopped: &wire.WaitEndingHowStopped{Value: a.EndedReason}}
	case wire.AgentStateArchived:
		return &wire.WaitEndingHow{Archived: &struct{}{}}
	}
	return nil
}

// closeWaits closes every open wait on an agent that has ended, and resumes those that
// may carry on now.
func (d *Daemon) closeWaits(on wire.UUID, how wire.WaitEndingHow) {
	at := now()
	for _, a := range d.Store.Agents() {
		if a.ID == on || !isOpenBlock(a.Report) || a.Report.Block == nil {
			continue
		}
		touched := false
		for _, w := range a.Report.Block.Waits {
			touched = touched || w.AgentID == on && w.Ending == nil
		}
		if !touched {
			continue
		}
		d.change(a.ID, func(a *wire.Agent) {
			r, b := *a.Report, *a.Report.Block
			b.Waits = append([]wire.Wait{}, b.Waits...)
			for i := range b.Waits {
				if b.Waits[i].AgentID == on && b.Waits[i].Ending == nil {
					b.Waits[i].Ending = &wire.WaitEnding{At: at, How: how}
				}
			}
			r.Block = &b
			a.Report = &r
		})
		d.resumeIfCleared(a.ID)
	}
}

func waitsCleared(b *wire.Block) bool {
	if len(b.Waits) == 0 {
		return false
	}
	any := b.WakeOn != nil && *b.WakeOn == wire.BlockWakeOnAny
	all := true
	for _, w := range b.Waits {
		if w.Ending != nil && any {
			return true
		}
		all = all && w.Ending != nil
	}
	return all && !any
}

func endingSummary(e *wire.WaitEnding) string {
	switch {
	case e.How.Finished != nil:
		if o := e.How.Finished.Outcome; o != nil {
			return "finished: " + strings.ToLower(headings[*o])
		}
		return "finished without saying how it went"
	case e.How.Stopped != nil:
		if r := e.How.Stopped.Value; r != nil {
			if s, ok := endedSummary[*r]; ok {
				return strings.ToLower(s)
			}
		}
		return "stopped"
	case e.How.Archived != nil:
		return "archived"
	}
	return "gone"
}

// resumePrompt is Block.resumePrompt.
func (d *Daemon) resumePrompt(b *wire.Block, message string, why wire.BlockClearing) string {
	anyOf := b.WakeOn != nil && *b.WakeOn == wire.BlockWakeOnAny && len(b.Waits) > 1
	var lines []string
	switch {
	case why == wire.BlockClearingWaits && anyOf:
		lines = append(lines, "The wait you reported has cleared: you asked to carry on when any of the agents you were waiting on finished, and one has.")
	case why == wire.BlockClearingWaits && len(b.Waits) == 1:
		lines = append(lines, "The wait you reported has cleared: the agent you were waiting on has finished.")
	case why == wire.BlockClearingWaits:
		lines = append(lines, "The wait you reported has cleared: every agent you were waiting on has finished.")
	default:
		lines = append(lines, "The time you asked to check again has come.")
	}
	line := func(w wire.Wait) string {
		s := "- “" + d.waitName(w) + "” (id " + string(w.AgentID) + "): "
		if w.Ending == nil {
			return s + "still working"
		}
		s += endingSummary(w.Ending)
		if f := w.Ending.How.Finished; f != nil && f.Message != nil {
			s += " — " + *f.Message
		}
		return s
	}
	var ended, going []wire.Wait
	for _, w := range b.Waits {
		if w.Ending != nil {
			ended = append(ended, w)
		} else {
			going = append(going, w)
		}
	}
	if anyOf {
		if len(ended) > 0 {
			lines = append(lines, "", "Finished:")
			for _, w := range ended {
				lines = append(lines, line(w))
			}
		}
		if len(going) > 0 {
			lines = append(lines, "", "Still running:")
			for _, w := range going {
				lines = append(lines, line(w))
			}
		}
	} else if len(b.Waits) > 0 {
		lines = append(lines, "")
		for _, w := range b.Waits {
			lines = append(lines, line(w))
		}
	}
	lines = append(lines, "", "You said you were waiting on: "+message)
	switch {
	case why == wire.BlockClearingWaits && len(going) == 0:
		lines = append(lines, "Carry on from here.")
	case why == wire.BlockClearingWaits:
		lines = append(lines, "Carry on from here. To wait on the rest, call wait_for_agents again, naming them.")
	default:
		lines = append(lines, "Check on it, and carry on or call check_again.")
	}
	return strings.Join(lines, "\n")
}

// resumeIfCleared queues the resume of a blocked agent whose block has cleared, and sends it.
func (d *Daemon) resumeIfCleared(id wire.UUID) {
	a := d.Store.Agent(id)
	if a == nil || a.State != wire.AgentStateFinished || a.Report == nil || a.Report.Outcome != wire.WorkOutcomeWaiting ||
		a.Report.Block == nil || a.Report.Block.ClearedAt != nil || len(a.QueuedPrompts) > 0 {
		return
	}
	b := *a.Report.Block
	t := now()
	due := b.CheckAgainAt != nil && !b.CheckAgainAt.Time().After(t.Time())
	if !waitsCleared(&b) && !due {
		return
	}
	l := d.live(id)
	l.mu.Lock()
	busy := l.running || l.inTurn
	l.mu.Unlock()
	if busy {
		return
	}
	// The block is looked at again, and cleared, in the one change (#3099): two waits that
	// close at once (a kill switch stopping both) each come here, and a block read before
	// the other cleared it was cleared again, queueing a second resume for a wait the agent
	// had already carried on from, which then woke its next wait at once.
	var prompt *wire.QueuedPrompt
	d.changeAgent(id, false, func(a *wire.Agent) {
		if a.State != wire.AgentStateFinished || !isOpenBlock(a.Report) || a.Report.Block == nil || len(a.QueuedPrompts) > 0 {
			return
		}
		b := *a.Report.Block
		cleared := waitsCleared(&b)
		if !cleared && !(b.CheckAgainAt != nil && !b.CheckAgainAt.Time().After(t.Time())) {
			return
		}
		why := wire.BlockClearingTime
		if cleared {
			why = wire.BlockClearingWaits
		}
		prompt = &wire.QueuedPrompt{ID: store.NewUUID(), Text: d.resumePrompt(&b, a.Report.Message, why), QueuedAt: t,
			From: wire.PromptOriginApp, Attachments: []wire.Attachment{}}
		b.ClearedAt, b.ClearedBy = &t, &why
		r := *a.Report
		r.Block = &b
		a.Report = &r
		a.QueuedPrompts = append(append([]wire.QueuedPrompt{}, a.QueuedPrompts...), *prompt)
		a.LastActivityAt = now()
	})
	if prompt == nil {
		return
	}
	if err := d.refuseToRun(a); err != nil {
		_, msg := errMessage(err)
		d.couldNotCarryOn(id, prompt.ID, msg)
		return
	}
	if err := d.needsSignIn(a.RuntimeID); err != nil {
		_, msg := errMessage(err)
		d.couldNotCarryOn(id, prompt.ID, msg)
		return
	}
	l.kick()
}

func (d *Daemon) couldNotCarryOn(id, promptID wire.UUID, why string) {
	text := "Could not carry on after the block cleared: " + why
	d.change(id, func(a *wire.Agent) {
		kept := a.QueuedPrompts[:0:0]
		for _, q := range a.QueuedPrompts {
			if q.ID != promptID {
				kept = append(kept, q)
			}
		}
		a.QueuedPrompts = kept
		// An unexpected stop, not an ending the agent chose (#1916).
		a.State, a.EndedReason = wire.AgentStateStopped, reason(wire.EndedReasonRuntimeError)
	})
	d.record(id, runtimeNote(text))
	d.reconsider()
}

// dropBlock clears a block the person has carried on past.
func (d *Daemon) dropBlock(id wire.UUID) {
	a := d.Store.Agent(id)
	if a == nil || !isOpenBlock(a.Report) {
		return
	}
	t := now()
	dropped := wire.BlockClearingDropped
	d.change(id, func(a *wire.Agent) {
		r := *a.Report
		b := wire.Block{Waits: []wire.Wait{}}
		if r.Block != nil {
			b = *r.Block
		}
		b.ClearedAt, b.ClearedBy = &t, &dropped
		r.Block = &b
		a.Report = &r
	})
}

// armBlockTimer aims one timer at the earliest time a block checks again.
func (d *Daemon) armBlockTimer() {
	var next *time.Time
	for _, a := range d.Store.Agents() {
		if isOpenBlock(a.Report) && a.Report.Block != nil && a.Report.Block.CheckAgainAt != nil {
			t := a.Report.Block.CheckAgainAt.Time()
			if next == nil || t.Before(*next) {
				next = &t
			}
		}
	}
	d.waitMu.Lock()
	defer d.waitMu.Unlock()
	if d.blockTimer != nil {
		d.blockTimer.Stop()
		d.blockTimer = nil
	}
	if next == nil || d.ctx.Err() != nil {
		return
	}
	d.blockTimer = time.AfterFunc(max(0, time.Until(*next))+20*time.Millisecond, func() {
		for _, a := range d.Store.Agents() {
			if isOpenBlock(a.Report) {
				d.resumeIfCleared(a.ID)
			}
		}
		d.armBlockTimer()
	})
}

// resumeBlocks is resumeBlocksAfterRestart: waits closed on what ended while the host was
// down, an unsent resume sent, and every block due resumed.
func (d *Daemon) resumeBlocks() {
	latest := wire.DateOf(time.Now().Add(blockMinutesHigh * time.Minute))
	for _, a := range d.Store.Agents() {
		if !isOpenBlock(a.Report) || a.Report.Block == nil {
			continue
		}
		if a.Report.Block.CheckAgainAt == nil && len(a.Report.Block.Waits) > 0 {
			d.change(a.ID, func(a *wire.Agent) {
				r, b := *a.Report, *a.Report.Block
				b.CheckAgainAt = &latest
				r.Block = &b
				a.Report = &r
			})
		}
		for _, w := range a.Report.Block.Waits {
			if w.Ending != nil {
				continue
			}
			t := d.Store.Agent(w.AgentID)
			if t == nil {
				// One on another machine is asked once this host is on its control plane (#2927).
				if d.thereNamed(a.ID, string(w.AgentID)) != nil {
					continue
				}
				d.closeWaits(w.AgentID, wire.WaitEndingHow{Gone: &struct{}{}})
				continue
			}
			if t.State == wire.AgentStateFinished && len(t.QueuedPrompts) > 0 {
				continue
			}
			if how := waitEndingHow(t); how != nil {
				d.closeWaits(t.ID, *how)
			}
		}
	}
	for _, a := range d.Store.Agents() {
		if a.State == wire.AgentStateFinished && a.Report != nil && a.Report.Outcome == wire.WorkOutcomeWaiting &&
			a.Report.Block != nil && a.Report.Block.ClearedAt != nil &&
			(a.Report.Block.ClearedBy == nil || *a.Report.Block.ClearedBy != wire.BlockClearingDropped) &&
			len(a.QueuedPrompts) > 0 && a.QueuedPrompts[0].From == wire.PromptOriginApp {
			d.live(a.ID).kick()
			continue
		}
		d.resumeIfCleared(a.ID)
	}
	d.armBlockTimer()
}

// keptBlock closes the waits of a block a turn has given back (#3173) on those that ended
// during the turn, when it had no block for closeWaits to find, and aims the timer again.
// The resume, when it has cleared or is due, is the run's once the turn is over.
func (d *Daemon) keptBlock(id wire.UUID) {
	a := d.Store.Agent(id)
	if a == nil || !isOpenBlock(a.Report) || a.Report.Block == nil {
		return
	}
	for _, w := range a.Report.Block.Waits {
		if w.Ending != nil {
			continue
		}
		if t := d.Store.Agent(w.AgentID); t != nil {
			if how := waitEndingHow(t); how != nil {
				d.closeWaits(t.ID, *how)
			}
		}
	}
	d.armBlockTimer()
}

// agentEnded closes the waits on an agent that has ended, off the call that ended it.
func (d *Daemon) agentEnded(id wire.UUID) {
	a := d.Store.Agent(id)
	if a == nil {
		return
	}
	if how := waitEndingHow(a); how != nil {
		h := *how
		d.goAfterTurn("close waits", func() { d.closeWaits(id, h) })
		// Started from another machine: its starter is told (#2927).
		d.tellStarter(id, h)
	}
}
