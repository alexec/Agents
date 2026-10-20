package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// Ports ShowFileTests, SuggestPromptTests and AskFormTests: a file put in front of the
// person and kept as a card, one suggestion in the empty prompt, and a form the person
// answers in the agent's words.

func TestShowingAFile(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "a.txt"), []byte("hi"), 0o644)
	a := seeded(t, d, dir, nil)
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	if text, _ := m.tool(2, "show_file", map[string]any{"path": filepath.Join(dir, "a.txt"), "line": 3}); text != "a.txt is open at line 3 in the files pane beside this conversation. Say what they are looking at; do not paste the file back." {
		t.Fatal(text)
	}
	if text, _ := m.tool(3, "show_file", map[string]any{"path": filepath.Join(dir, "notes.md")}); !strings.HasPrefix(text, "notes.md is open, empty, in the files pane") {
		t.Fatal(text)
	}
	for i, bad := range []map[string]any{{"path": "a.txt"}, {"path": "/etc/hosts"}, {"path": dir}, {"path": filepath.Join(dir, "gone.txt")}} {
		if _, isErr := m.tool(4+i, "show_file", bad); !isErr {
			t.Errorf("%v was shown", bad)
		}
	}
	var shown []wire.ShownFile
	for _, e := range kinds(d, a.ID) {
		if e == "fileShown" {
			shown = append(shown, wire.ShownFile{})
		}
	}
	if len(shown) != 2 {
		t.Fatalf("%v", kinds(d, a.ID))
	}
	if h := heard(t, c, 9)["agent/showFile"]; len(h) != 2 {
		t.Fatalf("%d", len(h))
	}
}

func TestSuggestingTheNextPrompt(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	a := seeded(t, d, t.TempDir(), nil)
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	if text, isErr := m.tool(2, "suggest_next_prompt", map[string]any{"label": "Run the tests", "prompt": ""}); !isErr || text != "Nothing was suggested: send a non-empty `label` and `prompt`." {
		t.Fatal(text)
	}
	if text, _ := m.tool(3, "suggest_next_prompt", map[string]any{"label": "Run the tests", "prompt": "Run them all"}); text != shownNote {
		t.Fatal(text)
	}
	if s := d.Store.Agent(a.ID).SuggestedPrompts; len(s) != 1 || s[0].Label != "Run the tests" || s[0].Prompt != "Run them all" {
		t.Fatalf("%+v", s)
	}
}

func TestAskingThePersonAForm(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	a := seeded(t, d, t.TempDir(), func(a *wire.Agent) { a.State, a.EndedReason = wire.AgentStateRunning, nil })
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	question := map[string]any{"questions": []any{map[string]any{"id": "colour", "prompt": "Which colour?",
		"options": []any{map[string]any{"id": "red", "label": "Red"}, map[string]any{"id": "blue"}}}}}
	if text, isErr := m.tool(2, "ask_form", question); !isErr || text != "A question can only be asked while this agent is working." {
		t.Fatal(text)
	}
	l := d.live(a.ID)
	l.mu.Lock()
	l.inTurn = true
	l.mu.Unlock()
	answered := make(chan string, 1)
	go func() { text, _ := m.tool(3, "ask_form", question); answered <- text }()
	var pending []wire.ElicitationRequest
	waitFor(t, "the form", func() bool {
		json.Unmarshal(c.call(t, 1, "elicitations/pending", nil), &pending)
		return len(pending) == 1
	})
	f := pending[0].Mode.Form.Value
	if *pending[0].Message != "Which colour?" || f.Properties[0].Kind.String.Choices[1].Title != "blue" {
		t.Fatalf("%+v", pending[0])
	}
	c.call(t, 2, "elicitations/answer", map[string]any{"requestID": pending[0].ID, "action": "accept", "content": map[string]any{"colour": "red"}})
	if text := <-answered; text != "They answered:\n- Which colour?: Red" {
		t.Fatal(text)
	}
	if text, isErr := m.tool(4, "ask_form", map[string]any{"questions": []any{map[string]any{"id": "x"}}}); !isErr || text != "Nothing was asked: each question needs an `id` and a `prompt`." {
		t.Fatal(text)
	}
}

// A form nobody answers in time (#1641): the call comes back before the runtime's own
// limit, the form stays open past the turn and its stop, the agent can still wait, and the
// answer starts it again.
func TestAFormLeftOpenBringsItsAnswerLater(t *testing.T) {
	fakeRuntimes(t)
	was := formHoldLimit
	formHoldLimit = 300 * time.Millisecond
	defer func() { formHoldLimit = was }()
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	a := seeded(t, d, t.TempDir(), func(a *wire.Agent) { a.State, a.EndedReason = wire.AgentStateRunning, nil })
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	l := d.live(a.ID)
	l.mu.Lock()
	l.inTurn = true
	l.mu.Unlock()
	question := map[string]any{"title": "Pick a colour", "questions": []any{map[string]any{"id": "colour", "prompt": "Which colour?",
		"options": []any{map[string]any{"id": "red", "label": "Red"}}}}}
	if text, isErr := m.tool(2, "ask_form", question); isErr || text != formStillOpen {
		t.Fatal(text)
	}
	if s := d.Store.Agent(a.ID).State; s != wire.AgentStateRunning {
		t.Fatalf("the turn is still held by the form: %s", s)
	}
	if l.asking() {
		t.Fatal("a form left open holds the turn, so the agent cannot wait")
	}
	l.closeForms(false) // the turn stops
	l.mu.Lock()
	l.inTurn = false
	l.mu.Unlock()
	var pending []wire.ElicitationRequest
	json.Unmarshal(c.call(t, 1, "elicitations/pending", nil), &pending)
	if len(pending) != 1 {
		t.Fatalf("the form was taken down: %+v", pending)
	}
	c.call(t, 2, "elicitations/answer", map[string]any{"requestID": pending[0].ID, "action": "accept", "content": map[string]any{"colour": "red"}})
	waitFor(t, "the answer in its chat", func() bool {
		return slices.Contains(userMessages(d, a.ID), "The person replied to your form \"Pick a colour\" (ask_form). They answered:\n- Which colour?: Red")
	})
	json.Unmarshal(c.call(t, 3, "elicitations/pending", nil), &pending)
	if len(pending) != 0 {
		t.Fatalf("%+v", pending)
	}
}
