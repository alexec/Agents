package linearmcp

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

// The MCP events (#839) of the Linear workspace's issues, in the github server's shape
// (Go/internal/githubmcp): the same issue.* names, cursor, paging and trust filter (#728),
// polled only: `events/list` and `events/poll` of the events draft
// (experimental-ext-triggers-events), which the Agents daemon speaks.

// rpcError is a JSON-RPC error answer: its code, message and optional data.
type rpcError struct {
	Code    int            `json:"code"`
	Message string         `json:"message"`
	Data    map[string]any `json:"data,omitempty"`
}

func (e *rpcError) Error() string { return e.Message }

func invalidParams(format string, args ...any) *rpcError {
	return &rpcError{Code: -32602, Message: fmt.Sprintf(format, args...)}
}

// property is one argument of an event: a string or a boolean.
type property struct {
	name        string
	kind        string // "string" or "boolean"
	description string
	pattern     *regexp.Regexp
	looksLike   string
}

func (p property) json() map[string]any {
	o := map[string]any{"type": p.kind, "description": p.description}
	if p.pattern != nil {
		o["pattern"] = p.pattern.String()
	}
	return o
}

// schema is an event's arguments: named properties in the order errors list them, none
// required, no others allowed.
type schema []property

func (s schema) json() map[string]any {
	props := map[string]any{}
	for _, p := range s {
		props[p.name] = p.json()
	}
	return map[string]any{"type": "object", "properties": props, "required": []string{}, "additionalProperties": false}
}

func (s schema) lookup(name string) (property, bool) {
	for _, p := range s {
		if p.name == name {
			return p, true
		}
	}
	return property{}, false
}

// args are an event's checked arguments.
type args struct {
	team, label, issue string
	anyone             bool
}

// check reads raw (null or missing as {}) and checks it: no unknown keys, types, shapes.
func (s schema) check(raw json.RawMessage) (args, *rpcError) {
	var a args
	given := map[string]json.RawMessage{}
	if len(raw) > 0 && string(raw) != "null" {
		if err := json.Unmarshal(raw, &given); err != nil {
			return a, invalidParams("arguments must be an object")
		}
	}
	keys := make([]string, 0, len(given))
	for k := range given {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, key := range keys {
		value := given[key]
		p, ok := s.lookup(key)
		if !ok {
			names := make([]string, len(s))
			for i, p := range s {
				names[i] = p.name
			}
			return a, invalidParams("unknown argument %s; takes %s", key, strings.Join(names, ", "))
		}
		if p.kind == "boolean" {
			var b bool
			if err := json.Unmarshal(value, &b); err != nil || string(value) == "null" {
				return a, invalidParams("%s must be true or false", key)
			}
			a.anyone = b
			continue
		}
		var text string
		if err := json.Unmarshal(value, &text); err != nil || string(value) == "null" {
			return a, invalidParams("%s must be a string", key)
		}
		if p.pattern != nil && !p.pattern.MatchString(text) {
			return a, invalidParams("%s must look like %s", key, p.looksLike)
		}
		switch key {
		case "team":
			a.team = strings.ToUpper(text)
		case "label":
			a.label = text
		case "issue":
			a.issue = strings.ToUpper(text)
		}
	}
	return a, nil
}

// event is one event as events/list gives it.
type event struct {
	name, title, description string
	kind                     Kind
	input                    schema
	payload                  map[string]any
}

func (e event) json() map[string]any {
	return map[string]any{"name": e.name, "title": e.title, "description": e.description, "delivery": []string{"poll"},
		"inputSchema": e.input.json(), "payloadSchema": e.payload}
}

var (
	teamProperty = property{name: "team", kind: "string",
		description: "Only issues of this team, by its key, as ENG. Left out, every team of the workspace.",
		pattern:     regexp.MustCompile(`^[A-Za-z0-9_]{1,10}$`), looksLike: "a team key, as ENG"}
	issueProperty = property{name: "issue", kind: "string", description: "Only this issue, by its identifier, as ENG-12.",
		pattern: regexp.MustCompile(`^[A-Za-z0-9_]{1,10}-[0-9]+$`), looksLike: "an issue identifier, as ENG-12"}
	// anyoneProperty opts into anyone's issue, comment, label or close (#728); left out, only the workspace's own.
	anyoneProperty = property{name: "anyone", kind: "boolean",
		description: "true: by anyone, guests, apps and integrations too. Left out, only the workspace's members, never a guest or an app."}
)

func object(props map[string]any) map[string]any {
	return map[string]any{"type": "object", "properties": props}
}

var str = map[string]any{"type": "string"}

// firstMinutes says what Linear's issue history, which labels and closes are read from,
// leaves out: it keeps nothing of what is changed in an issue's first minutes (seen live,
// #839: a label and a close 4 s and 90 s after creating it had no history; one 5 min after did).
const firstMinutes = "Linear keeps no history of changes in an issue's first few minutes, so a label added or a close then is not an event."

// events are the events this server offers.
var events = func() []event {
	issueSchema := object(map[string]any{
		"id": str, "identifier": str, "title": str, "team": str, "state": str, "author": str,
		"labels": map[string]any{"type": "array", "items": str}, "assignee": str, "url": str,
	})
	kinds := []struct {
		kind                      Kind
		title, description, label string
		payload                   map[string]any
		who                       string
	}{
		{Opened, "Issue opened", "An issue was created in Linear. Its data is the issue as it is when polled, so labels added in its first minutes are there.",
			"Only issues created with this label.", map[string]any{"openedAt": str}, "Only issues created by"},
		{Labelled, "Issue labelled", "A label was added to an issue: one event per label added. " + firstMinutes,
			"Only when this label is the one added.", map[string]any{"label": str, "by": str, "labelledAt": str}, "Only labels added by"},
		{Commented, "Issue commented on", "A comment was left on an issue. Its body is the first 4000 characters.",
			"Only issues with this label.",
			map[string]any{"comment": object(map[string]any{"author": str, "url": str, "body": str}), "commentedAt": str},
			"Only comments by"},
		{Closed, "Issue closed",
			"An issue moved into a Done (completed) or Canceled state from an open one. Moving it back and closing it again is a new event. " + firstMinutes,
			"Only issues with this label.",
			map[string]any{"reason": map[string]any{"type": "string", "enum": []string{"completed", "canceled"}}, "by": str, "closedAt": str},
			"Only issues closed by"},
	}
	out := make([]event, len(kinds))
	for i, k := range kinds {
		label := property{name: "label", kind: "string", description: k.label}
		input := schema{teamProperty, label, issueProperty, anyoneProperty}
		if k.kind == Opened {
			input = schema{teamProperty, label, anyoneProperty}
		}
		payload := map[string]any{"issue": issueSchema}
		for name, v := range k.payload {
			payload[name] = v
		}
		out[i] = event{name: "issue." + string(k.kind), title: k.title, kind: k.kind, input: input, payload: object(payload),
			description: k.description + " " + k.who + " the workspace's members, never a guest or an app, unless anyone is true."}
	}
	// For the person, not the workspace (#2034).
	return append(out, event{name: "issue.assigned", title: "Issue assigned to me", kind: Assigned,
		description: "An issue was assigned to the Linear account this server is connected as, by anyone: once per assignment, so one unassigned and assigned again is a new one. Linear keeps no history of an issue's first few minutes, so an issue assigned as it is made is not an event.",
		input:       schema{teamProperty, issueProperty},
		payload:     object(map[string]any{"issue": issueSchema, "by": str, "assignedAt": str})})
}()

func eventNamed(name string) (event, bool) {
	for _, e := range events {
		if e.name == name {
			return e, true
		}
	}
	return event{}, false
}

// EventNames is the events it declares, by name, in events/list's order.
func EventNames() []string {
	names := make([]string, len(events))
	for i, e := range events {
		names[i] = e.name
	}
	return names
}

// eventsList is events/list's answer.
func eventsList() map[string]any {
	list := make([]any, len(events))
	for i, e := range events {
		list[i] = e.json()
	}
	return map[string]any{"events": list}
}

// MARK: The cursor

// cursor is where a poll has got to: a high-water time, and the ids already raised at exactly
// that time, so events that share one time are neither lost nor raised twice. A client keeps
// it as an opaque string (base64url of its JSON).
type cursor struct {
	Since string   `json:"since"`
	IDs   []string `json:"ids"`
}

func (c cursor) encoded() string {
	if c.IDs == nil {
		c.IDs = []string{}
	}
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
	if json.Unmarshal(data, &c) != nil || normalized(c.Since) == "" {
		return cursor{}, refused
	}
	c.Since = normalized(c.Since)
	return c, nil
}

// MARK: Polling

// candidate is something that may be raised: its id, its time (in timeLayout) and its data.
type candidate struct {
	eventID string
	time    string
	data    map[string]any
}

const (
	maxEvents = 100
	// nextPollMs is a minute, not the github server's 30 s: a personal key has 1500 requests an
	// hour, and a wait on each of the four events costs three a poll.
	nextPollMs = 60000
)

type pollParams struct {
	Name      string          `json:"name"`
	Arguments json.RawMessage `json:"arguments"`
	Cursor    json.RawMessage `json:"cursor"`
	MaxEvents *int            `json:"maxEvents"`
}

func (p pollParams) firstPoll() bool { return len(p.Cursor) == 0 || string(p.Cursor) == "null" }

// Events answers events/list and events/poll over Linear.
type Events struct {
	Linear Linear
	// SignedIn says whether there is a key to read Linear with; nil is yes.
	SignedIn func() bool
	Now      func() time.Time
}

func (s *Events) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

// Poll answers events/poll's params. The first poll (no cursor) gives none and starts from
// now; later ones give what is new since, oldest first, at most maxEvents, with hasMore and a
// cursor that goes on from the last one taken.
func (s *Events) Poll(ctx context.Context, raw json.RawMessage) (map[string]any, *rpcError) {
	var p pollParams
	if err := json.Unmarshal(raw, &p); err != nil {
		return nil, invalidParams("params must be an object")
	}
	e, ok := eventNamed(p.Name)
	if !ok {
		names := make([]string, len(events))
		for i, e := range events {
			names[i] = e.name
		}
		return nil, &rpcError{Code: -32011, Message: fmt.Sprintf("no event %s; this server offers %s", p.Name, strings.Join(names, ", "))}
	}
	a, bad := e.input.check(p.Arguments)
	if bad != nil {
		return nil, bad
	}
	// No key is said at once, on the first poll too, so a wait set up without one fails then.
	if s.SignedIn != nil && !s.SignedIn() {
		return nil, eventsError(&LinearError{Kind: NotSignedIn, Message: "Linear is not signed in: connect Linear in Connectors, or set LINEAR_API_KEY to a personal API key"})
	}
	limit := 50
	if p.MaxEvents != nil {
		limit = *p.MaxEvents
	}
	limit = min(maxEvents, max(1, limit))
	now := s.now()
	if p.firstPoll() {
		return map[string]any{"events": []any{}, "cursor": cursor{Since: timeString(now)}.encoded(),
			"truncated": false, "hasMore": false, "nextPollMs": nextPollMs}, nil
	}
	c, bad := decodeCursor(p.Cursor)
	if bad != nil {
		return nil, bad
	}
	seen := map[string]bool{}
	for _, id := range c.IDs {
		seen[id] = true
	}
	found, truncated, err := s.candidates(ctx, e, a, c.Since)
	if err != nil {
		return nil, eventsError(err)
	}
	var fresh []candidate
	for _, f := range found {
		if f.time >= c.Since && !(f.time == c.Since && seen[f.eventID]) {
			fresh = append(fresh, f)
		}
	}
	sort.SliceStable(fresh, func(i, j int) bool {
		if fresh[i].time == fresh[j].time {
			return fresh[i].eventID < fresh[j].eventID
		}
		return fresh[i].time < fresh[j].time
	})
	taken := fresh[:min(limit, len(fresh))]
	since := c.Since
	if len(taken) > 0 {
		since = taken[len(taken)-1].time
	}
	var ids []string
	if since == c.Since {
		ids = append(ids, c.IDs...)
	}
	out := []any{}
	for _, t := range taken {
		if t.time == since && !contains(ids, t.eventID) {
			ids = append(ids, t.eventID)
		}
		out = append(out, map[string]any{"eventId": t.eventID, "name": e.name, "timestamp": t.time, "data": t.data})
	}
	return map[string]any{"events": out, "cursor": cursor{Since: since, IDs: ids}.encoded(),
		"truncated": truncated, "hasMore": len(fresh) > len(taken), "nextPollMs": nextPollMs}, nil
}

// candidates finds what e may raise at or after since, filtered by a.
func (s *Events) candidates(ctx context.Context, e event, a args, since string) ([]candidate, bool, error) {
	items, truncated, err := s.Linear.Activity(ctx, e.kind, a.team, since)
	if err != nil {
		return nil, false, err
	}
	var list []candidate
	for _, it := range items {
		if a.team != "" && !strings.EqualFold(it.Issue.Team, a.team) {
			continue
		}
		if a.issue != "" && !strings.EqualFold(it.Issue.Identifier, a.issue) {
			continue
		}
		// Assigned to the connection's owner is theirs, by anyone (#2034).
		if !a.anyone && it.Kind != Assigned && !it.trusted() {
			continue
		}
		if a.label != "" {
			if it.Kind == Labelled && !strings.EqualFold(it.Label, a.label) {
				continue
			}
			if it.Kind != Labelled && !containsFold(it.Issue.Labels, a.label) {
				continue
			}
		}
		at := normalized(it.At)
		if at == "" {
			continue
		}
		list = append(list, candidate{eventID: e.name + ":" + it.ID, time: at, data: it.data()})
	}
	return list, truncated, nil
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

func containsFold(list []string, s string) bool {
	for _, x := range list {
		if strings.EqualFold(x, s) {
			return true
		}
	}
	return false
}

// eventsError is a Linear failure as the events draft's error codes.
func eventsError(err error) *rpcError {
	var rpc *rpcError
	if errors.As(err, &rpc) {
		return rpc
	}
	var l *LinearError
	if !errors.As(err, &l) {
		return &rpcError{Code: -32603, Message: err.Error()}
	}
	switch l.Kind {
	case NotSignedIn:
		return &rpcError{Code: -32012, Message: l.Message, Data: map[string]any{"reason": "Linear not signed in"}}
	case RateLimited:
		return &rpcError{Code: -32013, Message: l.Message, Data: map[string]any{"retryAfterMs": l.RetryAfterMs}}
	case NotFound:
		return invalidParams("%s: check team", l.Message)
	}
	return &rpcError{Code: -32603, Message: l.Message}
}
