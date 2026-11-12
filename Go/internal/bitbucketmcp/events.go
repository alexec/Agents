package bitbucketmcp

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"slices"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/mcpevents"
	"github.com/alexec/agents/Go/wire"
)

// The MCP events (#2828) of a Bitbucket Cloud repository's pull requests, their checks and its
// issues, in the gitlab server's shape (Go/internal/gitlabmcp/events.go): the same names where
// they mean the same, and the same cursor, paging and trust filter (#728), polled only:
// `events/list` and `events/poll` of the events draft (experimental-ext-triggers-events), which
// the Agents daemon speaks.

// event is one event as events/list gives it.
type event = mcpevents.Event

// repoPattern is a repository's workspace/name.
var repoPattern = regexp.MustCompile(`^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`)

var (
	repoProperty = property{Name: "repo", Kind: "string",
		Description: "The repository on Bitbucket, as workspace/name. Left out, the repository this folder pushes to.",
		Pattern:     repoPattern, LooksLike: "workspace/name"}
	prProperty = property{Name: "pr", Kind: "integer", Description: "Only this pull request, by number."}
	// anyoneProperty opts into anyone's issue, comment or pull request (#728); left out, only the repository's own people.
	anyoneProperty = property{Name: "anyone", Kind: "boolean",
		Description: "true: from anyone, bots, forks and people outside the repository too. Left out, only people with write access to it or more, never an app or a bot, and for a pull request never one from a fork."}
	// mineProperty is only the token's owner's own pull requests (#2034), a fork's too.
	mineProperty = property{Name: "mine", Kind: "boolean",
		Description: "true: only pull requests by the Bitbucket account whose token this server has, whatever anyone says."}
	// anyProperty is every one in the repository (#3797): a wait that names none sets it.
	anyProperty = property{Name: "any", Kind: "boolean",
		Description: "true: every one in the repository. A wait (not a workflow trigger) that names none, by the other arguments that say which, is refused without it. It is about which ones; anyone is about who."}
	// fixesProperty is the pull requests that close these issues (#3797): a lead knows a child's issue before its pull request.
	fixesProperty = property{Name: "fixes", Kind: "refs",
		Description: `Only pull requests whose description closes one of these issues, as "#12" (this repository's) or "workspace/name#12".`,
		Pattern:     issueRefPattern, LooksLike: `issues, as "#12" or "workspace/name#12"`}
)

// ownPRs is what every pull request event says of whose pull requests it raises.
const ownPRs = " Only pull requests from a branch of the repository itself, not a fork, by people with write access to it or more, never an app or a bot, unless anyone is true."

func branchProperty(description string) property {
	return property{Name: "branch", Kind: "string", Description: description}
}

func object(props map[string]any) map[string]any {
	return map[string]any{"type": "object", "properties": props}
}

var str, integer = map[string]any{"type": "string"}, map[string]any{"type": "integer"}

func prSchema(extra map[string]any) map[string]any {
	props := map[string]any{"number": integer, "title": str, "branch": str, "url": str, "fixes": fixesSchema}
	for k, v := range extra {
		props[k] = v
	}
	return object(props)
}

func prInput() schema {
	return schema{repoProperty, branchProperty("Only the pull request from this branch."), prProperty, anyoneProperty}
}

// namedInput is prInput for an event about one pull request: it names it by fixes or mine
// too, or takes any (#3797).
func namedInput() schema {
	return schema{repoProperty, branchProperty("Only the pull request from this branch."), prProperty, fixesProperty,
		anyoneProperty, mineProperty, anyProperty}
}

// fixesSchema is a pull request's fixes: the issues its description closes, "#12" or
// "workspace/name#12" (#2349).
var fixesSchema = map[string]any{"type": "array", "items": str}

// events are the events this server offers, in the gitlab server's order, with run.completed
// after checks.failed as there (#4217).
var events = append([]event{
	{Name: "checks.failed", Title: "Checks failed",
		Description: "An open pull request's head commit failed its checks: one of its commit statuses (Bitbucket Pipelines or any CI that sets one) is FAILED. One event per commit and failure, so a check run again that fails again is a new one. failedJobs are the failed statuses; run is the Pipelines run the first one links to, by its build number (id 0 for another CI)." + ownPRs,
		Input:       schema{repoProperty, branchProperty("Only checks of the pull request from this branch."), prProperty, fixesProperty, anyoneProperty, mineProperty, anyProperty},
		Payload: object(map[string]any{
			"pr": prSchema(nil), "headSha": str,
			"run":        object(map[string]any{"id": integer, "name": str, "url": str}),
			"failedJobs": map[string]any{"type": "array", "items": object(map[string]any{"name": str, "url": str})},
		})},
	// A run no pull request owns, as main's or a tag's, as the github server's (#3810, #4217).
	{Name: "run.completed", Title: "Pipeline finished",
		Description: "A Bitbucket Pipelines run of the repository finished, whatever started it (a push, a tag, a person, a schedule) and whatever its result (successful, failed, error, stopped, expired): one event per run and finish time, so a run again is a new one. For a run no pull request owns, such as main's or a tag's release, or a custom pipeline run by hand; a pull request's failed checks are checks.failed. run.id is its build number (failed_log and retry_pipeline take it), run.name the pipeline it ran (a custom pipeline's name, a branch or tag pattern, or default), run.event its trigger (push, manual, schedule). Only runs started by a person with write access, never an app or a bot, unless anyone is true. deploys is what it deployed: each of its steps with deployment: that deployed, as bitbucket:<workspace/name>/<environment>/<build number>. Bitbucket has no API for a deploy that waits, so there is no deploy.waiting here.",
		Input: schema{repoProperty,
			property{Name: "pipeline", Kind: "string", Description: "Only runs of this pipeline, as a custom pipeline's name (release) or a branch pattern (main)."},
			branchProperty("Only runs of this branch or tag, as main or v0.16.0."),
			property{Name: "run", Kind: "integer", Description: "Only this run, by its build number."}, anyoneProperty, anyProperty},
		Payload: object(map[string]any{
			"run": object(map[string]any{"id": integer, "name": str, "number": integer, "event": str, "branch": str, "headSha": str,
				"url": str, "conclusion": str, "actor": str}),
			"completedAt": str,
			// What the run deployed: its successful deployments (#4217).
			"deploys": map[string]any{"type": "array", "items": str},
		})},
	{Name: "pr.opened", Title: "Pull request opened",
		Description: "A pull request was opened, or a draft was marked ready: a pull request open and not a draft now that was not at the last poll. Drafts never count. Reopened, it is raised again." + ownPRs,
		Input:       prInput(),
		Payload:     object(map[string]any{"pr": prSchema(map[string]any{"author": str}), "openedAt": str})},
	{Name: "pr.merged", Title: "Pull request merged", Description: "A pull request was merged." + ownPRs,
		Input:   namedInput(),
		Payload: object(map[string]any{"pr": prSchema(nil), "mergedAt": str, "mergeSha": str})},
	{Name: "pr.closed", Title: "Pull request closed", Description: "A pull request was declined: closed without being merged." + ownPRs,
		Input:   namedInput(),
		Payload: object(map[string]any{"pr": prSchema(nil), "closedAt": str})},
	{Name: "pr.conflicted", Title: "Pull request in conflict",
		Description: "An open pull request began to conflict with its base branch, so it cannot merge until it is rebased: a file in its diff is in conflict. Once per conflict: it is raised again only after it merges cleanly and then conflicts anew." + ownPRs,
		Input:       namedInput(),
		Payload:     object(map[string]any{"pr": prSchema(nil), "conflictedAt": str})},
	// For the person, not the repository (#2034): what asks the token's owner for something.
	{Name: "review.requested", Title: "Review requested from me",
		Description: "The Bitbucket account whose token this server has was asked to review an open pull request: once per request, so one taken off and put back is a new one. Anyone's pull request, a fork's too.",
		Input:       schema{repoProperty, prProperty},
		Payload:     object(map[string]any{"pr": prSchema(map[string]any{"author": str}), "requestedAt": str})},
	{Name: "review.comment", Title: "Pull request line commented on",
		Description: "Someone left a comment on a line of a pull request's diff in a review, or answered in its thread. Its body is the first 4000 characters. Only comments by people with write access to the repository or more, never an app or a bot, unless anyone is true; and only on the repository's own pull requests.",
		Input:       namedInput(),
		Payload: object(map[string]any{"pr": prSchema(nil), "commentedAt": str,
			"comment": object(map[string]any{"id": integer, "author": str, "path": str, "line": integer, "body": str, "url": str})})},
}, append(issueEvents(), assignedEvent)...)

// assignedEvent is for the person, not the repository (#2034): an issue given to the token's owner.
var assignedEvent = event{Name: "issue.assigned", Title: "Issue assigned to me",
	Description: "An open issue was assigned to the Bitbucket account whose token this server has: once per assignment, so one unassigned and assigned again is a new one. Anyone's issue.",
	Input:       schema{repoProperty, property{Name: "issue", Kind: "integer", Description: "Only this issue, by number."}},
	Payload: object(map[string]any{"issue": object(map[string]any{
		"number": integer, "title": str, "author": str, "labels": map[string]any{"type": "array", "items": str}, "url": str,
		"assignees": map[string]any{"type": "array", "items": str},
	}), "assignedAt": str})}

func issueEvents() []event {
	issueSchema := object(map[string]any{
		"number": integer, "title": str, "author": str, "labels": map[string]any{"type": "array", "items": str}, "url": str,
		"assignees": map[string]any{"type": "array", "items": str},
	})
	issue := property{Name: "issue", Kind: "integers", Description: "Only this issue, or these, by number."}
	kinds := []struct {
		kind                      IssueKind
		title, description, label string
		payload                   map[string]any
		who                       string
	}{
		{IssueOpened, "Issue opened", "An issue was opened.",
			"Only issues opened with this label.", map[string]any{"openedAt": str}, "Only issues opened by"},
		{IssueLabelled, "Issue labelled", "A label was added to an issue: Bitbucket's issues have no labels, so their kind (bug, enhancement, proposal, task) and component are the labels, and one set to a new value is a label added.",
			"Only when this label is the one added.", map[string]any{"label": str, "by": str, "labelledAt": str}, "Only labels added by"},
		{IssueCommented, "Issue commented on",
			"A comment was left on an issue. Its body is the first 4000 characters. A change with no words (a state or a kind set) is not a comment, nor is a comment on a pull request.",
			"Only issues with this label.",
			map[string]any{"comment": object(map[string]any{"author": str, "url": str, "body": str}), "commentedAt": str},
			"Only comments by"},
		{IssueClosed, "Issue closed", "An issue was closed. Reopened and closed again, it is a new event.", "Only issues with this label.",
			map[string]any{"by": str, "closedAt": str}, "Only issues closed by"},
	}
	out := make([]event, len(kinds))
	for i, k := range kinds {
		label := property{Name: "label", Kind: "string", Description: k.label}
		input := schema{repoProperty, label, issue, anyoneProperty, anyProperty}
		if k.kind == IssueOpened {
			input = schema{repoProperty, label, anyoneProperty}
		}
		description := k.description + " " + k.who + " people with write access to the repository or more, never an app or a bot, unless anyone is true."
		payload := map[string]any{"issue": issueSchema}
		for name, v := range k.payload {
			payload[name] = v
		}
		out[i] = event{Name: "issue." + string(k.kind), Title: k.title, Description: description, Input: input, Payload: object(payload)}
	}
	return out
}

func eventNamed(name string) (event, bool) { return mcpevents.Named(events, name) }

// EventNames is the events it declares, by name, in events/list's order.
func EventNames() []string { return mcpevents.Names(events) }

// eventsList is events/list's answer.
func eventsList() map[string]any { return mcpevents.List(events) }

// MARK: Polling

// candidate is something that may be raised: its id, its time (in mcpevents.TimeLayout), and its data,
// looked up only once it is taken; nil data skips it, though the cursor still moves past it.
type candidate = mcpevents.Candidate

const (
	maxEvents  = mcpevents.MaxEvents
	nextPollMs = 30000
)

type pollParams = mcpevents.Params

// polls is how it polls, with Bitbucket's times and errors.
var polls = mcpevents.Poller{NextPollMs: nextPollMs, Normalize: mcpevents.Normalized, Fail: eventsError}

// Events answers events/list and events/poll over Bitbucket.
type Events struct {
	Bitbucket Bitbucket
	Now       func() time.Time
}

func (s *Events) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

// Poll answers events/poll's params.
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
	if a.repo == "" {
		repo, err := s.Bitbucket.DefaultRepo(ctx)
		if err != nil {
			var fe *BitbucketError
			if errors.As(err, &fe) && fe.Kind == NotFound {
				return nil, invalidParams("%s", fe.Message)
			}
			return nil, eventsError(err)
		}
		a.repo = repo
	}
	// mine: the token's owner's own open pull requests, asked once a poll (#2034).
	var yours *Yours
	if a.mine || e.Name == "review.requested" || e.Name == "issue.assigned" {
		y, err := s.Bitbucket.Yours(ctx, a.repo)
		if err != nil {
			return nil, eventsError(err)
		}
		yours = &y
	}
	switch e.Name {
	case "review.requested":
		return s.pollDiff(e.Name, "requestedAt", a, p, func() ([]state, error) {
			var out []state
			for _, r := range yours.Reviews {
				j := r.PR.json()
				j["author"] = r.Author
				out = append(out, state{mr: r.PR, on: new(true), json: j})
			}
			return out, nil
		})
	case "issue.assigned":
		return s.pollDiff(e.Name, "assignedAt", a, p, func() ([]state, error) {
			var out []state
			for _, i := range yours.Assigned {
				if a.wantsIssue(i.Number) {
					out = append(out, state{mr: PR{Number: i.Number, Title: i.Title, URL: i.URL}, on: new(true), json: i.json()})
				}
			}
			return out, nil
		})
	case "pr.conflicted":
		return s.pollDiff(e.Name, "conflictedAt", a, p, func() ([]state, error) {
			prs, err := s.Bitbucket.OpenPRs(ctx, a.repo, true)
			var out []state
			for _, m := range prs {
				if a.mine {
					if a.byMe(m.PR, yours) {
						out = append(out, state{mr: m.PR, on: m.Conflicts, json: m.PR.json()})
					}
				} else if a.anyone || m.Trusted {
					out = append(out, state{mr: m.PR, on: m.Conflicts, json: m.PR.json()})
				}
			}
			return out, err
		})
	case "pr.opened":
		return s.pollDiff(e.Name, "openedAt", a, p, func() ([]state, error) {
			prs, err := s.Bitbucket.OpenPRs(ctx, a.repo, false)
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
		return candidates(ctx, s.Bitbucket, e.Name, a, yours, since)
	})
}

func (s *Events) poll(e event, p pollParams, find func(since string) ([]candidate, Listed, error)) (map[string]any, *rpcError) {
	return polls.Poll(e.Name, p, func() string { return mcpevents.TimeString(s.now().Truncate(time.Second)) },
		func(since string) ([]candidate, mcpevents.Listed, error) {
			found, listed, err := find(since)
			return found, mcpevents.Listed{Truncated: listed.Truncated, Newest: listed.Newest}, err
		})
}

func contains(list []string, s string) bool { return slices.Contains(list, s) }

// state is a pull request and whether its state (in conflict, or open and ready) is on now;
// nil keeps the one it had.
type state struct {
	mr   PR
	on   *bool
	json map[string]any
}

func (s *Events) pollDiff(name, key string, a args, p pollParams, states func() ([]state, error)) (map[string]any, *rpcError) {
	root := "pr"
	if strings.HasPrefix(name, "issue.") {
		root = "issue" // issue.assigned (#2034)
	}
	return polls.Diff(name, key, p, func() string { return mcpevents.TimeString(s.now()) }, func() ([]mcpevents.State, error) {
		all, err := states()
		var out []mcpevents.State
		for _, st := range all {
			if (a.pr != 0 && st.mr.Number != a.pr) || (a.branch != "" && st.mr.Branch != a.branch) || !a.closesOne(st.mr) {
				continue
			}
			out = append(out, mcpevents.State{ID: fmt.Sprintf("%s:%s:%d", name, a.repo, st.mr.Number), Number: st.mr.Number,
				On: st.on, Data: map[string]any{root: st.json}, Subject: diffRef(root, a.repo, st.mr.Number)})
		}
		return out, err
	})
}

// The refs of what bitbucket's events happen to (#4728, spec 4724-event-bus, "A ref").
func prRef(repo string, n int) wire.Ref { return mcpevents.Ref("bitbucket", "pr", repo, fmt.Sprint(n)) }
func runRef(repo string, n int) wire.Ref {
	return mcpevents.Ref("bitbucket", "run", repo, fmt.Sprint(n))
}
func issueRef(repo string, n int) wire.Ref {
	return mcpevents.Ref("bitbucket", "issue", repo, fmt.Sprint(n))
}

// diffRef is a state's subject: its issue for an issue's event, else its pr.
func diffRef(root, repo string, n int) wire.Ref {
	if root == "issue" {
		return issueRef(repo, n)
	}
	return prRef(repo, n)
}

// candidates finds what an event may raise at or after since.
func candidates(ctx context.Context, f Bitbucket, name string, a args, yours *Yours, since string) ([]candidate, Listed, error) {
	repo := a.repo
	// mine: the owner's own pull request, open or merged or declined, trusted or not; else the
	// trust filter (#728, #3797). fixes narrows every one by the issues it closes.
	wanted := func(m PR, trusted bool) bool {
		return (a.pr == 0 || m.Number == a.pr) && (a.branch == "" || m.Branch == a.branch) && a.closesOne(m) &&
			(a.mine && a.byMe(m, yours) || !a.mine && (a.anyone || trusted))
	}
	if kind, ok := strings.CutPrefix(name, "issue."); ok {
		items, listed, err := f.IssueActivity(ctx, repo, IssueKind(kind), since)
		if err != nil {
			return nil, Listed{}, err
		}
		var list []candidate
		for _, it := range items {
			if !a.wantsIssue(it.Issue.Number) || (!a.anyone && !it.Trusted) ||
				(a.label != "" && !contains(it.Issue.Labels, a.label)) ||
				(a.label != "" && it.Kind == IssueLabelled && it.Label != a.label) {
				continue
			}
			at := mcpevents.Normalized(it.At)
			if at == "" {
				continue
			}
			list = append(list, candidate{EventID: name + ":" + repo + ":" + it.ID, Time: at,
				Data:    func() (map[string]any, error) { return it.data(), nil },
				Subject: issueRef(repo, it.Issue.Number), Key: it.ID})
		}
		return list, listed, nil
	}
	switch name {
	case "review.comment":
		comments, listed, err := f.ReviewComments(ctx, repo, since)
		if err != nil {
			return nil, Listed{}, err
		}
		var list []candidate
		for _, c := range comments {
			// Trust is the commenter's; mine only narrows the pull request (#3797).
			m := c.PR
			if at := mcpevents.Normalized(c.At); at != "" && (a.pr == 0 || m.Number == a.pr) && (a.branch == "" || m.Branch == a.branch) &&
				a.closesOne(m) && a.byMe(m, yours) && (a.anyone || c.Trusted) {
				list = append(list, candidate{EventID: fmt.Sprintf("review.comment:%s:%d", repo, c.ID), Time: at,
					Data:    func() (map[string]any, error) { return c.data(), nil },
					Subject: prRef(repo, m.Number), Key: fmt.Sprint(c.ID)})
			}
		}
		return list, listed, nil
	case "run.completed":
		runs, listed, err := f.CompletedPipelines(ctx, repo, a.pipeline, a.branch, a.run, since)
		if err != nil {
			return nil, Listed{}, err
		}
		// Its finish time in the id: a run again (its failed steps) is a new event.
		var list []candidate
		for _, c := range runs {
			if c.At != "" && (a.anyone || c.Trusted) {
				list = append(list, candidate{EventID: fmt.Sprintf("run.completed:%s:%d:%s", repo, c.ID, c.At), Time: c.At,
					Subject: runRef(repo, c.ID), Key: c.At,
					Data: func() (map[string]any, error) {
						deploys, err := f.PipelineDeploys(ctx, repo, c)
						if err != nil {
							return nil, err
						}
						return c.data(deploys), nil
					}})
			}
		}
		return list, listed, nil
	case "checks.failed":
		failed, listed, err := f.FailedChecks(ctx, repo, since)
		if err != nil {
			return nil, Listed{}, err
		}
		// The newest failed status's time is in its id: run again and failed again, it is new.
		var list []candidate
		for _, d := range failed {
			if at := mcpevents.Normalized(d.At); at != "" && wanted(d.PR, d.Trusted) {
				list = append(list, candidate{EventID: fmt.Sprintf("checks.failed:%s:%s:%s", repo, d.HeadSHA, at), Time: at,
					Data:    func() (map[string]any, error) { return d.json(), nil },
					Subject: prRef(repo, d.PR.Number), Key: d.HeadSHA + ":" + at})
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
			if at := mcpevents.Normalized(m.MergedAt); wanted(m.PR, m.Trusted) && at != "" {
				list = append(list, candidate{EventID: fmt.Sprintf("pr.merged:%s:%d", repo, m.PR.Number), Time: at,
					Subject: prRef(repo, m.PR.Number),
					Data: func() (map[string]any, error) {
						return map[string]any{"pr": m.PR.json(), "mergedAt": m.MergedAt, "mergeSha": m.MergeSHA}, nil
					}})
			}
		}
		return list, listed, nil
	}
	// Its close time in the id: a pull request reopened and closed again is a new event.
	for _, c := range closed {
		if at := mcpevents.Normalized(c.ClosedAt); wanted(c.PR, c.Trusted) && at != "" {
			list = append(list, candidate{EventID: fmt.Sprintf("pr.closed:%s:%d:%s", repo, c.PR.Number, at), Time: at,
				Subject: prRef(repo, c.PR.Number), Key: at,
				Data: func() (map[string]any, error) {
					return map[string]any{"pr": c.PR.json(), "closedAt": c.ClosedAt}, nil
				}})
		}
	}
	return list, listed, nil
}

// eventsError is a Bitbucket failure as the events draft's error codes.
func eventsError(err error) *rpcError {
	var rpc *rpcError
	if errors.As(err, &rpc) {
		return rpc
	}
	var fe *BitbucketError
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
