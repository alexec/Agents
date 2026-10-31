package agentsd

import (
	"context"
	"encoding/json"
	"log"
	"sort"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/skillcatalog"
	"github.com/alexec/agents/Go/wire"
)

// Forms (elicitations), as DaemonCore+Serving holds them: the daemon's rather than a
// window's, answerable from any client, and held while nobody is watching.

// questionWentUnanswered is RuntimeNote.questionWentUnanswered.
const questionWentUnanswered = "Nobody answered this question before the agent ended."

// formHoldLimit is how long an ask_question call is held open (#1641): a runtime's MCP client
// lets a tool call go at about a minute ("The operation timed out"), as eventHoldLimit
// says for wait_for_event. After it, the call says the form is still open, and the answer
// comes to the agent as a prompt.
var formHoldLimit = 45 * time.Second

// formStillOpen is what an ask_question call says when it is not answered within formHoldLimit.
const formStillOpen = "The form is still open, and nobody has answered it yet. Your place is kept: end your turn " +
	"(or go on with other work). You'll be started again with the answer when they answer, skip or cancel. " +
	"Do not ask again."

type pendingElicitation struct {
	req   wire.ElicitationRequest
	reply chan elicitationReply
	// left is an ask_question whose call came back before the answer (formStillOpen): the
	// form stays open after the turn, and its answer goes to the agent as a prompt.
	left bool
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
	// On a bot's machine nobody answers (#1761, FR-032): declined, and the agent carries on.
	if d.isBot() {
		d.record(l.id, wire.TranscriptEntryKind{RuntimeNote: &wire.TranscriptEntryKindRuntimeNote{Value: noOneAnswersWords}})
		return string(wire.AnswerElicitationRequestActionDecline), nil
	}
	if a := d.Store.Agent(l.id); !inTurn || a == nil || a.Purpose != nil {
		d.record(l.id, wire.TranscriptEntryKind{RuntimeNote: &wire.TranscriptEntryKindRuntimeNote{Value: questionWentUnanswered}})
		return string(wire.AnswerElicitationRequestActionCancel), nil
	}
	r := l.holdForm(ctx, req)
	if r.action != wire.AnswerElicitationRequestActionAccept {
		return string(r.action), nil
	}
	content := map[string]any{}
	for k, v := range r.content {
		content[k] = value(v)
	}
	return string(r.action), content
}

// holdForm puts a form in front of the person and waits for the answer, the form taken
// down, or ctx: the runtime's own questions are held so.
func (l *live) holdForm(ctx context.Context, req wire.ElicitationRequest) elicitationReply {
	d := l.d
	pe := l.showForm(req)
	select {
	case r := <-pe.reply:
		return r
	case <-ctx.Done():
		// The runtime went (closeQuestionsOfAGoneRuntime): nothing to say to it.
		if l.take(req.ID) != nil {
			d.record(l.id, wire.TranscriptEntryKind{RuntimeNote: &wire.TranscriptEntryKindRuntimeNote{Value: questionWentUnanswered}})
			d.formDown(l.id, req.ID)
		}
		return cancelled()
	}
}

// showForm puts a form in front of the person, on every client.
func (l *live) showForm(req wire.ElicitationRequest) *pendingElicitation {
	d := l.d
	pe := &pendingElicitation{req: req, reply: make(chan elicitationReply, 1)}
	l.mu.Lock()
	l.elicitations[req.ID] = pe
	l.mu.Unlock()
	d.record(l.id, wire.TranscriptEntryKind{ElicitationAsked: &wire.TranscriptEntryKindElicitationAsked{Value: req}})
	d.moveIf(l.id, wire.AgentStateRunning, wire.AgentStateWaitingOnUser)
	Broadcast(d, wire.NotifyAgentElicitation, wire.ElicitationNotification{AgentID: l.id, RequestID: req.ID, Request: &req})
	d.raiseAgentEvent("agent.asked_form", l.id, "is asking for a form to be filled in.", nil)
	d.reconsider()
	return pe
}

// holdAskedForm is ask_question's form: held up to formHoldLimit, then left open, with false,
// for the answer to come as a prompt (#1641).
func (l *live) holdAskedForm(req wire.ElicitationRequest) (elicitationReply, bool) {
	pe := l.showForm(req)
	hold := time.NewTimer(formHoldLimit)
	defer hold.Stop()
	select {
	case r := <-pe.reply:
		return r, true
	case <-hold.C:
	}
	l.mu.Lock()
	_, open := l.elicitations[req.ID]
	pe.left = open
	l.mu.Unlock()
	if !open {
		return <-pe.reply, true // answered in the same instant
	}
	// The turn goes on: the agent is not held by this form any more.
	if !l.asking() {
		l.d.moveIf(l.id, wire.AgentStateWaitingOnUser, wire.AgentStateRunning)
	}
	return elicitationReply{}, false
}

// asking is whether a card holds the agent's turn: a permission or a form whose call
// waits. A form left open (pendingElicitation.left) does not hold it.
func (l *live) asking() bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if len(l.pending) > 0 {
		return true
	}
	for _, pe := range l.elicitations {
		if !pe.left {
			return true
		}
	}
	return false
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

// closeForms takes every form of the agent's turn down as the turn stops: the runtime
// hears cancel, the record says nobody answered. A form left open (pendingElicitation.left)
// is not the turn's, and stays, unless every one goes (the agent archived or deleted).
func (l *live) closeForms(every bool) {
	l.mu.Lock()
	var pes []*pendingElicitation
	for id, pe := range l.elicitations {
		if pe.left && !every {
			continue
		}
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
	secret := pe.req.Secret
	switch {
	case action != wire.AnswerElicitationRequestActionAccept:
	case secret != nil:
		// A secret is saved here (#2885), and from here on only its name goes anywhere.
		if err := d.saveAskedSecret(*secret, content); err != nil {
			return err
		}
		content = map[string]wire.JSONValue{}
	case form != nil:
		// An answer that does not fit is not sent, and the form is still waiting.
		if why := problems(form.Value, content); len(why) > 0 {
			return Invalid("%s", strings.Join(why, ". "))
		}
	}
	if l.take(r.RequestID) == nil {
		return &Error{Code: wire.FailureNoSuchAgent, Message: "That form has already been answered."}
	}
	var said []wire.ElicitationAnswer
	switch {
	case secret != nil:
		said = secretAnswered(*secret, action)
	case action == wire.AnswerElicitationRequestActionAccept && form != nil:
		said = answers(form.Value, content, pe.req.Message)
	}
	d.record(l.id, wire.TranscriptEntryKind{ElicitationAnswered: &wire.TranscriptEntryKindElicitationAnswered{ID: r.RequestID,
		Summary: outcomeSummary(action), Answers: said}})
	d.moveIf(l.id, wire.AgentStateWaitingOnUser, wire.AgentStateRunning)
	d.formDown(l.id, r.RequestID)
	// A form whose call came back already (#1641): the answer starts the agent again.
	if pe.left {
		if err := d.promptFromApp(l.id, d.formAnsweredWords(pe.req, action, said)); err != nil {
			log.Printf("agent %s: form answer: %v", l.id, err)
		}
		return nil
	}
	// The runtime hears last, so what it says next follows the answer in the record.
	pe.reply <- elicitationReply{action: action, content: content}
	return nil
}

// formAnsweredWords is the prompt that brings an answer to a form left open.
func (d *Daemon) formAnsweredWords(req wire.ElicitationRequest, action wire.AnswerElicitationRequestAction, said []wire.ElicitationAnswer) string {
	if req.Secret != nil {
		return "The person replied to your ask_secret for " + req.Secret.Name + ". " +
			secretNote(req.Secret.Name, skillcatalog.SecretsPath(d.personalHome()), action)
	}
	form := "your form"
	if req.Message != nil && strings.TrimSpace(*req.Message) != "" {
		form = "your form \"" + strings.TrimSpace(*req.Message) + "\""
	}
	return "The person replied to " + form + " (ask_question). " + askQuestionNote(action, said)
}

// moveIf moves an agent from one state to another, and does nothing from any other
// (AgentState's permissionAsked and permissionAnswered).
func (d *Daemon) moveIf(id wire.UUID, from, to wire.AgentState) {
	if a := d.Store.Agent(id); a != nil && a.State == from {
		d.setState(id, to)
	}
}
