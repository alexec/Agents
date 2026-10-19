package agentsd

import (
	"encoding/json"
	"os"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// The session search over what was said (#1585): agents/said finds the session and its line,
// a reply's chunks are one message, said.json is brought up to date from where it stopped and
// kept within saidBytes, and agents/list's query keeps the sessions that match.
func TestSaidSearch(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := t.TempDir()
	title := "Parser work"
	first := seeded(t, d, dir, func(a *wire.Agent) { a.Title = &title }).ID
	other := seeded(t, d, dir, nil).ID
	say := func(id wire.UUID, kind wire.TranscriptEntryKind) {
		d.Store.Append(id, wire.TranscriptEntry{ID: store.NewUUID(), At: now(), Kind: kind})
	}
	reply := func(text string) wire.TranscriptEntryKind {
		m := "m1"
		return wire.TranscriptEntryKind{AgentMessage: &wire.TranscriptEntryKindAgentMessage{MessageID: &m, Text: text}}
	}
	say(first, wire.TranscriptEntryKind{UserMessage: &wire.TranscriptEntryKindUserMessage{Value: "Make the build faster"}})
	say(first, reply("I moved the cache.\nThe bui"))
	say(first, reply("ld is warm now."))
	say(other, wire.TranscriptEntryKind{UserMessage: &wire.TranscriptEntryKindUserMessage{Value: "Write the docs"}})

	search := func(n int, text string) wire.SaidSearchResult {
		var r wire.SaidSearchResult
		json.Unmarshal(c.call(t, n, "agents/said", map[string]any{"text": text}), &r)
		return r
	}
	got := search(1, "build is WARM")
	if len(got.Matches) != 1 || got.Matches[0].AgentID != first || got.Matches[0].Line != "The build is warm now." {
		t.Fatalf("%+v", got)
	}
	// Up to date from where it stopped: a new message is found, the old ones kept.
	say(other, reply("The docs build too."))
	if got := search(2, "build"); len(got.Matches) != 2 {
		t.Fatalf("both said build: %+v", got)
	}
	b, _ := os.ReadFile(saidFile(d.Store.Loc, first))
	if !strings.Contains(string(b), "Make the build faster") {
		t.Fatalf("said.json %s", b)
	}
	// agents/list's query keeps a session for its title or for what it said.
	var listed []wire.Agent
	json.Unmarshal(c.call(t, 3, "agents/list", map[string]any{"includeArchived": true, "query": "docs"}), &listed)
	if len(listed) != 1 || listed[0].ID != other {
		t.Fatalf("listed %+v", listed)
	}
	json.Unmarshal(c.call(t, 4, "agents/list", map[string]any{"includeArchived": true, "query": "parser"}), &listed)
	if len(listed) != 1 || listed[0].ID != first {
		t.Fatalf("by title %+v", listed)
	}
}

func TestBoundSaid(t *testing.T) {
	big := strings.Repeat("x", saidBytes/2+1)
	kept := boundSaid([]string{"old", big, big})
	if len(kept) != 1 || kept[0] != big {
		t.Fatalf("kept %d", len(kept))
	}
}
