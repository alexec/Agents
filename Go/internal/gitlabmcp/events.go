package gitlabmcp

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

// The MCP events (#1629) of a GitLab project's merge requests, pipelines and issues, in the
// github server's shape (Go/internal/githubmcp/events.go): the same names where they mean the
// same, and the same cursor, paging and trust filter (#728), polled only: `events/list` and
// `events/poll` of the events draft (experimental-ext-triggers-events), which the Agents
// daemon speaks. A merge request is a "pr" in names and data, as on GitHub.

// event is one event as events/list gives it.
type event = mcpevents.Event

// projectPattern is a project's path (group/name, with subgroups) or its numeric id.
var projectPattern = regexp.MustCompile(`^([0-9]+|[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)+)$`)

var (
	projectProperty = property{Name: "project", Kind: "string",
		Description: "The GitLab project, by its path (group/name, subgroups too) or its id. Left out, the project this folder pushes to.",
		Pattern:     projectPattern, LooksLike: "group/name or a project id"}
	prProperty = property{Name: "pr", Kind: "integers", Description: "Only this merge request, or these, by number (its iid, as !12)."}
	// anyoneProperty opts into anyone's issue, comment or merge request (#728); left out, only the project's own people.
	anyoneProperty = property{Name: "anyone", Kind: "boolean",
		Description: "true: from anyone, bots, forks and people outside the project too. Left out, only the project's members with Reporter access or more, never a bot, and for a merge request never one from a fork."}
	// mineProperty is only the connection's owner's own merge requests (#2034), a fork's too.
	mineProperty = property{Name: "mine", Kind: "boolean",
		Description: "true: only merge requests by the GitLab account this server is connected as, whatever anyone says."}
	// anyProperty is every one in the project (#3797): a wait that names none sets it.
	anyProperty = property{Name: "any", Kind: "boolean",
		Description: "true: every one in the project. A wait (not a workflow trigger) that names none, by the other arguments that say which, is refused without it. It is about which ones; anyone is about who."}
	// fixesProperty is the merge requests that close these issues (#3797): a lead knows a child's issue before its merge request.
	fixesProperty = property{Name: "fixes", Kind: "refs",
		Description: `Only merge requests whose description closes one of these issues, as "#12" (this project's) or "group/project#12".`,
		Pattern:     issueRefPattern, LooksLike: `issues, as "#12" or "group/project#12"`}
)

// ownMRs is what every merge request event says of whose merge requests it raises.
const ownMRs = " Only merge requests from a branch of the project itself, not a fork, by its members with Reporter access or more, never a bot, unless anyone is true."

func branchProperty(description string) property {
	return property{Name: "branch", Kind: "string", Description: description}
}

func object(props map[string]any) map[string]any {
	return map[string]any{"type": "object", "properties": props}
}

var str, integer = map[string]any{"type": "string"}, map[string]any{"type": "integer"}

func mrSchema(extra map[string]any) map[string]any {
	props := map[string]any{"number": integer, "title": str, "branch": str, "url": str, "fixes": fixesSchema}
	for k, v := range extra {
		props[k] = v
	}
	return object(props)
}

func mrInput() schema {
	return schema{projectProperty, branchProperty("Only the merge request from this branch."), prProperty, anyoneProperty}
}

// namedInput is mrInput for an event about one merge request: it names it by fixes or mine
// too, or takes any (#3797).
func namedInput() schema {
	return schema{projectProperty, branchProperty("Only the merge request from this branch."), prProperty, fixesProperty,
		anyoneProperty, mineProperty, anyProperty}
}

// events are the events this server offers, in the github server's order, with run.completed
// and deploy.waiting after checks.failed as there (#4217).
// fixesSchema is a merge request's fixes: the issues its description closes, "#12" or
// "group/project#12" (#2349).
var fixesSchema = map[string]any{"type": "array", "items": str}

var events = append([]event{
	{Name: "checks.failed", Title: "Pipeline failed",
		Description: "A merge request's pipeline finished failed: one event per pipeline and failure, so a pipeline retried that fails again is a new one. Jobs allowed to fail are not in failedJobs." + ownMRs,
		Input:       schema{projectProperty, branchProperty("Only pipelines of the merge request from this branch."), prProperty, fixesProperty, anyoneProperty, mineProperty, anyProperty},
		Payload: object(map[string]any{
			"pr": mrSchema(nil), "headSha": str,
			"run":        object(map[string]any{"id": integer, "name": str, "url": str}),
			"failedJobs": map[string]any{"type": "array", "items": object(map[string]any{"name": str, "url": str})},
		})},
	// A pipeline no merge request owns, as main's or a tag's, as the github server's (#3810, #4217).
	{Name: "run.completed", Title: "Pipeline finished",
		Description: "A GitLab CI/CD pipeline of the project finished, whatever started it (a push, a tag, a person, a schedule, the API) and whatever its status (success, failed, canceled, skipped): one event per pipeline and update time, so a pipeline retried is a new one. For a pipeline no merge request owns, such as main's or a tag's release; a merge request's failed pipelines are checks.failed. run.name is its name (workflow:name, or Pipeline #<id>), run.number its iid, run.event its source (push, web, schedule, api, trigger, merge_request_event…), run.branch its ref. Only pipelines started by the project's members with Reporter access or more, never a bot, unless anyone is true. deploys is what it deployed: each of its jobs with an environment: that deployed, as gitlab:<project>/<environment>/<deployment iid>.",
		Input: schema{projectProperty,
			property{Name: "pipeline", Kind: "string", Description: "Only pipelines of this name (workflow:name), as release."},
			branchProperty("Only pipelines of this branch or tag, as main or v0.16.0."),
			property{Name: "run", Kind: "integer", Description: "Only this pipeline, by its id."}, anyoneProperty, anyProperty},
		Payload: object(map[string]any{
			"run": object(map[string]any{"id": integer, "name": str, "number": integer, "event": str, "branch": str, "headSha": str,
				"url": str, "conclusion": str, "actor": str}),
			"completedAt": str,
			// What the pipeline deployed: its successful deployments (#4217).
			"deploys": map[string]any{"type": "array", "items": str},
		})},
	// A deploy held by a protected environment's approvals, as the github server's (#3587, #4217).
	{Name: "deploy.waiting", Title: "Deploy waiting for approval",
		Description: "A GitLab pipeline's job is waiting for an approver of a protected environment's deployment approvals (GitLab Premium), as a release pipeline's deploy job to production: one event per pipeline and set of blocked deployments, so the next environment it waits on is a new one. Each of environments is one blocked deployment, by its id, named by its environment, with the job's page as its url. reviewers are the approval rules still open, by GitLab's names for them; canApprove says whether the GitLab account this server is connected as may answer every one. Answer it on GitLab. Only pipelines started by the project's members with Reporter access or more, never a bot, unless anyone is true.",
		Input: schema{projectProperty,
			property{Name: "pipeline", Kind: "string", Description: "Only pipelines of this name (workflow:name), as release."},
			branchProperty("Only pipelines of this branch or tag, as main or v0.16.0."), anyoneProperty},
		Payload: object(map[string]any{
			"run": object(map[string]any{"id": integer, "name": str, "number": integer, "event": str, "branch": str, "headSha": str,
				"url": str, "actor": str}),
			"environments": map[string]any{"type": "array", "items": object(map[string]any{"id": integer, "name": str, "url": str})},
			"reviewers":    map[string]any{"type": "array", "items": str},
			"canApprove":   map[string]any{"type": "boolean"},
			"waitingSince": str,
		})},
	deployEvent("deploy.started", "Deploy started",
		"A GitLab deployment went running: a job with an environment: began to deploy, whatever started its pipeline. One event per deployment."),
	deployEvent("deploy.succeeded", "Deploy succeeded",
		"A GitLab deployment went success: a job with an environment: deployed. One event per deployment."),
	deployEvent("deploy.failed", "Deploy failed",
		"A GitLab deployment went failed or canceled: a job with an environment: did not deploy. One event per deployment. outcome is cancelled when GitLab says canceled, else failed."),
	{Name: "pr.opened", Title: "Merge request opened",
		Description: "A merge request was opened, or a draft was marked ready: a merge request open and not a draft now that was not at the last poll. Drafts never count. Reopened, it is raised again." + ownMRs,
		Input:       mrInput(),
		Payload:     object(map[string]any{"pr": mrSchema(map[string]any{"author": str}), "openedAt": str})},
	{Name: "pr.merged", Title: "Merge request merged", Description: "A merge request was merged." + ownMRs,
		Input:   namedInput(),
		Payload: object(map[string]any{"pr": mrSchema(nil), "mergedAt": str, "mergeSha": str})},
	{Name: "pr.closed", Title: "Merge request closed", Description: "A merge request was closed without being merged." + ownMRs,
		Input:   namedInput(),
		Payload: object(map[string]any{"pr": mrSchema(nil), "closedAt": str})},
	{Name: "pr.conflicted", Title: "Merge request in conflict",
		Description: "An open merge request began to conflict with its target branch, so it cannot merge until it is rebased. Once per conflict: it is raised again only after it merges cleanly and then conflicts anew." + ownMRs,
		Input:       namedInput(),
		Payload:     object(map[string]any{"pr": mrSchema(nil), "conflictedAt": str})},
	{Name: "pr.blocked", Title: "Merge request blocked",
		Description: mcpevents.BlockedDescription("On GitLab: detailed_merge_status, one reason at a time (conflict, need_rebase as behind, ci_must_pass as required_check_failed with the head pipeline, requested_changes); automerge_disabled is never read, as GitLab does not say who turned auto-merge off."+ownMRs),
		Input:       namedInput(),
		Payload:     mcpevents.BlockedPayload(mrSchema(nil))},
	// For the person, not the project (#2034): what asks the connection's owner for something.
	{Name: "review.requested", Title: "Review requested from me",
		Description: "The GitLab account this server is connected as was made a reviewer of an open merge request: once per request, so one taken off and put back is a new one. Anyone's merge request, a fork's too.",
		Input:       schema{projectProperty, prProperty},
		Payload:     object(map[string]any{"pr": mrSchema(map[string]any{"author": str}), "requestedAt": str})},
	{Name: "review.comment", Title: "Merge request line commented on",
		Description: "Someone left a comment on a line of a merge request's diff, or answered in its thread. Its body is the first 4000 characters. Only comments by the project's members with Reporter access or more, never a bot, unless anyone is true; and only on the project's own merge requests.",
		Input:       namedInput(),
		Payload: object(map[string]any{"pr": mrSchema(nil), "commentedAt": str,
			"comment": object(map[string]any{"id": integer, "author": str, "path": str, "line": integer, "body": str, "url": str})})},
}, append(issueEvents(), assignedEvent)...)

// assignedEvent is for the person, not the project (#2034): an issue given to the connection's owner.
var assignedEvent = event{Name: "issue.assigned", Title: "Issue assigned to me",
	Description: "An open issue was assigned to the GitLab account this server is connected as: once per assignment, so one unassigned and assigned again is a new one. Anyone's issue.",
	Input:       schema{projectProperty, property{Name: "issue", Kind: "integer", Description: "Only this issue, by number (its iid, as #12)."}},
	Payload: object(map[string]any{"issue": object(map[string]any{
		"number": integer, "title": str, "author": str, "labels": map[string]any{"type": "array", "items": str}, "url": str,
		"assignees": map[string]any{"type": "array", "items": str},
	}), "assignedAt": str})}

func issueEvents() []event {
	issueSchema := object(map[string]any{
		"number": integer, "title": str, "author": str, "labels": map[string]any{"type": "array", "items": str}, "url": str,
		"assignees": map[string]any{"type": "array", "items": str},
	})
	issue := property{Name: "issue", Kind: "integers", Description: "Only this issue, or these, by number (its iid, as #12)."}
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
		label := property{Name: "label", Kind: "string", Description: k.label}
		input := schema{projectProperty, label, issue, anyoneProperty, anyProperty}
		if k.kind == IssueOpened {
			input = schema{projectProperty, label, anyoneProperty}
		}
		description := k.description + " " + k.who + " the project's members with Reporter access or more, never a bot, unless anyone is true."
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
// it as an opaque string (base64url of its JSON).
type cursor = mcpevents.Cursor

func decodeCursor(raw json.RawMessage) (cursor, *rpcError) { return polls.Decode(raw) }

// MARK: Polling

// candidate is something that may be raised: its id, its time (in mcpevents.TimeLayout), and its data,
// looked up only once it is taken; nil data skips it, though the cursor still moves past it.
type candidate = mcpevents.Candidate

const (
	maxEvents  = mcpevents.MaxEvents
	nextPollMs = 30000
)

type pollParams = mcpevents.Params

// polls is how it polls, with GitLab's times and errors.
var polls = mcpevents.Poller{NextPollMs: nextPollMs, Normalize: mcpevents.Normalized, Fail: eventsError}

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
	if a.mine || e.Name == "review.requested" || e.Name == "issue.assigned" {
		y, err := s.GitLab.Yours(ctx, a.project)
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
				j := r.MR.json()
				j["author"] = r.Author
				out = append(out, state{mr: r.MR, on: new(true), json: j})
			}
			return out, nil
		})
	case "issue.assigned":
		return s.pollDiff(e.Name, "assignedAt", a, p, func() ([]state, error) {
			var out []state
			for _, i := range yours.Assigned {
				if a.wantsIssue(i.Number) {
					out = append(out, state{mr: MR{Number: i.Number, Title: i.Title, URL: i.URL}, on: new(true), json: i.json()})
				}
			}
			return out, nil
		})
	case "pr.conflicted":
		return s.pollDiff(e.Name, "conflictedAt", a, p, func() ([]state, error) {
			mrs, err := s.GitLab.OpenMRs(ctx, a.project)
			var out []state
			for _, m := range mrs {
				if a.mine {
					if a.byMe(m.MR, yours) {
						out = append(out, state{mr: m.MR, on: m.Conflicts, json: m.MR.json()})
					}
				} else if a.anyone || m.Trusted {
					out = append(out, state{mr: m.MR, on: m.Conflicts, json: m.MR.json()})
				}
			}
			return out, err
		})
	case "pr.blocked":
		was := polls.CursorIDs(p)
		return s.pollDiff(e.Name, "blockedAt", a, p, func() ([]state, error) {
			mrs, err := s.GitLab.OpenMRs(ctx, a.project)
			var out []state
			for _, m := range mrs {
				if m.SkipsBlocked || (a.mine && !a.byMe(m.MR, yours)) || (!a.mine && !a.anyone && !m.Trusted) {
					continue
				}
				bs := mcpevents.Blocked(fmt.Sprintf("%s:%s:%d", e.Name, a.project, m.MR.Number), m.Blocking, was)
				out = append(out, state{mr: m.MR, on: &bs.On, key: bs.Key, json: m.MR.json(), extra: bs.Data})
			}
			return out, err
		})
	case "pr.opened":
		return s.pollDiff(e.Name, "openedAt", a, p, func() ([]state, error) {
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
		return candidates(ctx, s.GitLab, e.Name, a, yours, since)
	})
}

// poll is events/poll over a cursor (mcpevents.Poller.Poll), from now on the first poll.
func (s *Events) poll(e event, p pollParams, find func(since string) ([]candidate, Listed, error)) (map[string]any, *rpcError) {
	return polls.Poll(e.Name, p, func() string { return mcpevents.TimeString(s.now()) },
		func(since string) ([]candidate, mcpevents.Listed, error) {
			found, listed, err := find(since)
			return found, mcpevents.Listed{Truncated: listed.Truncated, Newest: listed.Newest}, err
		})
}

func contains(list []string, s string) bool { return slices.Contains(list, s) }

// state is a merge request and whether its state (in conflict, or open and ready) is on now;
// nil keeps the one it had.
// key, when set, is part of its id and its envelope's key; extra is more of the event's data
// (pr.blocked's, #5321).
type state struct {
	mr    MR
	on    *bool
	json  map[string]any
	key   string
	extra map[string]any
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
			if !a.wantsPR(st.mr.Number) || (a.branch != "" && st.mr.Branch != a.branch) || !a.closesOne(st.mr) {
				continue
			}
			id := fmt.Sprintf("%s:%s:%d", name, a.project, st.mr.Number)
			if st.key != "" {
				id += ":" + st.key
			}
			data := map[string]any{root: st.json}
			for k, v := range st.extra {
				data[k] = v
			}
			out = append(out, mcpevents.State{ID: id, Number: st.mr.Number,
				On: st.on, Data: data, Subject: diffRef(root, a.project, st.mr.Number), Key: st.key})
		}
		return out, err
	})
}

// The refs of what gitlab's events happen to (#4728, spec 4724-event-bus, "A ref").
func prRef(project string, n int) wire.Ref {
	return mcpevents.Ref("gitlab", "mr", project, fmt.Sprint(n))
}
func pipelineRef(project string, id int) wire.Ref {
	return mcpevents.Ref("gitlab", "pipeline", project, fmt.Sprint(id))
}
func issueRef(project string, n int) wire.Ref {
	return mcpevents.Ref("gitlab", "issue", project, fmt.Sprint(n))
}

// diffRef is a state's subject: its issue for an issue's event, else its mr.
func diffRef(root, project string, n int) wire.Ref {
	if root == "issue" {
		return issueRef(project, n)
	}
	return prRef(project, n)
}

// candidates finds what an event may raise at or after since.
func candidates(ctx context.Context, gl GitLab, name string, a args, yours *Yours, since string) ([]candidate, Listed, error) {
	project := a.project
	// mine: the owner's own merge request, open or merged or closed, trusted or not; else the
	// trust filter (#728, #3797). fixes narrows every one by the issues it closes.
	wanted := func(m MR, trusted bool) bool {
		return a.wantsPR(m.Number) && (a.branch == "" || m.Branch == a.branch) && a.closesOne(m) &&
			(a.mine && a.byMe(m, yours) || !a.mine && (a.anyone || trusted))
	}
	if kind, ok := strings.CutPrefix(name, "issue."); ok {
		items, listed, err := gl.IssueActivity(ctx, project, IssueKind(kind), since)
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
			list = append(list, candidate{EventID: name + ":" + project + ":" + it.ID, Time: at,
				Data:    func() (map[string]any, error) { return it.data(), nil },
				Subject: issueRef(project, it.Issue.Number), Key: it.ID})
		}
		return list, listed, nil
	}
	if mcpevents.IsDeployEvent(name) {
		deploys, listed, err := gl.Deployments(ctx, project, a.deploy.Environment, since)
		if err != nil {
			return nil, Listed{}, err
		}
		return mcpevents.DeployCandidates(name, a.deploy, deploys), listed, nil
	}
	switch name {
	case "review.comment":
		comments, listed, err := gl.ReviewComments(ctx, project, since)
		if err != nil {
			return nil, Listed{}, err
		}
		var list []candidate
		for _, c := range comments {
			// Trust is the commenter's; mine only narrows the merge request (#3797).
			m := c.MR
			if at := mcpevents.Normalized(c.At); at != "" && a.wantsPR(m.Number) && (a.branch == "" || m.Branch == a.branch) &&
				a.closesOne(m) && a.byMe(m, yours) && (a.anyone || c.Trusted) {
				list = append(list, candidate{EventID: fmt.Sprintf("review.comment:%s:%d", project, c.ID), Time: at,
					Data:    func() (map[string]any, error) { return c.data(), nil },
					Subject: prRef(project, m.Number), Key: fmt.Sprint(c.ID)})
			}
		}
		return list, listed, nil
	case "run.completed":
		pipelines, listed, err := gl.FinishedPipelines(ctx, project, a.branch, a.run, since)
		if err != nil {
			return nil, Listed{}, err
		}
		// Its update time in the id: a pipeline retried that finishes again is a new event. Who
		// started it, its name and its deploys are read only for one that is taken.
		var list []candidate
		for _, pl := range pipelines {
			at := mcpevents.Normalized(pl.UpdatedAt)
			if at == "" || (a.pipeline != "" && pl.Listed != "" && !strings.EqualFold(pl.Listed, a.pipeline)) {
				continue
			}
			list = append(list, candidate{EventID: fmt.Sprintf("run.completed:%s:%d:%s", project, pl.ID, at), Time: at,
				Subject: pipelineRef(project, pl.ID), Key: at,
				Data: func() (map[string]any, error) {
					c, err := gl.CompletedPipeline(ctx, project, pl.ID)
					if err != nil || c == nil || (a.pipeline != "" && !strings.EqualFold(c.Name, a.pipeline)) || (!a.anyone && !c.Trusted) {
						return nil, err
					}
					deploys, err := gl.PipelineDeploys(ctx, project, *c)
					if err != nil {
						return nil, err
					}
					return c.data(deploys), nil
				}})
		}
		return list, listed, nil
	case "deploy.waiting":
		waiting, err := gl.WaitingDeploys(ctx, project, a.branch)
		if err != nil {
			return nil, Listed{}, err
		}
		var list []candidate
		for _, w := range waiting {
			if w.Since == "" || (a.pipeline != "" && w.Pipeline.Listed != "" && !strings.EqualFold(w.Pipeline.Listed, a.pipeline)) {
				continue
			}
			list = append(list, candidate{EventID: fmt.Sprintf("deploy.waiting:%s:%d:%s", project, w.Pipeline.ID, w.key()), Time: w.Since,
				Subject: pipelineRef(project, w.Pipeline.ID), Key: w.key(),
				Data: func() (map[string]any, error) {
					c, err := gl.CompletedPipeline(ctx, project, w.Pipeline.ID)
					if err != nil || c == nil || (a.pipeline != "" && !strings.EqualFold(c.Name, a.pipeline)) || (!a.anyone && !c.Trusted) {
						return nil, err
					}
					reviewers, canApprove, err := gl.Approvers(ctx, project, w)
					if err != nil {
						return nil, err
					}
					envs := make([]any, len(w.Environments))
					for i, e := range w.Environments {
						envs[i] = map[string]any{"id": e.ID, "name": e.Name, "url": e.URL}
					}
					return map[string]any{"run": c.run(), "environments": envs, "reviewers": reviewers,
						"canApprove": canApprove, "waitingSince": w.Since}, nil
				}})
		}
		return list, Listed{}, nil
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
			at := mcpevents.Normalized(pl.UpdatedAt)
			if at == "" {
				continue
			}
			list = append(list, candidate{EventID: fmt.Sprintf("checks.failed:%s:%d:%s", project, pl.ID, at), Time: at,
				Subject: pipelineRef(project, pl.ID), Key: at,
				Data: func() (map[string]any, error) {
					if pl.MRNumber != 0 && !a.wantsPR(pl.MRNumber) {
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
			if at := mcpevents.Normalized(m.MergedAt); wanted(m.MR, m.Trusted) && at != "" {
				list = append(list, candidate{EventID: fmt.Sprintf("pr.merged:%s:%d", project, m.MR.Number), Time: at,
					Subject: prRef(project, m.MR.Number),
					Data: func() (map[string]any, error) {
						return map[string]any{"pr": m.MR.json(), "mergedAt": m.MergedAt, "mergeSha": m.MergeSHA}, nil
					}})
			}
		}
		return list, listed, nil
	}
	// Its close time in the id: a merge request reopened and closed again is a new event.
	for _, c := range closed {
		if at := mcpevents.Normalized(c.ClosedAt); wanted(c.MR, c.Trusted) && at != "" {
			list = append(list, candidate{EventID: fmt.Sprintf("pr.closed:%s:%d:%s", project, c.MR.Number, at), Time: at,
				Subject: prRef(project, c.MR.Number), Key: at,
				Data: func() (map[string]any, error) {
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
