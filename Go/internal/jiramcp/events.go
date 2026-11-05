package jiramcp

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

// The MCP events (#3247) of the Jira site's issues, in the linear server's shape
// (Go/internal/linearmcp): the same issue.* names, cursor, paging and trust filter (#728),
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
	project, label, issue string
	anyone                bool
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
		case "project":
			a.project = strings.ToUpper(text)
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
	projectProperty = property{name: "project", kind: "string",
		description: "Only issues of this project, by its key, as PROJ. Left out, every project of the site.",
		pattern:     regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_]{0,9}$`), looksLike: "a project key, as PROJ"}
	issueProperty = property{name: "issue", kind: "string", description: "Only this issue, by its key, as PROJ-12.",
		pattern: regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_]{0,9}-[0-9]+$`), looksLike: "an issue key, as PROJ-12"}
	// anyoneProperty opts into anyone's issue, comment or label (#728); left out, only the site's own users.
	anyoneProperty = property{name: "anyone", kind: "boolean",
		description: "true: by anyone, customers and apps too. Left out, only the site's own users, never a customer or an app."}
)

func object(props map[string]any) map[string]any {
	return map[string]any{"type": "object", "properties": props}
}

var str = map[string]any{"type": "string"}

// events are the events this server offers.
var events = func() []event {
	issueSchema := object(map[string]any{
		"id": str, "key": str, "title": str, "project": str, "status": str, "author": str,
		"labels": map[string]any{"type": "array", "items": str}, "assignee": str, "url": str,
	})
	kinds := []struct {
		kind                      Kind
		title, description, label string
		payload                   map[string]any
		who                       string
	}{
		{Opened, "Issue opened", "An issue was created in Jira. Its data is the issue as it is when polled, so labels added in its first minutes are there.",
			"Only issues created with this label.", map[string]any{"openedAt": str}, "Only issues created by"},
		{Labelled, "Issue labelled", "A label was added to an issue: one event per label added, read from the issue's history.",
			"Only when this label is the one added.", map[string]any{"label": str, "by": str, "labelledAt": str}, "Only labels added by"},
		{Commented, "Issue commented on", "A comment was left on an issue. Its body is the first 4000 characters, in Jira's wiki markup.",
			"Only issues with this label.",
			map[string]any{"comment": object(map[string]any{"author": str, "url": str, "body": str}), "commentedAt": str},
			"Only comments by"},
	}
	out := make([]event, len(kinds))
	for i, k := range kinds {
		label := property{name: "label", kind: "string", description: k.label}
		input := schema{projectProperty, label, issueProperty, anyoneProperty}
		if k.kind == Opened {
			input = schema{projectProperty, label, anyoneProperty}
		}
		payload := map[string]any{"issue": issueSchema}
		for name, v := range k.payload {
			payload[name] = v
		}
		out[i] = event{name: "issue." + string(k.kind), title: k.title, kind: k.kind, input: input, payload: object(payload),
			description: k.description + " " + k.who + " the site's own users, never a customer or an app, unless anyone is true."}
	}
	// For the person, not the site (#2034).
	return append(out, event{name: "issue.assigned", title: "Issue assigned to me", kind: Assigned,
		description: "An issue was assigned to the Jira account this server is connected as, by anyone: once per assignment, so one unassigned and assigned again is a new one. An issue made already assigned has no history of it, so it is not an event.",
		input:       schema{projectProperty, issueProperty},
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
	// nextPollMs is a minute, as the linear server's: Jira Cloud's rate limit is by cost, and
	// a site's Jira admin, who could set up webhooks instead, is often not the person.
	nextPollMs = 60000
)

type pollParams struct {
	Name      string          `json:"name"`
	Arguments json.RawMessage `json:"arguments"`
	Cursor    json.RawMessage `json:"cursor"`
	MaxEvents *int            `json:"maxEvents"`
}

func (p pollParams) firstPoll() bool { return len(p.Cursor) == 0 || string(p.Cursor) == "null" }

// Events answers events/list and events/poll over Jira.
type Events struct {
	Jira Jira
	// SignedIn says whether there is a site and a token to read Jira with; nil is yes.
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
		return nil, eventsError(&JiraError{Kind: NotSignedIn, Message: notSignedIn})
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
	items, truncated, err := s.Jira.Activity(ctx, e.kind, a.project, since)
	if err != nil {
		return nil, false, err
	}
	var list []candidate
	for _, it := range items {
		if a.project != "" && !strings.EqualFold(it.Issue.Project, a.project) {
			continue
		}
		if a.issue != "" && !strings.EqualFold(it.Issue.Key, a.issue) {
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

// eventsError is a Jira failure as the events draft's error codes.
func eventsError(err error) *rpcError {
	var rpc *rpcError
	if errors.As(err, &rpc) {
		return rpc
	}
	var l *JiraError
	if !errors.As(err, &l) {
		return &rpcError{Code: -32603, Message: err.Error()}
	}
	switch l.Kind {
	case NotSignedIn:
		return &rpcError{Code: -32012, Message: l.Message, Data: map[string]any{"reason": "Jira not signed in"}}
	case RateLimited:
		return &rpcError{Code: -32013, Message: l.Message, Data: map[string]any{"retryAfterMs": l.RetryAfterMs}}
	case NotFound:
		return invalidParams("%s: check project", l.Message)
	}
	return &rpcError{Code: -32603, Message: l.Message}
}
