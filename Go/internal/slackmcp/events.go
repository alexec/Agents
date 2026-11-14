package slackmcp

import (
	"context"
	"encoding/json"
	"sort"
	"strings"
	"time"

	"github.com/agentloops-dev/agents/Go/internal/mcpevents"
	"github.com/agentloops-dev/agents/Go/wire"
)

// The MCP events (#1351), polled only: `events/list` and `events/poll` of the events draft
// (experimental-ext-triggers-events), which the Agents daemon speaks, in the shape of the
// email server's (Go/internal/emailmcp/events.go). message.received is a message the bot
// can see; question.answered is a button pressed on a question that ask_question posted.
// Their data never has a message's text, which an agent reads with read_messages, marked as
// outside content. Each names its sender, so it starts work only as the person the Slack
// user is linked to (#1762).

// rpcError is a JSON-RPC error answer: its code, message and optional data.
type rpcError = mcpevents.Error

func invalidParams(format string, args ...any) *rpcError {
	return mcpevents.InvalidParams(format, args...)
}

// The events.
const (
	MessageReceived  = "message.received"
	QuestionAnswered = "question.answered"
)

type filter struct{ name, description string }

var filters = map[string][]filter{
	MessageReceived: {
		{"channel", "Only messages in this channel, by its id (C…, G… or D…), as list_channels gives it."},
		{"user", "Only messages from this Slack user, by id (U…)."},
		{"thread", "Only replies in this thread: the ts of its first message, as send_message or ask_question gave it."},
		{"mentions", "true: only messages that mention the bot, and direct messages to it."},
	},
	QuestionAnswered: {
		{"question", "Only answers to this question, by the id ask_question gave."},
		{"channel", "Only answers in this channel, by its id."},
	},
}

// EventNames is the events it declares, by name.
func EventNames() []string { return []string{MessageReceived, QuestionAnswered} }

func eventsList() map[string]any {
	str := map[string]any{"type": "string"}
	boolean := map[string]any{"type": "boolean"}
	schema := func(name string) map[string]any {
		props := map[string]any{}
		for _, f := range filters[name] {
			props[f.name] = map[string]any{"type": "string", "description": f.description}
		}
		return map[string]any{"type": "object", "properties": props, "required": []string{}, "additionalProperties": false}
	}
	return map[string]any{"events": []any{
		map[string]any{
			"name": MessageReceived, "title": "Slack message",
			"description": "A message came into a channel the bot is in, or to the bot directly; replies in threads too. Not the bot's own, nor other bots'. " +
				"Its data is the channel, the user, the message's ts and its thread's, and whether it mentions the bot: never its text. " +
				"read_messages gives the text, marked as outside content.",
			"delivery":    []string{"poll"},
			"inputSchema": schema(MessageReceived),
			"payloadSchema": map[string]any{"type": "object", "properties": map[string]any{
				"channel": str, "channelType": str, "user": str, "team": str, "ts": str, "threadTs": str, "mentioned": boolean,
			}},
		},
		map[string]any{
			"name": QuestionAnswered, "title": "Slack question answered",
			"description": "Someone pressed one of the options on a question ask_question posted. Its data is the question's id, channel and ts, " +
				"who answered, and the option they chose (its words and its place, from 0). Only the first answer counts: the question then says who answered.",
			"delivery":    []string{"poll"},
			"inputSchema": schema(QuestionAnswered),
			"payloadSchema": map[string]any{"type": "object", "properties": map[string]any{
				"question": str, "channel": str, "ts": str, "threadTs": str, "user": str, "team": str, "option": str,
				"index": map[string]any{"type": "integer"},
			}},
		},
	}}
}

// args are an event's checked arguments.
type args struct {
	channel, user, thread, question string
	mentions                        bool
}

func checkArgs(name string, raw json.RawMessage) (args, *rpcError) {
	var a args
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
		if !contains(names, key) {
			return a, invalidParams("unknown argument %s; %s takes %s", key, name, strings.Join(names, ", "))
		}
		var text string
		if string(given[key]) != "null" && json.Unmarshal(given[key], &text) != nil {
			if key != "mentions" {
				return a, invalidParams("%s must be a string", key)
			}
			text = string(given[key]) // true or false, not as a string
		}
		text = strings.TrimSpace(text)
		switch key {
		case "channel":
			a.channel = text
		case "user":
			a.user = text
		case "thread":
			a.thread = text
		case "question":
			a.question = text
		case "mentions":
			switch strings.ToLower(text) {
			case "true":
				a.mentions = true
			case "false", "":
			default:
				return a, invalidParams("mentions must be true or false")
			}
		}
	}
	return a, nil
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

func (a args) match(name string, it item) bool {
	return it.name == name &&
		(a.channel == "" || a.channel == it.channel) &&
		(a.user == "" || a.user == it.user) &&
		(a.thread == "" || a.thread == it.thread) &&
		(a.question == "" || a.question == it.question) &&
		(!a.mentions || it.mentioned)
}

// MARK: The cursor

// cursor is the run of the server and the last event read in it. A client keeps it as an
// opaque string (base64url of its JSON).
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
	// pollMs is the pace: a poll reads memory, so it costs Slack nothing.
	pollMs = 3000
)

type pollParams = mcpevents.Params

// Events answers events/poll from an Inbox that a Listener fills.
type Events struct {
	Workspace *Workspace
	Inbox     *Inbox
	Listener  *Listener
}

// Poll answers events/poll's params.
func (s *Events) Poll(_ context.Context, raw json.RawMessage) (map[string]any, *rpcError) {
	var p pollParams
	if err := json.Unmarshal(raw, &p); err != nil {
		return nil, invalidParams("params must be an object")
	}
	if !contains(EventNames(), p.Name) {
		return nil, mcpevents.NoEvent(p.Name, EventNames())
	}
	a, bad := checkArgs(p.Name, p.Arguments)
	if bad != nil {
		return nil, bad
	}
	if !s.Workspace.Connected() {
		return nil, &rpcError{Code: -32012, Message: ErrNotConnected.Error(), Data: map[string]any{"reason": "not connected"}}
	}
	if err := s.Listener.Refused(); err != nil {
		return nil, &rpcError{Code: -32012, Message: err.Error(), Data: map[string]any{"reason": "not connected"}}
	}
	limit := p.Limit()
	answer := func(events []any, c cursor, lost, more bool) map[string]any {
		return map[string]any{"events": events, "cursor": c.encoded(), "truncated": lost, "hasMore": more, "nextPollMs": pollMs}
	}
	now := cursor{Boot: s.Inbox.boot, Seq: s.Inbox.last()}
	if p.FirstPoll() {
		return answer([]any{}, now, false, false), nil
	}
	c, bad := decodeCursor(p.Cursor)
	if bad != nil {
		return nil, bad
	}
	if c.Boot != s.Inbox.boot {
		// The server started again: what came while it was down is gone. Start from now.
		return answer([]any{}, now, true, false), nil
	}
	found, read, lost, more := s.Inbox.since(c.Seq, limit, func(it item) bool { return a.match(p.Name, it) })
	out := []any{}
	for _, it := range found {
		out = append(out, mcpevents.Enveloped(map[string]any{"eventId": it.id, "name": it.name, "timestamp": it.at.UTC().Format(time.RFC3339),
			"data": it.data, "sender": it.sender}, messageRef(it.data), ""))
	}
	return answer(out, cursor{Boot: c.Boot, Seq: read}, lost, more), nil
}

// messageRef is the ref of the message an event is about (#4728): the message that came, or
// the question that was answered, as slack:message:<team>/<channel>#<ts>. Each happens once
// to its message (a question takes only its first answer), so there is no key. A message with
// no team is under its channel alone.
func messageRef(data map[string]any) wire.Ref {
	channel, _ := data["channel"].(string)
	ts, _ := data["ts"].(string)
	team, _ := data["team"].(string)
	if channel == "" || ts == "" {
		return wire.Ref{}
	}
	topic := channel
	if team != "" {
		topic = team + "/" + channel
	}
	return mcpevents.Ref("slack", "message", topic, ts)
}
