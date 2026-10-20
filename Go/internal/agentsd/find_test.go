package agentsd

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	goruntime "runtime"
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

// P20261019-2: a find reads a long chat without decoding what is not a prompt or a reply, and
// joins a reply's chunks without copying it again at each chunk. Before, 2,000 chunks of 1 KB
// copied about 2 GB, and each tool output was decoded.
func TestFindReadsOnlyMessages(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	id := seeded(t, d, t.TempDir(), nil).ID
	say := func(kind wire.TranscriptEntryKind) wire.UUID {
		e := wire.TranscriptEntry{ID: store.NewUUID(), At: now(), Kind: kind}
		d.Store.Append(id, e)
		return e.ID
	}
	output := strings.Repeat("output ", 2000)
	for range 1000 {
		say(wire.TranscriptEntryKind{ToolCallUpdate: &wire.TranscriptEntryKindToolCallUpdate{Value: wire.ToolCall{Title: output}}})
	}
	messageID := "long"
	chunk := strings.Repeat("streamed ", 110) + "\n"
	first := say(wire.TranscriptEntryKind{AgentMessage: &wire.TranscriptEntryKindAgentMessage{MessageID: &messageID, Text: chunk}})
	for range 2000 {
		say(wire.TranscriptEntryKind{AgentMessage: &wire.TranscriptEntryKindAgentMessage{MessageID: &messageID, Text: chunk}})
	}
	say(wire.TranscriptEntryKind{AgentMessage: &wire.TranscriptEntryKindAgentMessage{MessageID: &messageID, Text: "the needle at the end"}})
	info, err := os.Stat(d.Store.Loc.Transcript(string(id)))
	if err != nil {
		t.Fatal(err)
	}

	// The line index is made once per chat and kept (lineindex.go): not the find's cost.
	if _, err := d.Store.LineEnds(id); err != nil {
		t.Fatal(err)
	}
	var before, after goruntime.MemStats
	goruntime.GC()
	goruntime.ReadMemStats(&before)
	got, err := d.find(context.Background(), 1, wire.FindRequest{AgentID: id, Text: "NEEDLE"})
	goruntime.ReadMemStats(&after)
	if err != nil || len(got.Matches) != 1 || got.Matches[0].EntryID != first || got.Matches[0].Line != "the needle at the end" {
		t.Fatalf("find %+v %v", got, err)
	}
	allocated := after.TotalAlloc - before.TotalAlloc
	// The reply's 2 MB cost about ten times that to decode and join; the 14 MB of tool output,
	// not decoded, cost nothing. Before, decoding them alone was about 140 MB.
	if allocated > 3*uint64(info.Size()) {
		t.Fatalf("one find allocated %d bytes for a transcript of %d", allocated, info.Size())
	}
}

// A find stops when its client asks again in the same chat, or when the host stops.
func TestFindStops(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	id := seeded(t, d, t.TempDir(), nil).ID
	d.Store.Append(id, wire.TranscriptEntry{ID: store.NewUUID(), At: now(), Kind: wire.TranscriptEntryKind{UserMessage: &wire.TranscriptEntryKindUserMessage{Value: "cache"}}})
	older, _ := d.startFind(findKey{client: 1, agent: id})
	otherClient, _ := d.startFind(findKey{client: 2, agent: id})
	newer, done := d.startFind(findKey{client: 1, agent: id})
	if older() || !newer() || !otherClient() {
		t.Fatal("only the newest find of a client in a chat is wanted")
	}
	done()
	if len(d.finds) != 1 {
		t.Fatalf("a finished find keeps its place: %v", d.finds)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := d.find(ctx, 1, wire.FindRequest{AgentID: id, Text: "cache"}); !errors.Is(err, context.Canceled) {
		t.Fatalf("a stopped find %v", err)
	}
	if got, err := d.find(context.Background(), 1, wire.FindRequest{AgentID: id, Text: "cache"}); err != nil || len(got.Matches) != 1 {
		t.Fatalf("find %+v %v", got, err)
	}
}
