package agentsd

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// agents/find (#1532): prompts and replies that hold the text, any case; a reply's chunks are
// one message found at its first chunk; tool calls, thoughts and a subagent's words are not
// searched; the newest `limit` come back, oldest first.
func TestFindInChat(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	id := seeded(t, d, t.TempDir(), nil).ID
	say := func(kind wire.TranscriptEntryKind, subagent *string) wire.UUID {
		e := wire.TranscriptEntry{ID: store.NewUUID(), At: now(), Kind: kind, SubagentID: subagent}
		d.Store.Append(id, e)
		return e.ID
	}
	reply := func(messageID, text string) wire.TranscriptEntryKind {
		return wire.TranscriptEntryKind{AgentMessage: &wire.TranscriptEntryKindAgentMessage{MessageID: &messageID, Text: text}}
	}
	sub := "helper"
	ask := say(wire.TranscriptEntryKind{UserMessage: &wire.TranscriptEntryKindUserMessage{Value: "Fix the Cache, please"}}, nil)
	say(wire.TranscriptEntryKind{AgentThought: &wire.TranscriptEntryKindAgentThought{Text: "the cache is cold"}}, nil)
	first := say(reply("m1", "Looking at it.\nThe ca"), nil)
	say(reply("helper-1", "cache in the helper"), &sub)
	say(reply("m1", "che was cold; it is warm now."), nil)
	say(wire.TranscriptEntryKind{ToolCall: &wire.TranscriptEntryKindToolCall{Value: wire.ToolCall{Title: "Read cache.go"}}}, nil)
	long := say(reply("m2", strings.Repeat("word ", 60)+"CACHE "+strings.Repeat("more ", 60)), nil)

	find := func(n int, text string, limit int) wire.FindResult {
		var r wire.FindResult
		params := map[string]any{"agentID": id, "text": text}
		if limit > 0 {
			params["limit"] = limit
		}
		json.Unmarshal(c.call(t, n, "agents/find", params), &r)
		return r
	}
	got := find(1, "cache", 0)
	if len(got.Matches) != 3 || got.More {
		t.Fatalf("matches %+v", got)
	}
	if got.Matches[0].EntryID != ask || got.Matches[0].Line != "Fix the Cache, please" {
		t.Fatalf("the ask %+v", got.Matches[0])
	}
	if got.Matches[1].EntryID != first || got.Matches[1].Line != "The cache was cold; it is warm now." || got.Matches[1].Index != 2 {
		t.Fatalf("the joined reply %+v", got.Matches[1])
	}
	if l := got.Matches[2].Line; got.Matches[2].EntryID != long || !strings.HasPrefix(l, "…") || !strings.HasSuffix(l, "…") || !strings.Contains(l, "CACHE") {
		t.Fatalf("the long line %+v", got.Matches[2])
	}
	if newest := find(2, "CACHE", 2); len(newest.Matches) != 2 || !newest.More || newest.Matches[1].EntryID != long {
		t.Fatalf("limited %+v", newest)
	}
	if none := find(3, "  ", 0); len(none.Matches) != 0 {
		t.Fatalf("blank %+v", none)
	}
}
