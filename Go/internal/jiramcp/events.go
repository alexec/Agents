package jiramcp

import (
	"context"
	"encoding/json"
	"errors"
	"regexp"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/mcpevents"
)

// The MCP events (#3247) of the Jira site's issues, in the linear server's shape
// (Go/internal/linearmcp): the same issue.* names, cursor, paging and trust filter (#728),
// polled only: `events/list` and `events/poll` of the events draft
// (experimental-ext-triggers-events), which the Agents daemon speaks.

// rpcError is a JSON-RPC error answer: its code, message and optional data.
type rpcError = mcpevents.Error

func invalidParams(format string, args ...any) *rpcError {
	return mcpevents.InvalidParams(format, args...)
}

// property is one argument of an event: a string or a boolean.
type property = mcpevents.Property

// schema is an event's arguments: named properties in the order errors list them, none
// required, no others allowed.
type schema = mcpevents.Schema

// args are an event's checked arguments.
type args struct {
	project, label, issue string
	anyone                bool
}

// check reads raw (null or missing as {}) and checks it: no unknown keys, types, shapes.
func check(s schema, raw json.RawMessage) (args, *rpcError) {
	v, bad := s.Check(raw)
	if bad != nil {
		return args{}, bad
	}
	return args{project: strings.ToUpper(v.String("project")), label: v.String("label"), issue: strings.ToUpper(v.String("issue")), anyone: v.Bool("anyone")}, nil
}

// event is one event as events/list gives it, and the kind of activity it reads.
type event struct {
	mcpevents.Event
	kind Kind
}

var (
	projectProperty = property{Name: "project", Kind: "string",
		Description: "Only issues of this project, by its key, as PROJ. Left out, every project of the site.",
		Pattern:     regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_]{0,9}$`), LooksLike: "a project key, as PROJ"}
	issueProperty = property{Name: "issue", Kind: "string", Description: "Only this issue, by its key, as PROJ-12.",
		Pattern: regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_]{0,9}-[0-9]+$`), LooksLike: "an issue key, as PROJ-12"}
	// anyoneProperty opts into anyone's issue, comment or label (#728); left out, only the site's own users.
	anyoneProperty = property{Name: "anyone", Kind: "boolean",
		Description: "true: by anyone, customers and apps too. Left out, only the site's own users, never a customer or an app."}
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
		label := property{Name: "label", Kind: "string", Description: k.label}
		input := schema{projectProperty, label, issueProperty, anyoneProperty}
		if k.kind == Opened {
			input = schema{projectProperty, label, anyoneProperty}
		}
		payload := map[string]any{"issue": issueSchema}
		for name, v := range k.payload {
			payload[name] = v
		}
		out[i] = event{Event: mcpevents.Event{Name: "issue." + string(k.kind), Title: k.title, Input: input, Payload: object(payload),
			Description: k.description + " " + k.who + " the site's own users, never a customer or an app, unless anyone is true."}, kind: k.kind}
	}
	// For the person, not the site (#2034).
	return append(out, event{Event: mcpevents.Event{Name: "issue.assigned", Title: "Issue assigned to me",
		Description: "An issue was assigned to the Jira account this server is connected as, by anyone: once per assignment, so one unassigned and assigned again is a new one. An issue made already assigned has no history of it, so it is not an event.",
		Input:       schema{projectProperty, issueProperty},
		Payload:     object(map[string]any{"issue": issueSchema, "by": str, "assignedAt": str})}, kind: Assigned})
}()

func eventNamed(name string) (event, bool) { return mcpevents.Named(events, name) }

// EventNames is the events it declares, by name, in events/list's order.
func EventNames() []string { return mcpevents.Names(events) }

// eventsList is events/list's answer.
func eventsList() map[string]any { return mcpevents.List(events) }

// MARK: Polling

// candidate is something that may be raised: its id, its time (in timeLayout) and its data.
type candidate struct {
	eventID string
	time    string
	data    map[string]any
}

const (
	// nextPollMs is a minute, as the linear server's: Jira Cloud's rate limit is by cost, and
	// a site's Jira admin, who could set up webhooks instead, is often not the person.
	nextPollMs = 60000
)

// polls is how it polls, with Jira's times and errors.
var polls = mcpevents.Poller{NextPollMs: nextPollMs, Normalize: normalized, Fail: eventsError}

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
	p, bad := mcpevents.ParseParams(raw)
	if bad != nil {
		return nil, bad
	}
	e, ok := eventNamed(p.Name)
	if !ok {
		return nil, mcpevents.NoEvent(p.Name, EventNames())
	}
	a, bad := check(e.Input, p.Arguments)
	if bad != nil {
		return nil, bad
	}
	// No key is said at once, on the first poll too, so a wait set up without one fails then.
	if s.SignedIn != nil && !s.SignedIn() {
		return nil, eventsError(&JiraError{Kind: NotSignedIn, Message: notSignedIn})
	}
	now := s.now()
	return polls.Poll(e.Name, p, func() string { return timeString(now) }, func(since string) ([]mcpevents.Candidate, mcpevents.Listed, error) {
		found, truncated, err := s.candidates(ctx, e, a, since)
		list := make([]mcpevents.Candidate, len(found))
		for i, c := range found {
			list[i] = mcpevents.Candidate{EventID: c.eventID, Time: c.time, Data: mcpevents.Data(c.data)}
		}
		return list, mcpevents.Listed{Truncated: truncated}, err
	})
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
		list = append(list, candidate{eventID: e.Name + ":" + it.ID, time: at, data: it.data()})
	}
	return list, truncated, nil
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
