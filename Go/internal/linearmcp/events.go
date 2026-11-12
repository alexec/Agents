package linearmcp

import (
	"context"
	"encoding/json"
	"errors"
	"regexp"
	"slices"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/mcpevents"
)

// The MCP events (#839) of the Linear workspace's issues, in the github server's shape
// (Go/internal/githubmcp): the same issue.* names, cursor, paging and trust filter (#728),
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
	team, label, issue string
	anyone             bool
}

// check reads raw (null or missing as {}) and checks it: no unknown keys, types, shapes.
func check(s schema, raw json.RawMessage) (args, *rpcError) {
	v, bad := s.Check(raw)
	if bad != nil {
		return args{}, bad
	}
	return args{team: strings.ToUpper(v.String("team")), label: v.String("label"), issue: strings.ToUpper(v.String("issue")), anyone: v.Bool("anyone")}, nil
}

// event is one event as events/list gives it, and the kind of activity it reads.
type event struct {
	mcpevents.Event
	kind Kind
}

var (
	teamProperty = property{Name: "team", Kind: "string",
		Description: "Only issues of this team, by its key, as ENG. Left out, every team of the workspace.",
		Pattern:     regexp.MustCompile(`^[A-Za-z0-9_]{1,10}$`), LooksLike: "a team key, as ENG"}
	issueProperty = property{Name: "issue", Kind: "string", Description: "Only this issue, by its identifier, as ENG-12.",
		Pattern: regexp.MustCompile(`^[A-Za-z0-9_]{1,10}-[0-9]+$`), LooksLike: "an issue identifier, as ENG-12"}
	// anyoneProperty opts into anyone's issue, comment, label or close (#728); left out, only the workspace's own.
	anyoneProperty = property{Name: "anyone", Kind: "boolean",
		Description: "true: by anyone, guests, apps and integrations too. Left out, only the workspace's members, never a guest or an app."}
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
		label := property{Name: "label", Kind: "string", Description: k.label}
		input := schema{teamProperty, label, issueProperty, anyoneProperty}
		if k.kind == Opened {
			input = schema{teamProperty, label, anyoneProperty}
		}
		payload := map[string]any{"issue": issueSchema}
		for name, v := range k.payload {
			payload[name] = v
		}
		out[i] = event{Event: mcpevents.Event{Name: "issue." + string(k.kind), Title: k.title, Input: input, Payload: object(payload),
			Description: k.description + " " + k.who + " the workspace's members, never a guest or an app, unless anyone is true."}, kind: k.kind}
	}
	// For the person, not the workspace (#2034).
	return append(out, event{Event: mcpevents.Event{Name: "issue.assigned", Title: "Issue assigned to me",
		Description: "An issue was assigned to the Linear account this server is connected as, by anyone: once per assignment, so one unassigned and assigned again is a new one. Linear keeps no history of an issue's first few minutes, so an issue assigned as it is made is not an event.",
		Input:       schema{teamProperty, issueProperty},
		Payload:     object(map[string]any{"issue": issueSchema, "by": str, "assignedAt": str})}, kind: Assigned})
}()

func eventNamed(name string) (event, bool) { return mcpevents.Named(events, name) }

// EventNames is the events it declares, by name, in events/list's order.
func EventNames() []string { return mcpevents.Names(events) }

// eventsList is events/list's answer.
func eventsList() map[string]any { return mcpevents.List(events) }

// MARK: Polling

// candidate is something that may be raised: its id, its time (in timeLayout) and its data.
type candidate = mcpevents.Candidate

const (
	// nextPollMs is a minute, not the github server's 30 s: a personal key has 1500 requests an
	// hour, and a wait on each of the four events costs three a poll.
	nextPollMs = 60000
)

// polls is how it polls, with Linear's times and errors.
var polls = mcpevents.Poller{NextPollMs: nextPollMs, Normalize: normalized, Fail: eventsError}

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
		return nil, eventsError(&LinearError{Kind: NotSignedIn, Message: "Linear is not signed in: connect Linear in Connectors, or set LINEAR_API_KEY to a personal API key"})
	}
	now := s.now()
	return polls.Poll(e.Name, p, func() string { return timeString(now) }, func(since string) ([]candidate, mcpevents.Listed, error) {
		found, truncated, err := s.candidates(ctx, e, a, since)
		return found, mcpevents.Listed{Truncated: truncated}, err
	})
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
		// The issue is the subject; all but opened can happen again to it, keyed by the
		// comment's, label's or history entry's own id (#4728).
		key := ""
		if it.Kind != Opened {
			key = it.ID
		}
		list = append(list, candidate{EventID: e.Name + ":" + it.ID, Time: at, Data: mcpevents.Data(it.data()),
			Subject: mcpevents.Ref("linear", "issue", it.Issue.Team, it.Issue.Identifier), Key: key})
	}
	return list, truncated, nil
}

func contains(list []string, s string) bool { return slices.Contains(list, s) }

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
