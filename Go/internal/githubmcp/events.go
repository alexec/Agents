package githubmcp

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"slices"
	"strings"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/mcpevents"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// The MCP events (#383) of CIWatcher.swift, the same names, arguments, data and eventIds,
// polled only: `events/list` and `events/poll` of the events draft
// (experimental-ext-triggers-events), which the Agents daemon speaks.

// event is one event as events/list gives it.
type event = mcpevents.Event

var (
	repoProperty = property{Name: "repo", Kind: "string",
		Description: "The GitHub repo, owner/name. Left out, the repo this folder pushes to.",
		Pattern:     regexp.MustCompile(`^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`), LooksLike: "owner/name"}
	prProperty = property{Name: "pr", Kind: "integer", Description: "Only this pull request, by number."}
	// anyoneProperty opts into anyone's issue, comment or PR (#728); left out, only the repo's own people.
	anyoneProperty = property{Name: "anyone", Kind: "boolean",
		Description: "true: from anyone, bots, forks and people outside the repo too. Left out, only the repo's owner, members and collaborators, never a bot, and for a PR never one from a fork."}
	// mineProperty is only the connection's owner's own PRs (#2034), a fork's too.
	mineProperty = property{Name: "mine", Kind: "boolean",
		Description: "true: only pull requests by the GitHub account this server is connected as, whatever anyone says."}
	// anyProperty is every one in the repo (#3797): a wait that names none sets it.
	anyProperty = property{Name: "any", Kind: "boolean",
		Description: "true: every one in the repo. A wait (not a workflow trigger) that names none, by the other arguments that say which, is refused without it. It is about which ones; anyone is about who."}
	// fixesProperty is the PRs that close these issues (#3797): a lead knows a child's issue before its PR.
	fixesProperty = property{Name: "fixes", Kind: "refs",
		Description: `Only pull requests whose body closes one of these issues, as "#12" (this repo's) or "owner/repo#12".`,
		Pattern:     issueRefPattern, LooksLike: `issues, as "#12" or "owner/repo#12"`}
)

// ownPRs is what every PR event says of whose PRs it raises.
const ownPRs = " Only PRs from a branch of the repo itself, not a fork, by the repo's owner, members and collaborators or their agents' bot (<login>-agents), never another bot, unless anyone is true."

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

// fixesSchema is a PR's fixes: the issues its body closes, "#12" or "owner/repo#12" (#2349).
var fixesSchema = map[string]any{"type": "array", "items": str}

// events are the events this server offers, in CIWatcher's order.
var events = append([]event{
	{Name: "checks.failed", Title: "Checks failed",
		Description: "A pull request's checks finished with a failure: one event per run and attempt, so a rerun that fails again is a new one. run.createdAt is when the run was made, by its push (a rerun keeps it); completedAt is when it finished." + ownPRs,
		Input:       schema{repoProperty, branchProperty("Only runs on this PR branch."), prProperty, fixesProperty, anyoneProperty, mineProperty, anyProperty},
		Payload: object(map[string]any{
			"pr": prSchema(nil), "headSha": str,
			"run":         object(map[string]any{"id": integer, "attempt": integer, "name": str, "url": str, "createdAt": str}),
			"completedAt": str,
			"failedJobs":  map[string]any{"type": "array", "items": object(map[string]any{"name": str, "url": str})},
		})},
	{Name: "checks.passed", Title: "Checks passed",
		Description: "A pull request's checks finished with a success: one event per run and attempt, so a lane waiting on CI going green wakes without polling. run.createdAt is when the run was made, by its push (a rerun keeps it); completedAt is when it finished." + ownPRs,
		Input:       schema{repoProperty, branchProperty("Only runs on this PR branch."), prProperty, fixesProperty, anyoneProperty, mineProperty, anyProperty},
		Payload: object(map[string]any{
			"pr": prSchema(nil), "headSha": str,
			"run":         object(map[string]any{"id": integer, "attempt": integer, "name": str, "url": str, "createdAt": str}),
			"completedAt": str,
		})},
	// A run no pull request owns, as a tag's release or a workflow_dispatch run (#3444).
	{Name: "run.completed", Title: "Workflow run finished",
		Description: "A GitHub Actions workflow run finished, whatever started it (a push, a tag, workflow_dispatch, a schedule) and whatever its conclusion (success, failure, cancelled…): one event per run and attempt, so a rerun is a new one. For a run no pull request owns, such as a tag's release.yml or a dry run started by hand; a PR's own runs are checks.failed and checks.passed. Only runs from the repo itself, not a fork, started by a person, never a bot, unless anyone is true. deploys is what its jobs say they deployed: the message of each notice titled deploy, <target>:<id>/<version>, as testflight:<bundle id>/<build> from ::notice title=deploy::testflight:com.example.app/42.",
		Input: schema{repoProperty,
			property{Name: "workflow", Kind: "string", Description: "Only runs of this workflow, by its file name, as release.yml.",
				Pattern: regexp.MustCompile(`^[A-Za-z0-9_.-]+\.ya?ml$`), LooksLike: "release.yml"},
			branchProperty("Only runs on this branch or tag, as main or v0.16.0."),
			property{Name: "run", Kind: "integer", Description: "Only this run, by its id."}, anyoneProperty, anyProperty},
		Payload: object(map[string]any{
			"run": object(map[string]any{"id": integer, "attempt": integer, "name": str, "workflow": str, "event": str,
				"branch": str, "headSha": str, "url": str, "conclusion": str, "actor": str}),
			"completedAt": str,
			// What the run deployed, as its jobs say with ::notice title=deploy::<target>:<id>/<version> (#3584).
			"deploys": map[string]any{"type": "array", "items": str},
		})},
	// A deploy held by a GitHub environment with required reviewers (#3587).
	{Name: "deploy.waiting", Title: "Deploy waiting for approval",
		Description: "A GitHub Actions run is waiting for a reviewer of an environment with required reviewers, as a release.yml job with environment: production: one event per run, attempt and set of environments, so the next environment it waits on is a new one. canApprove says whether the GitHub account this server is connected as is one of its reviewers; Agents lists it in Needs You for them, with Approve and Reject. Only runs from the repo itself, started by a person, never a bot, unless anyone is true.",
		Input: schema{repoProperty,
			property{Name: "workflow", Kind: "string", Description: "Only runs of this workflow, by its file name, as release.yml.",
				Pattern: regexp.MustCompile(`^[A-Za-z0-9_.-]+\.ya?ml$`), LooksLike: "release.yml"},
			branchProperty("Only runs on this branch or tag, as main or v0.16.0."), anyoneProperty},
		Payload: object(map[string]any{
			"run": object(map[string]any{"id": integer, "attempt": integer, "name": str, "workflow": str, "event": str,
				"branch": str, "headSha": str, "url": str, "actor": str}),
			"environments": map[string]any{"type": "array", "items": object(map[string]any{"id": integer, "name": str, "url": str})},
			"reviewers":    map[string]any{"type": "array", "items": str},
			"canApprove":   map[string]any{"type": "boolean"},
			"waitingSince": str,
		})},
	deployEvent("deploy.started", "Deploy started",
		"A GitHub Deployment went running (queued or in_progress): a job with environment: began to deploy, whatever started its run. One event per Deployment, so a queued after in_progress is no new one."),
	deployEvent("deploy.succeeded", "Deploy succeeded",
		"A GitHub Deployment went succeeded (success): a job with environment: deployed. One event per Deployment. GitHub's later inactive is not read: in a repo whose jobs share an environment, it does not mean replaced."),
	deployEvent("deploy.failed", "Deploy failed",
		"A GitHub Deployment went failed (failure or error): a job with environment: did not deploy. One event per Deployment. outcome is cancelled when its job was cancelled, else failed."),
	{Name: "pr.opened", Title: "Pull request opened",
		Description: "A pull request was opened, or a draft was marked ready for review: a PR open and not a draft now that was not at the last poll. Drafts never count. Reopened, it is raised again." + ownPRs,
		Input:       schema{repoProperty, branchProperty("Only the PR from this branch."), prProperty, anyoneProperty},
		Payload:     object(map[string]any{"pr": prSchema(map[string]any{"author": str}), "openedAt": str})},
	{Name: "pr.merged", Title: "Pull request merged", Description: "A pull request was merged." + ownPRs,
		Input:   schema{repoProperty, branchProperty("Only the PR from this branch."), prProperty, fixesProperty, anyoneProperty, mineProperty, anyProperty},
		Payload: object(map[string]any{"pr": prSchema(nil), "mergedAt": str, "mergeSha": str})},
	{Name: "pr.closed", Title: "Pull request closed", Description: "A pull request was closed without being merged." + ownPRs,
		Input:   schema{repoProperty, branchProperty("Only the PR from this branch."), prProperty, fixesProperty, anyoneProperty, mineProperty, anyProperty},
		Payload: object(map[string]any{"pr": prSchema(nil), "closedAt": str})},
	{Name: "pr.conflicted", Title: "Pull request in conflict",
		Description: "An open pull request began to conflict with its base, so it cannot merge and its CI may not run until it is rebased. Once per conflict: it is raised again only after the PR merges cleanly and then conflicts anew." + ownPRs,
		Input:       schema{repoProperty, branchProperty("Only the PR from this branch."), prProperty, fixesProperty, anyoneProperty, mineProperty, anyProperty},
		Payload:     object(map[string]any{"pr": prSchema(nil), "conflictedAt": str})},
	{Name: "pr.blocked", Title: "Pull request blocked",
		Description: mcpevents.BlockedDescription("On GitHub: mergeable, mergeStateStatus (BEHIND only under a rule that wants the branch up to date), reviewDecision, the last auto-merge event, and the head's checks against the required checks of the base's rulesets and branch protection."+ownPRs),
		Input:       schema{repoProperty, branchProperty("Only the PR from this branch."), prProperty, fixesProperty, anyoneProperty, mineProperty, anyProperty},
		Payload:     mcpevents.BlockedPayload(prSchema(nil))},
	{Name: "pr.commented", Title: "Pull request commented on",
		Description: "A comment was left on a pull request's conversation (not a review comment on a line of its diff, which review.comment covers). Its body is the first 4000 characters. A comment whose body starts with <!-- agent --> is left out: an agent's, not a person's, since every PR and comment is posted as the same account. Only comments by the repo's owner, members and collaborators, never a bot, unless anyone is true.",
		Input:       schema{repoProperty, prProperty, fixesProperty, anyoneProperty, mineProperty, anyProperty},
		Payload: object(map[string]any{"pr": prSchema(nil),
			"comment": object(map[string]any{"author": str, "url": str, "body": str}), "commentedAt": str})},
	// A person's review (#3860): how the person approves a bot's PR, where a comment did before.
	{Name: "pr.reviewed", Title: "Pull request reviewed",
		Description: "A review was posted on a pull request: Approve (state approved), Request changes (changes_requested), or a comment with words (commented). A pending, a dismissed and an empty review are left out. Its body is the first 4000 characters, and commit is the commit it reviewed. Only reviews by the repo's owner, members and collaborators, never a bot, unless anyone is true; only open pull requests." + ownPRs,
		Input:       schema{repoProperty, branchProperty("Only the PR from this branch."), prProperty, fixesProperty, anyoneProperty, mineProperty, anyProperty},
		Payload: object(map[string]any{"pr": prSchema(nil),
			"review": object(map[string]any{"author": str, "state": str, "body": str, "url": str, "commit": str}), "reviewedAt": str})},
	// For the person, not the repo (#2034): what asks the connection's owner for something.
	{Name: "review.requested", Title: "Review requested from me",
		Description: "A review was requested from the GitHub account this server is connected as, on an open pull request: once per request, so a request taken back and made again is a new one. Anyone's PR, a fork's too.",
		Input:       schema{repoProperty, prProperty},
		Payload:     object(map[string]any{"pr": prSchema(map[string]any{"author": str}), "requestedAt": str})},
	// CodeRabbit's (#1344), known by its GitHub App, not by a name.
	{Name: "review.posted", Title: "CodeRabbit reviewed",
		Description: "CodeRabbit finished a review of a pull request's head commit: its CodeRabbit status on that commit gone to success, or, where it sets no status, a review by its GitHub App on that commit. Once per review: a push it reviews, or a full review asked of the same commit (coderabbit_review with full), is a new one. state is its review's (commented, approved or changes_requested), empty when only its status says so; its comments come as review.comment." + ownPRs,
		Input:       schema{repoProperty, branchProperty("Only the PR from this branch."), prProperty, fixesProperty, anyoneProperty, mineProperty, anyProperty},
		Payload:     object(map[string]any{"pr": prSchema(nil), "headSha": str, "state": str, "url": str, "reviewedAt": str})},
	{Name: "review.comment", Title: "CodeRabbit commented on a line",
		Description: "CodeRabbit left a review comment on a pull request: on a line of its diff, or as an answer in a thread (inReplyTo is the comment it answers). Its body is the first 4000 characters. Answer it with coderabbit_reply and comment.id." + ownPRs,
		Input:       schema{repoProperty, branchProperty("Only the PR from this branch."), prProperty, fixesProperty, anyoneProperty, mineProperty, anyProperty},
		Payload: object(map[string]any{"pr": prSchema(nil), "commentedAt": str,
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
		label := property{Name: "label", Kind: "string", Description: "Only when this label is the one changed."}
		description := k.description + " " + k.who + " the repo's owner, members and collaborators, never a bot, unless anyone is true."
		out[i] = event{Name: "pr." + string(k.kind), Title: k.title, Description: description,
			Input:   schema{repoProperty, prProperty, label, fixesProperty, anyoneProperty, mineProperty, anyProperty},
			Payload: object(map[string]any{"pr": prSchema(nil), "label": str, "by": str, k.timeKey: str})}
	}
	return out
}

// assignedEvent is for the person, not the repo (#2034): an issue given to the connection's owner.
var assignedEvent = event{Name: "issue.assigned", Title: "Issue assigned to me",
	Description: "An open issue was assigned to the GitHub account this server is connected as: once per assignment, so one unassigned and assigned again is a new one. Anyone's issue.",
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
		label := property{Name: "label", Kind: "string", Description: k.label}
		input := schema{repoProperty, label, issue, anyoneProperty, anyProperty}
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
		out[i] = event{Name: "issue." + string(k.kind), Title: k.title, Description: description, Input: input, Payload: object(payload)}
	}
	return out
}

func eventNamed(name string) (event, bool) { return mcpevents.Named(events, name) }

// EventNames is the events it declares, by name, in events/list's order.
func EventNames() []string { return mcpevents.Names(events) }

// eventsList is events/list's answer.
func eventsList() map[string]any { return mcpevents.List(events) }

// MARK: The cursor

// cursor is where a poll has got to: a high-water time, and the ids already raised at exactly
// that time, so events that share one time are neither lost nor raised twice. A client keeps
// it as an opaque string (base64url of its JSON), as CIWatcher's PollCursor.
type cursor mcpevents.Cursor

func (c cursor) encoded() string { return mcpevents.Cursor(c).Encoded() }

// MARK: Polling

// candidate is something that may be raised: its id, its time (in mcpevents.TimeLayout), and its data,
// looked up only once it is taken; nil data skips it, though the cursor still moves past it.
type candidate = mcpevents.Candidate

const (
	maxEvents  = mcpevents.MaxEvents
	nextPollMs = 30000
	// historyDays: a cursor older than this may have missed some, as GitHub keeps no more.
	historyDays = 90
)

type pollParams = mcpevents.Params

// polls is how it polls, with GitHub's times and errors.
var polls = mcpevents.Poller{NextPollMs: nextPollMs, Normalize: mcpevents.Normalized, Fail: eventsError}

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
	if a.mine || e.Name == "review.requested" || e.Name == "issue.assigned" {
		y, err := s.GitHub.Yours(ctx, a.repo)
		if err != nil {
			return nil, eventsError(err)
		}
		yours = &y
	}
	switch e.Name {
	case "review.requested":
		return s.pollDiff(ctx, e.Name, "requestedAt", a, p, func() ([]state, error) {
			var out []state
			for _, r := range yours.Reviews {
				j := r.PR.json()
				j["author"] = r.Author
				out = append(out, state{pr: r.PR, on: new(true), json: j})
			}
			return out, nil
		})
	case "issue.assigned":
		return s.pollDiff(ctx, e.Name, "assignedAt", a, p, func() ([]state, error) {
			var out []state
			for _, i := range yours.Assigned {
				if a.wantsIssue(i.Number) {
					out = append(out, state{pr: PR{Number: i.Number, Title: i.Title, URL: i.URL}, on: new(true), json: i.json()})
				}
			}
			return out, nil
		})
	case "pr.conflicted":
		return s.pollDiff(ctx, e.Name, "conflictedAt", a, p, func() ([]state, error) {
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
	case "pr.blocked":
		was := polls.CursorIDs(p)
		return s.pollDiff(ctx, e.Name, "blockedAt", a, p, func() ([]state, error) {
			prs, err := s.GitHub.BlockedPRs(ctx, a.repo)
			var out []state
			for _, b := range prs {
				if b.Skip || (yours != nil && !yours.owns(b.PR.Number)) || (yours == nil && !a.anyone && !b.Trusted) {
					continue
				}
				bs := mcpevents.Blocked(fmt.Sprintf("%s:%s:%d", e.Name, a.repo, b.PR.Number), b.Blocking, was)
				out = append(out, state{pr: b.PR, on: &bs.On, key: bs.Key, json: b.PR.json(), extra: bs.Data})
			}
			return out, err
		})
	case "pr.opened":
		return s.pollDiff(ctx, e.Name, "openedAt", a, p, func() ([]state, error) {
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
		return s.pollDiff(ctx, e.Name, "reviewedAt", a, p, func() ([]state, error) {
			prs, err := s.GitHub.CodeRabbitPRs(ctx, a.repo)
			var out []state
			for _, r := range prs {
				if a.byMe(r.PR, yours) && (a.mine || a.anyone || r.Trusted) {
					reviewed := r.Reviewed
					out = append(out, state{pr: r.PR, on: &reviewed, key: r.round(),
						json: r.PR.json(), extra: map[string]any{"headSha": r.HeadSHA, "state": r.Review, "url": r.URL}})
				}
			}
			return out, err
		})
	}
	return s.poll(e, p, func(since string) ([]candidate, bool, error) {
		return candidates(ctx, s.GitHub, e.Name, a, yours, since)
	})
}

// poll is events/poll over a cursor (mcpevents.Poller.Poll), truncated too when its cursor is
// older than GitHub keeps.
func (s *Events) poll(e event, p pollParams, find func(since string) ([]candidate, bool, error)) (map[string]any, *rpcError) {
	now := s.now()
	result, bad := polls.Poll(e.Name, p, func() string { return mcpevents.TimeString(now) },
		func(since string) ([]candidate, mcpevents.Listed, error) {
			found, truncated, err := find(since)
			return found, mcpevents.Listed{Truncated: truncated}, err
		})
	if bad != nil || p.FirstPoll() {
		return result, bad
	}
	c, _ := polls.Decode(p.Cursor)
	if sinceTime, _ := mcpevents.ParseTime(c.Since); sinceTime.Before(now.Add(-historyDays * 24 * time.Hour)) {
		result["truncated"] = true
	}
	return result, nil
}

func contains(list []string, s string) bool { return slices.Contains(list, s) }

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

func (s *Events) pollDiff(_ context.Context, name, key string, a args, p pollParams, states func() ([]state, error)) (map[string]any, *rpcError) {
	root := "pr"
	if strings.HasPrefix(name, "issue.") {
		root = "issue" // issue.assigned (#2034)
	}
	return polls.Diff(name, key, p, func() string { return mcpevents.TimeString(s.now()) }, func() ([]mcpevents.State, error) {
		all, err := states()
		var out []mcpevents.State
		for _, st := range all {
			if (a.pr != 0 && st.pr.Number != a.pr) || (a.branch != "" && st.pr.Branch != a.branch) || !a.closesOne(st.pr) {
				continue
			}
			id := fmt.Sprintf("%s:%s:%d", name, a.repo, st.pr.Number)
			if st.key != "" {
				id += ":" + st.key
			}
			data := map[string]any{root: st.json}
			for k, v := range st.extra {
				data[k] = v
			}
			subject := prRef(a.repo, st.pr.Number)
			if root == "issue" {
				subject = issueRef(a.repo, st.pr.Number)
			}
			out = append(out, mcpevents.State{ID: id, Number: st.pr.Number, On: st.on, Data: data, Subject: subject, Key: st.key})
		}
		return out, err
	})
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
			if !a.wantsIssue(it.Issue.Number) {
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
			at := mcpevents.Normalized(it.At)
			if at == "" {
				continue
			}
			list = append(list, candidate{EventID: name + ":" + repo + ":" + it.ID, Time: at,
				Data:    func() (map[string]any, error) { return it.data(), nil },
				Subject: issueRef(repo, it.Issue.Number), Key: it.ID})
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
			if (a.pr != 0 && it.PR.Number != a.pr) || !a.closesOne(it.PR) || !a.byMe(it.PR, yours) {
				continue
			}
			if !a.anyone && !it.Trusted {
				continue
			}
			if a.label != "" && it.Label != a.label {
				continue
			}
			at := mcpevents.Normalized(it.At)
			if at == "" {
				continue
			}
			list = append(list, candidate{EventID: name + ":" + repo + ":" + it.ID, Time: at,
				Data:    func() (map[string]any, error) { return it.data(), nil },
				Subject: prRef(repo, it.PR.Number), Key: it.ID})
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
			at := mcpevents.Normalized(c.At)
			if at == "" || (a.pr != 0 && c.PR.Number != a.pr) || (a.branch != "" && c.PR.Branch != a.branch) ||
				!(a.mine || a.anyone || c.Trusted) || !a.closesOne(c.PR) || !a.byMe(c.PR, yours) {
				continue
			}
			list = append(list, candidate{EventID: fmt.Sprintf("review.comment:%s:%d", repo, c.ID), Time: at,
				Data:    func() (map[string]any, error) { return c.data(), nil },
				Subject: prRef(repo, c.PR.Number), Key: fmt.Sprint(c.ID)})
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
			at := mcpevents.Normalized(c.At)
			if at == "" {
				continue
			}
			list = append(list, candidate{EventID: fmt.Sprintf("pr.commented:%s:%d", repo, c.ID), Time: at,
				Subject: prRef(repo, c.PR.Number), Key: fmt.Sprint(c.ID),
				Data: func() (map[string]any, error) {
					if c.Other || (a.pr != 0 && c.PR.Number != a.pr) || !(a.anyone || c.Trusted) || !a.closesOne(c.PR) || !a.byMe(c.PR, yours) {
						return nil, nil
					}
					return c.data(), nil
				}})
		}
		return list, truncated, nil
	}
	if name == "pr.reviewed" {
		reviews, err := gh.PRReviews(ctx, repo, since, a.pr)
		if err != nil {
			return nil, false, err
		}
		var list []candidate
		for _, r := range reviews {
			at := mcpevents.Normalized(r.At)
			if at == "" || (a.pr != 0 && r.PR.Number != a.pr) || (a.branch != "" && r.PR.Branch != a.branch) ||
				!(a.anyone || r.Trusted) || !a.closesOne(r.PR) || !a.byMe(r.PR, yours) {
				continue
			}
			list = append(list, candidate{EventID: fmt.Sprintf("pr.reviewed:%s:%d", repo, r.ID), Time: at,
				Data:    func() (map[string]any, error) { return r.data(), nil },
				Subject: prRef(repo, r.PR.Number), Key: fmt.Sprint(r.ID)})
		}
		return list, false, nil
	}
	if name == "deploy.started" || name == "deploy.succeeded" || name == "deploy.failed" {
		return deployCandidates(ctx, gh, name, a, since)
	}
	if name == "deploy.waiting" {
		waiting, err := gh.WaitingDeploys(ctx, repo, a.workflow, a.branch)
		if err != nil {
			return nil, false, err
		}
		var list []candidate
		for _, w := range waiting {
			at := mcpevents.Normalized(w.Run.Run.UpdatedAt)
			if at == "" || (!a.anyone && !w.Run.Trusted) {
				continue
			}
			list = append(list, candidate{EventID: "deploy.waiting:" + repo + ":" + w.key(), Time: at,
				Data:    func() (map[string]any, error) { return w.data(), nil },
				Subject: runRef(repo, w.Run.Run.ID), Key: strings.TrimPrefix(w.key(), fmt.Sprint(w.Run.Run.ID)+":")})
		}
		return list, false, nil
	}
	if name == "run.completed" {
		runs, truncated, err := gh.CompletedRuns(ctx, repo, a.workflow, a.branch, a.run, since)
		if err != nil {
			return nil, false, err
		}
		var list []candidate
		for _, r := range runs {
			at := mcpevents.Normalized(r.Run.UpdatedAt)
			if at == "" {
				continue
			}
			list = append(list, candidate{EventID: fmt.Sprintf("run.completed:%s:%d:%d", repo, r.Run.ID, r.Run.Attempt), Time: at,
				Subject: runRef(repo, r.Run.ID), Key: fmt.Sprint(r.Run.Attempt),
				Data: func() (map[string]any, error) {
					if !a.anyone && !r.Trusted {
						return nil, nil
					}
					deploys, err := gh.RunDeploys(ctx, repo, r)
					if err != nil {
						return nil, err
					}
					return r.data(deploys), nil
				}})
		}
		return list, truncated, nil
	}
	if name == "checks.failed" {
		return checkRunCandidates(ctx, gh, name, a, yours, since, gh.FailedRuns, true, RunData.json)
	}
	if name == "checks.passed" {
		return checkRunCandidates(ctx, gh, name, a, yours, since, gh.PassedRuns, false, RunData.passedJSON)
	}
	merged, closed, truncated, err := gh.ClosedPRs(ctx, repo, since)
	if err != nil {
		return nil, false, err
	}
	wanted := func(p PR, trusted bool) bool {
		// mine: the owner's own PR, trusted or not, as checks.* and pr.conflicted (#3797).
		return (a.pr == 0 || p.Number == a.pr) && (a.branch == "" || p.Branch == a.branch) && a.closesOne(p) &&
			(a.mine && a.byMe(p, yours) || !a.mine && (a.anyone || trusted))
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
		return list, truncated, nil
	}
	// Its close time in the id: a PR reopened and closed again is a new event.
	for _, c := range closed {
		if at := mcpevents.Normalized(c.ClosedAt); wanted(c.PR, c.Trusted) && at != "" {
			list = append(list, candidate{EventID: fmt.Sprintf("pr.closed:%s:%d:%s", repo, c.PR.Number, c.ClosedAt), Time: at,
				Subject: prRef(repo, c.PR.Number), Key: c.ClosedAt,
				Data: func() (map[string]any, error) {
					return map[string]any{"pr": c.PR.json(), "closedAt": c.ClosedAt}, nil
				}})
		}
	}
	return list, truncated, nil
}

// checkRunCandidates is checks.failed's and checks.passed's candidates: listRuns finds the
// finished runs, jobs says whether to fetch each one's jobs, toJSON shapes each one's data
// (RunData.json keeps failedJobs, .passedJSON drops it). With a pr and no branch, only the PR's
// branch is listed (#3107). A run that names another PR is skipped before its details are fetched; one that
// names none is checked against the PR its details find. The cursor still moves past both.
func checkRunCandidates(ctx context.Context, gh GitHub, name string, a args, yours *Yours, since string,
	listRuns func(ctx context.Context, repo, branch, since string) ([]RunRef, bool, error), jobs bool,
	toJSON func(RunData) map[string]any,
) ([]candidate, bool, error) {
	repo := a.repo
	branch := a.branch
	if branch == "" && a.pr != 0 {
		var err error
		var missing *GitHubError
		// A PR GitHub does not know lists the whole repo, as before; its runs never match.
		if branch, err = gh.PRBranch(ctx, repo, a.pr); err != nil && !(errors.As(err, &missing) && missing.Kind == NotFound) {
			return nil, false, err
		}
	}
	runs, truncated, err := listRuns(ctx, repo, branch, since)
	if err != nil {
		return nil, false, err
	}
	var list []candidate
	for _, ref := range runs {
		at := mcpevents.Normalized(ref.UpdatedAt)
		if at == "" {
			continue
		}
		// The subject is the run's PR, keyed by its head commit, once its details say the PR.
		subject, key := runRef(repo, ref.ID), fmt.Sprint(ref.Attempt)
		list = append(list, candidate{EventID: fmt.Sprintf("%s:%s:%d:%d", name, repo, ref.ID, ref.Attempt), Time: at,
			Envelope: func() (wire.Ref, string) { return subject, key },
			Data: func() (map[string]any, error) {
				if (a.pr != 0 && ref.PRNumber != 0 && ref.PRNumber != a.pr) || (yours != nil && ref.PRNumber != 0 && !yours.owns(ref.PRNumber)) {
					return nil, nil
				}
				details, err := gh.RunDetails(ctx, repo, ref, jobs)
				if err != nil || details == nil {
					return nil, err
				}
				if a.pr != 0 && details.PR.Number != a.pr || !a.closesOne(details.PR) {
					return nil, nil
				}
				// mine: the owner's own PR, trusted or not; else the trust filter (#728).
				if yours != nil && !yours.ownsPR(details.PR) || yours == nil && !a.anyone && !details.Trusted {
					return nil, nil
				}
				if details.PR.Number != 0 && details.HeadSHA != "" {
					subject, key = prRef(repo, details.PR.Number), details.HeadSHA
				}
				return toJSON(*details), nil
			}})
	}
	return list, truncated, nil
}

// The refs of what GitHub's events happen to (#4728, spec 4724-event-bus, "A ref").
func prRef(repo string, n int) wire.Ref { return mcpevents.Ref("github", "pr", repo, fmt.Sprint(n)) }
func issueRef(repo string, n int) wire.Ref {
	return mcpevents.Ref("github", "issue", repo, fmt.Sprint(n))
}
func runRef(repo string, id int) wire.Ref {
	return mcpevents.Ref("github", "run", repo, fmt.Sprint(id))
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
