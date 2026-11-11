package agentsd

import (
	"strings"
	"time"

	sdk "github.com/coder/acp-go-sdk"

	"github.com/alexec/agents/Go/wire"
)

// An unprompted turn (#4323) is a runtime working after its prompt was answered. Claude's
// adapter answers session/prompt with end_turn when the model stops, also with a background
// command still running; when the command ends, Claude starts a cycle of its own on it (a
// task-notification) and streams it with no prompt in flight. The daemon took that cycle
// for a finished agent: Done in every list, and every app tool that needs a turn
// (hand_to_person, ask_question, ask_secret) refused. The cycle's first words or tool call
// begin a turn here, and its result ends it: the usage_update that names the cycle's origin
// in _meta, or, from a runtime that names none, a quiet stretch with nothing in flight.

// unpromptedQuiet is how long an unprompted turn with no tool in flight and no card open
// may go without an update before it is taken as ended.
var unpromptedQuiet = 2 * time.Minute

// beginsWork is whether an update between turns is the runtime working: words, a thought or
// a new tool call. A late tool_call_update or a usage count is not.
func beginsWork(u sdk.SessionUpdate) bool {
	return u.AgentMessageChunk != nil || u.AgentThoughtChunk != nil || u.ToolCall != nil
}

// endsCycle is whether a usage_update is the end of a cycle: Claude's adapter sends one at
// each result, with the cycle's origin in _meta when it was not the person's prompt.
func endsCycle(meta map[string]any) bool {
	_, ok := meta["_claude/origin"]
	return ok
}

// beginUnprompted begins an unprompted turn when no turn is in flight and the runtime is
// there; it is false when one was not begun.
func (l *live) beginUnprompted() bool {
	l.mu.Lock()
	if l.inTurn || l.running || l.session == nil {
		l.mu.Unlock()
		return false
	}
	l.turnSeq++
	seq := l.turnSeq
	// prompting, so a stop sends session/cancel: the runtime has the turn.
	l.inTurn, l.prompting, l.unprompted = true, true, true
	l.stopped, l.reported, l.showedFile, l.heldBlock = false, false, false, nil
	l.lastMessageID, l.lastMessage = "", strings.Builder{}
	l.failure = nil
	l.armQuiet(seq)
	l.mu.Unlock()
	if a := l.d.Store.Agent(l.id); a == nil || a.State == wire.AgentStateArchived {
		// An archived agent's runtime finishing off is not a turn to show.
		l.endUnprompted(wire.AgentStateFinished, wire.EndedReasonEndTurn)
		return false
	}
	l.d.setState(l.id, wire.AgentStateRunning)
	return true
}

// armQuiet starts or restarts the quiet timer of unprompted turn seq. Called with l.mu held.
func (l *live) armQuiet(seq int) {
	if l.quiet != nil {
		l.quiet.Stop()
	}
	l.quiet = time.AfterFunc(unpromptedQuiet, func() { l.quietEnded(seq) })
}

// quietEnded ends unprompted turn seq after a quiet stretch, unless a tool or a card is
// still open: a hand_to_person or a permission waits on the person, not on the runtime.
func (l *live) quietEnded(seq int) {
	l.mu.Lock()
	if !l.unprompted || l.turnSeq != seq {
		l.mu.Unlock()
		return
	}
	if len(l.tools.open) > 0 || len(l.pending) > 0 {
		l.armQuiet(seq)
		l.mu.Unlock()
		return
	}
	l.mu.Unlock()
	l.endUnprompted(wire.AgentStateFinished, wire.EndedReasonEndTurn)
}

// heard is an update during an unprompted turn: the quiet stretch starts again.
func (l *live) heard() {
	l.mu.Lock()
	if l.unprompted {
		l.armQuiet(l.turnSeq)
	}
	l.mu.Unlock()
}

// endUnprompted ends the unprompted turn in flight, if there is one, as a prompt's end
// does: the state, its reason and the report from the last words.
func (l *live) endUnprompted(s wire.AgentState, why wire.EndedReason) {
	if !l.leaveUnprompted() {
		return
	}
	l.flushHeld()
	l.d.end(l, s, why)
}

// leaveUnprompted clears an unprompted turn's marks; it is false when none was in flight.
func (l *live) leaveUnprompted() bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if !l.unprompted {
		return false
	}
	l.unprompted = false
	l.inTurn, l.prompting = false, false
	if l.quiet != nil {
		l.quiet.Stop()
		l.quiet = nil
	}
	return true
}
