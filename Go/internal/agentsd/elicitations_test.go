package agentsd

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// Ports ElicitationTests and ElicitationSchemaTests: a form is held, answered from any
// client, refused when the answer does not fit, and taken down by a stop or the runtime.

// callError sends a call and is the error it answers with, or fails when it answers.
func (c *conn) callError(t *testing.T, id int, method string, params any) *Error {
	t.Helper()
	p, _ := json.Marshal(params)
	b, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": id, "method": method, "params": json.RawMessage(p)})
	c.in <- string(b)
	deadline := time.After(5 * time.Second)
	for {
		select {
		case line := <-c.out:
			var m message
			json.Unmarshal([]byte(line), &m)
			if string(m.ID) != string(mustJSON(id)) {
				continue
			}
			if m.Error == nil {
				t.Fatalf("%s answered %s", method, m.Result)
			}
			return m.Error
		case <-deadline:
			t.Fatalf("%s: no answer", method)
		}
	}
}

func asked(form *wire.ElicitationRequest) func(string, json.RawMessage) bool {
	return func(method string, p json.RawMessage) bool {
		var n wire.ElicitationNotification
		if method == "agent/elicitation" && json.Unmarshal(p, &n) == nil && n.Request != nil {
			*form = *n.Request
			return true
		}
		return false
	}
}

func takenDown(id wire.UUID) func(string, json.RawMessage) bool {
	return func(method string, p json.RawMessage) bool {
		var n wire.ElicitationNotification
		return method == "agent/elicitation" && json.Unmarshal(p, &n) == nil && n.Request == nil && n.RequestID == id
	}
}

func kinds(d *Daemon, id wire.UUID) []string {
	entries, _, _ := d.Store.Transcript(id, 0)
	var out []string
	for _, e := range entries {
		b, _ := json.Marshal(e.Kind)
		var k map[string]json.RawMessage
		json.Unmarshal(b, &k)
		for name := range k {
			out = append(out, name)
		}
	}
	return out
}

func entryOf[T any](d *Daemon, id wire.UUID, pick func(wire.TranscriptEntryKind) *T) *T {
	entries, _, _ := d.Store.Transcript(id, 0)
	for _, e := range entries {
		if v := pick(e.Kind); v != nil {
			return v
		}
	}
	return nil
}

func TestAFormIsHeldAndAnswered(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	var id wire.UUID
	json.Unmarshal(c.call(t, 1, "agents/start", map[string]any{"runtimeID": "claude", "cwd": "file://" + t.TempDir(),
		"prompt": "a form please"}), &id)
	var form wire.ElicitationRequest
	c.until(t, "a form", asked(&form))
	if form.AgentID != id || form.Mode.Form == nil || form.Message == nil || *form.Message != "Which colour?" ||
		form.Scope != wire.ElicitationRequestScopeSession {
		t.Fatalf("%+v", form)
	}
	if p := form.Mode.Form.Value.Properties; len(p) != 1 || p[0].Name != "colour" || !p[0].IsRequired ||
		p[0].Kind.String == nil || len(p[0].Kind.String.Choices) != 2 {
		t.Fatalf("%+v", p)
	}
	var pending []wire.ElicitationRequest
	json.Unmarshal(c.call(t, 2, "elicitations/pending", nil), &pending)
	if len(pending) != 1 || pending[0].ID != form.ID {
		t.Fatalf("pending %+v", pending)
	}
	if a := d.Store.Agent(id); a.State != wire.AgentStateWaitingOnUser {
		t.Fatalf("state %s while asking", a.State)
	}
	// An answer that does not fit is not sent, and the form waits on.
	if e := c.callError(t, 3, "elicitations/answer", map[string]any{"requestID": form.ID, "action": "accept",
		"content": map[string]any{"colour": "green"}}); e.Code != CodeInvalidParams || e.Message != "Not one of the choices" {
		t.Fatalf("%+v", e)
	}
	if e := c.callError(t, 4, "elicitations/answer", map[string]any{"requestID": form.ID, "action": "accept",
		"content": map[string]any{}}); e.Message != "colour is needed" {
		t.Fatalf("%+v", e)
	}
	c.call(t, 5, "elicitations/answer", map[string]any{"requestID": form.ID, "action": "accept",
		"content": map[string]any{"colour": "blue"}})
	c.until(t, "the end", ended(id, wire.AgentStateFinished))
	// The record's last line follows the agent/changed that says it ended.
	waitFor(t, "the ending recorded", func() bool { k := kinds(d, id); return len(k) > 0 && k[len(k)-1] == "stateChanged" })
	if a := d.Store.Agent(id); a.Report == nil || a.Report.Message != "You chose blue." {
		t.Fatalf("report %+v", a.Report)
	}
	answered := entryOf(d, id, func(k wire.TranscriptEntryKind) *wire.TranscriptEntryKindElicitationAnswered {
		return k.ElicitationAnswered
	})
	if answered == nil || answered.ID != form.ID || answered.Summary != "You answered the agent's form" ||
		len(answered.Answers) != 1 || answered.Answers[0] != (wire.ElicitationAnswer{Question: "Which colour?", Answer: "blue"}) {
		t.Fatalf("%+v", answered)
	}
	// "You chose " now, "blue." held for a token's sake until the turn ends (#1001).
	want := "runtimeNote userMessage stateChanged elicitationAsked stateChanged elicitationAnswered stateChanged agentMessage agentMessage stateChanged"
	if got := strings.Join(kinds(d, id), " "); got != want {
		t.Fatalf("transcript\n got %s\nwant %s", got, want)
	}
	// Answered once: again is no such form.
	if e := c.callError(t, 6, "elicitations/answer", map[string]any{"requestID": form.ID, "action": "decline"}); e.Code != wire.FailureNoSuchAgent {
		t.Fatalf("%+v", e)
	}
}

func TestStoppingAnAgentTakesItsFormDownWithIt(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	var id wire.UUID
	json.Unmarshal(c.call(t, 1, "agents/start", map[string]any{"runtimeID": "claude", "cwd": "file://" + t.TempDir(),
		"prompt": "a form please"}), &id)
	var form wire.ElicitationRequest
	c.until(t, "a form", asked(&form))
	// Sent, not called: call skips what is heard before its answer.
	c.in <- `{"jsonrpc":"2.0","id":2,"method":"agents/stop","params":{"agentID":"` + string(id) + `"}}`
	c.until(t, "the form taken down", takenDown(form.ID))
	for deadline := time.Now().Add(5 * time.Second); d.Store.Agent(id).State != wire.AgentStateStopped; {
		if time.Now().After(deadline) {
			a := d.Store.Agent(id)
			t.Fatalf("not stopped: %s %v %v", a.State, a.EndedReason, kinds(d, id))
		}
		time.Sleep(20 * time.Millisecond)
	}
	if got := d.pendingElicitations(); len(got) != 0 {
		t.Fatalf("still pending %+v", got)
	}
	note := entryOf(d, id, func(k wire.TranscriptEntryKind) *wire.TranscriptEntryKindRuntimeNote {
		if k.RuntimeNote != nil && k.RuntimeNote.Value == questionWentUnanswered {
			return k.RuntimeNote
		}
		return nil
	})
	if note == nil {
		t.Fatalf("no note: %v", kinds(d, id))
	}
}

func TestAWithdrawnFormTakesTheAgentOutOfWaiting(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	var id wire.UUID
	json.Unmarshal(c.call(t, 1, "agents/start", map[string]any{"runtimeID": "claude", "cwd": "file://" + t.TempDir(),
		"prompt": "a form, then withdraw it"}), &id)
	var form wire.ElicitationRequest
	c.until(t, "a link", asked(&form))
	if form.Mode.URL == nil || form.Mode.URL.Value != "https://example.com/sign-in" || form.ElicitationID == nil || *form.ElicitationID != "e1" {
		t.Fatalf("%+v", form)
	}
	c.until(t, "the form taken down", takenDown(form.ID))
	c.until(t, "the end", ended(id, wire.AgentStateFinished))
	answered := entryOf(d, id, func(k wire.TranscriptEntryKind) *wire.TranscriptEntryKindElicitationAnswered {
		return k.ElicitationAnswered
	})
	if answered == nil || answered.Summary != "The form was closed" {
		t.Fatalf("%+v", answered)
	}
	if a := d.Store.Agent(id); a.Report == nil || a.Report.Message != "The form was closed." {
		t.Fatalf("report %+v", a.Report)
	}
}

func TestAFormOutsideATurnIsNotHeld(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	l := d.live("8C1F6A1E-0000-4000-8000-000000000001")
	action, _ := l.Elicitation(t.Context(), json.RawMessage(`{"message":"x","requestedSchema":{"properties":{"a":{"type":"boolean"}}}}`))
	if action != "cancel" || len(d.pendingElicitations()) != 0 {
		t.Fatal(action)
	}
	if action, _ := l.Elicitation(t.Context(), json.RawMessage(`{"message":"x","requestedSchema":{"properties":{"a":{"type":"object"}}}}`)); action != "decline" {
		t.Fatalf("a form we cannot draw: %s", action)
	}
}

// ElicitationSchemaTests: the schema's own order, titled choices, the free-text box that
// goes with the question before it, and the checks.
func TestAFormIsReadAsSwiftReadsIt(t *testing.T) {
	req, ok := parseElicitation(json.RawMessage(`{"message":"Two things","requestId":"r1","requestedSchema":{
		"title":"Setup","propertyOrder":["question_0","question_0_custom","question_1","when","count","ok","tags"],
		"required":["question_0","count"],
		"properties":{
			"question_0":{"type":"string","title":"Which?","oneOf":[{"const":"a","title":"Apple"},{"const":"b","title":"Banana"}]},
			"question_0_custom":{"type":"string","description":"add to your selection above"},
			"question_1":{"type":"string","format":"email"},
			"when":{"type":"string","format":"date"},
			"count":{"type":"integer","minimum":1,"maximum":3},
			"ok":{"type":"boolean","default":true},
			"tags":{"type":"array","items":{"anyOf":[{"const":"x","title":"Ex"},{"const":"y"}]},"maxItems":1}}}}`), "A")
	if !ok || req.Scope != wire.ElicitationRequestScopeRequest || elicitationTitle(req) != "Setup" {
		t.Fatalf("%v %+v", ok, req)
	}
	s := req.Mode.Form.Value
	var names []string
	for _, p := range s.Properties {
		names = append(names, p.Name)
	}
	if strings.Join(names, " ") != "question_0 question_0_custom question_1 when count ok tags" {
		t.Fatal(names)
	}
	if string(s.Properties[5].DefaultValue) != "true" || s.Properties[0].Kind.String.Choices[1].Title != "Banana" ||
		s.Properties[6].Kind.MultiSelect.Items[1].Title != "y" {
		t.Fatalf("%+v", s.Properties)
	}
	if ps := pages(s); len(ps) != 6 || len(ps[0]) != 2 {
		t.Fatalf("pages %d", len(ps))
	}
	content := map[string]wire.JSONValue{"question_0": json.RawMessage(`"b"`), "question_0_custom": json.RawMessage(`"ripe"`),
		"question_1": json.RawMessage(`"me@example"`), "when": json.RawMessage(`"2026-10-16"`), "count": json.RawMessage(`2.5`),
		"ok": json.RawMessage(`false`), "tags": json.RawMessage(`["x","y"]`)}
	got := strings.Join(problems(s, content), ". ")
	if got != "Not a email. count must be a whole number. Choose at most 1" {
		t.Fatal(got)
	}
	content["question_1"], content["count"], content["tags"] = json.RawMessage(`"me@example.com"`), json.RawMessage(`4`), json.RawMessage(`["x"]`)
	if got := strings.Join(problems(s, content), ". "); got != "At most 3" {
		t.Fatal(got)
	}
	content["count"] = json.RawMessage(`3`)
	said := answers(s, content, req.Message)
	b, _ := json.Marshal(said)
	if string(b) != `[{"question":"Which?","answer":"Banana, ripe"},{"question":"question_1","answer":"me@example.com"},`+
		`{"question":"when","answer":"2026-10-16"},{"question":"count","answer":"3"},{"question":"ok","answer":"No"},`+
		`{"question":"tags","answer":"Ex"}]` {
		t.Fatal(string(b))
	}
	if askQuestionNote(wire.AnswerElicitationRequestActionAccept, said[:1]) != "They answered:\n- Which?: Banana, ripe" {
		t.Fatal(askQuestionNote(wire.AnswerElicitationRequestActionAccept, said[:1]))
	}
	// A lone untitled question takes the message as its question; with no order, by name.
	one, _ := parseElicitation(json.RawMessage(`{"message":"Go ahead?","requestedSchema":{"properties":{"b":{"type":"boolean"},"a":{"type":"number","maximum":2}}}}`), "A")
	if p := one.Mode.Form.Value.Properties; p[0].Name != "a" || p[1].Name != "b" {
		t.Fatalf("%+v", p)
	}
	if why := problem(one.Mode.Form.Value.Properties[0], json.RawMessage(`2.5`)); why != "At most 2.0" {
		t.Fatal(why)
	}
	lone, _ := parseElicitation(json.RawMessage(`{"message":"Go ahead?","requestedSchema":{"properties":{"go":{"type":"boolean"}}}}`), "A")
	if a := answers(lone.Mode.Form.Value, map[string]wire.JSONValue{"go": json.RawMessage(`true`)}, lone.Message); a[0].Question != "Go ahead?" || a[0].Answer != "Yes" {
		t.Fatalf("%+v", a)
	}
	// A request is a form or a link, and neither is nothing.
	if _, ok := parseElicitation(json.RawMessage(`{"message":"x","schema":{"properties":{"a":{"type":"string"}}}}`), "A"); ok {
		t.Fatal("a form under the wrong key")
	}
}

func waitFor(t *testing.T, what string, ok func() bool) {
	t.Helper()
	for deadline := time.Now().Add(10 * time.Second); !ok(); time.Sleep(20 * time.Millisecond) {
		if time.Now().After(deadline) {
			t.Fatalf("never %s", what)
		}
	}
}
