package slackmcp

import (
	"context"
	"encoding/json"
	"reflect"
	"strings"
	"testing"
	"time"
)

// The listener over the fake's Socket Mode: each envelope is acknowledged, a person's
// message and an answer come out of events/poll with their sender, and the bot's own
// messages, other bots' and edits do not.

func posted(envelope, channel, user, ts, text string, extra map[string]any) map[string]any {
	event := map[string]any{"type": "message", "channel": channel, "user": user, "ts": ts, "text": text, "channel_type": "channel"}
	for k, v := range extra {
		event[k] = v
	}
	return map[string]any{"envelope_id": envelope, "type": "events_api", "accepts_response_payload": false,
		"payload": map[string]any{"token": "x", "team_id": fakeTeam, "api_app_id": "A1", "type": "event_callback",
			"event_id": "Ev" + envelope, "event_time": 1762300000, "event": event}}
}

func press(envelope, question, channel, ts, user string, index int, label string) map[string]any {
	return map[string]any{"envelope_id": envelope, "type": "interactive", "accepts_response_payload": false,
		"payload": map[string]any{"type": "block_actions", "team": map[string]any{"id": fakeTeam},
			"user":      map[string]any{"id": user, "team_id": fakeTeam},
			"channel":   map[string]any{"id": channel},
			"container": map[string]any{"type": "message", "message_ts": ts, "channel_id": channel},
			"message":   map[string]any{"type": "message", "ts": ts, "text": "Ship it?"},
			"actions": []any{map[string]any{"type": "button", "action_id": "answer-1", "block_id": questionBlock + question,
				"value": "1", "text": map[string]any{"type": "plain_text", "text": label}}}}}
}

func TestTheListenerBringsMessagesAndAnswersIn(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	f := newFakeSlack(t)
	w := f.workspace()
	inbox := NewInbox()
	l := &Listener{Workspace: w, Inbox: inbox, Logger: quiet()}
	events := &Events{Workspace: w, Inbox: inbox, Listener: l}
	poll := func(name string, arguments map[string]any, cursor any) map[string]any {
		t.Helper()
		raw, _ := json.Marshal(map[string]any{"name": name, "arguments": arguments, "cursor": cursor})
		r, err := events.Poll(ctx, raw)
		if err != nil {
			t.Fatalf("poll %s: %v", name, err)
		}
		return r
	}
	start := poll(MessageReceived, nil, nil)["cursor"]
	go l.Run(ctx)

	f.envelopes <- posted("e1", "C1", "UBOT", "1762300001.000100", "my own", nil)
	f.envelopes <- posted("e2", "C1", "U9", "1762300002.000100", "a bot", map[string]any{"bot_id": "B9"})
	f.envelopes <- posted("e3", "C1", "U2", "1762300003.000100", "edited", map[string]any{"subtype": "message_changed"})
	f.envelopes <- posted("e4", "C1", "U2", "1762300004.000100", "<@UBOT> deploy please", nil)
	f.envelopes <- posted("e5", "C1", "U2", "1762300005.000100", "in the thread", map[string]any{"thread_ts": "1762300004.000100"})
	f.envelopes <- press("e6", "q1", "C1", "1762300006.000100", "U2", 1, "No")
	f.envelopes <- press("e7", "q1", "C1", "1762300006.000100", "U3", 0, "Yes")

	deadline := time.Now().Add(20 * time.Second)
	for len(f.acked()) < 7 || inbox.last() < 3 {
		if time.Now().After(deadline) {
			t.Fatalf("acks %v, %d events", f.acked(), inbox.last())
		}
		time.Sleep(20 * time.Millisecond)
	}
	if got := f.acked(); !reflect.DeepEqual(got, []string{"e1", "e2", "e3", "e4", "e5", "e6", "e7"}) {
		t.Fatalf("acks: %v", got)
	}

	got := poll(MessageReceived, nil, start)["events"].([]any)
	if len(got) != 2 {
		t.Fatalf("messages: %v", got)
	}
	first := got[0].(map[string]any)
	data := first["data"].(map[string]any)
	if first["eventId"] != "message.received:C1:1762300004.000100" || data["mentioned"] != true || data["user"] != "U2" ||
		data["threadTs"] != "" || data["team"] != fakeTeam {
		t.Fatalf("first message: %v", first)
	}
	if _, ok := data["text"]; ok {
		t.Fatal("an event has the message's text")
	}
	// Its envelope (#4728): the message's ref, and no key, as a message comes once.
	if _, keyed := first["key"]; first["subject"] != "slack:message:t1/c1#1762300004.000100" || keyed {
		t.Fatalf("the message's subject and key: %v %v", first["subject"], first["key"])
	}
	if sender := first["sender"].(map[string]any); !reflect.DeepEqual(sender,
		map[string]any{"channel": "slack", "identity": "T1/U2", "name": "Sam", "email": "sam@example.com"}) {
		t.Fatalf("sender: %v", sender)
	}
	reply := got[1].(map[string]any)["data"].(map[string]any)
	if reply["threadTs"] != "1762300004.000100" || reply["mentioned"] != false {
		t.Fatalf("reply: %v", reply)
	}
	if thread := poll(MessageReceived, map[string]any{"thread": "1762300004.000100"}, start)["events"].([]any); len(thread) != 1 {
		t.Fatalf("thread filter: %v", thread)
	}
	if mentions := poll(MessageReceived, map[string]any{"mentions": true}, start)["events"].([]any); len(mentions) != 1 {
		t.Fatalf("mentions filter: %v", mentions)
	}

	answers := poll(QuestionAnswered, map[string]any{"question": "q1"}, start)["events"].([]any)
	if len(answers) != 1 {
		t.Fatalf("only the first answer counts: %v", answers)
	}
	answer := answers[0].(map[string]any)["data"].(map[string]any)
	if answer["option"] != "No" || answer["index"] != 1 || answer["user"] != "U2" || answer["ts"] != "1762300006.000100" {
		t.Fatalf("answer: %v", answer)
	}
	updates := f.called("chat.update")
	if len(updates) != 1 || updates[0].Get("ts") != "1762300006.000100" || !strings.Contains(updates[0].Get("blocks"), "\\u003c@U2\\u003e answered: *No*") &&
		!strings.Contains(updates[0].Get("blocks"), "<@U2> answered: *No*") {
		t.Fatalf("chat.update: %v", updates)
	}
	if strings.Contains(updates[0].Get("blocks"), "actions") {
		t.Fatalf("the answered question kept its buttons: %v", updates[0].Get("blocks"))
	}
}
