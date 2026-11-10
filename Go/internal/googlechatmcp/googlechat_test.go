package googlechatmcp

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

const fakeKey = `{"type":"service_account","project_id":"my-chat-app","client_email":"agents@my-chat-app.iam.gserviceaccount.com","private_key":"x"}`

func TestTheAccountComesFromTheKeyAndTheSubscription(t *testing.T) {
	env := func(vars map[string]string) func(string) string { return func(k string) string { return vars[k] } }

	if _, err := AccountFrom(env(nil)); err != ErrNotConnected {
		t.Fatalf("no key: %v", err)
	}
	a, err := AccountFrom(env(map[string]string{"GOOGLE_CHAT_CREDENTIALS": fakeKey}))
	if err != nil || a.Subscription != "projects/my-chat-app/subscriptions/agents-chat" || string(a.Credentials) != fakeKey {
		t.Fatalf("the key alone: %+v %v", a, err)
	}
	path := filepath.Join(t.TempDir(), "key.json")
	if err := os.WriteFile(path, []byte(fakeKey+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	a, err = AccountFrom(env(map[string]string{"GOOGLE_CHAT_CREDENTIALS": path, "GOOGLE_CHAT_SUBSCRIPTION": "chat-in"}))
	if err != nil || a.Subscription != "projects/my-chat-app/subscriptions/chat-in" || string(a.Credentials) != fakeKey {
		t.Fatalf("a key file and a short name: %+v %v", a, err)
	}
	a, err = AccountFrom(env(map[string]string{"GOOGLE_CHAT_CREDENTIALS": fakeKey, "GOOGLE_CHAT_SUBSCRIPTION": "projects/other-proj/subscriptions/sub-1"}))
	if err != nil || a.Subscription != "projects/other-proj/subscriptions/sub-1" {
		t.Fatalf("a full name: %+v %v", a, err)
	}
	for _, bad := range []map[string]string{
		{"GOOGLE_CHAT_CREDENTIALS": `{"type":"authorized_user"}`},
		{"GOOGLE_CHAT_CREDENTIALS": "/no/such/key.json"},
		{"GOOGLE_CHAT_CREDENTIALS": fakeKey, "GOOGLE_CHAT_SUBSCRIPTION": "projects/x/topics/y"},
	} {
		if _, err := AccountFrom(env(bad)); err == nil {
			t.Fatalf("%v: no error", bad)
		}
	}
}

// poll is one events/poll, as the daemon sends it.
func poll(t *testing.T, e *Events, name string, args map[string]any, cursor any) ([]map[string]any, any) {
	t.Helper()
	params := map[string]any{"name": name, "arguments": args}
	if cursor != nil {
		params["cursor"] = cursor
	}
	raw, _ := json.Marshal(params)
	result, err := e.Poll(context.Background(), raw)
	if err != nil {
		t.Fatalf("poll %s: %v", name, err)
	}
	out := []map[string]any{}
	for _, ev := range result["events"].([]any) {
		data, _ := json.Marshal(ev)
		var m map[string]any
		_ = json.Unmarshal(data, &m)
		out = append(out, m)
	}
	return out, result["cursor"]
}

// eventually polls until want events come, or fails.
func eventually(t *testing.T, e *Events, name string, args map[string]any, cursor any, want int) ([]map[string]any, any) {
	t.Helper()
	var got []map[string]any
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		var next any
		var some []map[string]any
		some, next = poll(t, e, name, args, cursor)
		got, cursor = append(got, some...), next
		if len(got) >= want {
			return got, cursor
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("%s: %d events, want %d", name, len(got), want)
	return nil, nil
}

func TestMessagesAndAnswersAreRaisedWithTheirSender(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	f := newFakeGoogle(t)
	g := f.google()
	inbox := NewInbox(g, slog.New(slog.NewTextHandler(io.Discard, nil)))
	inbox.Answered = MarkAnswered(g, nil)
	e := &Events{Inbox: inbox, Context: ctx}

	// The first poll gives a cursor at now, and starts the loop.
	none, messages := poll(t, e, MessageEvent, nil, nil)
	_, answers := poll(t, e, AnswerEvent, nil, nil)
	_, direct := poll(t, e, MessageEvent, map[string]any{"direct": "true"}, nil)
	if len(none) != 0 {
		t.Fatalf("the first poll: %v", none)
	}
	<-f.pulled

	f.send(chatEvent("ADDED_TO_SPACE", "spaces/AAA", "SPACE", sam, nil))
	f.send(chatEvent("MESSAGE", "spaces/AAA", "SPACE", sam, map[string]any{"message": map[string]any{
		"name": "spaces/AAA/messages/x1", "text": "@Agents start fixing the build", "argumentText": " start fixing the build",
		"thread": map[string]any{"name": "spaces/AAA/threads/th1"}}}))
	bot := map[string]any{"name": "users/222", "displayName": "Bot", "type": "BOT"}
	f.send(chatEvent("MESSAGE", "spaces/AAA", "SPACE", bot, map[string]any{"message": map[string]any{"name": "spaces/AAA/messages/x2", "text": "hi"}}))
	f.send(chatEvent("MESSAGE", "spaces/DM1", "DIRECT_MESSAGE", sam, map[string]any{"message": map[string]any{"name": "spaces/DM1/messages/x3", "text": "hello"}}))
	click := map[string]any{"message": map[string]any{"name": "spaces/AAA/messages/q1", "thread": map[string]any{"name": "spaces/AAA/threads/th2"}},
		"common": map[string]any{"invokedFunction": answerFunction, "parameters": map[string]any{"question": "s-42", "answer": "yes", "label": "Yes, merge it"}}}
	f.send(chatEvent("CARD_CLICKED", "spaces/AAA", "SPACE", sam, click))
	f.send(chatEvent("CARD_CLICKED", "spaces/AAA", "SPACE", sam, click)) // a second press

	got, _ := eventually(t, e, MessageEvent, nil, messages, 2)
	if len(got) != 2 {
		t.Fatalf("messages: %v", got)
	}
	first := got[0]
	data := first["data"].(map[string]any)
	if first["name"] != MessageEvent || data["text"] != "start fixing the build" || data["thread"] != "spaces/AAA/threads/th1" ||
		data["space"] != "spaces/AAA" || data["spaceType"] != "SPACE" {
		t.Fatalf("the message: %v", first)
	}
	if want := map[string]any{"channel": "googlechat", "identity": "users/111", "name": "Sam", "email": "sam@example.com"}; !reflect.DeepEqual(first["sender"], want) {
		t.Fatalf("its sender: %v", first["sender"])
	}
	if dm, _ := eventually(t, e, MessageEvent, map[string]any{"direct": "true"}, direct, 1); len(dm) != 1 || dm[0]["data"].(map[string]any)["text"] != "hello" {
		t.Fatalf("direct messages: %v", dm)
	}

	got, _ = eventually(t, e, AnswerEvent, nil, answers, 1)
	if len(got) != 1 {
		t.Fatalf("answers (a second press counts once): %v", got)
	}
	data = got[0]["data"].(map[string]any)
	if data["question"] != "s-42" || data["answer"] != "yes" || data["label"] != "Yes, merge it" || data["message"] != "spaces/AAA/messages/q1" {
		t.Fatalf("the answer: %v", got[0])
	}

	// Everything pulled is acknowledged, and the answered card loses its buttons.
	deadline := time.Now().Add(5 * time.Second)
	for {
		acked, _, edited := f.snapshot()
		if len(acked) == 6 && len(edited) == 1 {
			card, _ := json.Marshal(edited[0])
			if edited[0]["_name"] != "spaces/AAA/messages/q1" || edited[0]["_mask"] != "cardsV2" ||
				!strings.Contains(string(card), `\u003cb\u003eSam\u003c/b\u003e answered: Yes, merge it`) || strings.Contains(string(card), "buttonList") {
				t.Fatalf("the edited card: %s", card)
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("acked %v, edited %v", acked, edited)
		}
		time.Sleep(20 * time.Millisecond)
	}

	// A cursor from an earlier run reads all this run holds.
	stale := cursor{Boot: "earlier", Seq: 99}.encoded()
	if all, _ := poll(t, e, MessageEvent, map[string]any{"text": "start *"}, stale); len(all) != 1 {
		t.Fatalf("an earlier run's cursor, text start *: %v", all)
	}
}

func TestPollRefusesWhatItDoesNotOffer(t *testing.T) {
	f := newFakeGoogle(t)
	e := &Events{Inbox: NewInbox(f.google(), nil), Context: t.Context()}
	for _, params := range []map[string]any{
		{"name": "chat.deleted"},
		{"name": MessageEvent, "arguments": map[string]any{"question": "q"}},
		{"name": MessageEvent, "arguments": map[string]any{"direct": "maybe"}},
		{"name": MessageEvent, "cursor": "not-ours"},
	} {
		raw, _ := json.Marshal(params)
		if _, err := e.Poll(context.Background(), raw); err == nil {
			t.Fatalf("%v: no error", params)
		}
	}
	off := &Events{Inbox: NewInbox(&Google{Account: func() (Account, error) { return Account{}, ErrNotConnected }}, nil), Context: t.Context()}
	raw, _ := json.Marshal(map[string]any{"name": MessageEvent})
	if _, err := off.Poll(context.Background(), raw); err == nil || err.Code != -32012 {
		t.Fatalf("not connected: %v", err)
	}
}

// The front as the Agents daemon talks to it: initialize carries the events capability, the
// events are answered here, and the tools post through the Chat API.
func TestTheFrontOffersTheEventsAndTools(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	f := newFakeGoogle(t)
	g := f.google()
	ev := &Events{Inbox: NewInbox(g, nil), Context: ctx}
	front := &Front{Events: ev, Upstream: NewServer("test", ev), Version: "test",
		Logger: slog.New(slog.NewTextHandler(io.Discard, nil))}
	clientIn, frontOut := io.Pipe()
	frontIn, clientOut := io.Pipe()
	go func() { _ = front.Serve(ctx, frontIn, frontOut); _ = frontOut.Close() }()
	defer clientOut.Close()

	lines := bufio.NewScanner(clientIn)
	lines.Buffer(nil, 16<<20)
	send := func(msg map[string]any) {
		data, _ := json.Marshal(msg)
		if _, err := clientOut.Write(append(data, '\n')); err != nil {
			t.Fatal(err)
		}
	}
	call := func(id int, method string, params any) map[string]any {
		t.Helper()
		send(map[string]any{"jsonrpc": "2.0", "id": id, "method": method, "params": params})
		for lines.Scan() {
			var reply map[string]any
			if err := json.Unmarshal(lines.Bytes(), &reply); err != nil {
				t.Fatalf("%s: %v", lines.Text(), err)
			}
			if reply["id"] == float64(id) {
				return reply
			}
		}
		t.Fatalf("%s: no answer (%v)", method, lines.Err())
		return nil
	}
	tool := func(id int, name string, args map[string]any) map[string]any {
		t.Helper()
		result := call(id, "tools/call", map[string]any{"name": name, "arguments": args})["result"].(map[string]any)
		if result["isError"] == true {
			t.Fatalf("%s: %v", name, result["content"])
		}
		return result["structuredContent"].(map[string]any)
	}

	init := call(1, "initialize", map[string]any{"protocolVersion": "2025-06-18", "capabilities": map[string]any{},
		"clientInfo": map[string]any{"name": "Agents", "version": "1"}})["result"].(map[string]any)
	if !reflect.DeepEqual(init["capabilities"].(map[string]any)["events"], map[string]any{"listChanged": false}) ||
		init["serverInfo"].(map[string]any)["name"] != "googlechat-mcp" || init["instructions"] != Instructions {
		t.Fatalf("initialize: %v", init)
	}
	send(map[string]any{"jsonrpc": "2.0", "method": "notifications/initialized"})

	listed := call(2, "events/list", map[string]any{})["result"].(map[string]any)["events"].([]any)
	var events []string
	for _, ev := range listed {
		events = append(events, ev.(map[string]any)["name"].(string))
	}
	if !reflect.DeepEqual(events, EventNames()) {
		t.Fatalf("events/list: %v", events)
	}

	tools := call(3, "tools/list", map[string]any{})["result"].(map[string]any)["tools"].([]any)
	var names []string
	for _, tl := range tools {
		names = append(names, tl.(map[string]any)["name"].(string))
	}
	if want := []string{"ask_question", "list_conversations", "list_spaces", "read_messages", "reply", "send_message"}; !reflect.DeepEqual(names, want) {
		t.Fatalf("tools: %v", names)
	}

	spaces := tool(4, "list_spaces", map[string]any{})["spaces"].([]any)
	if len(spaces) != 2 || spaces[0].(map[string]any)["name"] != "spaces/AAA" || spaces[1].(map[string]any)["type"] != "DIRECT_MESSAGE" {
		t.Fatalf("list_spaces: %v", spaces)
	}
	sent := tool(5, "send_message", map[string]any{"space": "spaces/AAA", "text": "On it.", "thread": "spaces/AAA/threads/th1"})
	if sent["thread"] != "spaces/AAA/threads/th1" || !strings.HasPrefix(sent["message"].(string), "spaces/AAA/messages/") {
		t.Fatalf("send_message: %v", sent)
	}
	asked := tool(6, "ask_question", map[string]any{"space": "spaces/AAA", "question": "Merge <PR 12>?", "id": "s-42", "title": "Fix the build",
		"options": []any{map[string]any{"id": "yes", "label": "Merge"}, map[string]any{"id": "no", "label": "Not yet"}}})
	if asked["question"] != "s-42" {
		t.Fatalf("ask_question: %v", asked)
	}
	_, posted, _ := f.snapshot()
	if len(posted) != 2 || posted[0]["text"] != "On it." || posted[0]["_replyOption"] != "REPLY_MESSAGE_FALLBACK_TO_NEW_THREAD" {
		t.Fatalf("posted: %v", posted)
	}
	card, _ := json.Marshal(posted[1]["cardsV2"])
	for _, want := range []string{`"cardId":"question-s-42"`, `"title":"Fix the build"`, "Merge \\u0026lt;PR 12\\u0026gt;?", `"function":"agents.answer"`,
		`{"key":"question","value":"s-42"}`, `{"key":"answer","value":"no"}`, `"text":"Not yet"`} {
		if !strings.Contains(string(card), want) {
			t.Fatalf("the question's card has no %s: %s", want, card)
		}
	}
	if posted[1]["fallbackText"] != "Merge <PR 12>?" {
		t.Fatalf("the question's fallback text: %v", posted[1])
	}

	for i, bad := range []map[string]any{
		{"space": "AAA", "text": "x"},
		{"space": "spaces/AAA", "text": "x", "thread": "spaces/BBB/threads/t"},
		{"space": "spaces/AAA", "text": "  "},
	} {
		if r := call(10+i, "tools/call", map[string]any{"name": "send_message", "arguments": bad})["result"].(map[string]any); r["isError"] != true {
			t.Fatalf("send_message %v: %v", bad, r)
		}
	}
	for i, bad := range []map[string]any{
		{"space": "spaces/AAA", "question": "q", "options": []any{map[string]any{"id": "a", "label": "A"}}},
		{"space": "spaces/AAA", "question": "q", "options": []any{map[string]any{"id": "a", "label": "A"}, map[string]any{"id": "a", "label": "B"}}},
		{"space": "spaces/AAA", "question": "q", "id": "no spaces", "options": []any{map[string]any{"id": "a", "label": "A"}, map[string]any{"id": "b", "label": "B"}}},
	} {
		if r := call(20+i, "tools/call", map[string]any{"name": "ask_question", "arguments": bad})["result"].(map[string]any); r["isError"] != true {
			t.Fatalf("ask_question %v: %v", bad, r)
		}
	}

	// A refused key says to check it.
	f.mu.Lock()
	f.refuse = http.StatusUnauthorized
	f.mu.Unlock()
	r := call(30, "tools/call", map[string]any{"name": "list_spaces", "arguments": map[string]any{}})["result"].(map[string]any)
	if r["isError"] != true || !strings.Contains(r["content"].([]any)[0].(map[string]any)["text"].(string), "GOOGLE_CHAT_CREDENTIALS") {
		t.Fatalf("a refused key: %v", r)
	}
}
