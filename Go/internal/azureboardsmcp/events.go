package azureboardsmcp

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// The MCP events (#3804) of an Azure Boards project's work items, in the jira and linear
// servers' shape (Go/internal/jiramcp, Go/internal/linearmcp): the same issue.* names, cursor,
// paging and trust filter (#728), polled only: `events/list` and `events/poll` of the events
// draft (experimental-ext-triggers-events), which the Agents daemon speaks. A work item is the
// event's issue, and its tags are its labels.

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

// property is one argument of an event: a string, a boolean, or one or a list of work
// items' ids.
type property struct {
	name        string
	kind        string // "string", "boolean" or "ids"
	description string
	pattern     *regexp.Regexp
	looksLike   string
}

func (p property) json() map[string]any {
	if p.kind == "ids" {
		item := map[string]any{"type": "string", "pattern": p.pattern.String()}
		return map[string]any{"type": []string{"string", "array"}, "pattern": p.pattern.String(), "items": item, "description": p.description}
	}
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
	area, kind, label string
	issues            []int
	anyone, all       bool
}

// wantsIssue is whether the work item with id n is one asked for: any, when none is.
func (a args) wantsIssue(n int) bool {
	if len(a.issues) == 0 {
		return true
	}
	for _, i := range a.issues {
		if i == n {
			return true
		}
	}
	return false
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
			if key == "any" {
				a.all = b
			} else {
				a.anyone = b
			}
			continue
		}
		if p.kind == "ids" {
			// One id, or a list of them (#3797): a lead waits on all its open children at once.
			var list []string
			if strings.HasPrefix(strings.TrimSpace(string(value)), "[") {
				if json.Unmarshal(value, &list) != nil || len(list) == 0 {
					return a, invalidParams("%s must be %s, or a list of them", key, p.looksLike)
				}
			} else {
				var text string
				if json.Unmarshal(value, &text) != nil || string(value) == "null" {
					return a, invalidParams("%s must be %s, or a list of them", key, p.looksLike)
				}
				list = []string{text}
			}
			for _, text := range list {
				if !p.pattern.MatchString(text) {
					return a, invalidParams("%s must be %s, or a list of them", key, p.looksLike)
				}
				n, _ := strconv.Atoi(text)
				a.issues = append(a.issues, n)
			}
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
		case "area":
			a.area = strings.TrimSuffix(text, `\`)
		case "type":
			a.kind = text
		case "label":
			a.label = text
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
	areaProperty = property{name: "area", kind: "string",
		description: `Only work items in this area path or under it, as Web App\Team. Left out, every area of the project.`}
	typeProperty  = property{name: "type", kind: "string", description: "Only work items of this type, as Bug or User Story."}
	issueProperty = property{name: "issue", kind: "ids", description: `Only this work item, or these, by its id, as "12" or ["12", "13"].`,
		pattern: regexp.MustCompile(`^[1-9][0-9]{0,9}$`), looksLike: "a work item's id, as 12"}
	// anyoneProperty opts into anyone's work item, comment or tag (#728); left out, only people.
	anyoneProperty = property{name: "anyone", kind: "boolean",
		description: "true: by anyone, build services and other bots too. Left out, only people, never a bot."}
	// anyProperty is every work item in the project (#3797): a wait that names none sets it.
	anyProperty = property{name: "any", kind: "boolean",
		description: "true: every work item in the project. A wait (not a workflow trigger) that names none, by issue or label, is refused without it. It is about which ones; anyone is about who."}
)

func object(props map[string]any) map[string]any {
	return map[string]any{"type": "object", "properties": props}
}

var str = map[string]any{"type": "string"}

// events are the events this server offers.
var events = func() []event {
	issueSchema := object(map[string]any{
		"id": map[string]any{"type": "integer"}, "key": str, "title": str, "type": str, "status": str, "area": str,
		"author": str, "labels": map[string]any{"type": "array", "items": str}, "assignee": str, "url": str,
	})
	kinds := []struct {
		kind                      Kind
		title, description, label string
		payload                   map[string]any
		who                       string
	}{
		{Opened, "Work item opened", "A work item was created in Azure Boards. Its data is the work item as it is when polled, so tags added in its first minutes are there.",
			"Only work items created with this tag.", map[string]any{"openedAt": str}, "Only work items created by"},
		{Labelled, "Work item tagged", "A tag was added to a work item: one event per tag added, read from its updates.",
			"Only when this tag is the one added.", map[string]any{"label": str, "by": str, "labelledAt": str}, "Only tags added by"},
		{Commented, "Work item commented on", "A comment was left on a work item. Its body is the first 4000 characters, as Azure DevOps keeps it (HTML).",
			"Only work items with this tag.",
			map[string]any{"comment": object(map[string]any{"author": str, "url": str, "body": str}), "commentedAt": str},
			"Only comments by"},
		{Closed, "Work item closed", "A work item moved to a state of the Completed or Removed category, as Closed, Done or Removed: once per move, so one reopened and closed again is a new one.",
			"Only work items with this tag.", map[string]any{"state": str, "by": str, "closedAt": str}, "Only work items closed by"},
	}
	out := make([]event, len(kinds))
	for i, k := range kinds {
		label := property{name: "label", kind: "string", description: k.label}
		input := schema{areaProperty, typeProperty, label, issueProperty, anyoneProperty, anyProperty}
		if k.kind == Opened {
			input = schema{areaProperty, typeProperty, label, anyoneProperty}
		}
		payload := map[string]any{"issue": issueSchema}
		for name, v := range k.payload {
			payload[name] = v
		}
		out[i] = event{name: "issue." + string(k.kind), title: k.title, kind: k.kind, input: input, payload: object(payload),
			description: k.description + " " + k.who + " people, never a build service or another bot, unless anyone is true."}
	}
	// For the person, not the project (#2034).
	return append(out, event{name: "issue.assigned", title: "Work item assigned to me", kind: Assigned,
		description: "A work item was assigned to the person whose token this server has, by anyone: once per assignment, so one unassigned and assigned again is a new one. One created already assigned is one too.",
		input:       schema{areaProperty, typeProperty, issueProperty},
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
	// nextPollMs is a minute, as the jira and linear servers': Azure DevOps's rate limit is by
	// use, and a poll reads each changed work item's updates or comments.
	nextPollMs = 60000
)

type pollParams struct {
	Name      string          `json:"name"`
	Arguments json.RawMessage `json:"arguments"`
	Cursor    json.RawMessage `json:"cursor"`
	MaxEvents *int            `json:"maxEvents"`
}

func (p pollParams) firstPoll() bool { return len(p.Cursor) == 0 || string(p.Cursor) == "null" }

// Events answers events/list and events/poll over Azure Boards.
type Events struct {
	Boards Boards
	// SignedIn says whether there is a token to read Azure DevOps with; nil is yes.
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
		return nil, eventsError(&BoardsError{Kind: NotSignedIn, Message: NotConnected})
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
	items, truncated, err := s.Boards.Activity(ctx, e.kind, since)
	if err != nil {
		return nil, false, err
	}
	var list []candidate
	for _, it := range items {
		w := it.WorkItem
		if a.area != "" && !strings.EqualFold(w.Area, a.area) && !strings.HasPrefix(strings.ToLower(w.Area), strings.ToLower(a.area)+`\`) {
			continue
		}
		if a.kind != "" && !strings.EqualFold(w.Type, a.kind) {
			continue
		}
		if !a.wantsIssue(w.ID) {
			continue
		}
		// Assigned to the token's owner is theirs, by anyone (#2034).
		if !a.anyone && it.Kind != Assigned && !it.trusted() {
			continue
		}
		if a.label != "" {
			if it.Kind == Labelled && !strings.EqualFold(it.Label, a.label) {
				continue
			}
			if it.Kind != Labelled && !containsFold(w.Tags, a.label) {
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

// eventsError is an Azure DevOps failure as the events draft's error codes.
func eventsError(err error) *rpcError {
	var rpc *rpcError
	if errors.As(err, &rpc) {
		return rpc
	}
	var l *BoardsError
	if !errors.As(err, &l) {
		return &rpcError{Code: -32603, Message: err.Error()}
	}
	switch l.Kind {
	case NotSignedIn:
		return &rpcError{Code: -32012, Message: l.Message, Data: map[string]any{"reason": "Azure DevOps not connected"}}
	case RateLimited:
		return &rpcError{Code: -32013, Message: l.Message, Data: map[string]any{"retryAfterMs": l.RetryAfterMs}}
	case NotFound:
		return invalidParams("%s: check AZURE_BOARDS_PROJECT", l.Message)
	}
	return &rpcError{Code: -32603, Message: l.Message}
}
