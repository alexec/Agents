package betterstackmcp

import (
	"context"
	"encoding/json"
	"errors"
	"sort"
	"strings"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/mcpevents"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// The MCP events (#3655), polled only: `events/list` and `events/poll` of the events draft
// (experimental-ext-triggers-events), in the sentry server's shape
// (Go/internal/sentrymcp/events.go): the cursor is a time and the incidents raised at or
// after it, so the server keeps nothing and a restart loses nothing.
// health.incident_started is a monitor or a heartbeat that failed, as the status page shows
// it; health.incident_resolved is one that came back. Each is a health node in Lineage,
// seen-in the release that was out when it started.

// rpcError is a JSON-RPC error answer: its code, message and optional data.
type rpcError = mcpevents.Error

func invalidParams(format string, args ...any) *rpcError {
	return mcpevents.InvalidParams(format, args...)
}

// The events.
const (
	IncidentStarted  = "health.incident_started"
	IncidentResolved = "health.incident_resolved"
)

// EventNames is the events it declares, by name.
func EventNames() []string { return []string{IncidentStarted, IncidentResolved} }

func eventsList() map[string]any {
	str := map[string]any{"type": "string"}
	input := map[string]any{"type": "object", "properties": map[string]any{
		"monitor": map[string]any{"type": "string", "description": "Only incidents of this monitor, by its id."},
	}, "required": []string{}, "additionalProperties": false}
	incident := map[string]any{"type": "object", "properties": map[string]any{
		"id": str, "name": str, "cause": str, "url": str, "monitor": str,
	}}
	payload := func(at ...string) map[string]any {
		props := map[string]any{"team": str, "incident": incident}
		for _, key := range at {
			props[key] = str
		}
		return map[string]any{"type": "object", "properties": props}
	}
	return map[string]any{"events": []any{
		map[string]any{
			"name": IncidentStarted, "title": "Better Stack incident started",
			"description": "A Better Stack monitor or heartbeat failed: the app is down or broken, as its status page shows. " +
				"Its data is the team, the incident (its id, the monitor's name, the cause, the address checked and the monitor's id) " +
				"and when it started.",
			"delivery": []string{"poll"}, "inputSchema": input, "payloadSchema": payload("startedAt"),
		},
		map[string]any{
			"name": IncidentResolved, "title": "Better Stack incident resolved",
			"description": "A Better Stack incident was resolved: the monitor or heartbeat works again. " +
				"An incident that lasted more than 7 days is not raised. " +
				"Its data is the team, the incident (its id, the monitor's name, the cause, the address checked and the monitor's id), " +
				"when it started and when it was resolved.",
			"delivery": []string{"poll"}, "inputSchema": input, "payloadSchema": payload("startedAt", "resolvedAt"),
		},
	}}
}

// checkArgs is an event's monitor filter: Better Stack's ids are digits.
func checkArgs(name string, raw json.RawMessage) (string, *rpcError) {
	given := map[string]json.RawMessage{}
	if len(raw) > 0 && string(raw) != "null" {
		if err := json.Unmarshal(raw, &given); err != nil {
			return "", invalidParams("arguments must be an object")
		}
	}
	monitor := ""
	for key, value := range given {
		if key != "monitor" {
			return "", invalidParams("unknown argument %s; %s takes monitor", key, name)
		}
		if string(value) != "null" && json.Unmarshal(value, &monitor) != nil {
			return "", invalidParams("monitor must be a string")
		}
		monitor = strings.TrimSpace(monitor)
		if strings.Trim(monitor, "0123456789") != "" {
			return "", invalidParams("monitor must be a monitor's id, digits only")
		}
	}
	return monitor, nil
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

// MARK: The cursor

// cursor is the time the last poll read up to, and the incidents it raised from Lag before
// it on, which a later poll leaves out. A client keeps it as an opaque string (base64url of
// its JSON).
type cursor = mcpevents.Cursor

func decodeCursor(raw json.RawMessage) (cursor, time.Time, *rpcError) {
	refused := mcpevents.RefusedCursor()
	var c cursor
	if !mcpevents.DecodeCursor(raw, &c) {
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
	// nextPollMs is the pace: two reads a minute per wait, well under Better Stack's limits.
	nextPollMs = 30000
	// Lag is how far back each poll looks again, for an incident Better Stack writes late.
	Lag = 30 * time.Minute
	// longest is how long an incident can have lasted and still be raised when resolved:
	// Better Stack finds incidents by the day they started.
	longest = 7 * 24 * time.Hour
)

type pollParams = mcpevents.Params

// Events answers events/poll from Better Stack's incidents.
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

// candidate is one event an incident raises.
type candidate struct {
	key  string
	at   time.Time
	data map[string]any
	// subject is its envelope (#4728): the incident, betterstack:incident:<team>#<id>. Each
	// incident starts and resolves once, so it has no key.
	subject wire.Ref
}

// Poll answers events/poll's params.
func (s *Events) Poll(ctx context.Context, raw json.RawMessage) (map[string]any, *rpcError) {
	var p pollParams
	if err := json.Unmarshal(raw, &p); err != nil {
		return nil, invalidParams("params must be an object")
	}
	if !contains(EventNames(), p.Name) {
		return nil, mcpevents.NoEvent(p.Name, EventNames())
	}
	monitor, bad := checkArgs(p.Name, p.Arguments)
	if bad != nil {
		return nil, bad
	}
	if !s.Account.Connected() {
		return nil, &rpcError{Code: -32012, Message: ErrNotConnected.Error(), Data: map[string]any{"reason": "not connected"}}
	}
	limit := p.Limit()
	now := s.now().Truncate(time.Second)
	first := p.FirstPoll()
	c, since := cursor{}, now
	if !first {
		var bad *rpcError
		if c, since, bad = decodeCursor(p.Cursor); bad != nil {
			return nil, bad
		}
	}
	found, truncated, err := s.candidates(ctx, p.Name, monitor, since.Add(-Lag))
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
		raised[cand.key] = true
		out = append(out, mcpevents.Enveloped(map[string]any{"eventId": p.Name + ":" + cand.key, "name": p.Name,
			"timestamp": cand.at.Format(time.RFC3339), "data": cand.data}, cand.subject, ""))
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
	return map[string]any{"events": out, "cursor": cursor{Since: next.Format(time.RFC3339), IDs: ids}.Encoded(),
		"truncated": truncated, "hasMore": more, "nextPollMs": nextPollMs}, nil
}

// candidates is every incident that raises the event from since on; truncated when Better
// Stack had more than one read takes.
func (s *Events) candidates(ctx context.Context, name, monitor string, since time.Time) ([]candidate, bool, error) {
	resolved := name == IncidentResolved
	from := since
	if resolved {
		from = since.Add(-longest)
	}
	incidents, truncated, err := s.Account.Incidents(ctx, from, monitor, resolved)
	if err != nil {
		return nil, false, err
	}
	out := []candidate{}
	for _, it := range incidents {
		if monitor != "" && it.MonitorID() != monitor {
			continue
		}
		started, ok := parseTime(it.Attributes.StartedAt)
		if !ok {
			continue
		}
		data := map[string]any{"team": it.Attributes.TeamName, "startedAt": started.Format(time.RFC3339),
			"incident": map[string]any{"id": it.ID, "name": it.Attributes.Name, "cause": it.Attributes.Cause,
				"url": it.Attributes.URL, "monitor": it.MonitorID()}}
		at := started
		if resolved {
			if it.Attributes.ResolvedAt == nil {
				continue
			}
			if at, ok = parseTime(*it.Attributes.ResolvedAt); !ok {
				continue
			}
			data["resolvedAt"] = at.Format(time.RFC3339)
		}
		if at.Before(since) {
			continue
		}
		out = append(out, candidate{key: it.ID, at: at, data: data,
			subject: mcpevents.Ref("betterstack", "incident", it.Attributes.TeamName, it.ID)})
	}
	return out, truncated, nil
}

// eventsError is a Better Stack failure as the events draft's error codes.
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
		return invalidParams("%s: check BETTERSTACK_TEAM and the monitor", api.Message)
	}
	return &rpcError{Code: -32603, Message: api.Message}
}
