package mcpevents

import (
	"encoding/base64"
	"encoding/json"
	"slices"
	"sort"
	"strings"

	"github.com/agentloops-dev/agents/Go/wire"
)

// MaxEvents is the most events one poll gives; a poll that asks for none gives 50.
const MaxEvents = 100

// Params are events/poll's params.
type Params struct {
	Name      string          `json:"name"`
	Arguments json.RawMessage `json:"arguments"`
	Cursor    json.RawMessage `json:"cursor"`
	MaxEvents *int            `json:"maxEvents"`
}

// ParseParams reads events/poll's params.
func ParseParams(raw json.RawMessage) (Params, *Error) {
	var p Params
	if err := json.Unmarshal(raw, &p); err != nil {
		return p, InvalidParams("params must be an object")
	}
	return p, nil
}

// FirstPoll is whether the poll has no cursor.
func (p Params) FirstPoll() bool { return len(p.Cursor) == 0 || string(p.Cursor) == "null" }

// Limit is how many events the poll takes: maxEvents, 50 when not given, from 1 to MaxEvents.
func (p Params) Limit() int {
	limit := 50
	if p.MaxEvents != nil {
		limit = *p.MaxEvents
	}
	return min(MaxEvents, max(1, limit))
}

// MARK: The cursor

// EncodeCursor is c as a client keeps it: an opaque string, base64url of its JSON.
func EncodeCursor(c any) string {
	data, _ := json.Marshal(c)
	return base64.RawURLEncoding.EncodeToString(data)
}

// DecodeCursor reads raw, a string EncodeCursor gave, into c; ok is false when it is not one.
func DecodeCursor(raw json.RawMessage, c any) bool {
	var text string
	if err := json.Unmarshal(raw, &text); err != nil {
		return false
	}
	data, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(text, "="))
	if err != nil {
		return false
	}
	return json.Unmarshal(data, c) == nil
}

// RefusedCursor is the answer to a cursor this server did not give.
func RefusedCursor() *Error { return InvalidParams("cursor is not one this server gave") }

// Cursor is where a poll has got to: a high-water time, and the ids already raised at exactly
// that time, so events that share one time are neither lost nor raised twice.
type Cursor struct {
	Since string   `json:"since"`
	IDs   []string `json:"ids"`
}

// Encoded is the cursor as a client keeps it.
func (c Cursor) Encoded() string {
	if c.IDs == nil {
		c.IDs = []string{}
	}
	return EncodeCursor(c)
}

// MARK: Polling

// Poller is how one server polls: its pace, its times and its errors.
type Poller struct {
	// NextPollMs is the nextPollMs of every answer.
	NextPollMs int
	// Normalize is a time in the server's one layout, or "" when it is not a time; nil keeps it.
	Normalize func(string) string
	// Fail is an error of the server's reads as the events draft's error codes.
	Fail func(error) *Error
}

// Enveloped is a polled event with its envelope as the server says it (#4728, spec
// 4724-event-bus, "An event"): its subject, the ref of what it happened to, and its key,
// set when the same event can happen again to that thing. Both come from the provider's
// data only, never from the machine or the clock, so two machines say the same. A zero or
// bad ref says none.
func Enveloped(event map[string]any, subject wire.Ref, key string) map[string]any {
	if subject.IsZero() || subject.Check() != nil {
		return event
	}
	event["subject"] = subject.String()
	if key != "" {
		event["key"] = key
	}
	return event
}

func (pl Poller) fail(err error) *Error {
	if pl.Fail != nil {
		return pl.Fail(err)
	}
	return &Error{Code: -32603, Message: err.Error()}
}

// Decode is the cursor raw, its time normalized.
func (pl Poller) Decode(raw json.RawMessage) (Cursor, *Error) {
	var c Cursor
	if !DecodeCursor(raw, &c) {
		return Cursor{}, RefusedCursor()
	}
	if pl.Normalize != nil {
		c.Since = pl.Normalize(c.Since)
	}
	if c.Since == "" {
		return Cursor{}, RefusedCursor()
	}
	return c, nil
}

// Answer is an events/poll answer.
func (pl Poller) Answer(events []any, cursor string, truncated, hasMore bool) map[string]any {
	if events == nil {
		events = []any{}
	}
	return map[string]any{"events": events, "cursor": cursor, "truncated": truncated, "hasMore": hasMore, "nextPollMs": pl.NextPollMs}
}

// Candidate is something that may be raised: its id, its time (in the server's one layout,
// which sorts as text), and its data, looked up only once it is taken; nil data skips it,
// though the cursor still moves past it.
type Candidate struct {
	EventID string
	Time    string
	Data    func() (map[string]any, error)
	// Subject and Key are the event's envelope (Enveloped). Envelope, when set, gives them
	// instead, after Data: for what only its data finds, such as a run's pull request.
	Subject  wire.Ref
	Key      string
	Envelope func() (wire.Ref, string)
}

// Ref is a ref with its topic in lower case, as a ref's topic is: an owner/name keeps its
// case on the forge.
func Ref(provider, typ, topic, id string) wire.Ref {
	return wire.Ref{Provider: provider, Type: typ, Topic: strings.ToLower(topic), ID: id}
}

// Data is data, for a candidate that has it already.
func Data(data map[string]any) func() (map[string]any, error) {
	return func() (map[string]any, error) { return data, nil }
}

// Listed is what a listing saw: whether it was cut short, and the newest time in it, wanted
// or not ("" when it says nothing of it).
type Listed struct {
	Truncated bool
	Newest    string
}

// Poll is events/poll of the event name over a cursor: the first poll (no cursor) gives none
// and starts from start(); later ones give what find finds new since, oldest first, at most
// p.Limit(), with hasMore and a cursor that goes on from the last one taken. A poll that took
// all there was and was not truncated goes on to the newest the listing saw, wanted or not
// (P20261020-1): a wait whose filter drops everything would otherwise read all since its last
// event, every poll.
func (pl Poller) Poll(name string, p Params, start func() string, find func(since string) ([]Candidate, Listed, error)) (map[string]any, *Error) {
	limit := p.Limit()
	if p.FirstPoll() {
		return pl.Answer(nil, Cursor{Since: start()}.Encoded(), false, false), nil
	}
	c, bad := pl.Decode(p.Cursor)
	if bad != nil {
		return nil, bad
	}
	seen := map[string]bool{}
	for _, id := range c.IDs {
		seen[id] = true
	}
	found, listed, err := find(c.Since)
	if err != nil {
		return nil, pl.fail(err)
	}
	var fresh []Candidate
	for _, f := range found {
		if f.Time > c.Since || (f.Time == c.Since && !seen[f.EventID]) {
			fresh = append(fresh, f)
		}
	}
	sort.SliceStable(fresh, func(i, j int) bool {
		if fresh[i].Time == fresh[j].Time {
			return fresh[i].EventID < fresh[j].EventID
		}
		return fresh[i].Time < fresh[j].Time
	})
	taken := fresh[:min(limit, len(fresh))]
	since := c.Since
	if len(taken) > 0 {
		since = taken[len(taken)-1].Time
	}
	if !listed.Truncated && len(taken) == len(fresh) && listed.Newest > since {
		since = listed.Newest
	}
	var ids []string
	if since == c.Since {
		ids = append(ids, c.IDs...)
	}
	for _, t := range taken {
		if t.Time == since && !slices.Contains(ids, t.EventID) {
			ids = append(ids, t.EventID)
		}
	}
	out := []any{}
	for _, t := range taken {
		data, err := t.Data()
		if err != nil {
			return nil, pl.fail(err)
		}
		if data != nil {
			subject, key := t.Subject, t.Key
			if t.Envelope != nil {
				subject, key = t.Envelope()
			}
			out = append(out, Enveloped(map[string]any{"eventId": t.EventID, "name": name, "timestamp": t.Time, "data": data}, subject, key))
		}
	}
	return pl.Answer(out, Cursor{Since: since, IDs: ids}.Encoded(), listed.Truncated, len(fresh) > len(taken)), nil
}

// State is a thing whose state (a pull request in conflict, or open and ready) is on or off
// now: its id in the cursor, its number, which orders those raised together, whether it is on
// (nil keeps what it was), and its event's data.
type State struct {
	ID     string
	Number int
	On     *bool
	Data   map[string]any
	// Subject and Key are the event's envelope (Enveloped); no Key makes the poll's time
	// the key, as a state can come on again.
	Subject wire.Ref
	Key     string
}

// Diff is events/poll of the event name by a state's diff: one event for each state that is
// on now and was not at the last poll, the cursor's ids being those that were on then. A
// first poll takes those already on as known, and so gives none. Each event's data is its
// state's, with key (as "conflictedAt") set to now(), its time. It is for what has a state
// and no time of its own, as a conflict.
func (pl Poller) Diff(name, key string, p Params, now func() string, states func() ([]State, error)) (map[string]any, *Error) {
	first := p.FirstPoll()
	c := Cursor{}
	if !first {
		var bad *Error
		if c, bad = pl.Decode(p.Cursor); bad != nil {
			return nil, bad
		}
	}
	limit := MaxEvents
	if !first {
		limit = p.Limit()
	}
	all, err := states()
	if err != nil {
		return nil, pl.fail(err)
	}
	was := map[string]bool{}
	for _, id := range c.IDs {
		was[id] = true
	}
	var still, fresh []State
	for _, st := range all {
		on := (st.On != nil && *st.On) || (st.On == nil && was[st.ID])
		switch {
		case on && was[st.ID]:
			still = append(still, st)
		case on:
			fresh = append(fresh, st)
		}
	}
	sort.SliceStable(fresh, func(i, j int) bool { return fresh[i].Number < fresh[j].Number })
	taken := fresh[:min(limit, len(fresh))]
	at := now()
	ids := []string{}
	for _, st := range append(still, taken...) {
		ids = append(ids, st.ID)
	}
	out := []any{}
	if !first {
		for _, t := range taken {
			data := map[string]any{key: at}
			for k, v := range t.Data {
				data[k] = v
			}
			key := t.Key
			if key == "" {
				// A state has no time or id of its own: its key is when this poll saw it,
				// so two machines can make two ids for one change (best effort, #4728).
				key = at
			}
			out = append(out, Enveloped(map[string]any{"eventId": t.ID + ":" + at, "name": name, "timestamp": at, "data": data}, t.Subject, key))
		}
	}
	return pl.Answer(out, Cursor{Since: at, IDs: ids}.Encoded(), false, !first && len(fresh) > len(taken)), nil
}
