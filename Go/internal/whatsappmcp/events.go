package whatsappmcp

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strings"
	"time"
)

// The MCP events message.received and question.answered (#1352), polled only: `events/list` and
// `events/poll` of the events draft (experimental-ext-triggers-events), which the Agents
// daemon speaks, in the shape of the Google Chat server's (Go/internal/googlechatmcp/events.go).
// Each carries `sender`, the person on WhatsApp, so the machine raises it only when that
// person has linked their WhatsApp number to themselves (#1762): a message starts nothing for
// anyone else. The names and the filters are the slack and googlechat servers', so one
// workflow can listen to every chat server. A chat on WhatsApp is with one person, so an
// event's space is that person's number, and every message is direct.

// rpcError is a JSON-RPC error answer.
type rpcError struct {
	Code    int            `json:"code"`
	Message string         `json:"message"`
	Data    map[string]any `json:"data,omitempty"`
}

func (e *rpcError) Error() string { return e.Message }

func invalidParams(format string, args ...any) *rpcError {
	return &rpcError{Code: -32602, Message: fmt.Sprintf(format, args...)}
}

const (
	// MessageEvent: a person wrote to the number.
	MessageEvent = "message.received"
	// AnswerEvent: a person pressed an option of a question the number asked.
	AnswerEvent = "question.answered"
)

// EventNames is the events it declares, by name.
func EventNames() []string { return []string{MessageEvent, AnswerEvent} }

func kindOf(name string) (Kind, bool) {
	switch name {
	case MessageEvent:
		return Message, true
	case AnswerEvent:
		return Answer, true
	}
	return "", false
}

// filters are the events' arguments, all strings, none required.
var filters = map[string][]struct{ name, description string }{
	MessageEvent: {
		{"space", "Only messages from this person: their number in international form, digits only, such as 15551234567."},
		{"text", "Only messages whose text matches this pattern, such as start * or *deploy*. * is any text, ? one character; case does not matter."},
		{"direct", "true: every message (each WhatsApp chat is with one person); false: none. For workflows that hear every chat server."},
	},
	AnswerEvent: {
		{"space", "Only answers from this person's number."},
		{"question", "Only answers to this question: the id ask_question gave or was given."},
	},
}

func eventsList() map[string]any {
	str := map[string]any{"type": "string"}
	person := map[string]any{"type": "object", "properties": map[string]any{"wa_id": str, "name": str}}
	common := map[string]any{"space": str, "spaceType": str, "message": str, "replyTo": str, "type": str, "from": person, "date": str}
	message := map[string]any{"text": str}
	answer := map[string]any{"question": str, "answer": str, "label": str}
	for k, v := range common {
		message[k], answer[k] = v, v
	}
	schema := func(name string) map[string]any {
		props := map[string]any{}
		for _, f := range filters[name] {
			props[f.name] = map[string]any{"type": "string", "description": f.description}
		}
		return map[string]any{"type": "object", "properties": props, "required": []string{}, "additionalProperties": false}
	}
	return map[string]any{"events": []any{
		map[string]any{
			"name": MessageEvent, "title": "WhatsApp message",
			"description": "A person wrote to the WhatsApp number: a text, a template's quick reply, or a photo, video or document with a caption. Its data is the space " +
				"(the person's number), the message's id, the message it replied to, who wrote it and its text. It is raised only for a person who linked their " +
				"WhatsApp number, and acts as them. Answer with send_message to the space, with the message as reply_to.",
			"delivery": []string{"poll"}, "inputSchema": schema(MessageEvent),
			"payloadSchema": map[string]any{"type": "object", "properties": message},
		},
		map[string]any{
			"name": AnswerEvent, "title": "WhatsApp answer",
			"description": "A person pressed an option of a question that ask_question sent. Its data is the question's id, the option's id and words (answer, label), " +
				"the space (the person's number), the question's message (replyTo) and who answered. Only the first press of a question counts.",
			"delivery": []string{"poll"}, "inputSchema": schema(AnswerEvent),
			"payloadSchema": map[string]any{"type": "object", "properties": answer},
		},
	}}
}

// args are an event's checked arguments, with the pattern compiled.
type args struct {
	kind            Kind
	space, question string
	text            *regexp.Regexp
	direct          *bool
}

func checkArgs(name string, raw json.RawMessage) (args, *rpcError) {
	kind, _ := kindOf(name)
	a := args{kind: kind}
	given := map[string]json.RawMessage{}
	if len(raw) > 0 && string(raw) != "null" {
		if err := json.Unmarshal(raw, &given); err != nil {
			return a, invalidParams("arguments must be an object")
		}
	}
	names := []string{}
	for _, f := range filters[name] {
		names = append(names, f.name)
	}
	keys := make([]string, 0, len(given))
	for k := range given {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, key := range keys {
		known := false
		for _, n := range names {
			known = known || n == key
		}
		if !known {
			return a, invalidParams("unknown argument %s; %s takes %s", key, name, strings.Join(names, ", "))
		}
		text := strings.TrimSpace(strings.Trim(string(given[key]), `"`))
		if key != "direct" {
			if err := json.Unmarshal(given[key], &text); err != nil || string(given[key]) == "null" {
				return a, invalidParams("%s must be a string", key)
			}
			text = strings.TrimSpace(text)
		}
		switch key {
		case "space":
			a.space = strings.TrimPrefix(text, "+")
		case "question":
			a.question = text
		case "text":
			a.text = glob(text)
		case "direct":
			switch strings.ToLower(text) {
			case "true":
				yes := true
				a.direct = &yes
			case "false":
				no := false
				a.direct = &no
			case "", "null":
			default:
				return a, invalidParams("direct must be true or false")
			}
		}
	}
	return a, nil
}

// glob is a pattern of * and ? over the whole text, case folded; nil when empty.
func glob(pattern string) *regexp.Regexp {
	if pattern == "" {
		return nil
	}
	var b strings.Builder
	b.WriteString(`(?is)^`)
	for _, r := range pattern {
		switch r {
		case '*':
			b.WriteString(`.*`)
		case '?':
			b.WriteString(`.`)
		default:
			b.WriteString(regexp.QuoteMeta(string(r)))
		}
	}
	b.WriteString(`$`)
	return regexp.MustCompile(b.String())
}

func (a args) match(it Item) bool {
	return it.Kind == a.kind &&
		(a.space == "" || it.From.WaID == a.space) &&
		(a.question == "" || it.Question == a.question) &&
		(a.text == nil || a.text.MatchString(it.Text)) &&
		(a.direct == nil || *a.direct)
}

// senderOf is who did it, for a channel link (#1762): their number, which WhatsApp checked
// when they signed up, with the name of their profile. WhatsApp gives no email address, so the
// first message asks the admins.
func senderOf(it Item) map[string]any {
	s := map[string]any{"channel": Provider, "identity": it.From.WaID}
	if it.From.Name != "" {
		s["name"] = it.From.Name
	}
	return s
}

func dataOf(it Item) map[string]any {
	d := map[string]any{"space": it.From.WaID, "spaceType": "DIRECT_MESSAGE", "message": it.ID, "replyTo": it.ReplyTo, "type": it.Type,
		"from": map[string]any{"wa_id": it.From.WaID, "name": it.From.Name}, "date": it.At.UTC().Format(time.RFC3339)}
	if it.Kind == Answer {
		d["question"], d["answer"], d["label"] = it.Question, it.Answer, it.Label
	} else {
		d["text"] = it.Text
	}
	return d
}

// MARK: The cursor

// cursor is where a poll has got to: the run of the server and the last item looked at. A
// client keeps it as an opaque string (base64url of its JSON).
type cursor struct {
	Boot string `json:"boot"`
	Seq  uint64 `json:"seq"`
}

func (c cursor) encoded() string {
	data, _ := json.Marshal(c)
	return base64.RawURLEncoding.EncodeToString(data)
}

func decodeCursor(raw json.RawMessage) (cursor, *rpcError) {
	refused := invalidParams("cursor is not one this server gave")
	var text string
	if err := json.Unmarshal(raw, &text); err != nil {
		return cursor{}, refused
	}
	data, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(text, "="))
	if err != nil {
		return cursor{}, refused
	}
	var c cursor
	if json.Unmarshal(data, &c) != nil || c.Boot == "" {
		return cursor{}, refused
	}
	return c, nil
}

// MARK: Polling

const (
	maxEvents = 100
	// nextPollMs is short: the inbox is in memory, so a poll costs Meta nothing.
	nextPollMs = 3000
)

type pollParams struct {
	Name      string          `json:"name"`
	Arguments json.RawMessage `json:"arguments"`
	Cursor    json.RawMessage `json:"cursor"`
	MaxEvents *int            `json:"maxEvents"`
}

// Events answers events/poll over an Inbox, whose webhook it starts with Context.
type Events struct {
	Inbox   *Inbox
	Context context.Context
}

// Poll answers events/poll's params.
func (s *Events) Poll(_ context.Context, raw json.RawMessage) (map[string]any, *rpcError) {
	var p pollParams
	if err := json.Unmarshal(raw, &p); err != nil {
		return nil, invalidParams("params must be an object")
	}
	if _, ok := kindOf(p.Name); !ok {
		return nil, &rpcError{Code: -32011, Message: fmt.Sprintf("no event %s; this server offers %s", p.Name, strings.Join(EventNames(), " and "))}
	}
	a, bad := checkArgs(p.Name, p.Arguments)
	if bad != nil {
		return nil, bad
	}
	if _, err := s.Inbox.Account(); err != nil {
		return nil, eventsError(err)
	}
	s.Inbox.Start(s.Context)
	limit := 50
	if p.MaxEvents != nil {
		limit = *p.MaxEvents
	}
	limit = min(maxEvents, max(1, limit))
	boot, head := s.Inbox.Head()
	answer := func(events []any, c cursor, more bool) map[string]any {
		return map[string]any{"events": events, "cursor": c.encoded(), "truncated": false, "hasMore": more, "nextPollMs": nextPollMs}
	}
	if len(p.Cursor) == 0 || string(p.Cursor) == "null" {
		return answer([]any{}, cursor{Boot: boot, Seq: head}, false), nil
	}
	c, bad := decodeCursor(p.Cursor)
	if bad != nil {
		return nil, bad
	}
	if c.Boot != boot {
		// An earlier run's cursor: everything this run holds came after it.
		c = cursor{Boot: boot}
	}
	found, more, failure := s.Inbox.After(c.Seq, limit)
	if failure != nil && len(found) == 0 {
		return nil, eventsError(failure)
	}
	out := []any{}
	next := c
	for _, it := range found {
		next.Seq = it.Seq
		if !a.match(it) {
			continue
		}
		name := MessageEvent
		if it.Kind == Answer {
			name = AnswerEvent
		}
		out = append(out, map[string]any{
			"eventId": name + ":" + it.ID, "name": name, "timestamp": it.At.UTC().Format(time.RFC3339),
			"data": dataOf(it), "sender": senderOf(it),
		})
	}
	return answer(out, next, more), nil
}

// eventsError is a failure as the events draft's error codes.
func eventsError(err error) *rpcError {
	var notSignedIn *NotSignedInError
	if errors.Is(err, ErrNotConnected) || errors.As(err, &notSignedIn) {
		return &rpcError{Code: -32012, Message: err.Error(), Data: map[string]any{"reason": "not connected"}}
	}
	return &rpcError{Code: -32603, Message: err.Error()}
}
