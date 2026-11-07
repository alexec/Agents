package azuredevopsmcp

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

// The MCP events (#2829) of an Azure DevOps repository's pull requests and their Azure
// Pipelines builds, in the gitlab server's shape (Go/internal/gitlabmcp/events.go): the same
// names where they mean the same, and the same cursor, paging and trust filter (#728), polled
// only: `events/list` and `events/poll` of the events draft (experimental-ext-triggers-events),
// which the Agents daemon speaks. Work items are not here: they are the tracker's, as Linear's
// and Jira's issues are.

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

// repoPattern is a repository's organization/project/name. A project's name may have spaces.
var repoPattern = regexp.MustCompile(`^[^/\s][^/]*/[^/\s][^/]*/[^/\s][^/]*$`)

var (
	repoProperty = property{name: "repo", kind: "string",
		description: "The repository on Azure DevOps, as organization/project/name (collection/project/name on Azure DevOps Server). Left out, the repository this folder pushes to.",
		pattern:     repoPattern, looksLike: "organization/project/name"}
	prProperty = property{name: "pr", kind: "integer", description: "Only this pull request, by number."}
	// anyoneProperty opts into anyone's comment or pull request (#728); left out, only the project's own people.
	anyoneProperty = property{name: "anyone", kind: "boolean",
		description: "true: from anyone, bots and forks too. Left out, never a bot (a build service) and for a pull request never one from a fork. Only a project's members can write to it on Azure DevOps."}
	// mineProperty is only the token's owner's own pull requests (#2034), a fork's too.
	mineProperty = property{name: "mine", kind: "boolean",
		description: "true: only pull requests by the Azure DevOps account whose token this server has, whatever anyone says."}
)

// ownPRs is what every pull request event says of whose pull requests it raises.
const ownPRs = " Only pull requests from a branch of the repository itself, not a fork, and never by a bot, unless anyone is true."

func branchProperty(description string) property {
	return property{name: "branch", kind: "string", description: description}
}

func object(props map[string]any) map[string]any {
	return map[string]any{"type": "object", "properties": props}
}

var str, integer = map[string]any{"type": "string"}, map[string]any{"type": "integer"}

func prSchema(extra map[string]any) map[string]any {
	props := map[string]any{"number": integer, "title": str, "branch": str, "url": str}
	for k, v := range extra {
		props[k] = v
	}
	return object(props)
}

func prInput() schema {
	return schema{repoProperty, branchProperty("Only the pull request from this branch."), prProperty, anyoneProperty}
}

// fixesSchema is a pull request's fixes: the work items its description closes, "#12" (#2349).
var fixesSchema = map[string]any{"type": "array", "items": str}

// events are the events this server offers, in the gitlab server's order, and checks.passed
// and run.completed as the github server's (#3805, #3810); the gitlab server's issue events
// are the tracker's here.
var events = []event{
	{name: "checks.failed", title: "Checks failed",
		description: "An open pull request's checks failed at its head commit: an Azure Pipelines build of it (its build validation, or any pipeline it triggers), a build of its branch at that commit (a CI trigger's), or the newest status that another service set on it (failed or error). One event per commit and failure time, so a build run again that fails again is a new one. failedJobs are the failed builds and statuses; run is the first failed build (get_build_log reads its failed steps), or the first failed status with id 0 when no build failed." + ownPRs,
		input:       schema{repoProperty, branchProperty("Only checks of the pull request from this branch."), prProperty, anyoneProperty, mineProperty},
		payload: object(map[string]any{
			"pr": prSchema(nil), "headSha": str,
			"run":        object(map[string]any{"id": integer, "name": str, "url": str}),
			"failedJobs": map[string]any{"type": "array", "items": object(map[string]any{"name": str, "url": str})},
		})},
	{name: "checks.passed", title: "Checks passed",
		description: "One of an open pull request's checks passed at its head commit: an Azure Pipelines build of it or of its branch at that commit, or the newest status of one context that another service set on it. One event per build or status, so a lane waiting on CI going green wakes without polling. run is the build (id 0 for a status)." + ownPRs,
		input:       schema{repoProperty, branchProperty("Only checks of the pull request from this branch."), prProperty, anyoneProperty, mineProperty},
		payload: object(map[string]any{
			"pr": prSchema(nil), "headSha": str,
			"run": object(map[string]any{"id": integer, "name": str, "url": str}),
		})},
	// A build no pull request owns, as main's or a tag's, as the github server's (#3444, #3810).
	{name: "run.completed", title: "Pipeline build finished",
		description: "An Azure Pipelines build of the repository finished, whatever started it (a push, a tag, a person, a schedule) and whatever its result (succeeded, failed, canceled, partiallySucceeded): one event per build and finish time, so a build run again is a new one. For a build no pull request owns, such as main's or a tag's release; a pull request's own builds are checks.failed and checks.passed. run.name is its pipeline's name, run.number its build number, run.event what started it (manual, individualCI, batchedCI, schedule, pullRequest…). Only builds asked for by a person, never a bot (a build service), and never a fork's pull request's, unless anyone is true.",
		input: schema{repoProperty,
			property{name: "pipeline", kind: "string", description: "Only builds of this pipeline, by its name, as release."},
			branchProperty("Only builds of this branch or tag, as main or v0.16.0."),
			property{name: "run", kind: "integer", description: "Only this build, by its id."}, anyoneProperty},
		payload: object(map[string]any{
			"run": object(map[string]any{"id": integer, "name": str, "number": str, "event": str, "branch": str, "headSha": str,
				"url": str, "conclusion": str, "actor": str}),
			"completedAt": str,
		})},
	{name: "pr.opened", title: "Pull request opened",
		description: "A pull request was opened, or a draft was published: a pull request active and not a draft now that was not at the last poll. Drafts never count. Reactivated, it is raised again." + ownPRs,
		input:       prInput(),
		payload:     object(map[string]any{"pr": prSchema(map[string]any{"author": str, "fixes": fixesSchema}), "openedAt": str})},
	{name: "pr.merged", title: "Pull request merged", description: "A pull request was completed: merged into its target." + ownPRs,
		input:   prInput(),
		payload: object(map[string]any{"pr": prSchema(map[string]any{"fixes": fixesSchema}), "mergedAt": str, "mergeSha": str})},
	{name: "pr.closed", title: "Pull request closed", description: "A pull request was abandoned: closed without being merged." + ownPRs,
		input:   prInput(),
		payload: object(map[string]any{"pr": prSchema(map[string]any{"fixes": fixesSchema}), "closedAt": str})},
	{name: "pr.conflicted", title: "Pull request in conflict",
		description: "An active pull request began to conflict with its target branch, so it cannot merge until it is rebased. Once per conflict: it is raised again only after it merges cleanly and then conflicts anew." + ownPRs,
		input:       append(prInput(), mineProperty),
		payload:     object(map[string]any{"pr": prSchema(nil), "conflictedAt": str})},
	// For the person, not the repository (#2034): what asks the token's owner for something.
	{name: "review.requested", title: "Review requested from me",
		description: "The Azure DevOps account whose token this server has was added as a reviewer of an active pull request and has not voted: once per request, so a vote reset by a new push is a new one. Anyone's pull request, a fork's too.",
		input:       schema{repoProperty, prProperty},
		payload:     object(map[string]any{"pr": prSchema(map[string]any{"author": str}), "requestedAt": str})},
	{name: "review.comment", title: "Pull request line commented on",
		description: "Someone left a comment on a line of a pull request's diff, or answered in its thread. Its body is the first 4000 characters; comment.threadId is the thread to answer in with reply_to_pull_request_comment. The 50 newest active pull requests are read, and those closed since. Never a bot's comment, unless anyone is true; and only on the repository's own pull requests.",
		input:       prInput(),
		payload: object(map[string]any{"pr": prSchema(nil), "commentedAt": str,
			"comment": object(map[string]any{"id": integer, "threadId": integer, "author": str, "path": str, "line": integer, "body": str, "url": str})})},
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

// Events answers events/list and events/poll over an Azure DevOps.
type Events struct {
	AzureDevOps AzureDevOps
	Now         func() time.Time
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
	if a.repo == "" {
		repo, err := s.AzureDevOps.DefaultRepo(ctx)
		if err != nil {
			var ae *AzureDevOpsError
			if errors.As(err, &ae) && ae.Kind == NotFound {
				return nil, invalidParams("%s", ae.Message)
			}
			return nil, eventsError(err)
		}
		a.repo = repo
	}
	// mine: the token's owner's own open pull requests, asked once a poll (#2034).
	var yours *Yours
	if a.mine || e.name == "review.requested" {
		y, err := s.AzureDevOps.Yours(ctx, a.repo)
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
				j := r.PR.json()
				j["author"] = r.Author
				out = append(out, state{mr: r.PR, on: new(true), json: j})
			}
			return out, nil
		})
	case "pr.conflicted":
		return s.pollDiff(e.name, "conflictedAt", a, p, func() ([]state, error) {
			prs, err := s.AzureDevOps.OpenPRs(ctx, a.repo)
			var out []state
			for _, m := range prs {
				if yours != nil {
					if yours.owns(m.PR.Number) {
						out = append(out, state{mr: m.PR, on: m.Conflicts, json: m.PR.json()})
					}
				} else if a.anyone || m.Trusted {
					out = append(out, state{mr: m.PR, on: m.Conflicts, json: m.PR.json()})
				}
			}
			return out, err
		})
	case "pr.opened":
		return s.pollDiff(e.name, "openedAt", a, p, func() ([]state, error) {
			prs, err := s.AzureDevOps.OpenPRs(ctx, a.repo)
			var out []state
			for _, m := range prs {
				if !a.anyone && !m.Trusted {
					continue
				}
				ready := !m.Draft
				j := m.PR.json()
				j["author"] = m.Author
				out = append(out, state{mr: m.PR, on: &ready, json: j})
			}
			return out, err
		})
	}
	return s.poll(e, p, func(since string) ([]candidate, Listed, error) {
		return candidates(ctx, s.AzureDevOps, e.name, a, yours, since)
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
		// From the start of this second: a thing made in it would otherwise be older than the
		// cursor when a listing gives times to the second.
		return map[string]any{"events": []any{}, "cursor": cursor{Since: timeString(s.now().Truncate(time.Second))}.encoded(),
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

// state is a pull request and whether its state (in conflict, or open and ready) is on now;
// nil keeps the one it had.
type state struct {
	mr   PR
	on   *bool
	json map[string]any
}

// pollDiff raises an event for each pull request whose state is on now and was not at the
// last poll: the cursor's ids are the pull requests that were on then. A first poll takes
// those already on as known. A conflict has no time on Azure DevOps, only a state, so pr.conflicted
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
	prs, err := states()
	if err != nil {
		return nil, eventsError(err)
	}
	was := map[string]bool{}
	for _, id := range c.IDs {
		was[id] = true
	}
	id := func(st state) string { return fmt.Sprintf("%s:%s:%d", name, a.repo, st.mr.Number) }
	var still, fresh []state
	for _, st := range prs {
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
	if !first {
		for _, t := range taken {
			out = append(out, map[string]any{"eventId": id(t) + ":" + now, "name": name, "timestamp": now,
				"data": map[string]any{"pr": t.json, key: now}})
		}
	}
	return map[string]any{"events": out, "cursor": cursor{Since: now, IDs: ids}.encoded(), "truncated": false,
		"hasMore": !first && len(fresh) > len(taken), "nextPollMs": nextPollMs}, nil
}

// candidates finds what an event may raise at or after since.
func candidates(ctx context.Context, f AzureDevOps, name string, a args, yours *Yours, since string) ([]candidate, Listed, error) {
	repo := a.repo
	// mine: the owner's own pull request, trusted or not; else the trust filter (#728).
	wanted := func(m PR, trusted bool) bool {
		who := a.anyone || trusted
		if yours != nil {
			who = yours.owns(m.Number)
		}
		return (a.pr == 0 || m.Number == a.pr) && (a.branch == "" || m.Branch == a.branch) && who
	}
	switch name {
	case "run.completed":
		builds, listed, err := f.CompletedBuilds(ctx, repo, a.pipeline, a.branch, a.run, since)
		if err != nil {
			return nil, Listed{}, err
		}
		// Its finish time in the id: a build run again (its failed jobs) is a new event.
		var list []candidate
		for _, b := range builds {
			if b.At != "" && (a.anyone || b.Trusted) {
				list = append(list, candidate{eventID: fmt.Sprintf("run.completed:%s:%d:%s", repo, b.ID, b.At), time: b.At,
					data: func() (map[string]any, error) { return b.data(), nil }})
			}
		}
		return list, listed, nil
	case "review.comment":
		comments, listed, err := f.ReviewComments(ctx, repo, since)
		if err != nil {
			return nil, Listed{}, err
		}
		var list []candidate
		for _, c := range comments {
			if at := normalized(c.At); at != "" && wanted(c.PR, c.Trusted) {
				list = append(list, candidate{eventID: fmt.Sprintf("review.comment:%s:%d:%d:%d", repo, c.PR.Number, c.ThreadID, c.ID), time: at,
					data: func() (map[string]any, error) { return c.data(), nil }})
			}
		}
		return list, listed, nil
	case "checks.failed":
		failed, listed, err := f.FailedChecks(ctx, repo, since)
		if err != nil {
			return nil, Listed{}, err
		}
		// The newest failed build's time is in its id: run again and failed again, it is new.
		var list []candidate
		for _, d := range failed {
			if at := normalized(d.At); at != "" && wanted(d.PR, d.Trusted) {
				list = append(list, candidate{eventID: fmt.Sprintf("checks.failed:%s:%s:%s", repo, d.HeadSHA, at), time: at,
					data: func() (map[string]any, error) { return d.json(), nil }})
			}
		}
		return list, listed, nil
	case "checks.passed":
		passed, listed, err := f.PassedChecks(ctx, repo, since)
		if err != nil {
			return nil, Listed{}, err
		}
		// One a build or a status, at its time: a build run again that passes again is a new one.
		var list []candidate
		for _, d := range passed {
			if at := normalized(d.At); at != "" && wanted(d.PR, d.Trusted) {
				list = append(list, candidate{eventID: fmt.Sprintf("checks.passed:%s:%s:%s:%s", repo, d.HeadSHA, d.Key, at), time: at,
					data: func() (map[string]any, error) { return d.json(), nil }})
			}
		}
		return list, listed, nil
	}
	merged, closed, listed, err := f.ClosedPRs(ctx, repo, since)
	if err != nil {
		return nil, Listed{}, err
	}
	var list []candidate
	if name == "pr.merged" {
		for _, m := range merged {
			if at := normalized(m.MergedAt); wanted(m.PR, m.Trusted) && at != "" {
				list = append(list, candidate{eventID: fmt.Sprintf("pr.merged:%s:%d", repo, m.PR.Number), time: at,
					data: func() (map[string]any, error) {
						return map[string]any{"pr": m.PR.json(), "mergedAt": m.MergedAt, "mergeSha": m.MergeSHA}, nil
					}})
			}
		}
		return list, listed, nil
	}
	// Its close time in the id: a pull request reopened and closed again is a new event.
	for _, c := range closed {
		if at := normalized(c.ClosedAt); wanted(c.PR, c.Trusted) && at != "" {
			list = append(list, candidate{eventID: fmt.Sprintf("pr.closed:%s:%d:%s", repo, c.PR.Number, at), time: at,
				data: func() (map[string]any, error) {
					return map[string]any{"pr": c.PR.json(), "closedAt": c.ClosedAt}, nil
				}})
		}
	}
	return list, listed, nil
}

// eventsError is an Azure DevOps failure as the events draft's error codes.
func eventsError(err error) *rpcError {
	var rpc *rpcError
	if errors.As(err, &rpc) {
		return rpc
	}
	var fe *AzureDevOpsError
	if !errors.As(err, &fe) {
		return &rpcError{Code: -32603, Message: err.Error()}
	}
	switch fe.Kind {
	case NotSignedIn:
		return &rpcError{Code: -32012, Message: fe.Message, Data: map[string]any{"reason": "not connected"}}
	case RateLimited:
		return &rpcError{Code: -32013, Message: fe.Message, Data: map[string]any{"retryAfterMs": fe.RetryAfterMs}}
	case NotFound:
		return invalidParams("%s: check repo", fe.Message)
	}
	return &rpcError{Code: -32603, Message: fe.Message}
}
