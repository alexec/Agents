package githubmcp

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

// The MCP events (#383) of CIWatcher.swift, the same names, arguments, data and eventIds,
// polled only: `events/list` and `events/poll` of the events draft
// (experimental-ext-triggers-events), which the Agents daemon speaks.

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

var (
	repoProperty = property{name: "repo", kind: "string",
		description: "The GitHub repo, owner/name. Left out, the repo this folder pushes to.",
		pattern:     regexp.MustCompile(`^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`), looksLike: "owner/name"}
	prProperty = property{name: "pr", kind: "integer", description: "Only this pull request, by number."}
	// anyoneProperty opts into anyone's issue, comment or PR (#728); left out, only the repo's own people.
	anyoneProperty = property{name: "anyone", kind: "boolean",
		description: "true: from anyone, bots, forks and people outside the repo too. Left out, only the repo's owner, members and collaborators, never a bot, and for a PR never one from a fork."}
	// mineProperty is only the connection's owner's own PRs (#2034), a fork's too.
	mineProperty = property{name: "mine", kind: "boolean",
		description: "true: only pull requests by the GitHub account this server is connected as, whatever anyone says."}
)

// ownPRs is what every PR event says of whose PRs it raises.
const ownPRs = " Only PRs from a branch of the repo itself, not a fork, by the repo's owner, members and collaborators, never a bot, unless anyone is true."

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

// fixesSchema is a PR's fixes: the issues its body closes, "#12" or "owner/repo#12" (#2349).
var fixesSchema = map[string]any{"type": "array", "items": str}

// events are the events this server offers, in CIWatcher's order.
var events = append([]event{
	{name: "checks.failed", title: "Checks failed",
		description: "A pull request's checks finished with a failure: one event per run and attempt, so a rerun that fails again is a new one." + ownPRs,
		input:       schema{repoProperty, branchProperty("Only runs on this PR branch."), prProperty, anyoneProperty, mineProperty},
		payload: object(map[string]any{
			"pr": prSchema(nil), "headSha": str,
			"run":        object(map[string]any{"id": integer, "attempt": integer, "name": str, "url": str}),
			"failedJobs": map[string]any{"type": "array", "items": object(map[string]any{"name": str, "url": str})},
		})},
	{name: "checks.passed", title: "Checks passed",
		description: "A pull request's checks finished with a success: one event per run and attempt, so a lane waiting on CI going green wakes without polling." + ownPRs,
		input:       schema{repoProperty, branchProperty("Only runs on this PR branch."), prProperty, anyoneProperty, mineProperty},
		payload: object(map[string]any{
			"pr": prSchema(nil), "headSha": str,
			"run": object(map[string]any{"id": integer, "attempt": integer, "name": str, "url": str}),
		})},
	{name: "pr.opened", title: "Pull request opened",
		description: "A pull request was opened, or a draft was marked ready for review: a PR open and not a draft now that was not at the last poll. Drafts never count. Reopened, it is raised again." + ownPRs,
		input:       schema{repoProperty, branchProperty("Only the PR from this branch."), prProperty, anyoneProperty},
		payload:     object(map[string]any{"pr": prSchema(map[string]any{"author": str, "fixes": fixesSchema}), "openedAt": str})},
	{name: "pr.merged", title: "Pull request merged", description: "A pull request was merged." + ownPRs,
		input:   schema{repoProperty, branchProperty("Only the PR from this branch."), prProperty, anyoneProperty},
		payload: object(map[string]any{"pr": prSchema(map[string]any{"fixes": fixesSchema}), "mergedAt": str, "mergeSha": str})},
	{name: "pr.closed", title: "Pull request closed", description: "A pull request was closed without being merged." + ownPRs,
		input:   schema{repoProperty, branchProperty("Only the PR from this branch."), prProperty, anyoneProperty},
		payload: object(map[string]any{"pr": prSchema(map[string]any{"fixes": fixesSchema}), "closedAt": str})},
	{name: "pr.conflicted", title: "Pull request in conflict",
		description: "An open pull request began to conflict with its base, so it cannot merge and its CI may not run until it is rebased. Once per conflict: it is raised again only after the PR merges cleanly and then conflicts anew." + ownPRs,
		input:       schema{repoProperty, branchProperty("Only the PR from this branch."), prProperty, anyoneProperty, mineProperty},
		payload:     object(map[string]any{"pr": prSchema(nil), "conflictedAt": str})},
	{name: "pr.commented", title: "Pull request commented on",
		description: "A comment was left on a pull request's conversation (not a review comment on a line of its diff, which review.comment covers). Its body is the first 4000 characters. A comment whose body starts with <!-- agent --> is left out: an agent's, not a person's, since every PR and comment is posted as the same account. Only comments by the repo's owner, members and collaborators, never a bot, unless anyone is true.",
		input:       schema{repoProperty, prProperty, anyoneProperty},
		payload: object(map[string]any{"pr": prSchema(nil),
			"comment": object(map[string]any{"author": str, "url": str, "body": str}), "commentedAt": str})},
	// For the person, not the repo (#2034): what asks the connection's owner for something.
	{name: "review.requested", title: "Review requested from me",
		description: "A review was requested from the GitHub account this server is connected as, on an open pull request: once per request, so a request taken back and made again is a new one. Anyone's PR, a fork's too.",
		input:       schema{repoProperty, prProperty},
		payload:     object(map[string]any{"pr": prSchema(map[string]any{"author": str}), "requestedAt": str})},
	// CodeRabbit's (#1344), known by its GitHub App, not by a name.
	{name: "review.posted", title: "CodeRabbit reviewed",
		description: "CodeRabbit finished a review of a pull request's head commit: its CodeRabbit status on that commit gone to success, or, where it sets no status, a review by its GitHub App on that commit. Once per review: a push it reviews, or a full review asked of the same commit (coderabbit_review with full), is a new one. state is its review's (commented, approved or changes_requested), empty when only its status says so; its comments come as review.comment." + ownPRs,
		input:       schema{repoProperty, branchProperty("Only the PR from this branch."), prProperty, anyoneProperty},
		payload:     object(map[string]any{"pr": prSchema(nil), "headSha": str, "state": str, "url": str, "reviewedAt": str})},
	{name: "review.comment", title: "CodeRabbit commented on a line",
		description: "CodeRabbit left a review comment on a pull request: on a line of its diff, or as an answer in a thread (inReplyTo is the comment it answers). Its body is the first 4000 characters. Answer it with coderabbit_reply and comment.id." + ownPRs,
		input:       schema{repoProperty, branchProperty("Only the PR from this branch."), prProperty, anyoneProperty},
		payload: object(map[string]any{"pr": prSchema(nil), "commentedAt": str,
			"comment": object(map[string]any{"id": integer, "path": str, "line": integer, "inReplyTo": integer, "body": str, "url": str})})},
}, append(prLabelEvents(), append(issueEvents(), assignedEvent)...)...)

// prLabelEvents are pr.labelled and pr.unlabelled: a label added to or removed from a pull
// request, filtered by whatever label fires it, so a workflow can wait on one by name instead
// of polling (#3036).
func prLabelEvents() []event {
	kinds := []struct {
		kind                    PRLabelKind
		title, description, who string
		timeKey                 string
	}{
		{PRLabelled, "Pull request labelled", "A label was added to a pull request: one event per label added.",
			"Only labels added by", "labelledAt"},
		{PRUnlabelled, "Pull request unlabelled", "A label was removed from a pull request: one event per label removed.",
			"Only labels removed by", "unlabelledAt"},
	}
	out := make([]event, len(kinds))
	for i, k := range kinds {
		label := property{name: "label", kind: "string", description: "Only when this label is the one changed."}
		description := k.description + " " + k.who + " the repo's owner, members and collaborators, never a bot, unless anyone is true."
		out[i] = event{name: "pr." + string(k.kind), title: k.title, description: description,
			input:   schema{repoProperty, prProperty, label, anyoneProperty},
			payload: object(map[string]any{"pr": prSchema(nil), "label": str, "by": str, k.timeKey: str})}
	}
	return out
}

// assignedEvent is for the person, not the repo (#2034): an issue given to the connection's owner.
var assignedEvent = event{name: "issue.assigned", title: "Issue assigned to me",
	description: "An open issue was assigned to the GitHub account this server is connected as: once per assignment, so one unassigned and assigned again is a new one. Anyone's issue.",
	input:       schema{repoProperty, property{name: "issue", kind: "integer", description: "Only this issue, by number."}},
	payload: object(map[string]any{"issue": object(map[string]any{
		"number": integer, "title": str, "author": str, "labels": map[string]any{"type": "array", "items": str}, "url": str,
		"assignees": map[string]any{"type": "array", "items": str},
	}), "assignedAt": str})}

func issueEvents() []event {
	issueSchema := object(map[string]any{
		"number": integer, "title": str, "author": str, "labels": map[string]any{"type": "array", "items": str}, "url": str,
		"assignees": map[string]any{"type": "array", "items": str},
	})
	issue := property{name: "issue", kind: "integer", description: "Only this issue, by number."}
	kinds := []struct {
		kind                      IssueKind
		title, description, label string
		payload                   map[string]any
		who                       string
	}{
		{IssueOpened, "Issue opened", "An issue was opened. Pull requests are not issues here.",
			"Only issues opened with this label.", map[string]any{"openedAt": str}, "Only issues opened by"},
		{IssueLabelled, "Issue labelled", "A label was added to an issue: one event per label added.",
			"Only when this label is the one added.", map[string]any{"label": str, "by": str, "labelledAt": str}, "Only labels added by"},
		{IssueCommented, "Issue commented on",
			"A comment was left on an issue (not a pull request). Its body is the first 4000 characters.",
			"Only issues with this label.",
			map[string]any{"comment": object(map[string]any{"author": str, "url": str, "body": str}), "commentedAt": str},
			"Only comments by"},
		{IssueClosed, "Issue closed", "An issue was closed, as completed or not planned.", "Only issues with this label.",
			map[string]any{"reason": map[string]any{"type": "string", "enum": []string{"completed", "not_planned"}}, "by": str, "closedAt": str},
			"Only issues closed by"},
	}
	out := make([]event, len(kinds))
	for i, k := range kinds {
		label := property{name: "label", kind: "string", description: k.label}
		input := schema{repoProperty, label, issue, anyoneProperty}
		if k.kind == IssueOpened {
			input = schema{repoProperty, label, anyoneProperty}
		}
		description := k.description + " " + k.who + " the repo's owner, members and collaborators, never a bot, unless anyone is true."
		if k.kind == IssueClosed {
			description += " Someone outside the repo closing their own issue does not count."
		}
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
// it as an opaque string (base64url of its JSON), as CIWatcher's PollCursor.
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
	// historyDays: a cursor older than this may have missed some, as GitHub keeps no more.
	historyDays = 90
)

type pollParams struct {
	Name      string          `json:"name"`
	Arguments json.RawMessage `json:"arguments"`
	Cursor    json.RawMessage `json:"cursor"`
	MaxEvents *int            `json:"maxEvents"`
}

func (p pollParams) firstPoll() bool { return len(p.Cursor) == 0 || string(p.Cursor) == "null" }

// Events answers events/list and events/poll over a GitHub.
type Events struct {
	GitHub GitHub
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
	if a.repo == "" {
		repo, err := s.GitHub.DefaultRepo(ctx)
		if err != nil {
			var gh *GitHubError
			if errors.As(err, &gh) && gh.Kind == NotFound {
				return nil, invalidParams("%s", gh.Message)
			}
			return nil, eventsError(err)
		}
		a.repo = repo
	}
	// mine: the connection's owner's own open PRs, asked once a poll (#2034).
	var yours *Yours
	if a.mine || e.name == "review.requested" || e.name == "issue.assigned" {
		y, err := s.GitHub.Yours(ctx, a.repo)
		if err != nil {
			return nil, eventsError(err)
		}
		yours = &y
	}
	switch e.name {
	case "review.requested":
		return s.pollDiff(ctx, e.name, "requestedAt", a, p, func() ([]state, error) {
			var out []state
			for _, r := range yours.Reviews {
				j := r.PR.json()
				j["author"] = r.Author
				out = append(out, state{pr: r.PR, on: new(true), json: j})
			}
			return out, nil
		})
	case "issue.assigned":
		return s.pollDiff(ctx, e.name, "assignedAt", a, p, func() ([]state, error) {
			var out []state
			for _, i := range yours.Assigned {
				if a.issue == 0 || i.Number == a.issue {
					out = append(out, state{pr: PR{Number: i.Number, Title: i.Title, URL: i.URL}, on: new(true), json: i.json()})
				}
			}
			return out, nil
		})
	case "pr.conflicted":
		return s.pollDiff(ctx, e.name, "conflictedAt", a, p, func() ([]state, error) {
			prs, err := s.GitHub.ConflictPRs(ctx, a.repo)
			var out []state
			for _, c := range prs {
				if yours != nil {
					if yours.owns(c.PR.Number) {
						out = append(out, state{pr: c.PR, on: c.Conflicts, json: c.PR.json()})
					}
				} else if a.anyone || c.Trusted {
					out = append(out, state{pr: c.PR, on: c.Conflicts, json: c.PR.json()})
				}
			}
			return out, err
		})
	case "pr.opened":
		return s.pollDiff(ctx, e.name, "openedAt", a, p, func() ([]state, error) {
			prs, err := s.GitHub.OpenPRs(ctx, a.repo)
			var out []state
			for _, o := range prs {
				if !a.anyone && !o.Trusted {
					continue
				}
				ready := !o.Draft
				j := o.PR.json()
				j["author"] = o.Author
				out = append(out, state{pr: o.PR, on: &ready, json: j})
			}
			return out, err
		})
	case "review.posted":
		return s.pollDiff(ctx, e.name, "reviewedAt", a, p, func() ([]state, error) {
			prs, err := s.GitHub.CodeRabbitPRs(ctx, a.repo)
			var out []state
			for _, r := range prs {
				if a.anyone || r.Trusted {
					reviewed := r.Reviewed
					out = append(out, state{pr: r.PR, on: &reviewed, key: r.round(),
						json: r.PR.json(), extra: map[string]any{"headSha": r.HeadSHA, "state": r.Review, "url": r.URL}})
				}
			}
			return out, err
		})
	}
	return s.poll(e, p, func(since string) ([]candidate, bool, error) {
		return candidates(ctx, s.GitHub, e.name, a, yours, since)
	})
}

// poll is events/poll over a cursor: the first poll (no cursor) gives none and starts from
// now; later ones give what is new since, oldest first, at most maxEvents, with hasMore and a
// cursor that goes on from the last one taken.
func (s *Events) poll(e event, p pollParams, find func(since string) ([]candidate, bool, error)) (map[string]any, *rpcError) {
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
	found, truncated, err := find(c.Since)
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
	sinceTime, _ := parseTime(c.Since)
	old := sinceTime.Before(now.Add(-historyDays * 24 * time.Hour))
	return map[string]any{"events": out, "cursor": cursor{Since: since, IDs: ids}.encoded(),
		"truncated": truncated || old, "hasMore": len(fresh) > len(taken), "nextPollMs": nextPollMs}, nil
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

// state is a PR and whether its state (in conflict, open and ready, or reviewed) is on now;
// nil keeps the one it had. key, when set, is part of its id: review.posted's head commit and
// review, so each review is raised once. extra is more of the event's data.
type state struct {
	pr    PR
	on    *bool
	key   string
	json  map[string]any
	extra map[string]any
}

// pollDiff raises an event for each PR whose state is on now and was not at the last poll:
// the cursor's ids are the PRs that were on then. A first poll takes those already on as
// known. A conflict has no time on GitHub, only a state, so pr.conflicted diffs it (#712); so
// does pr.opened (#833), so a draft marked ready is raised as it is, and review.posted (#1344),
// by head commit and review, so a review and its status that say the same are raised once.
func (s *Events) pollDiff(_ context.Context, name, key string, a args, p pollParams, states func() ([]state, error)) (map[string]any, *rpcError) {
	first := p.firstPoll()
	c := cursor{}
	if !first {
		var bad *rpcError
		if c, bad = decodeCursor(p.Cursor); bad != nil {
			return nil, bad
		}
	}
	limit := 100
	if !first {
		limit = 50
		if p.MaxEvents != nil {
			limit = *p.MaxEvents
		}
		limit = min(100, max(1, limit))
	}
	prs, err := states()
	if err != nil {
		return nil, eventsError(err)
	}
	was := map[string]bool{}
	for _, id := range c.IDs {
		was[id] = true
	}
	id := func(st state) string {
		if st.key != "" {
			return fmt.Sprintf("%s:%s:%d:%s", name, a.repo, st.pr.Number, st.key)
		}
		return fmt.Sprintf("%s:%s:%d", name, a.repo, st.pr.Number)
	}
	var still, fresh []state
	for _, st := range prs {
		if (a.pr != 0 && st.pr.Number != a.pr) || (a.branch != "" && st.pr.Branch != a.branch) {
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
	sort.SliceStable(fresh, func(i, j int) bool { return fresh[i].pr.Number < fresh[j].pr.Number })
	taken := fresh[:min(limit, len(fresh))]
	now := timeString(s.now())
	ids := []string{}
	for _, st := range append(still, taken...) {
		ids = append(ids, id(st))
	}
	out := []any{}
	if !first {
		for _, t := range taken {
			root := "pr"
			if strings.HasPrefix(name, "issue.") {
				root = "issue" // issue.assigned (#2034)
			}
			data := map[string]any{root: t.json, key: now}
			for k, v := range t.extra {
				data[k] = v
			}
			out = append(out, map[string]any{"eventId": id(t) + ":" + now, "name": name, "timestamp": now, "data": data})
		}
	}
	return map[string]any{"events": out, "cursor": cursor{Since: now, IDs: ids}.encoded(), "truncated": false,
		"hasMore": !first && len(fresh) > len(taken), "nextPollMs": nextPollMs}, nil
}

// candidates finds what an event may raise at or after since.
func candidates(ctx context.Context, gh GitHub, name string, a args, yours *Yours, since string) ([]candidate, bool, error) {
	repo := a.repo
	if kind, ok := strings.CutPrefix(name, "issue."); ok {
		items, truncated, err := gh.IssueActivity(ctx, repo, IssueKind(kind), since)
		if err != nil {
			return nil, false, err
		}
		var list []candidate
		for _, it := range items {
			if a.issue != 0 && it.Issue.Number != a.issue {
				continue
			}
			if !a.anyone && !it.Trusted {
				continue
			}
			if a.label != "" {
				if it.Kind == IssueLabelled && it.Label != a.label {
					continue
				}
				if it.Kind != IssueLabelled && !contains(it.Issue.Labels, a.label) {
					continue
				}
			}
			at := normalized(it.At)
			if at == "" {
				continue
			}
			list = append(list, candidate{eventID: name + ":" + repo + ":" + it.ID, time: at,
				data: func() (map[string]any, error) { return it.data(), nil }})
		}
		return list, truncated, nil
	}
	if name == "pr.labelled" || name == "pr.unlabelled" {
		kind := PRLabelled
		if name == "pr.unlabelled" {
			kind = PRUnlabelled
		}
		items, truncated, err := gh.PRLabelActivity(ctx, repo, kind, since)
		if err != nil {
			return nil, false, err
		}
		var list []candidate
		for _, it := range items {
			if a.pr != 0 && it.PR.Number != a.pr {
				continue
			}
			if !a.anyone && !it.Trusted {
				continue
			}
			if a.label != "" && it.Label != a.label {
				continue
			}
			at := normalized(it.At)
			if at == "" {
				continue
			}
			list = append(list, candidate{eventID: name + ":" + repo + ":" + it.ID, time: at,
				data: func() (map[string]any, error) { return it.data(), nil }})
		}
		return list, truncated, nil
	}
	if name == "review.comment" {
		comments, truncated, err := gh.CodeRabbitComments(ctx, repo, since)
		if err != nil {
			return nil, false, err
		}
		var list []candidate
		for _, c := range comments {
			at := normalized(c.At)
			if at == "" || (a.pr != 0 && c.PR.Number != a.pr) || (a.branch != "" && c.PR.Branch != a.branch) || !(a.anyone || c.Trusted) {
				continue
			}
			list = append(list, candidate{eventID: fmt.Sprintf("review.comment:%s:%d", repo, c.ID), time: at,
				data: func() (map[string]any, error) { return c.data(), nil }})
		}
		return list, truncated, nil
	}
	if name == "pr.commented" {
		comments, truncated, err := gh.PRComments(ctx, repo, since, a.pr)
		if err != nil {
			return nil, false, err
		}
		// Every comment is a candidate, so the cursor moves past the ones left out (P20261031-1).
		var list []candidate
		for _, c := range comments {
			at := normalized(c.At)
			if at == "" {
				continue
			}
			list = append(list, candidate{eventID: fmt.Sprintf("pr.commented:%s:%d", repo, c.ID), time: at,
				data: func() (map[string]any, error) {
					if c.Other || (a.pr != 0 && c.PR.Number != a.pr) || !(a.anyone || c.Trusted) {
						return nil, nil
					}
					return c.data(), nil
				}})
		}
		return list, truncated, nil
	}
	if name == "checks.failed" {
		return checkRunCandidates(ctx, gh, name, a, yours, since, gh.FailedRuns, RunData.json)
	}
	if name == "checks.passed" {
		return checkRunCandidates(ctx, gh, name, a, yours, since, gh.PassedRuns, RunData.passedJSON)
	}
	merged, closed, truncated, err := gh.ClosedPRs(ctx, repo, since)
	if err != nil {
		return nil, false, err
	}
	wanted := func(p PR, trusted bool) bool {
		return (a.pr == 0 || p.Number == a.pr) && (a.branch == "" || p.Branch == a.branch) && (a.anyone || trusted)
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
		return list, truncated, nil
	}
	// Its close time in the id: a PR reopened and closed again is a new event.
	for _, c := range closed {
		if at := normalized(c.ClosedAt); wanted(c.PR, c.Trusted) && at != "" {
			list = append(list, candidate{eventID: fmt.Sprintf("pr.closed:%s:%d:%s", repo, c.PR.Number, c.ClosedAt), time: at,
				data: func() (map[string]any, error) {
					return map[string]any{"pr": c.PR.json(), "closedAt": c.ClosedAt}, nil
				}})
		}
	}
	return list, truncated, nil
}

// checkRunCandidates is checks.failed's and checks.passed's candidates: listRuns finds the
// finished runs, toJSON shapes each one's data (RunData.json keeps failedJobs, .passedJSON
// drops it). A run that names another PR is skipped before its details are fetched; one that
// names none is checked against the PR its details find. The cursor still moves past both.
func checkRunCandidates(ctx context.Context, gh GitHub, name string, a args, yours *Yours, since string,
	listRuns func(ctx context.Context, repo, branch, since string) ([]RunRef, bool, error),
	toJSON func(RunData) map[string]any,
) ([]candidate, bool, error) {
	repo := a.repo
	runs, truncated, err := listRuns(ctx, repo, a.branch, since)
	if err != nil {
		return nil, false, err
	}
	var list []candidate
	for _, ref := range runs {
		at := normalized(ref.UpdatedAt)
		if at == "" {
			continue
		}
		list = append(list, candidate{eventID: fmt.Sprintf("%s:%s:%d:%d", name, repo, ref.ID, ref.Attempt), time: at,
			data: func() (map[string]any, error) {
				if (a.pr != 0 && ref.PRNumber != 0 && ref.PRNumber != a.pr) || (yours != nil && ref.PRNumber != 0 && !yours.owns(ref.PRNumber)) {
					return nil, nil
				}
				details, err := gh.RunDetails(ctx, repo, ref)
				if err != nil || details == nil {
					return nil, err
				}
				if a.pr != 0 && details.PR.Number != a.pr {
					return nil, nil
				}
				// mine: the owner's own PR, trusted or not; else the trust filter (#728).
				if yours != nil && !yours.owns(details.PR.Number) || yours == nil && !a.anyone && !details.Trusted {
					return nil, nil
				}
				return toJSON(*details), nil
			}})
	}
	return list, truncated, nil
}

// eventsError is a GitHub failure as the events draft's error codes.
func eventsError(err error) *rpcError {
	var rpc *rpcError
	if errors.As(err, &rpc) {
		return rpc
	}
	var gh *GitHubError
	if !errors.As(err, &gh) {
		return &rpcError{Code: -32603, Message: err.Error()}
	}
	switch gh.Kind {
	case NotSignedIn:
		return &rpcError{Code: -32012, Message: gh.Message, Data: map[string]any{"reason": "not connected"}}
	case RateLimited:
		return &rpcError{Code: -32013, Message: gh.Message, Data: map[string]any{"retryAfterMs": gh.RetryAfterMs}}
	case NotFound:
		return invalidParams("%s: check repo", gh.Message)
	}
	return &rpcError{Code: -32603, Message: gh.Message}
}
