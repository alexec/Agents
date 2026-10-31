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

func TestHangingUpVoiceMode(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	a := seeded(t, d, t.TempDir(), nil)
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	if d.Store.Agent(a.ID).VoiceHungUpAt != nil {
		t.Fatal("hung up before hang_up")
	}
	if text, isErr := m.tool(2, "hang_up", map[string]any{}); isErr || !strings.HasPrefix(text, "Voice mode ends") {
		t.Fatal(text)
	}
	if d.Store.Agent(a.ID).VoiceHungUpAt == nil {
		t.Fatal("hang_up left no mark for the client")
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
	if text, isErr := m.tool(2, "ask_question", question); !isErr || text != "A question can only be asked while this agent is working." {
		t.Fatal(text)
	}
	l := d.live(a.ID)
	l.mu.Lock()
	l.inTurn = true
	l.mu.Unlock()
	answered := make(chan string, 1)
	go func() { text, _ := m.tool(3, "ask_question", question); answered <- text }()
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
	if text, isErr := m.tool(4, "ask_question", map[string]any{"questions": []any{map[string]any{"id": "x"}}}); !isErr || text != "Nothing was asked: each question needs an `id` and a `prompt`." {
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
	if text, isErr := m.tool(2, "ask_question", question); isErr || text != formStillOpen {
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
		return slices.Contains(userMessages(d, a.ID), "The person replied to your form \"Pick a colour\" (ask_question). They answered:\n- Which colour?: Red")
	})
	json.Unmarshal(c.call(t, 3, "elicitations/pending", nil), &pending)
	if len(pending) != 0 {
		t.Fatalf("%+v", pending)
	}
	// The prompt that brings the answer starts a turn, so the answer is the end of the
	// turn that asked, not drawn after the next turn's steps (#2934).
	var page wire.TurnsPage
	json.Unmarshal(c.call(t, 4, "agents/turns", map[string]any{"agentID": a.ID, "limit": 50}), &page)
	ends, err := d.Store.LineEnds(a.ID)
	if err != nil {
		t.Fatal(err)
	}
	opening, _, err := d.Store.Entries(a.ID, ends, int(page.OpenStart), int(page.OpenStart)+1)
	if err != nil || len(opening) != 1 || opening[0].Kind.UserMessage == nil || *opening[0].Kind.UserMessage.From != wire.PromptOriginApp {
		t.Fatalf("the last turn starts with %+v", opening)
	}
	if n := len(page.Turns); n == 0 || page.Turns[n-1].Outcome[len(page.Turns[n-1].Outcome)-1].Kind.ElicitationAnswered == nil {
		b, _ := json.Marshal(page)
		t.Fatalf("the answer is not the end of the turn that asked: %s", b)
	}
}
