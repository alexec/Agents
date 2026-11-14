package googlechatmcp

import (
	"context"
	"encoding/json"
	"errors"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/agentloops-dev/agents/Go/internal/mcpevents"
	"github.com/agentloops-dev/agents/Go/wire"
)

// The MCP events message.received and question.answered (#1016), polled only: `events/list` and
// `events/poll` of the events draft (experimental-ext-triggers-events), which the Agents
// daemon speaks, in the shape of the email server's (Go/internal/emailmcp/events.go). Each
// carries `sender`, the person on Google Chat, so the machine raises it only when that person
// has linked their Google Chat user to themselves (#1762): a message starts nothing for
// anyone else. The names are the slack server's (Go/internal/slackmcp), so one workflow can
// listen to both chat servers.

// rpcError is a JSON-RPC error answer: its code, message and optional data.
type rpcError = mcpevents.Error

func invalidParams(format string, args ...any) *rpcError {
	return mcpevents.InvalidParams(format, args...)
}

const (
	// MessageEvent: a person wrote to the app, in a direct message or with an @mention.
	MessageEvent = "message.received"
	// AnswerEvent: a person pressed an option of a question the app asked.
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
		{"space", "Only messages in this space, as list_spaces names it: spaces/AAAA…."},
		{"text", "Only messages whose text matches this pattern, such as start * or *deploy*. * is any text, ? one character; case does not matter. Matched against the whole text, without the app's @mention."},
		{"direct", "true: only direct messages to the app; false: only messages in spaces and group chats."},
	},
	AnswerEvent: {
		{"space", "Only answers in this space."},
		{"question", "Only answers to this question: the id ask_question gave or was given."},
	},
}

func eventsList() map[string]any {
	str := map[string]any{"type": "string"}
	person := map[string]any{"type": "object", "properties": map[string]any{"name": str, "displayName": str, "email": str}}
	common := map[string]any{"space": str, "spaceType": str, "spaceName": str, "thread": str, "message": str, "from": person, "date": str}
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
			"name": MessageEvent, "title": "Google Chat message",
			"description": "A person wrote to the Chat app: a direct message, or a message that @mentions it in a space. Its data is the space, the thread, the message's name, " +
				"who wrote it and its text. It is raised only for a person who linked their Google Chat user, and acts as them. Answer with send_message in the same thread.",
			"delivery": []string{"poll"}, "inputSchema": schema(MessageEvent),
			"payloadSchema": map[string]any{"type": "object", "properties": message},
		},
		map[string]any{
			"name": AnswerEvent, "title": "Google Chat answer",
			"description": "A person pressed an option of a question that ask_question posted. Its data is the question's id, the option's id and words (answer, label), " +
				"the space, the thread, the question's message and who answered. Only the first press of a question counts.",
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
			a.space = text
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
		(a.space == "" || it.Space == a.space) &&
		(a.question == "" || it.Question == a.question) &&
		(a.text == nil || a.text.MatchString(it.Text)) &&
		(a.direct == nil || *a.direct == (it.SpaceType == "DIRECT_MESSAGE"))
}

// senderOf is who did it, for a channel link (#1762): the Chat API's name for the user
// (users/…), which never changes, with the name and the email address Google Chat gave.
func senderOf(it Item) map[string]any {
	s := map[string]any{"channel": Provider, "identity": it.From.Name}
	if it.From.DisplayName != "" {
		s["name"] = it.From.DisplayName
	}
	if it.From.Email != "" {
		s["email"] = strings.ToLower(it.From.Email)
	}
	return s
}

func dataOf(it Item) map[string]any {
	d := map[string]any{"space": it.Space, "spaceType": it.SpaceType, "spaceName": it.SpaceName, "thread": it.Thread, "message": it.Message,
		"from": map[string]any{"name": it.From.Name, "displayName": it.From.DisplayName, "email": it.From.Email}, "date": it.At.Format(time.RFC3339)}
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
	return mcpevents.EncodeCursor(c)
}

func decodeCursor(raw json.RawMessage) (cursor, *rpcError) {
	refused := mcpevents.RefusedCursor()
	var c cursor
	if !mcpevents.DecodeCursor(raw, &c) || c.Boot == "" {
		return cursor{}, refused
	}
	return c, nil
}

// MARK: Polling

const (
	// nextPollMs is short: the inbox is in memory, so a poll costs Google nothing.
	nextPollMs = 3000
)

type pollParams = mcpevents.Params

// Events answers events/poll over an Inbox, whose loop it starts with Context.
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
		return nil, mcpevents.NoEvent(p.Name, EventNames())
	}
	a, bad := checkArgs(p.Name, p.Arguments)
	if bad != nil {
		return nil, bad
	}
	if _, err := s.Inbox.Google.Account(); err != nil {
		return nil, eventsError(err)
	}
	s.Inbox.Start(s.Context)
	limit := p.Limit()
	boot, head := s.Inbox.Head()
	answer := func(events []any, c cursor, more bool) map[string]any {
		return map[string]any{"events": events, "cursor": c.encoded(), "truncated": false, "hasMore": more, "nextPollMs": nextPollMs}
	}
	if p.FirstPoll() {
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
		var notSignedIn *NotSignedInError
		if errors.As(failure, &notSignedIn) {
			return nil, eventsError(failure)
		}
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
		out = append(out, mcpevents.Enveloped(map[string]any{
			"eventId": name + ":" + it.ID, "name": name, "timestamp": it.At.Format(time.RFC3339),
			"data": dataOf(it), "sender": senderOf(it),
		}, messageRef(it), ""))
	}
	return answer(out, next, more), nil
}

// messageRef is the ref of the message an event is about (#4728): the message that came, or
// the question that was answered, as googlechat:message:spaces/<space>#<message>. Each
// happens once to its message (a question takes only its first press), so there is no key.
func messageRef(it Item) wire.Ref {
	_, id, ok := strings.Cut(it.Message, "/messages/")
	if !ok || id == "" || it.Space == "" {
		return wire.Ref{}
	}
	return mcpevents.Ref("googlechat", "message", it.Space, id)
}

// eventsError is a failure as the events draft's error codes.
func eventsError(err error) *rpcError {
	var notSignedIn *NotSignedInError
	if errors.Is(err, ErrNotConnected) || errors.As(err, &notSignedIn) {
		return &rpcError{Code: -32012, Message: err.Error(), Data: map[string]any{"reason": "not connected"}}
	}
	return &rpcError{Code: -32603, Message: err.Error()}
}
