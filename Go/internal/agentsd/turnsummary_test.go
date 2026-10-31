package agentsd

import (
	"encoding/json"
	"fmt"
	"testing"

	"github.com/alexec/agents/Go/internal/agentsd/store"
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
	if len(s.Outcome) != 1 || s.Outcome[0].Kind.AgentMessage.Text != "Fixed it." || *s.Steps != 2 {
		t.Fatalf("outcome %+v steps %d", s.Outcome, *s.Steps)
	}
	if s.Usage == nil || s.Usage.TotalTokens != 15 || s.Usage.Cost.Amount != 0.75 {
		t.Fatalf("%+v", s.Usage)
	}
	// A turn that ends on a run: stopped is the outcome, and the message before the run is
	// a step.
	es = entriesOf(t,
		`{"userMessage":{"_0":"Go"}}`,
		`{"agentMessage":{"text":"On it."}}`,
		`{"toolCall":{"_0":{"toolCallID":"c1","title":"Run make","kind":"execute","content":[{"content":{"type":"text","text":"ok"}}],"locations":[],"rawInput":{"description":"Build it","command":"make"}}}}`,
		`{"permissionAnswered":{"requestID":"p","optionID":"allow","label":"Allow"}}`,
		`{"stateChanged":{"_0":"stopped","reason":"cancelled"}}`,
	)
	s = turnSummaryOf(es, 0)
	if len(s.Outcome) != 2 || s.Outcome[1].Kind.StateChanged == nil || *s.Steps != 2 {
		b, _ := json.Marshal(s.Outcome)
		t.Fatalf("%s %d", b, *s.Steps)
	}
}

// A branch's note comes after the reply it keeps and the report, not among the steps (#1749).
func TestABranchsNoteComesAfterTheReply(t *testing.T) {
	es := entriesOf(t,
		`{"userMessage":{"_0":"Remember APPLE"}}`,
		`{"toolCall":{"_0":{"toolCallID":"c1","title":"ls","kind":"execute","content":[],"locations":[]}}}`,
		`{"agentMessage":{"messageID":"m1","text":"OK APPLE"}}`,
		`{"workReported":{"_0":{"outcome":"done","message":"Remembered","at":0}}}`,
		`{"stateChanged":{"_0":"finished","reason":"endTurn"}}`,
		`{"runtimeNote":{"_0":"Branched from APPLE before its prompt 2."}}`,
	)
	s := turnSummaryOf(es, 0)
	if len(s.Outcome) != 3 || s.Outcome[0].Kind.AgentMessage == nil || s.Outcome[1].Kind.WorkReported == nil ||
		s.Outcome[2].Kind.RuntimeNote == nil || *s.Steps != 1 {
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

// Ports the kept turns (AgentStoreTurnsTests): a page of a long chat makes only its own
// turns, the rest are filled in behind it into turns.jsonl, the next look reads them
// from there, and a kept turn that no longer matches its transcript is made again.
func TestTurnsAreKept(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	var id wire.UUID
	json.Unmarshal(c.call(t, 1, "agents/start", map[string]any{"runtimeID": "claude", "cwd": "file://" + t.TempDir(), "prompt": "hello"}), &id)
	c.until(t, "the first turn", ended(id, wire.AgentStateFinished))
	person, agent := wire.PromptOriginPerson, wire.PromptOriginAgent
	for i := range 300 {
		// The first is another agent's: a turn, but not one of the person's prompts (#1862).
		from := &person
		if i == 0 {
			from = &agent
		}
		d.Store.Append(id, wire.TranscriptEntry{ID: store.NewUUID(), At: now(), Kind: wire.TranscriptEntryKind{
			UserMessage: &wire.TranscriptEntryKindUserMessage{Value: fmt.Sprintf("ask %d", i), From: from}}})
		d.Store.Append(id, wire.TranscriptEntry{ID: store.NewUUID(), At: now(), Kind: wire.TranscriptEntryKind{
			AgentMessage: &wire.TranscriptEntryKindAgentMessage{Text: fmt.Sprintf("done %d", i)}}})
	}
	var page wire.TurnsPage
	json.Unmarshal(c.call(t, 2, "agents/turns", map[string]any{"agentID": id, "limit": 5}), &page)
	// Before "ask 294": "hello" and asks 1 to 293, which the Prompts list numbers from (#1862).
	if len(page.Turns) != 5 || page.Turns[4].Ask.Kind.UserMessage.Value != "ask 298" || page.FirstPrompt == nil || *page.FirstPrompt != 294 {
		t.Fatalf("%+v", page)
	}
	closed := int(page.FirstTurn) + 5
	waitFor(t, "turns.jsonl filled", func() bool { return len(d.readTurns(id)) == closed })

	// A fresh look reads them, checking the last: one whose first entry is another is made
	// again from there.
	kept := d.readTurns(id)
	kept[closed-1].ID = store.NewUUID()
	d.writeTurns(id, kept)
	d.turnMu.Lock()
	d.turnsOf = nil
	d.turnMu.Unlock()
	page = wire.TurnsPage{}
	json.Unmarshal(c.call(t, 3, "agents/turns", map[string]any{"agentID": id, "before": 150, "limit": 1}), &page)
	ask := 149 - (closed - 299)
	if len(page.Turns) != 1 || page.Turns[0].Ask.Kind.UserMessage.Value != fmt.Sprintf("ask %d", ask) ||
		page.FirstPrompt == nil || *page.FirstPrompt != int64(ask) {
		b, _ := json.Marshal(page)
		t.Fatalf("%s", b)
	}
	waitFor(t, "made again", func() bool {
		k := d.readTurns(id)
		return len(k) == closed && k[closed-1].ID != kept[closed-1].ID
	})
	var tp wire.TranscriptPage
	json.Unmarshal(c.call(t, 4, "agents/transcript", map[string]any{"agentID": id, "before": 10, "limit": 3}), &tp)
	if tp.FirstIndex != 7 || len(tp.Entries) != 3 || tp.Total < 600 {
		t.Fatalf("%+v", tp)
	}
}
