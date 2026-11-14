package agentsd

import (
	"context"
	"encoding/json"
	"strings"

	"github.com/agentloops-dev/agents/Go/internal/agentsd/store"
	"github.com/agentloops-dev/agents/Go/wire"
)

// hand_to_person (#3529, spike #3527): the agent gives the person one step on the page in
// the machine's browser that no guardrail can do (a CAPTCHA, a sign-in, a click it must
// not make itself). It is an ordinary question card, held like ask_question's: the step,
// why, and one choice, Done or Can't do it, with a line for what stopped them. A client
// that shows the machine's browser (the Mac and the web page) adds Open the page, which
// opens the Agent Browser at the agent's tab; the Remote says to do it on one of those.
// When the browser is Google Chrome, its real window comes to the front for the step
// instead, and the card names it (handoffwindow.go, #5208).
// While the card is open, the agent's other browser calls are refused, so the page does
// not move under the person, and the agent keeps browser:agents past its turn's end, so
// no other agent takes the page from them.

const handToPersonName = "hand_to_person"

// handToPersonTool is hand_to_person as tools/list sends it, with the browser tools.
var handToPersonTool = json.RawMessage(`{"name":"hand_to_person","title":"Hand a step on the page to the person",` +
	`"description":"Ask the person to do one step on the browser's current page that you cannot or must not do: solve a CAPTCHA, sign in, approve a sign-in on their phone, or click something only a person should. ` +
	`Use it only when no tool or secret can do the step: fill a password with fill_secret, not this. ` +
	`Every client shows a card with the step; the person does it and answers Done or Can't do it. When the app's browser is Google Chrome on a Mac the person is at, its window comes to the front for the step and goes back on Done; otherwise the card has Open the page. ` +
	`When the step is in one of the agents' own Chrome windows (a real Chrome over DevTools, as for a site that refuses the app's browser), give its cdp_port: the card names that window. ` +
	`Never do a human check (a CAPTCHA, a press-and-hold, a slider) yourself with synthetic input: hand it over. ` +
	`You get their answer; then call browser_snapshot to see where the page is now, and carry on from it. ` +
	`Your other browser calls are refused until they answer. Hand over one step at a time.",` +
	`"inputSchema":{"type":"object","properties":{` +
	`"step":{"type":"string","description":"What the person does, as a short instruction: e.g. \"Solve the CAPTCHA\", \"Sign in to GitLab\"."},` +
	`"reason":{"type":"string","description":"Why you need them, in one sentence: e.g. \"The sign-up form needs a person to pass its check.\""},` +
	`"cdp_port":{"type":"integer","minimum":1024,"maximum":65535,"description":"Only when the step is in one of the agents' own Chrome windows on this machine, not the app's browser: that Chrome's DevTools port (e.g. 9233 for the profile chrome-profile-microsoft that .agents/signups/cdp.mjs drives). Its page tab comes to the front, and the card names that window."}},` +
	`"required":["step","reason"],"additionalProperties":false},` +
	`"annotations":{"title":"Hand to the person","readOnlyHint":true,"openWorldHint":false}}`)

// The hand-off form's one question and its note, as ask_question names a choice and the
// free text beside it (question_0, question_0_custom), so every client draws it as one.
const (
	handOffOutcome = "outcome"
	handOffNote    = "outcome_note"
	handOffDone    = "done"
	handOffCannot  = "cannot"
)

// handOffSchema is the card's form: Done or Can't do it, and what stopped them. The choice
// has no title of its own: the card's title is the step, and the record says the answer
// under it ("Solve the CAPTCHA: Done").
func handOffSchema(reason string) wire.ElicitationSchema {
	noteTitle := "What stopped you (optional)"
	return wire.ElicitationSchema{Description: &reason, Properties: []wire.ElicitationSchemaProperty{
		{Name: handOffOutcome, IsRequired: true, Kind: wire.ElicitationSchemaPropertyKind{String: &wire.ElicitationSchemaPropertyKindString{
			Choices: []wire.ElicitationSchemaPropertyChoice{{Value: handOffDone, Title: "Done"}, {Value: handOffCannot, Title: "Can't do it"}}}}},
		{Name: handOffNote, Title: &noteTitle, Kind: wire.ElicitationSchemaPropertyKind{String: &wire.ElicitationSchemaPropertyKindString{}}},
	}}
}

// handToPerson is hand_to_person, called by an agent that holds browser:agents, or, with
// cdp_port, by any agent whose step is in one of the agents' own Chrome windows (#5095).
func (d *Daemon) handToPerson(ctx context.Context, agent wire.UUID, args map[string]json.RawMessage) (string, bool) {
	step, reason := strings.TrimSpace(argString(args, "step")), strings.TrimSpace(argString(args, "reason"))
	if step == "" {
		return "Nothing was handed over: say in `step` what the person does, e.g. \"Solve the CAPTCHA\".", true
	}
	if reason == "" {
		return "Nothing was handed over: say in `reason` why you need the person for " + step + ".", true
	}
	if d.handOffOpen(agent) != nil {
		return "Nothing was handed over: the person has the page already. Wait for their answer.", true
	}
	l, err := d.asker(agent, "A step can only be handed to the person while this agent is working.")
	if err != nil {
		return browserWords(err), true
	}
	handOff := &wire.ElicitationHandOff{Step: step, Reason: &reason}
	if port, ok := handOffPort(args); ok {
		window, err := frontChromeTab(ctx, port)
		if err != nil {
			return "Nothing was handed over: " + err.Error(), true
		}
		handOff.Window = &window
	}
	id := store.NewUUID()
	if handOff.Window == nil {
		// The agents' browser is Google Chrome (#5207): the person gets its real window
		// (#5208), which comes down again with the card (formDown).
		if window, ok := d.showHandOffWindow(agent, id); ok {
			handOff.Window = &window
		}
	}
	req := wire.ElicitationRequest{ID: id, AgentID: agent, Message: &step, HandOff: handOff,
		Mode:  wire.ElicitationRequestMode{Form: &wire.ElicitationRequestModeForm{Value: handOffSchema(reason)}},
		Scope: wire.ElicitationRequestScopeSession, AskedAt: now()}
	r, answered := l.holdAskedForm(req, nil, formHoldLimit)
	if !answered {
		return handOffStillOpen, false
	}
	return handOffNoteFor(step, r.action, r.content), false
}

// handOffStillOpen is what the call says when the person has not answered within
// formHoldLimit: a CAPTCHA or a sign-in often takes longer.
const handOffStillOpen = "The person has not finished yet. Your place and the browser are kept: end your turn. " +
	"You'll be started again with their answer. Do not hand it over again, and make no browser calls until then."

// handOffNoteFor is the words an agent reads for the answer to its hand-off.
func handOffNoteFor(step string, action wire.AnswerElicitationRequestAction, content map[string]wire.JSONValue) string {
	if action != wire.AnswerElicitationRequestActionAccept {
		return "The person did not take the page for \"" + step + "\". Carry on without it, or say what you cannot do without it."
	}
	outcome, _ := text(value(content[handOffOutcome]))
	note, _ := text(value(content[handOffNote]))
	note = strings.TrimSpace(note)
	if outcome == handOffDone {
		said := "The person did \"" + step + "\". The page is yours again: call browser_snapshot to see where it is now, and carry on from it."
		if note != "" {
			said += " They added: " + note
		}
		return said
	}
	said := "The person could not do \"" + step + "\"."
	if note != "" {
		said += " They said: " + note
	}
	return said + " The page is yours again. Try another way, or say what you cannot do without it."
}

// handOffOpen is the agent's open hand-off, or nil: while there is one, the person has the page.
func (d *Daemon) handOffOpen(agent wire.UUID) *wire.ElicitationHandOff {
	d.mu.Lock()
	l := d.lives[agent]
	d.mu.Unlock()
	if l == nil {
		return nil
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	for _, pe := range l.elicitations {
		if pe.req.HandOff != nil {
			return pe.req.HandOff
		}
	}
	return nil
}

// handOffHolds is the refusal for a browser call made while the person has the page.
func handOffHolds(h *wire.ElicitationHandOff) string {
	return "The person has the page, to \"" + h.Step + "\". Make no browser calls until they answer your hand_to_person: " +
		"end your turn, and you'll be started again with their answer."
}
