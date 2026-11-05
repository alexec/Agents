package slackmcp

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
)

// events/poll over an inbox filled by hand: the cursor, the bound, a cursor from another
// run, the arguments, and no tokens.

func pollRaw(t *testing.T, e *Events, params map[string]any) (map[string]any, *rpcError) {
	t.Helper()
	raw, _ := json.Marshal(params)
	return e.Poll(context.Background(), raw)
}

func kept(b *Inbox, n int) {
	for i := range n {
		b.add(item{id: fmt.Sprintf("m%d", i), name: MessageReceived, channel: "C1", user: "U2", data: map[string]any{"n": i}})
	}
}

func TestPollReadsOnFromItsCursor(t *testing.T) {
	inbox := NewInbox()
	e := &Events{Workspace: &Workspace{BotToken: "xoxb-x", AppToken: "xapp-x"}, Inbox: inbox}
	start, err := pollRaw(t, e, map[string]any{"name": MessageReceived})
	if err != nil || len(start["events"].([]any)) != 0 {
		t.Fatalf("first poll: %v %v", start, err)
	}
	kept(inbox, 3)
	inbox.add(item{id: "m0", name: MessageReceived}) // Slack sent it again
	r, _ := pollRaw(t, e, map[string]any{"name": MessageReceived, "cursor": start["cursor"], "maxEvents": 2})
	if len(r["events"].([]any)) != 2 || r["hasMore"] != true || r["truncated"] != false {
		t.Fatalf("a page: %v", r)
	}
	r, _ = pollRaw(t, e, map[string]any{"name": MessageReceived, "cursor": r["cursor"]})
	if got := r["events"].([]any); len(got) != 1 || got[0].(map[string]any)["eventId"] != "m2" || r["hasMore"] != false {
		t.Fatalf("the rest: %v", r)
	}
	if r, _ = pollRaw(t, e, map[string]any{"name": MessageReceived, "cursor": r["cursor"]}); len(r["events"].([]any)) != 0 {
		t.Fatalf("nothing new: %v", r)
	}
	if r, _ := pollRaw(t, e, map[string]any{"name": MessageReceived, "cursor": start["cursor"], "arguments": map[string]any{"user": "U3"}}); len(r["events"].([]any)) != 0 {
		t.Fatalf("user filter: %v", r)
	}
}

func TestTheInboxIsBounded(t *testing.T) {
	inbox := NewInbox()
	e := &Events{Workspace: &Workspace{BotToken: "xoxb-x", AppToken: "xapp-x"}, Inbox: inbox}
	start, _ := pollRaw(t, e, map[string]any{"name": MessageReceived})
	kept(inbox, maxKept+5)
	if len(inbox.items) != maxKept || len(inbox.seen) != maxKept {
		t.Fatalf("kept %d, seen %d", len(inbox.items), len(inbox.seen))
	}
	r, _ := pollRaw(t, e, map[string]any{"name": MessageReceived, "cursor": start["cursor"], "maxEvents": 100})
	if r["truncated"] != true || r["events"].([]any)[0].(map[string]any)["eventId"] != "m5" {
		t.Fatalf("lost the oldest: %v", r["truncated"])
	}
}

func TestACursorFromAnotherRunStartsFromNow(t *testing.T) {
	old := &Events{Workspace: &Workspace{BotToken: "xoxb-x", AppToken: "xapp-x"}, Inbox: NewInbox()}
	c, _ := pollRaw(t, old, map[string]any{"name": MessageReceived})
	again := &Events{Workspace: old.Workspace, Inbox: NewInbox()}
	kept(again.Inbox, 2)
	r, err := pollRaw(t, again, map[string]any{"name": MessageReceived, "cursor": c["cursor"]})
	if err != nil || len(r["events"].([]any)) != 0 || r["truncated"] != true {
		t.Fatalf("%v %v", r, err)
	}
	if r, _ = pollRaw(t, again, map[string]any{"name": MessageReceived, "cursor": r["cursor"]}); len(r["events"].([]any)) != 0 {
		t.Fatalf("from now: %v", r)
	}
	if _, err := pollRaw(t, again, map[string]any{"name": MessageReceived, "cursor": "nonsense"}); err == nil || err.Code != -32602 {
		t.Fatalf("a cursor it never gave: %v", err)
	}
}

func TestPollChecksItsArguments(t *testing.T) {
	e := &Events{Workspace: &Workspace{BotToken: "xoxb-x", AppToken: "xapp-x"}, Inbox: NewInbox()}
	for _, c := range []struct {
		params map[string]any
		code   int
		says   string
	}{
		{map[string]any{"name": "reaction.added"}, -32011, "no event reaction.added"},
		{map[string]any{"name": MessageReceived, "arguments": map[string]any{"question": "q1"}}, -32602, "unknown argument question"},
		{map[string]any{"name": QuestionAnswered, "arguments": map[string]any{"mentions": "true"}}, -32602, "unknown argument mentions"},
		{map[string]any{"name": MessageReceived, "arguments": map[string]any{"channel": 4}}, -32602, "channel must be a string"},
		{map[string]any{"name": MessageReceived, "arguments": map[string]any{"mentions": "maybe"}}, -32602, "mentions must be true or false"},
	} {
		if _, err := pollRaw(t, e, c.params); err == nil || err.Code != c.code || !strings.Contains(err.Message, c.says) {
			t.Errorf("%v: %v", c.params, err)
		}
	}
	for _, mentions := range []any{true, "true", false} {
		if _, err := pollRaw(t, e, map[string]any{"name": MessageReceived, "arguments": map[string]any{"mentions": mentions}}); err != nil {
			t.Errorf("mentions %v: %v", mentions, err)
		}
	}
	none := &Events{Workspace: &Workspace{}, Inbox: NewInbox()}
	if _, err := pollRaw(t, none, map[string]any{"name": MessageReceived}); err == nil || err.Code != -32012 || err.Data["reason"] != "not connected" {
		t.Fatalf("no tokens: %v", err)
	}
}
