package azureboardsmcp

import (
	"context"
	"encoding/json"
	"errors"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/mcpevents"
)

// The MCP events (#3804) of an Azure Boards project's work items, in the jira and linear
// servers' shape (Go/internal/jiramcp, Go/internal/linearmcp): the same issue.* names, cursor,
// paging and trust filter (#728), polled only: `events/list` and `events/poll` of the events
// draft (experimental-ext-triggers-events), which the Agents daemon speaks. A work item is the
// event's issue, and its tags are its labels.

// issueIDs are work items' ids as the issue argument gives them (its pattern makes each one).
func issueIDs(texts []string) []int {
	var ids []int
	for _, text := range texts {
		id, _ := strconv.Atoi(text)
		ids = append(ids, id)
	}
	return ids
}

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
func check(s schema, raw json.RawMessage) (args, *rpcError) {
	v, bad := s.Check(raw)
	if bad != nil {
		return args{}, bad
	}
	return args{area: strings.TrimSuffix(v.String("area"), `\`), kind: v.String("type"), label: v.String("label"), issues: issueIDs(v.Strings("issue")), anyone: v.Bool("anyone"), all: v.Bool("any")}, nil
}

// event is one event as events/list gives it, and the kind of activity it reads.
type event struct {
	mcpevents.Event
	kind Kind
}

var (
	areaProperty = property{Name: "area", Kind: "string",
		Description: `Only work items in this area path or under it, as Web App\Team. Left out, every area of the project.`}
	typeProperty  = property{Name: "type", Kind: "string", Description: "Only work items of this type, as Bug or User Story."}
	issueProperty = property{Name: "issue", Kind: "ids", Description: `Only this work item, or these, by its id, as "12" or ["12", "13"].`,
		Pattern: regexp.MustCompile(`^[1-9][0-9]{0,9}$`), LooksLike: "a work item's id, as 12"}
	// anyoneProperty opts into anyone's work item, comment or tag (#728); left out, only people.
	anyoneProperty = property{Name: "anyone", Kind: "boolean",
		Description: "true: by anyone, build services and other bots too. Left out, only people, never a bot."}
	// anyProperty is every work item in the project (#3797): a wait that names none sets it.
	anyProperty = property{Name: "any", Kind: "boolean",
		Description: "true: every work item in the project. A wait (not a workflow trigger) that names none, by issue or label, is refused without it. It is about which ones; anyone is about who."}
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
		label := property{Name: "label", Kind: "string", Description: k.label}
		input := schema{areaProperty, typeProperty, label, issueProperty, anyoneProperty, anyProperty}
		if k.kind == Opened {
			input = schema{areaProperty, typeProperty, label, anyoneProperty}
		}
		payload := map[string]any{"issue": issueSchema}
		for name, v := range k.payload {
			payload[name] = v
		}
		out[i] = event{Event: mcpevents.Event{Name: "issue." + string(k.kind), Title: k.title, Input: input, Payload: object(payload),
			Description: k.description + " " + k.who + " people, never a build service or another bot, unless anyone is true."}, kind: k.kind}
	}
	// For the person, not the project (#2034).
	return append(out, event{Event: mcpevents.Event{Name: "issue.assigned", Title: "Work item assigned to me",
		Description: "A work item was assigned to the person whose token this server has, by anyone: once per assignment, so one unassigned and assigned again is a new one. One created already assigned is one too.",
		Input:       schema{areaProperty, typeProperty, issueProperty},
		Payload:     object(map[string]any{"issue": issueSchema, "by": str, "assignedAt": str})}, kind: Assigned})
}()

func eventNamed(name string) (event, bool) { return mcpevents.Named(events, name) }

// EventNames is the events it declares, by name, in events/list's order.
func EventNames() []string { return mcpevents.Names(events) }

// eventsList is events/list's answer.
func eventsList() map[string]any { return mcpevents.List(events) }

// MARK: Polling

// candidate is something that may be raised: its id, its time (in mcpevents.TimeLayout) and its data.
type candidate = mcpevents.Candidate

const (
	// nextPollMs is a minute, as the jira and linear servers': Azure DevOps's rate limit is by
	// use, and a poll reads each changed work item's updates or comments.
	nextPollMs = 60000
)

// polls is how it polls, with Azure DevOps's times and errors.
var polls = mcpevents.Poller{NextPollMs: nextPollMs, Normalize: mcpevents.Normalized, Fail: eventsError}

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
		return nil, eventsError(&BoardsError{Kind: NotSignedIn, Message: NotConnected})
	}
	now := s.now()
	return polls.Poll(e.Name, p, func() string { return mcpevents.TimeString(now) }, func(since string) ([]candidate, mcpevents.Listed, error) {
		found, truncated, err := s.candidates(ctx, e, a, since)
		return found, mcpevents.Listed{Truncated: truncated}, err
	})
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
		at := mcpevents.Normalized(it.At)
		if at == "" {
			continue
		}
		// The work item is the subject; opened happens once to it, the rest are keyed by
		// the comment's, tag's or update's own id (#4728).
		key := ""
		if it.Kind != Opened {
			key = it.ID
		}
		list = append(list, candidate{EventID: e.Name + ":" + it.ID, Time: at, Data: mcpevents.Data(it.data()),
			Subject: mcpevents.Ref("azureboards", "issue", it.Project, itoa(w.ID)), Key: key})
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
