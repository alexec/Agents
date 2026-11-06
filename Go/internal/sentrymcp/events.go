package sentrymcp

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"
)

// The MCP events (#3583), polled only: `events/list` and `events/poll` of the events draft
// (experimental-ext-triggers-events), which the Agents daemon speaks, in the github server's
// shape (Go/internal/githubmcp/events.go): the cursor is a time and the issues raised at or
// after it, so the server keeps nothing and a restart loses nothing. health.issue_new is an
// issue Sentry saw for the first time; health.issue_regressed is a resolved issue that came
// back. Each names its project, the issue, its level and the release that saw it, which is
// the health node's `seen-in` link in Lineage (#3585).

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

// The events.
const (
	IssueNew       = "health.issue_new"
	IssueRegressed = "health.issue_regressed"
)

// EventNames is the events it declares, by name.
func EventNames() []string { return []string{IssueNew, IssueRegressed} }

type filter struct{ name, description string }

var filters = []filter{
	{"project", "Only issues in this Sentry project, by its slug."},
	{"environment", "Only issues seen in this environment, as production."},
	{"level", "Only issues of this level: fatal, error, warning, info or debug."},
}

var levels = []string{"fatal", "error", "warning", "info", "debug"}

func eventsList() map[string]any {
	str := map[string]any{"type": "string"}
	props := map[string]any{}
	for _, f := range filters {
		props[f.name] = map[string]any{"type": "string", "description": f.description}
	}
	input := map[string]any{"type": "object", "properties": props, "required": []string{}, "additionalProperties": false}
	issue := map[string]any{"type": "object", "properties": map[string]any{
		"id": str, "shortId": str, "title": str, "culprit": str, "level": str, "url": str,
	}}
	payload := func(at string) map[string]any {
		return map[string]any{"type": "object", "properties": map[string]any{
			"org": str, "project": str, "issue": issue, "release": str, at: str,
		}}
	}
	return map[string]any{"events": []any{
		map[string]any{
			"name": IssueNew, "title": "New Sentry issue",
			"description": "Sentry saw an issue for the first time: a crash or an error no issue had grouped before. " +
				"Its data is the organization, the project's slug, the issue (its id, short id, title, culprit, level and its page) " +
				"and the release that first saw it, empty when the app sends none.",
			"delivery": []string{"poll"}, "inputSchema": input, "payloadSchema": payload("firstSeen"),
		},
		map[string]any{
			"name": IssueRegressed, "title": "Sentry issue regressed",
			"description": "An issue that was resolved came back: Sentry saw it again after it was marked resolved, or in a release after the one that fixed it. " +
				"Once per regression, so an issue that comes back again is a new one. " +
				"Its data is the organization, the project's slug, the issue (its id, short id, title, culprit, level and its page) " +
				"and the release it came back in, empty when Sentry does not know it.",
			"delivery": []string{"poll"}, "inputSchema": input, "payloadSchema": payload("regressedAt"),
		},
	}}
}

// args are an event's checked arguments.
type args struct{ project, environment, level string }

func checkArgs(name string, raw json.RawMessage) (args, *rpcError) {
	var a args
	given := map[string]json.RawMessage{}
	if len(raw) > 0 && string(raw) != "null" {
		if err := json.Unmarshal(raw, &given); err != nil {
			return a, invalidParams("arguments must be an object")
		}
	}
	names := []string{}
	for _, f := range filters {
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
			return a, invalidParams("%s must be a string", key)
		}
		text = strings.TrimSpace(text)
		// A value goes into Sentry's search: no space or quote can widen it.
		if strings.ContainsAny(text, " \t\"") {
			return a, invalidParams("%s must be one word", key)
		}
		switch key {
		case "project":
			a.project = text
		case "environment":
			a.environment = text
		case "level":
			a.level = strings.ToLower(text)
			if a.level != "" && !contains(levels, a.level) {
				return a, invalidParams("level must be one of %s", strings.Join(levels, ", "))
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

// query is Sentry's search for an event's issues from since on.
func (a args) query(name string, since time.Time) string {
	parts := []string{}
	at := since.UTC().Format("2006-01-02T15:04:05")
	if name == IssueNew {
		parts = append(parts, "firstSeen:>="+at)
	} else {
		parts = append(parts, "is:regressed", "lastSeen:>="+at)
	}
	if a.project != "" {
		parts = append(parts, "project:"+a.project)
	}
	if a.level != "" {
		parts = append(parts, "level:"+a.level)
	}
	return strings.Join(parts, " ")
}

func (a args) match(it Issue) bool {
	return (a.project == "" || a.project == it.Project.Slug) && (a.level == "" || a.level == it.Level)
}

// MARK: The cursor

// cursor is the time the last poll read up to, and the issues it raised from Lag before it
// on, which a later poll leaves out. A client keeps it as an opaque string (base64url of its
// JSON).
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

func decodeCursor(raw json.RawMessage) (cursor, time.Time, *rpcError) {
	refused := invalidParams("cursor is not one this server gave")
	var text string
	if err := json.Unmarshal(raw, &text); err != nil {
		return cursor{}, time.Time{}, refused
	}
	data, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(text, "="))
	if err != nil {
		return cursor{}, time.Time{}, refused
	}
	var c cursor
	if json.Unmarshal(data, &c) != nil {
		return cursor{}, time.Time{}, refused
	}
	since, ok := parseTime(c.Since)
	if !ok {
		return cursor{}, time.Time{}, refused
	}
	return c, since, nil
}

// MARK: Polling

const (
	maxEvents = 100
	// nextPollMs is the pace: two searches a minute per wait, well under Sentry's limits.
	nextPollMs = 30000
	// Lag is how far back each poll looks again: Sentry dates an issue by its first event's
	// own time, which can come in a while after it.
	Lag = 30 * time.Minute
	// maxLookups is the most regressed issues whose own page one poll reads.
	maxLookups = 25
)

type pollParams struct {
	Name      string          `json:"name"`
	Arguments json.RawMessage `json:"arguments"`
	Cursor    json.RawMessage `json:"cursor"`
	MaxEvents *int            `json:"maxEvents"`
}

// Events answers events/poll from Sentry's issues.
type Events struct {
	Account *Account
	Now     func() time.Time
}

func (s *Events) now() time.Time {
	if s.Now != nil {
		return s.Now().UTC()
	}
	return time.Now().UTC()
}

// candidate is one event an issue may raise.
type candidate struct {
	key string // the cursor's: the issue's id, and for a regression its time
	at  time.Time
	// data is the event's data, read from the issue's own page when it is raised.
	data func(context.Context) (map[string]any, error)
}

// Poll answers events/poll's params.
func (s *Events) Poll(ctx context.Context, raw json.RawMessage) (map[string]any, *rpcError) {
	var p pollParams
	if err := json.Unmarshal(raw, &p); err != nil {
		return nil, invalidParams("params must be an object")
	}
	if !contains(EventNames(), p.Name) {
		return nil, &rpcError{Code: -32011, Message: fmt.Sprintf("no event %s; this server offers %s", p.Name, strings.Join(EventNames(), ", "))}
	}
	a, bad := checkArgs(p.Name, p.Arguments)
	if bad != nil {
		return nil, bad
	}
	if !s.Account.Connected() {
		return nil, &rpcError{Code: -32012, Message: ErrNotConnected.Error(), Data: map[string]any{"reason": "not connected"}}
	}
	limit := 50
	if p.MaxEvents != nil {
		limit = *p.MaxEvents
	}
	limit = min(maxEvents, max(1, limit))
	now := s.now().Truncate(time.Second)
	first := len(p.Cursor) == 0 || string(p.Cursor) == "null"
	c, since := cursor{}, now
	if !first {
		var bad *rpcError
		if c, since, bad = decodeCursor(p.Cursor); bad != nil {
			return nil, bad
		}
	}
	found, truncated, err := s.candidates(ctx, p.Name, a, since.Add(-Lag))
	if err != nil {
		return nil, eventsError(err)
	}
	fresh := []candidate{}
	for _, cand := range found {
		if !contains(c.IDs, cand.key) {
			fresh = append(fresh, cand)
		}
	}
	sort.SliceStable(fresh, func(i, j int) bool { return fresh[i].at.Before(fresh[j].at) })
	taken := fresh
	if first {
		taken = nil // the first poll only marks where it starts
	} else if len(taken) > limit {
		taken = taken[:limit]
	}
	out := []any{}
	raised := map[string]bool{}
	for _, cand := range taken {
		data, err := cand.data(ctx)
		if err != nil {
			return nil, eventsError(err)
		}
		raised[cand.key] = true
		out = append(out, map[string]any{"eventId": p.Name + ":" + s.Account.Org + ":" + cand.key, "name": p.Name,
			"timestamp": cand.at.Format(time.RFC3339), "data": data})
	}
	more := !first && len(fresh) > len(taken)
	next := now
	if more {
		next = since // what is left is still after it
	}
	ids := []string{}
	for _, cand := range found {
		if (first || raised[cand.key] || contains(c.IDs, cand.key)) && !cand.at.Before(next.Add(-Lag)) {
			ids = append(ids, cand.key)
		}
	}
	return map[string]any{"events": out, "cursor": cursor{Since: next.Format(time.RFC3339), IDs: ids}.encoded(),
		"truncated": truncated, "hasMore": more, "nextPollMs": nextPollMs}, nil
}

// candidates is every issue that may raise the event from since on; truncated when Sentry
// had more than one search reads.
func (s *Events) candidates(ctx context.Context, name string, a args, since time.Time) ([]candidate, bool, error) {
	sortBy := "new"
	if name == IssueRegressed {
		sortBy = "date"
	}
	issues, err := s.Account.Issues(ctx, a.query(name, since), sortBy, a.environment)
	if err != nil {
		return nil, false, err
	}
	truncated := len(issues) >= maxIssues
	out := []candidate{}
	lookups := 0
	for _, it := range issues {
		if !a.match(it) {
			continue
		}
		if name == IssueNew {
			at, ok := parseTime(it.FirstSeen)
			if !ok || at.Before(since) {
				continue
			}
			out = append(out, candidate{key: it.ID, at: at, data: func(ctx context.Context) (map[string]any, error) {
				d, err := s.Account.Issue(ctx, it.ID)
				if err != nil {
					return nil, err
				}
				release := ""
				if d.FirstRelease != nil {
					release = d.FirstRelease.Version
				}
				return s.data(it, release, "firstSeen", at), nil
			}})
			continue
		}
		// A regression's time and release are on the issue's own page.
		if lookups == maxLookups {
			truncated = true
			break
		}
		lookups++
		d, err := s.Account.Issue(ctx, it.ID)
		if err != nil {
			return nil, false, err
		}
		at, release, ok := regression(d)
		if !ok || at.Before(since) {
			continue
		}
		out = append(out, candidate{key: it.ID + "@" + at.Format(time.RFC3339), at: at,
			data: func(context.Context) (map[string]any, error) { return s.data(it, release, "regressedAt", at), nil }})
	}
	return out, truncated, nil
}

// regression is the issue's last set_regression: when, and the release it names, or the
// release that last saw the issue.
func regression(d Details) (time.Time, string, bool) {
	var at time.Time
	release := ""
	for _, act := range d.Activity {
		if act.Type != "set_regression" {
			continue
		}
		t, ok := parseTime(act.DateCreated)
		if !ok || !t.After(at) {
			continue
		}
		at = t
		release, _ = act.Data["version"].(string)
	}
	if at.IsZero() {
		return at, "", false
	}
	if release == "" && d.LastRelease != nil {
		release = d.LastRelease.Version
	}
	return at, release, true
}

func (s *Events) data(it Issue, release, key string, at time.Time) map[string]any {
	return map[string]any{
		"org": s.Account.Org, "project": it.Project.Slug, "release": release, key: at.Format(time.RFC3339),
		"issue": map[string]any{"id": it.ID, "shortId": it.ShortID, "title": it.Title, "culprit": it.Culprit,
			"level": it.Level, "url": it.Permalink},
	}
}

// eventsError is a Sentry failure as the events draft's error codes.
func eventsError(err error) *rpcError {
	var api *APIError
	if !errors.As(err, &api) {
		return &rpcError{Code: -32603, Message: err.Error()}
	}
	switch api.Kind {
	case NotSignedIn:
		return &rpcError{Code: -32012, Message: api.Message, Data: map[string]any{"reason": "not connected"}}
	case RateLimited:
		return &rpcError{Code: -32013, Message: api.Message, Data: map[string]any{"retryAfterMs": api.RetryAfterMs}}
	case NotFound:
		return invalidParams("%s: check SENTRY_ORG", api.Message)
	}
	return &rpcError{Code: -32603, Message: api.Message}
}
