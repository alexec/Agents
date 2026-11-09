package azuredevopsmcp

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"slices"
	"time"

	"github.com/alexec/agents/Go/internal/mcpevents"
)

// The MCP events (#2829) of an Azure DevOps repository's pull requests and their Azure
// Pipelines builds, in the gitlab server's shape (Go/internal/gitlabmcp/events.go): the same
// names where they mean the same, and the same cursor, paging and trust filter (#728), polled
// only: `events/list` and `events/poll` of the events draft (experimental-ext-triggers-events),
// which the Agents daemon speaks. Work items are not here: they are the tracker's, as Linear's
// and Jira's issues are.

// event is one event as events/list gives it.
type event = mcpevents.Event

// repoPattern is a repository's organization/project/name. A project's name may have spaces.
var repoPattern = regexp.MustCompile(`^[^/\s][^/]*/[^/\s][^/]*/[^/\s][^/]*$`)

var (
	repoProperty = property{Name: "repo", Kind: "string",
		Description: "The repository on Azure DevOps, as organization/project/name (collection/project/name on Azure DevOps Server). Left out, the repository this folder pushes to.",
		Pattern:     repoPattern, LooksLike: "organization/project/name"}
	prProperty = property{Name: "pr", Kind: "integer", Description: "Only this pull request, by number."}
	// anyoneProperty opts into anyone's comment or pull request (#728); left out, only the project's own people.
	anyoneProperty = property{Name: "anyone", Kind: "boolean",
		Description: "true: from anyone, bots and forks too. Left out, never a bot (a build service) and for a pull request never one from a fork. Only a project's members can write to it on Azure DevOps."}
	// mineProperty is only the token's owner's own pull requests (#2034), a fork's too.
	mineProperty = property{Name: "mine", Kind: "boolean",
		Description: "true: only pull requests by the Azure DevOps account whose token this server has, whatever anyone says."}
)

// ownPRs is what every pull request event says of whose pull requests it raises.
const ownPRs = " Only pull requests from a branch of the repository itself, not a fork, and never by a bot, unless anyone is true."

func branchProperty(description string) property {
	return property{Name: "branch", Kind: "string", Description: description}
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
	{Name: "checks.failed", Title: "Checks failed",
		Description: "An open pull request's checks failed at its head commit: an Azure Pipelines build of it (its build validation, or any pipeline it triggers), a build of its branch at that commit (a CI trigger's), or the newest status that another service set on it (failed or error). One event per commit and failure time, so a build run again that fails again is a new one. failedJobs are the failed builds and statuses; run is the first failed build (get_build_log reads its failed steps), or the first failed status with id 0 when no build failed." + ownPRs,
		Input:       schema{repoProperty, branchProperty("Only checks of the pull request from this branch."), prProperty, anyoneProperty, mineProperty},
		Payload: object(map[string]any{
			"pr": prSchema(nil), "headSha": str,
			"run":        object(map[string]any{"id": integer, "name": str, "url": str}),
			"failedJobs": map[string]any{"type": "array", "items": object(map[string]any{"name": str, "url": str})},
		})},
	{Name: "checks.passed", Title: "Checks passed",
		Description: "One of an open pull request's checks passed at its head commit: an Azure Pipelines build of it or of its branch at that commit, or the newest status of one context that another service set on it. One event per build or status, so a lane waiting on CI going green wakes without polling. run is the build (id 0 for a status)." + ownPRs,
		Input:       schema{repoProperty, branchProperty("Only checks of the pull request from this branch."), prProperty, anyoneProperty, mineProperty},
		Payload: object(map[string]any{
			"pr": prSchema(nil), "headSha": str,
			"run": object(map[string]any{"id": integer, "name": str, "url": str}),
		})},
	// A build no pull request owns, as main's or a tag's, as the github server's (#3444, #3810).
	{Name: "run.completed", Title: "Pipeline build finished",
		Description: "An Azure Pipelines build of the repository finished, whatever started it (a push, a tag, a person, a schedule) and whatever its result (succeeded, failed, canceled, partiallySucceeded): one event per build and finish time, so a build run again is a new one. For a build no pull request owns, such as main's or a tag's release; a pull request's own builds are checks.failed and checks.passed. run.name is its pipeline's name, run.number its build number, run.event what started it (manual, individualCI, batchedCI, schedule, pullRequest…). Only builds asked for by a person, never a bot (a build service), and never a fork's pull request's, unless anyone is true.",
		Input: schema{repoProperty,
			property{Name: "pipeline", Kind: "string", Description: "Only builds of this pipeline, by its name, as release."},
			branchProperty("Only builds of this branch or tag, as main or v0.16.0."),
			property{Name: "run", Kind: "integer", Description: "Only this build, by its id."}, anyoneProperty},
		Payload: object(map[string]any{
			"run": object(map[string]any{"id": integer, "name": str, "number": str, "event": str, "branch": str, "headSha": str,
				"url": str, "conclusion": str, "actor": str}),
			"completedAt": str,
		})},
	{Name: "pr.opened", Title: "Pull request opened",
		Description: "A pull request was opened, or a draft was published: a pull request active and not a draft now that was not at the last poll. Drafts never count. Reactivated, it is raised again." + ownPRs,
		Input:       prInput(),
		Payload:     object(map[string]any{"pr": prSchema(map[string]any{"author": str, "fixes": fixesSchema}), "openedAt": str})},
	{Name: "pr.merged", Title: "Pull request merged", Description: "A pull request was completed: merged into its target." + ownPRs,
		Input:   prInput(),
		Payload: object(map[string]any{"pr": prSchema(map[string]any{"fixes": fixesSchema}), "mergedAt": str, "mergeSha": str})},
	{Name: "pr.closed", Title: "Pull request closed", Description: "A pull request was abandoned: closed without being merged." + ownPRs,
		Input:   prInput(),
		Payload: object(map[string]any{"pr": prSchema(map[string]any{"fixes": fixesSchema}), "closedAt": str})},
	{Name: "pr.conflicted", Title: "Pull request in conflict",
		Description: "An active pull request began to conflict with its target branch, so it cannot merge until it is rebased. Once per conflict: it is raised again only after it merges cleanly and then conflicts anew." + ownPRs,
		Input:       append(prInput(), mineProperty),
		Payload:     object(map[string]any{"pr": prSchema(nil), "conflictedAt": str})},
	// For the person, not the repository (#2034): what asks the token's owner for something.
	{Name: "review.requested", Title: "Review requested from me",
		Description: "The Azure DevOps account whose token this server has was added as a reviewer of an active pull request and has not voted: once per request, so a vote reset by a new push is a new one. Anyone's pull request, a fork's too.",
		Input:       schema{repoProperty, prProperty},
		Payload:     object(map[string]any{"pr": prSchema(map[string]any{"author": str}), "requestedAt": str})},
	{Name: "review.comment", Title: "Pull request line commented on",
		Description: "Someone left a comment on a line of a pull request's diff, or answered in its thread. Its body is the first 4000 characters; comment.threadId is the thread to answer in with reply_to_pull_request_comment. The 50 newest active pull requests are read, and those closed since. Never a bot's comment, unless anyone is true; and only on the repository's own pull requests.",
		Input:       prInput(),
		Payload: object(map[string]any{"pr": prSchema(nil), "commentedAt": str,
			"comment": object(map[string]any{"id": integer, "threadId": integer, "author": str, "path": str, "line": integer, "body": str, "url": str})})},
}

func eventNamed(name string) (event, bool) { return mcpevents.Named(events, name) }

// EventNames is the events it declares, by name, in events/list's order.
func EventNames() []string { return mcpevents.Names(events) }

// eventsList is events/list's answer.
func eventsList() map[string]any { return mcpevents.List(events) }

// MARK: Polling

// candidate is something that may be raised: its id, its time (in timeLayout), and its data,
// looked up only once it is taken; nil data skips it, though the cursor still moves past it.
type candidate = mcpevents.Candidate

const (
	maxEvents  = mcpevents.MaxEvents
	nextPollMs = 30000
)

type pollParams = mcpevents.Params

// polls is how it polls, with Azure DevOps's times and errors.
var polls = mcpevents.Poller{NextPollMs: nextPollMs, Normalize: normalized, Fail: eventsError}

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
	if a.mine || e.Name == "review.requested" {
		y, err := s.AzureDevOps.Yours(ctx, a.repo)
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
	case "pr.conflicted":
		return s.pollDiff(e.Name, "conflictedAt", a, p, func() ([]state, error) {
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
		return s.pollDiff(e.Name, "openedAt", a, p, func() ([]state, error) {
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
		return candidates(ctx, s.AzureDevOps, e.Name, a, yours, since)
	})
}

func (s *Events) poll(e event, p pollParams, find func(since string) ([]candidate, Listed, error)) (map[string]any, *rpcError) {
	return polls.Poll(e.Name, p, func() string { return timeString(s.now().Truncate(time.Second)) },
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
	return polls.Diff(name, key, p, func() string { return timeString(s.now()) }, func() ([]mcpevents.State, error) {
		all, err := states()
		var out []mcpevents.State
		for _, st := range all {
			if (a.pr != 0 && st.mr.Number != a.pr) || (a.branch != "" && st.mr.Branch != a.branch) {
				continue
			}
			out = append(out, mcpevents.State{ID: fmt.Sprintf("%s:%s:%d", name, a.repo, st.mr.Number), Number: st.mr.Number,
				On: st.on, Data: map[string]any{root: st.json}})
		}
		return out, err
	})
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
				list = append(list, candidate{EventID: fmt.Sprintf("run.completed:%s:%d:%s", repo, b.ID, b.At), Time: b.At,
					Data: func() (map[string]any, error) { return b.data(), nil }})
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
				list = append(list, candidate{EventID: fmt.Sprintf("review.comment:%s:%d:%d:%d", repo, c.PR.Number, c.ThreadID, c.ID), Time: at,
					Data: func() (map[string]any, error) { return c.data(), nil }})
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
				list = append(list, candidate{EventID: fmt.Sprintf("checks.failed:%s:%s:%s", repo, d.HeadSHA, at), Time: at,
					Data: func() (map[string]any, error) { return d.json(), nil }})
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
				list = append(list, candidate{EventID: fmt.Sprintf("checks.passed:%s:%s:%s:%s", repo, d.HeadSHA, d.Key, at), Time: at,
					Data: func() (map[string]any, error) { return d.json(), nil }})
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
				list = append(list, candidate{EventID: fmt.Sprintf("pr.merged:%s:%d", repo, m.PR.Number), Time: at,
					Data: func() (map[string]any, error) {
						return map[string]any{"pr": m.PR.json(), "mergedAt": m.MergedAt, "mergeSha": m.MergeSHA}, nil
					}})
			}
		}
		return list, listed, nil
	}
	// Its close time in the id: a pull request reopened and closed again is a new event.
	for _, c := range closed {
		if at := normalized(c.ClosedAt); wanted(c.PR, c.Trusted) && at != "" {
			list = append(list, candidate{EventID: fmt.Sprintf("pr.closed:%s:%d:%s", repo, c.PR.Number, at), Time: at,
				Data: func() (map[string]any, error) {
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
