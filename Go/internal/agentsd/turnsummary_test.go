package agentsd

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// Ports TurnSummaryTests and TurnsPageTests: a finished turn is its ask, its last block,
// its outcome and its count of steps; a page of them counts back from the turn still going.

func entriesOf(t *testing.T, lines ...string) []wire.TranscriptEntry {
	t.Helper()
	var out []wire.TranscriptEntry
	for i, l := range lines {
		var e wire.TranscriptEntry
		if err := json.Unmarshal([]byte(`{"id":"00000000-0000-0000-0000-00000000000`+string(rune('a'+i))+`","at":0,"kind":`+l+`}`), &e); err != nil {
			t.Fatalf("%s: %v", l, err)
		}
		out = append(out, e)
	}
	return out
}

func TestATurnSummarised(t *testing.T) {
	es := entriesOf(t,
		`{"userMessage":{"_0":"Fix it"}}`,
		`{"stateChanged":{"_0":"running"}}`,
		`{"agentMessage":{"messageID":"m1","text":"Looking."}}`,
		`{"toolCall":{"_0":{"toolCallID":"c1","title":"Read a.go","kind":"read","content":[],"locations":[],"rawInput":{"description":"Read the file"}}}}`,
		`{"toolCallUpdate":{"_0":{"toolCallID":"c1","title":"Tool call","status":"completed","content":[{"content":{"type":"text","text":"x"}}],"locations":[]}}}`,
		`{"toolCall":{"_0":{"toolCallID":"c2","title":"finish_turn","name":"mcp__agents__finish_turn","content":[],"locations":[]}}}`,
		`{"agentMessage":{"messageID":"m2","text":"RetriableError: overloaded\nFixed "}}`,
		`{"agentMessage":{"messageID":"m2","text":"it."}}`,
		`{"usageRecorded":{"_0":{"totalTokens":10,"inputTokens":6,"outputTokens":4,"cost":{"amount":0.5,"currency":"USD"}}}}`,
		`{"usageRecorded":{"_0":{"totalTokens":5,"inputTokens":3,"outputTokens":2,"cost":{"amount":0.25,"currency":"USD"}}}}`,
		`{"stateChanged":{"_0":"finished","reason":"endTurn"}}`,
	)
	s := turnSummaryOf(es, 7)
	if s.ID != es[0].ID || s.Ask == nil || s.Start != 7 || s.End != 18 {
		t.Fatalf("%+v", s)
	}
	if s.Last == nil || s.Last.Kind.AgentMessage == nil || s.Last.Kind.AgentMessage.Text != "Fixed it." {
		t.Fatalf("last %+v", s.Last)
	}
	if len(s.Outcome) != 1 || s.Outcome[0].Kind.AgentMessage.Text != "Fixed it." || *s.Steps != 2 {
		t.Fatalf("outcome %+v steps %d", s.Outcome, *s.Steps)
	}
	if s.Usage == nil || s.Usage.TotalTokens != 15 || s.Usage.Cost.Amount != 0.75 {
		t.Fatalf("%+v", s.Usage)
	}
	// A turn that ends on a run: the run as its last call, said in its own words, with the
	// message before it.
	es = entriesOf(t,
		`{"userMessage":{"_0":"Go"}}`,
		`{"agentMessage":{"text":"On it."}}`,
		`{"toolCall":{"_0":{"toolCallID":"c1","title":"Run make","kind":"execute","content":[{"content":{"type":"text","text":"ok"}}],"locations":[],"rawInput":{"description":"Build it","command":"make"}}}}`,
		`{"permissionAnswered":{"requestID":"p","optionID":"allow","label":"Allow"}}`,
		`{"stateChanged":{"_0":"stopped","reason":"cancelled"}}`,
	)
	s = turnSummaryOf(es, 0)
	b, _ := json.Marshal(s.Concise)
	if len(s.Concise) != 3 || s.Concise[1].ID != es[2].ID || !strings.Contains(string(b), `"rawInput":{"description":"Build it"}`) || strings.Contains(string(b), `"command"`) || strings.Contains(string(b), `"ok"`) {
		t.Fatalf("%s", b)
	}
	// Stopped is the outcome, and the message before the run is a step.
	if len(s.Outcome) != 2 || s.Outcome[1].Kind.StateChanged == nil || *s.Steps != 2 {
		b, _ := json.Marshal(s.Outcome)
		t.Fatalf("%s %d", b, *s.Steps)
	}
}

func TestAPageOfTurns(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	var id wire.UUID
	json.Unmarshal(c.call(t, 1, "agents/start", map[string]any{"runtimeID": "claude", "cwd": "file://" + t.TempDir(),
		"prompt": "hello", "attachments": []any{}, "startOptions": map[string]any{"values": map[string]any{}, "extraArguments": []any{}},
		"additionalDirectories": []any{}, "mcpServers": []any{}, "labels": []any{}}), &id)
	c.until(t, "the first turn", ended(id, wire.AgentStateFinished))
	c.call(t, 2, "agents/prompt", map[string]any{"agentID": id, "text": "again", "from": "person"})
	waitFor(t, "the second turn", func() bool {
		u := userMessages(d, id)
		return len(u) == 2 && d.Store.Agent(id).State == wire.AgentStateFinished
	})
	var page wire.TurnsPage
	json.Unmarshal(c.call(t, 3, "agents/turns", map[string]any{"agentID": id, "limit": 50}), &page)
	// What came before the first ask is a turn of its own, as the Swift host counts them.
	if len(page.Turns) != 2 || page.FirstTurn != 0 || page.Turns[0].Ask != nil || page.Turns[1].Ask.Kind.UserMessage.Value != "hello" ||
		page.Turns[1].End != page.OpenStart || page.Turns[1].Outcome[0].Kind.AgentMessage.Text != "I wrote hi.txt. Anything else?" {
		b, _ := json.Marshal(page)
		t.Fatalf("%s", b)
	}
	page = wire.TurnsPage{}
	json.Unmarshal(c.call(t, 4, "agents/turns", map[string]any{"agentID": id, "before": 2, "limit": 1}), &page)
	if len(page.Turns) != 1 || page.FirstTurn != 1 || page.OpenStart == 0 {
		t.Fatalf("%+v", page)
	}
}
