package channels

import (
	"context"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

// The Slack adapter against a fake Slack: SlackChannelTests' first part.

const member = "U0ALEX"

var teaOrCoffee = NeedMessage{Key: "h1|elicitation:A", Heading: "work · Fix the test", Question: "Tea or coffee?",
	Options: []Option{{Value: "tea", Title: "Tea"}, {Value: "coffee", Title: "Coffee"}}, TakesText: true}

type heardLog struct {
	mu       sync.Mutex
	replies  []ChannelReply
	statuses []ChannelStatus
}

func (h *heardLog) all() []ChannelReply {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]ChannelReply(nil), h.replies...)
}

func (h *heardLog) status() ChannelStatus {
	h.mu.Lock()
	defer h.mu.Unlock()
	if len(h.statuses) == 0 {
		return ChannelStatus{}
	}
	return h.statuses[len(h.statuses)-1]
}

func (h *heardLog) reply(r ChannelReply) {
	h.mu.Lock()
	h.replies = append(h.replies, r)
	h.mu.Unlock()
}
func (h *heardLog) state(s ChannelStatus) {
	h.mu.Lock()
	h.statuses = append(h.statuses, s)
	h.mu.Unlock()
}

func connected(t *testing.T, slack *fakeSlack) (*SlackChannel, *heardLog) {
	t.Helper()
	channel := NewSlackChannel(SlackTokens{App: "xapp-1", Bot: "xoxb-1"}, member, slack,
		func(int) time.Duration { return 10 * time.Millisecond }, nil)
	heard := &heardLog{}
	channel.Start(heard.reply, heard.state)
	t.Cleanup(channel.Stop)
	eventually(t, "connected", func() bool { return heard.status().State == StatusConnected })
	return channel, heard
}

func blocksOf(t *testing.T, body map[string]any) []map[string]any {
	t.Helper()
	raw, ok := body["blocks"].([]any)
	if !ok {
		t.Fatalf("no blocks in %v", body)
	}
	var out []map[string]any
	for _, b := range raw {
		out = append(out, b.(map[string]any))
	}
	return out
}

func actionsOf(blocks []map[string]any) map[string]any {
	for _, b := range blocks {
		if b["type"] == "actions" {
			return b
		}
	}
	return nil
}

func TestAQuestionGoesToTheMembersDirectMessagesWithItsOptionsAsButtons(t *testing.T) {
	slack := newFakeSlack()
	channel, _ := connected(t, slack)
	if err := channel.Send(context.Background(), teaOrCoffee); err != nil {
		t.Fatal(err)
	}
	if got := slack.made("apps.connections.open"); len(got) == 0 || got[0].token != "xapp-1" {
		t.Fatalf("apps.connections.open: %v", got)
	}
	open := slack.made("conversations.open")
	if len(open) != 1 || open[0].body["users"] != member || open[0].token != "xoxb-1" {
		t.Fatalf("conversations.open: %v", open)
	}
	post := slack.made("chat.postMessage")[0]
	if post.body["channel"] != "D1" || !strings.Contains(post.body["text"].(string), "Tea or coffee?") {
		t.Fatalf("post: %v", post.body)
	}
	actions := actionsOf(blocksOf(t, post.body))
	if actions["block_id"] != teaOrCoffee.Key {
		t.Fatalf("block_id: %v", actions)
	}
	var values []string
	for _, e := range actions["elements"].([]any) {
		values = append(values, e.(map[string]any)["value"].(string))
	}
	if !reflect.DeepEqual(values, []string{"tea", "coffee"}) {
		t.Fatalf("values: %v", values)
	}
	first := actions["elements"].([]any)[0].(map[string]any)
	if first["text"].(map[string]any)["text"] != "Tea" {
		t.Fatalf("title: %v", first)
	}
}

func TestOnlyTheTiedMembersButtonIsHeardAndEveryEnvelopeIsAcknowledged(t *testing.T) {
	slack := newFakeSlack()
	channel, heard := connected(t, slack)
	if err := channel.Send(context.Background(), teaOrCoffee); err != nil {
		t.Fatal(err)
	}
	slack.press("coffee", teaOrCoffee.Key, "U0SOMEONE")
	slack.press("tea", "h1|elicitation:NOT-SENT", member)
	slack.press("tea", teaOrCoffee.Key, member)
	want := []ChannelReply{{Kind: Picked, Key: teaOrCoffee.Key, Value: "tea"}}
	eventually(t, "the press", func() bool { return reflect.DeepEqual(heard.all(), want) })
	eventually(t, "three acks", func() bool { return len(slack.socket().acks()) == 3 })
	if len(heard.all()) != 1 {
		t.Fatalf("heard %v", heard.all())
	}
}

func TestAReplyInTheQuestionsThreadIsHeardAndNothingElseIs(t *testing.T) {
	slack := newFakeSlack()
	channel, heard := connected(t, slack)
	if err := channel.Send(context.Background(), teaOrCoffee); err != nil {
		t.Fatal(err)
	}
	ts := slack.lastTS()
	slack.reply("not in a thread", "", member, false)
	slack.reply("someone else", ts, "U0SOMEONE", false)
	slack.reply("the bot itself", ts, member, true)
	slack.reply("another thread", "1.2", member, false)
	slack.reply("Coffee, please", ts, member, false)
	want := []ChannelReply{{Kind: Wrote, Key: teaOrCoffee.Key, Value: "Coffee, please"}}
	eventually(t, "the reply", func() bool { return reflect.DeepEqual(heard.all(), want) })
	eventually(t, "five acks", func() bool { return len(slack.socket().acks()) == 5 })
	if len(heard.all()) != 1 {
		t.Fatalf("heard %v", heard.all())
	}
}

func TestAClosedQuestionLosesItsButtonsAndSaysWhy(t *testing.T) {
	slack := newFakeSlack()
	channel, heard := connected(t, slack)
	ctx := context.Background()
	if err := channel.Send(ctx, teaOrCoffee); err != nil {
		t.Fatal(err)
	}
	channel.Note(ctx, teaOrCoffee.Key, "Pick one of the buttons.")
	channel.Close(ctx, teaOrCoffee.Key, "Answered: Tea")

	posts := slack.made("chat.postMessage")
	if note := posts[len(posts)-1]; note.body["thread_ts"] != slack.lastTS() {
		t.Fatalf("note: %v", note.body)
	}
	updates := slack.made("chat.update")
	if len(updates) != 1 || updates[0].body["ts"] != slack.lastTS() {
		t.Fatalf("update: %v", updates)
	}
	blocks := blocksOf(t, updates[0].body)
	if actionsOf(blocks) != nil {
		t.Fatal("a closed question kept its buttons")
	}
	last := blocks[len(blocks)-1]["elements"].([]any)[0].(map[string]any)
	if last["text"] != "Answered: Tea" {
		t.Fatalf("closing words: %v", last)
	}
	// Closed: a late press answers nothing.
	slack.press("tea", teaOrCoffee.Key, member)
	eventually(t, "one ack", func() bool { return len(slack.socket().acks()) == 1 })
	if len(heard.all()) != 0 {
		t.Fatalf("heard %v", heard.all())
	}
}

func TestItConnectsAgainWhenSlackSaysToGo(t *testing.T) {
	slack := newFakeSlack()
	_, heard := connected(t, slack)
	slack.socket().push(map[string]any{"type": "disconnect", "reason": "refresh_requested"})
	eventually(t, "connected again", func() bool {
		return slack.connections() == 2 && heard.status().State == StatusConnected
	})
	if n := len(slack.made("apps.connections.open")); n != 2 {
		t.Fatalf("apps.connections.open %d times", n)
	}
}

func TestARefusedTokenIsSaidInWords(t *testing.T) {
	slack := newFakeSlack()
	slack.refuse["apps.connections.open"] = "invalid_auth"
	channel := NewSlackChannel(SlackTokens{App: "xapp-1", Bot: "xoxb-1"}, member, slack,
		func(int) time.Duration { return time.Minute }, nil)
	heard := &heardLog{}
	channel.Start(heard.reply, heard.state)
	t.Cleanup(channel.Stop)
	eventually(t, "the refusal", func() bool {
		s := heard.status()
		return s.State == StatusFailed && strings.Contains(s.Words, "Check the app and bot tokens")
	})
}

func TestBackoffDoublesToTwoMinutes(t *testing.T) {
	var got []time.Duration
	for attempt := range 8 {
		got = append(got, SlackBackoff(attempt)/time.Second)
	}
	if !reflect.DeepEqual(got, []time.Duration{2, 4, 8, 16, 32, 64, 120, 120}) {
		t.Fatalf("backoff %v", got)
	}
}

func TestSlackTextIsEscapedAndTheHintFitsTheQuestion(t *testing.T) {
	m := NeedMessage{Key: "k", Question: "a < b & c > d", TakesText: true}
	blocks := slackBlocks(m, nil)
	section := blocks[0].(map[string]any)["text"].(map[string]any)["text"]
	if section != "*a &lt; b &amp; c &gt; d*" {
		t.Fatalf("section %v", section)
	}
	hint := func(m NeedMessage) any {
		b := slackBlocks(m, nil)
		return b[len(b)-1].(map[string]any)["elements"].([]any)[0].(map[string]any)["text"]
	}
	if h := hint(m); h != "Reply in this thread to answer." {
		t.Fatalf("hint %v", h)
	}
	if h := hint(teaOrCoffee); h != "Press one, or reply in this thread." {
		t.Fatalf("hint %v", h)
	}
	if h := hint(NeedMessage{AnswerElsewhere: true}); h != "Answer this one in Agents." {
		t.Fatalf("hint %v", h)
	}
	if f := slackFallback(NeedMessage{Question: "Q"}); f != "An agent needs you: Q" {
		t.Fatalf("fallback %v", f)
	}
}
