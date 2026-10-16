package agentsd

import (
	"context"
	"encoding/json"
	"sort"
	"strings"

	"github.com/alexec/agents/Go/wire"
)

// Forms (elicitations), as DaemonCore+Serving holds them: the daemon's rather than a
// window's, answerable from any client, and held while nobody is watching.

// questionWentUnanswered is RuntimeNote.questionWentUnanswered.
const questionWentUnanswered = "Nobody answered this question before the agent ended."

type pendingElicitation struct {
	req   wire.ElicitationRequest
	reply chan elicitationReply
}

type elicitationReply struct {
	action  wire.AnswerElicitationRequestAction
	content map[string]wire.JSONValue
}

func cancelled() elicitationReply {
	return elicitationReply{action: wire.AnswerElicitationRequestActionCancel}
}

// Elicitation holds a form until it is answered, withdrawn or the turn ends, and says the
// answer to the runtime.
func (l *live) Elicitation(ctx context.Context, params json.RawMessage) (string, map[string]any) {
	d := l.d
	req, ok := parseElicitation(params, l.id)
	if !ok {
		return string(wire.AnswerElicitationRequestActionDecline), nil // a form we cannot draw
	}
	// Only a turn asks; a writer (#858) asks only through its tools, in the sheet.
	l.mu.Lock()
	inTurn := l.inTurn
	l.mu.Unlock()
	if a := d.Store.Agent(l.id); !inTurn || a == nil || a.Purpose != nil {
		d.record(l.id, wire.TranscriptEntryKind{RuntimeNote: &wire.TranscriptEntryKindRuntimeNote{Value: questionWentUnanswered}})
		return string(wire.AnswerElicitationRequestActionCancel), nil
	}
	pe := &pendingElicitation{req: req, reply: make(chan elicitationReply, 1)}
	l.mu.Lock()
	l.elicitations[req.ID] = pe
	l.mu.Unlock()
	d.record(l.id, wire.TranscriptEntryKind{ElicitationAsked: &wire.TranscriptEntryKindElicitationAsked{Value: req}})
	d.moveIf(l.id, wire.AgentStateRunning, wire.AgentStateWaitingOnUser)
	Broadcast(d, wire.NotifyAgentElicitation, wire.ElicitationNotification{AgentID: l.id, RequestID: req.ID, Request: &req})
	d.reconsider()

	var r elicitationReply
	select {
	case r = <-pe.reply:
	case <-ctx.Done():
		// The runtime went (closeQuestionsOfAGoneRuntime): nothing to say to it.
		if l.take(req.ID) != nil {
			d.record(l.id, wire.TranscriptEntryKind{RuntimeNote: &wire.TranscriptEntryKindRuntimeNote{Value: questionWentUnanswered}})
			d.formDown(l.id, req.ID)
		}
		return string(wire.AnswerElicitationRequestActionCancel), nil
	}
	if r.action != wire.AnswerElicitationRequestActionAccept {
		return string(r.action), nil
	}
	content := map[string]any{}
	for k, v := range r.content {
		content[k] = value(v)
	}
	return string(r.action), content
}

// take removes a pending form, and is nil when it has gone already.
func (l *live) take(id wire.UUID) *pendingElicitation {
	l.mu.Lock()
	defer l.mu.Unlock()
	pe := l.elicitations[id]
	delete(l.elicitations, id)
	return pe
}

func (d *Daemon) formDown(agentID, requestID wire.UUID) {
	Broadcast(d, wire.NotifyAgentElicitation, wire.ElicitationNotification{AgentID: agentID, RequestID: requestID})
	d.reconsider()
}

// ElicitationComplete is the runtime taking its own form down (withdrawElicitation):
// everything an answer would have done still happens, and the runtime hears cancel.
func (l *live) ElicitationComplete(elicitationID string) {
	l.mu.Lock()
	var ids []wire.UUID
	for id, pe := range l.elicitations {
		if pe.req.ElicitationID != nil && *pe.req.ElicitationID == elicitationID {
			ids = append(ids, id)
		}
	}
	l.mu.Unlock()
	for _, id := range ids {
		pe := l.elicitationFor(id)
		if pe == nil {
			continue
		}
		l.d.record(l.id, wire.TranscriptEntryKind{ElicitationAnswered: &wire.TranscriptEntryKindElicitationAnswered{ID: id,
			Summary: outcomeSummary(wire.AnswerElicitationRequestActionCancel)}})
		// The state moves before the form is dropped: a client that sees no form must
		// not see an agent still waiting on one.
		l.d.moveIf(l.id, wire.AgentStateWaitingOnUser, wire.AgentStateRunning)
		if l.take(id) != nil {
			pe.reply <- cancelled()
		}
		l.d.formDown(l.id, id)
	}
}

func (l *live) elicitationFor(id wire.UUID) *pendingElicitation {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.elicitations[id]
}

// closeForms takes every form of the agent down as its turn stops: the runtime hears
// cancel, the record says nobody answered.
func (l *live) closeForms() {
	l.mu.Lock()
	var pes []*pendingElicitation
	for id, pe := range l.elicitations {
		pes = append(pes, pe)
		delete(l.elicitations, id)
	}
	l.mu.Unlock()
	for _, pe := range pes {
		l.d.record(l.id, wire.TranscriptEntryKind{RuntimeNote: &wire.TranscriptEntryKindRuntimeNote{Value: questionWentUnanswered}})
		pe.reply <- cancelled()
		l.d.formDown(l.id, pe.req.ID)
	}
}

func (d *Daemon) everyLive() []*live {
	d.mu.Lock()
	defer d.mu.Unlock()
	ls := make([]*live, 0, len(d.lives))
	for _, l := range d.lives {
		ls = append(ls, l)
	}
	return ls
}

func (d *Daemon) pendingElicitations() []wire.ElicitationRequest {
	out := []wire.ElicitationRequest{}
	for _, l := range d.everyLive() {
		l.mu.Lock()
		for _, pe := range l.elicitations {
			out = append(out, pe.req)
		}
		l.mu.Unlock()
	}
	sort.Slice(out, func(i, j int) bool { return out[i].AskedAt < out[j].AskedAt })
	return out
}

// answerElicitation is DaemonCore.answerElicitation.
func (d *Daemon) answerElicitation(r wire.AnswerElicitationRequest) error {
	var l *live
	var pe *pendingElicitation
	for _, each := range d.everyLive() {
		if pe = each.elicitationFor(r.RequestID); pe != nil {
			l = each
			break
		}
	}
	if pe == nil {
		return &Error{Code: wire.FailureNoSuchAgent, Message: "That form has already been answered."}
	}
	action := r.Action
	if action == "" {
		action = wire.AnswerElicitationRequestActionCancel
	}
	content := r.Content
	if content == nil {
		content = map[string]wire.JSONValue{}
	}
	form := pe.req.Mode.Form
	if action == wire.AnswerElicitationRequestActionAccept && form != nil {
		// An answer that does not fit is not sent, and the form is still waiting.
		if why := problems(form.Value, content); len(why) > 0 {
			return Invalid("%s", strings.Join(why, ". "))
		}
	}
	if l.take(r.RequestID) == nil {
		return &Error{Code: wire.FailureNoSuchAgent, Message: "That form has already been answered."}
	}
	var said []wire.ElicitationAnswer
	if action == wire.AnswerElicitationRequestActionAccept && form != nil {
		said = answers(form.Value, content, pe.req.Message)
	}
	d.record(l.id, wire.TranscriptEntryKind{ElicitationAnswered: &wire.TranscriptEntryKindElicitationAnswered{ID: r.RequestID,
		Summary: outcomeSummary(action), Answers: said}})
	d.moveIf(l.id, wire.AgentStateWaitingOnUser, wire.AgentStateRunning)
	d.formDown(l.id, r.RequestID)
	// The runtime hears last, so what it says next follows the answer in the record.
	pe.reply <- elicitationReply{action: action, content: content}
	return nil
}

// moveIf moves an agent from one state to another, and does nothing from any other
// (AgentState's permissionAsked and permissionAnswered).
func (d *Daemon) moveIf(id wire.UUID, from, to wire.AgentState) {
	if a := d.Store.Agent(id); a != nil && a.State == from {
		d.setState(id, to)
	}
}
