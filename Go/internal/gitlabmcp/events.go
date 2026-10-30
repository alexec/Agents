package gitlabmcp

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

// The MCP events (#1629) of a GitLab project's merge requests, pipelines and issues, in the
// github server's shape (Go/internal/githubmcp/events.go): the same names where they mean the
// same, and the same cursor, paging and trust filter (#728), polled only: `events/list` and
// `events/poll` of the events draft (experimental-ext-triggers-events), which the Agents
// daemon speaks. A merge request is a "pr" in names and data, as on GitHub.

// event is one event as events/list gives it.
type event struct {
	name, title, description string
	input                    schema
	payload                  map[string]any
}

func (e event) json() map[string]any {
	return map[string]any{"name": e.name, "title": e.title, "description": e.description, "delivery": []string{"poll"},
		"inputSchema": e.input.json(), "payloadSchema": e.payload}
}

// projectPattern is a project's path (group/name, with subgroups) or its numeric id.
var projectPattern = regexp.MustCompile(`^([0-9]+|[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)+)$`)

var (
	projectProperty = property{name: "project", kind: "string",
		description: "The GitLab project, by its path (group/name, subgroups too) or its id. Left out, the project this folder pushes to.",
		pattern:     projectPattern, looksLike: "group/name or a project id"}
	prProperty = property{name: "pr", kind: "integer", description: "Only this merge request, by number (its iid, as !12)."}
	// anyoneProperty opts into anyone's issue, comment or merge request (#728); left out, only the project's own people.
	anyoneProperty = property{name: "anyone", kind: "boolean",
		description: "true: from anyone, bots, forks and people outside the project too. Left out, only the project's members with Reporter access or more, never a bot, and for a merge request never one from a fork."}
	// mineProperty is only the connection's owner's own merge requests (#2034), a fork's too.
	mineProperty = property{name: "mine", kind: "boolean",
		description: "true: only merge requests by the GitLab account this server is connected as, whatever anyone says."}
)

// ownMRs is what every merge request event says of whose merge requests it raises.
const ownMRs = " Only merge requests from a branch of the project itself, not a fork, by its members with Reporter access or more, never a bot, unless anyone is true."

func branchProperty(description string) property {
	return property{name: "branch", kind: "string", description: description}
}

func object(props map[string]any) map[string]any {
	return map[string]any{"type": "object", "properties": props}
}

var str, integer = map[string]any{"type": "string"}, map[string]any{"type": "integer"}

func mrSchema(extra map[string]any) map[string]any {
	props := map[string]any{"number": integer, "title": str, "branch": str, "url": str}
	for k, v := range extra {
		props[k] = v
	}
	return object(props)
}

func mrInput() schema {
	return schema{projectProperty, branchProperty("Only the merge request from this branch."), prProperty, anyoneProperty}
}

// events are the events this server offers, in the github server's order.
// fixesSchema is a merge request's fixes: the issues its description closes, "#12" or
// "group/project#12" (#2349).
var fixesSchema = map[string]any{"type": "array", "items": str}

var events = append([]event{
	{name: "checks.failed", title: "Pipeline failed",
		description: "A merge request's pipeline finished failed: one event per pipeline and failure, so a pipeline retried that fails again is a new one. Jobs allowed to fail are not in failedJobs." + ownMRs,
		input:       schema{projectProperty, branchProperty("Only pipelines of the merge request from this branch."), prProperty, anyoneProperty, mineProperty},
		payload: object(map[string]any{
			"pr": mrSchema(nil), "headSha": str,
			"run":        object(map[string]any{"id": integer, "name": str, "url": str}),
			"failedJobs": map[string]any{"type": "array", "items": object(map[string]any{"name": str, "url": str})},
		})},
	{name: "pr.opened", title: "Merge request opened",
		description: "A merge request was opened, or a draft was marked ready: a merge request open and not a draft now that was not at the last poll. Drafts never count. Reopened, it is raised again." + ownMRs,
		input:       mrInput(),
		payload:     object(map[string]any{"pr": mrSchema(map[string]any{"author": str, "fixes": fixesSchema}), "openedAt": str})},
	{name: "pr.merged", title: "Merge request merged", description: "A merge request was merged." + ownMRs,
		input:   mrInput(),
		payload: object(map[string]any{"pr": mrSchema(map[string]any{"fixes": fixesSchema}), "mergedAt": str, "mergeSha": str})},
	{name: "pr.closed", title: "Merge request closed", description: "A merge request was closed without being merged." + ownMRs,
		input:   mrInput(),
		payload: object(map[string]any{"pr": mrSchema(map[string]any{"fixes": fixesSchema}), "closedAt": str})},
	{name: "pr.conflicted", title: "Merge request in conflict",
		description: "An open merge request began to conflict with its target branch, so it cannot merge until it is rebased. Once per conflict: it is raised again only after it merges cleanly and then conflicts anew." + ownMRs,
		input:       append(mrInput(), mineProperty),
		payload:     object(map[string]any{"pr": mrSchema(nil), "conflictedAt": str})},
	// For the person, not the project (#2034): what asks the connection's owner for something.
	{name: "review.requested", title: "Review requested from me",
		description: "The GitLab account this server is connected as was made a reviewer of an open merge request: once per request, so one taken off and put back is a new one. Anyone's merge request, a fork's too.",
		input:       schema{projectProperty, prProperty},
		payload:     object(map[string]any{"pr": mrSchema(map[string]any{"author": str}), "requestedAt": str})},
	{name: "review.comment", title: "Merge request line commented on",
		description: "Someone left a comment on a line of a merge request's diff, or answered in its thread. Its body is the first 4000 characters. Only comments by the project's members with Reporter access or more, never a bot, unless anyone is true; and only on the project's own merge requests.",
		input:       mrInput(),
		payload: object(map[string]any{"pr": mrSchema(nil), "commentedAt": str,
			"comment": object(map[string]any{"id": integer, "author": str, "path": str, "line": integer, "body": str, "url": str})})},
}, append(issueEvents(), assignedEvent)...)

// assignedEvent is for the person, not the project (#2034): an issue given to the connection's owner.
var assignedEvent = event{name: "issue.assigned", title: "Issue assigned to me",
	description: "An open issue was assigned to the GitLab account this server is connected as: once per assignment, so one unassigned and assigned again is a new one. Anyone's issue.",
	input:       schema{projectProperty, property{name: "issue", kind: "integer", description: "Only this issue, by number (its iid, as #12)."}},
	payload: object(map[string]any{"issue": object(map[string]any{
		"number": integer, "title": str, "author": str, "labels": map[string]any{"type": "array", "items": str}, "url": str,
		"assignees": map[string]any{"type": "array", "items": str},
	}), "assignedAt": str})}

func issueEvents() []event {
	issueSchema := object(map[string]any{
		"number": integer, "title": str, "author": str, "labels": map[string]any{"type": "array", "items": str}, "url": str,
		"assignees": map[string]any{"type": "array", "items": str},
	})
	issue := property{name: "issue", kind: "integer", description: "Only this issue, by number (its iid, as #12)."}
	kinds := []struct {
		kind                      IssueKind
		title, description, label string
		payload                   map[string]any
		who                       string
	}{
		{IssueOpened, "Issue opened", "An issue was opened.",
			"Only issues opened with this label.", map[string]any{"openedAt": str}, "Only issues opened by"},
		{IssueLabelled, "Issue labelled", "A label was added to an issue: one event per label added.",
			"Only when this label is the one added.", map[string]any{"label": str, "by": str, "labelledAt": str}, "Only labels added by"},
		{IssueCommented, "Issue commented on",
			"A comment was left on an issue. Its body is the first 4000 characters. GitLab's own notes (a label added, a close) are not comments.",
			"Only issues with this label.",
			map[string]any{"comment": object(map[string]any{"author": str, "url": str, "body": str}), "commentedAt": str},
			"Only comments by"},
		{IssueClosed, "Issue closed", "An issue was closed. Reopened and closed again, it is a new event.", "Only issues with this label.",
			map[string]any{"by": str, "closedAt": str}, "Only issues closed by"},
	}
	out := make([]event, len(kinds))
	for i, k := range kinds {
		label := property{name: "label", kind: "string", description: k.label}
		input := schema{projectProperty, label, issue, anyoneProperty}
		if k.kind == IssueOpened {
			input = schema{projectProperty, label, anyoneProperty}
		}
		description := k.description + " " + k.who + " the project's members with Reporter access or more, never a bot, unless anyone is true."
		payload := map[string]any{"issue": issueSchema}
		for name, v := range k.payload {
			payload[name] = v
		}
		out[i] = event{name: "issue." + string(k.kind), title: k.title, description: description, input: input, payload: object(payload)}
	}
	return out
}

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

// candidate is something that may be raised: its id, its time (in timeLayout), and its data,
// looked up only once it is taken; nil data skips it, though the cursor still moves past it.
type candidate struct {
	eventID string
	time    string
	data    func() (map[string]any, error)
}

const (
	maxEvents  = 100
	nextPollMs = 30000
)

type pollParams struct {
	Name      string          `json:"name"`
	Arguments json.RawMessage `json:"arguments"`
	Cursor    json.RawMessage `json:"cursor"`
	MaxEvents *int            `json:"maxEvents"`
}

func (p pollParams) firstPoll() bool { return len(p.Cursor) == 0 || string(p.Cursor) == "null" }

// Events answers events/list and events/poll over a GitLab.
type Events struct {
	GitLab GitLab
	Now    func() time.Time
}

func (s *Events) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

// Poll answers events/poll's params.
func (s *Events) Poll(ctx context.Context, raw json.RawMessage) (map[string]any, *rpcError) {
	var p pollParams
	if err := json.Unmarshal(raw, &p); err != nil {
		return nil, invalidParams("params must be an object")
	}
	e, ok := eventNamed(p.Name)
	if !ok {
		return nil, &rpcError{Code: -32011, Message: fmt.Sprintf("no event %s; this server offers %s", p.Name, strings.Join(EventNames(), ", "))}
	}
	a, bad := e.input.check(p.Arguments)
	if bad != nil {
		return nil, bad
	}
	if a.project == "" {
		project, err := s.GitLab.DefaultProject(ctx)
		if err != nil {
			var gl *GitLabError
			if errors.As(err, &gl) && gl.Kind == NotFound {
				return nil, invalidParams("%s", gl.Message)
			}
			return nil, eventsError(err)
		}
		a.project = project
	}
	// mine: the connection's owner's own open merge requests, asked once a poll (#2034).
	var yours *Yours
	if a.mine || e.name == "review.requested" || e.name == "issue.assigned" {
		y, err := s.GitLab.Yours(ctx, a.project)
		if err != nil {
			return nil, eventsError(err)
		}
		yours = &y
	}
	switch e.name {
	case "review.requested":
		return s.pollDiff(e.name, "requestedAt", a, p, func() ([]state, error) {
			var out []state
			for _, r := range yours.Reviews {
				j := r.MR.json()
				j["author"] = r.Author
				out = append(out, state{mr: r.MR, on: new(true), json: j})
			}
			return out, nil
		})
	case "issue.assigned":
		return s.pollDiff(e.name, "assignedAt", a, p, func() ([]state, error) {
			var out []state
			for _, i := range yours.Assigned {
				if a.issue == 0 || i.Number == a.issue {
					out = append(out, state{mr: MR{Number: i.Number, Title: i.Title, URL: i.URL}, on: new(true), json: i.json()})
				}
			}
			return out, nil
		})
	case "pr.conflicted":
		return s.pollDiff(e.name, "conflictedAt", a, p, func() ([]state, error) {
			mrs, err := s.GitLab.OpenMRs(ctx, a.project)
			var out []state
			for _, m := range mrs {
				if yours != nil {
					if yours.owns(m.MR.Number) {
						out = append(out, state{mr: m.MR, on: m.Conflicts, json: m.MR.json()})
					}
				} else if a.anyone || m.Trusted {
					out = append(out, state{mr: m.MR, on: m.Conflicts, json: m.MR.json()})
				}
			}
			return out, err
		})
	case "pr.opened":
		return s.pollDiff(e.name, "openedAt", a, p, func() ([]state, error) {
			mrs, err := s.GitLab.OpenMRs(ctx, a.project)
			var out []state
			for _, m := range mrs {
				if !a.anyone && !m.Trusted {
					continue
				}
				ready := !m.Draft
				j := m.MR.json()
				j["author"] = m.Author
				out = append(out, state{mr: m.MR, on: &ready, json: j})
			}
			return out, err
		})
	}
	return s.poll(e, p, func(since string) ([]candidate, Listed, error) {
		return candidates(ctx, s.GitLab, e.name, a, yours, since)
	})
}

// poll is events/poll over a cursor: the first poll (no cursor) gives none and starts from
// now; later ones give what is new since, oldest first, at most maxEvents, with hasMore and a
// cursor that goes on from the last one taken. A poll that took all there was and was not
// truncated goes on to the newest the listing saw, wanted or not (P20261020-1): a wait whose
// filter drops everything would otherwise read all since its last event, every poll.
func (s *Events) poll(e event, p pollParams, find func(since string) ([]candidate, Listed, error)) (map[string]any, *rpcError) {
	limit := 50
	if p.MaxEvents != nil {
		limit = *p.MaxEvents
	}
	limit = min(maxEvents, max(1, limit))
	if p.firstPoll() {
		return map[string]any{"events": []any{}, "cursor": cursor{Since: timeString(s.now())}.encoded(),
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
	found, listed, err := find(c.Since)
	if err != nil {
		return nil, eventsError(err)
	}
	var fresh []candidate
	for _, f := range found {
		if f.time > c.Since || (f.time == c.Since && !seen[f.eventID]) {
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
	if !listed.Truncated && len(taken) == len(fresh) && listed.Newest > since {
		since = listed.Newest
	}
	var ids []string
	if since == c.Since {
		ids = append(ids, c.IDs...)
	}
	for _, t := range taken {
		if t.time == since && !contains(ids, t.eventID) {
			ids = append(ids, t.eventID)
		}
	}
	out := []any{}
	for _, t := range taken {
		data, err := t.data()
		if err != nil {
			return nil, eventsError(err)
		}
		if data != nil {
			out = append(out, map[string]any{"eventId": t.eventID, "name": e.name, "timestamp": t.time, "data": data})
		}
	}
	return map[string]any{"events": out, "cursor": cursor{Since: since, IDs: ids}.encoded(),
		"truncated": listed.Truncated, "hasMore": len(fresh) > len(taken), "nextPollMs": nextPollMs}, nil
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

// state is a merge request and whether its state (in conflict, or open and ready) is on now;
// nil keeps the one it had.
type state struct {
	mr   MR
	on   *bool
	json map[string]any
}

// pollDiff raises an event for each merge request whose state is on now and was not at the
// last poll: the cursor's ids are the merge requests that were on then. A first poll takes
// those already on as known. A conflict has no time on GitLab, only a state, so pr.conflicted
// diffs it; so does pr.opened, so a draft marked ready is raised as it is.
func (s *Events) pollDiff(name, key string, a args, p pollParams, states func() ([]state, error)) (map[string]any, *rpcError) {
	first := p.firstPoll()
	c := cursor{}
	if !first {
		var bad *rpcError
		if c, bad = decodeCursor(p.Cursor); bad != nil {
			return nil, bad
		}
	}
	limit := maxEvents
	if !first {
		limit = 50
		if p.MaxEvents != nil {
			limit = *p.MaxEvents
		}
		limit = min(maxEvents, max(1, limit))
	}
	mrs, err := states()
	if err != nil {
		return nil, eventsError(err)
	}
	was := map[string]bool{}
	for _, id := range c.IDs {
		was[id] = true
	}
	id := func(st state) string { return fmt.Sprintf("%s:%s:%d", name, a.project, st.mr.Number) }
	var still, fresh []state
	for _, st := range mrs {
		if (a.pr != 0 && st.mr.Number != a.pr) || (a.branch != "" && st.mr.Branch != a.branch) {
			continue
		}
		on := (st.on != nil && *st.on) || (st.on == nil && was[id(st)])
		switch {
		case on && was[id(st)]:
			still = append(still, st)
		case on:
			fresh = append(fresh, st)
		}
	}
	sort.SliceStable(fresh, func(i, j int) bool { return fresh[i].mr.Number < fresh[j].mr.Number })
	taken := fresh[:min(limit, len(fresh))]
	now := timeString(s.now())
	ids := []string{}
	for _, st := range append(still, taken...) {
		ids = append(ids, id(st))
	}
	out := []any{}
	root := "pr"
	if strings.HasPrefix(name, "issue.") {
		root = "issue" // issue.assigned (#2034)
	}
	if !first {
		for _, t := range taken {
			out = append(out, map[string]any{"eventId": id(t) + ":" + now, "name": name, "timestamp": now,
				"data": map[string]any{root: t.json, key: now}})
		}
	}
	return map[string]any{"events": out, "cursor": cursor{Since: now, IDs: ids}.encoded(), "truncated": false,
		"hasMore": !first && len(fresh) > len(taken), "nextPollMs": nextPollMs}, nil
}

// candidates finds what an event may raise at or after since.
func candidates(ctx context.Context, gl GitLab, name string, a args, yours *Yours, since string) ([]candidate, Listed, error) {
	project := a.project
	// mine: the owner's own merge request, trusted or not; else the trust filter (#728).
	wanted := func(m MR, trusted bool) bool {
		who := a.anyone || trusted
		if yours != nil {
			who = yours.owns(m.Number)
		}
		return (a.pr == 0 || m.Number == a.pr) && (a.branch == "" || m.Branch == a.branch) && who
	}
	if kind, ok := strings.CutPrefix(name, "issue."); ok {
		items, listed, err := gl.IssueActivity(ctx, project, IssueKind(kind), since)
		if err != nil {
			return nil, Listed{}, err
		}
		var list []candidate
		for _, it := range items {
			if (a.issue != 0 && it.Issue.Number != a.issue) || (!a.anyone && !it.Trusted) ||
				(a.label != "" && !contains(it.Issue.Labels, a.label)) ||
				(a.label != "" && it.Kind == IssueLabelled && it.Label != a.label) {
				continue
			}
			at := normalized(it.At)
			if at == "" {
				continue
			}
			list = append(list, candidate{eventID: name + ":" + project + ":" + it.ID, time: at,
				data: func() (map[string]any, error) { return it.data(), nil }})
		}
		return list, listed, nil
	}
	switch name {
	case "review.comment":
		comments, listed, err := gl.ReviewComments(ctx, project, since)
		if err != nil {
			return nil, Listed{}, err
		}
		var list []candidate
		for _, c := range comments {
			if at := normalized(c.At); at != "" && wanted(c.MR, c.Trusted) {
				list = append(list, candidate{eventID: fmt.Sprintf("review.comment:%s:%d", project, c.ID), time: at,
					data: func() (map[string]any, error) { return c.data(), nil }})
			}
		}
		return list, listed, nil
	case "checks.failed":
		pipelines, listed, err := gl.FailedPipelines(ctx, project, since)
		if err != nil {
			return nil, Listed{}, err
		}
		// A pipeline that names another merge request is skipped before its details are
		// fetched; one that names none is checked against the one its details find. The cursor
		// still moves past both. Its update time is in its id: retried and failed again, it is new.
		var list []candidate
		for _, pl := range pipelines {
			at := normalized(pl.UpdatedAt)
			if at == "" {
				continue
			}
			list = append(list, candidate{eventID: fmt.Sprintf("checks.failed:%s:%d:%s", project, pl.ID, at), time: at,
				data: func() (map[string]any, error) {
					if a.pr != 0 && pl.MRNumber != 0 && pl.MRNumber != a.pr {
						return nil, nil
					}
					details, err := gl.PipelineDetails(ctx, project, pl)
					if err != nil || details == nil {
						return nil, err
					}
					if !wanted(details.MR, details.Trusted) {
						return nil, nil
					}
					return details.json(), nil
				}})
		}
		return list, listed, nil
	}
	merged, closed, listed, err := gl.ClosedMRs(ctx, project, since)
	if err != nil {
		return nil, Listed{}, err
	}
	var list []candidate
	if name == "pr.merged" {
		for _, m := range merged {
			if at := normalized(m.MergedAt); wanted(m.MR, m.Trusted) && at != "" {
				list = append(list, candidate{eventID: fmt.Sprintf("pr.merged:%s:%d", project, m.MR.Number), time: at,
					data: func() (map[string]any, error) {
						return map[string]any{"pr": m.MR.json(), "mergedAt": m.MergedAt, "mergeSha": m.MergeSHA}, nil
					}})
			}
		}
		return list, listed, nil
	}
	// Its close time in the id: a merge request reopened and closed again is a new event.
	for _, c := range closed {
		if at := normalized(c.ClosedAt); wanted(c.MR, c.Trusted) && at != "" {
			list = append(list, candidate{eventID: fmt.Sprintf("pr.closed:%s:%d:%s", project, c.MR.Number, at), time: at,
				data: func() (map[string]any, error) {
					return map[string]any{"pr": c.MR.json(), "closedAt": c.ClosedAt}, nil
				}})
		}
	}
	return list, listed, nil
}

// eventsError is a GitLab failure as the events draft's error codes.
func eventsError(err error) *rpcError {
	var rpc *rpcError
	if errors.As(err, &rpc) {
		return rpc
	}
	var gl *GitLabError
	if !errors.As(err, &gl) {
		return &rpcError{Code: -32603, Message: err.Error()}
	}
	switch gl.Kind {
	case NotSignedIn:
		return &rpcError{Code: -32012, Message: gl.Message, Data: map[string]any{"reason": "not connected"}}
	case RateLimited:
		return &rpcError{Code: -32013, Message: gl.Message, Data: map[string]any{"retryAfterMs": gl.RetryAfterMs}}
	case NotFound:
		return invalidParams("%s: check project", gl.Message)
	}
	return &rpcError{Code: -32603, Message: gl.Message}
}
