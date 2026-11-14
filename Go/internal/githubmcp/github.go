package githubmcp

import (
	"context"
	"regexp"
	"strings"
)

// What the events read from GitHub, as CIWatcher's GitHub.swift has it (#383). RealGitHub
// reads it over the REST and GraphQL APIs with the gh sign-in's token; tests use a fake.

// PR is a pull request as every event names it.
type PR struct {
	Number int
	Title  string
	Branch string
	URL    string
	// Fixes is the issues its body says it closes (#2349), where the list read its body.
	Fixes []string
	// Author is who opened it, for mine on a PR no longer open (#3797); not in its JSON.
	Author string
}

func (p PR) json() map[string]any {
	j := map[string]any{"number": p.Number, "title": p.Title, "branch": p.Branch, "url": p.URL}
	if len(p.Fixes) > 0 {
		j["fixes"] = p.Fixes
	}
	return j
}

// closingPattern is GitHub's keywords that close an issue when the PR merges, then the
// issue: #12 in the PR's own repo, or owner/repo#12.
var closingPattern = regexp.MustCompile(`(?i)\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?):?\s+([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#([0-9]{1,9})\b`)

// mostFixes bounds the issues read from one body.
const mostFixes = 20

// closingRefs is the issues a PR's body closes, each once, in order: "#12", or
// "owner/repo#12" for another repo's.
func closingRefs(body string) []string {
	var out []string
	seen := map[string]bool{}
	for _, m := range closingPattern.FindAllStringSubmatch(body, -1) {
		ref := m[1] + "#" + strings.TrimLeft(m[2], "0")
		if strings.HasSuffix(ref, "#") || seen[strings.ToLower(ref)] {
			continue
		}
		seen[strings.ToLower(ref)] = true
		out = append(out, ref)
		if len(out) == mostFixes {
			break
		}
	}
	return out
}

// RunRef is a finished run as listed, before its PR and jobs are looked up.
type RunRef struct {
	ID        int
	Attempt   int
	Name      string
	URL       string
	HeadSHA   string
	Branch    string
	PRNumber  int // 0 when the run names none
	UpdatedAt string
	// CreatedAt is when the run was made, by the push that started it; a rerun keeps it (#4554).
	CreatedAt string
}

// Job is a failed job of a run.
type Job struct{ Name, URL string }

// RunData is a checks.failed or checks.passed event's data: the run's PR, and, for
// checks.failed, its failed jobs.
type RunData struct {
	PR         PR
	HeadSHA    string
	Run        RunRef
	FailedJobs []Job
	// Trusted says whether the PR is the repo's own: not a fork, by one of its own (#728).
	Trusted bool
}

func (d RunData) run() map[string]any {
	return map[string]any{
		"pr": d.PR.json(), "headSha": d.HeadSHA,
		"run": map[string]any{"id": d.Run.ID, "attempt": d.Run.Attempt, "name": d.Run.Name, "url": d.Run.URL, "createdAt": d.Run.CreatedAt},
		// When the run finished: the daemon's CI time to green (#4554).
		"completedAt": d.Run.UpdatedAt,
	}
}

// json is checks.failed's payload: the run, and its failed jobs.
func (d RunData) json() map[string]any {
	jobs := make([]any, len(d.FailedJobs))
	for i, j := range d.FailedJobs {
		jobs[i] = map[string]any{"name": j.Name, "url": j.URL}
	}
	j := d.run()
	j["failedJobs"] = jobs
	return j
}

// passedJSON is checks.passed's payload: the run, with no failedJobs.
func (d RunData) passedJSON() map[string]any { return d.run() }

// CompletedRun is a finished workflow run of any trigger, as run.completed sees it (#3444): a
// tag's release.yml or a workflow_dispatch run, which no pull request owns.
type CompletedRun struct {
	Run RunRef
	// CheckSuite is the run's check suite, whose check runs (its jobs) carry its annotations.
	CheckSuite int
	// Workflow is the workflow's file name, as release.yml; Event is what started it, as push.
	Workflow, Event, Conclusion, Actor string
	// Trusted says whether the run is the repo's own: not from a fork, and started by a person,
	// not a bot (#728).
	Trusted bool
}

// data is run.completed's payload; deploys are what the run says it deployed (#3584).
func (c CompletedRun) data(deploys []string) map[string]any {
	if deploys == nil {
		deploys = []string{}
	}
	return map[string]any{"run": map[string]any{
		"id": c.Run.ID, "attempt": c.Run.Attempt, "name": c.Run.Name, "workflow": c.Workflow, "event": c.Event,
		"branch": c.Run.Branch, "headSha": c.Run.HeadSHA, "url": c.Run.URL, "conclusion": c.Conclusion, "actor": c.Actor,
	}, "completedAt": c.Run.UpdatedAt, "deploys": deploys}
}

// OpenPR is an open pull request, drafts too, as pr.opened sees it (#833). Here and in the
// PRs below, Trusted says whether the PR is the repo's own: its branch not in a fork, and its
// author the repo's owner, a member or a collaborator, not a bot (#728).
type OpenPR struct {
	PR      PR
	Author  string
	Draft   bool
	Trusted bool
}

// MergedPR is a pull request that merged.
type MergedPR struct {
	PR       PR
	MergedAt string
	MergeSHA string
	Trusted  bool
}

// ClosedPR is a pull request closed without being merged.
type ClosedPR struct {
	PR       PR
	ClosedAt string
	Trusted  bool
}

// ConflictPR is an open pull request and whether it conflicts with its base (#712): nil while
// GitHub is still working it out.
type ConflictPR struct {
	PR        PR
	Conflicts *bool
	Trusted   bool
}

// Issue is an issue as the issue events name it.
type Issue struct {
	Number    int
	Title     string
	Author    string
	Labels    []string
	URL       string
	Assignees []string
}

func (i Issue) json() map[string]any {
	labels, assignees := i.Labels, i.Assignees
	if labels == nil {
		labels = []string{}
	}
	if assignees == nil {
		assignees = []string{}
	}
	return map[string]any{"number": i.Number, "title": i.Title, "author": i.Author, "labels": labels, "url": i.URL,
		"assignees": assignees}
}

// IssueKind is what happened to an issue.
type IssueKind string

const (
	IssueOpened    IssueKind = "opened"
	IssueLabelled  IssueKind = "labelled"
	IssueCommented IssueKind = "commented"
	IssueClosed    IssueKind = "closed"
)

// IssueActivity is one thing that happened to an issue (never a pull request).
type IssueActivity struct {
	ID    string
	At    string
	Issue Issue
	Kind  IssueKind
	// Label and By for a label; By and Reason (completed or not_planned) for a close.
	Label, By, Reason string
	// CommentAuthor, CommentURL and CommentBody (clipped) for a comment.
	CommentAuthor, CommentURL, CommentBody string
	// Trusted says whether whoever did it is one of the repo's own (#728).
	Trusted bool
}

func (a IssueActivity) data() map[string]any {
	d := map[string]any{"issue": a.Issue.json()}
	switch a.Kind {
	case IssueOpened:
		d["openedAt"] = a.At
	case IssueLabelled:
		d["label"], d["by"], d["labelledAt"] = a.Label, a.By, a.At
	case IssueCommented:
		d["comment"] = map[string]any{"author": a.CommentAuthor, "url": a.CommentURL, "body": a.CommentBody}
		d["commentedAt"] = a.At
	case IssueClosed:
		d["reason"], d["by"], d["closedAt"] = a.Reason, a.By, a.At
	}
	return d
}

// PRLabelKind is what happened to a pull request's labels.
type PRLabelKind string

const (
	PRLabelled   PRLabelKind = "labelled"
	PRUnlabelled PRLabelKind = "unlabelled"
)

// PRLabelActivity is a label added to or removed from a pull request (never an issue).
type PRLabelActivity struct {
	ID    string
	At    string
	PR    PR
	Kind  PRLabelKind
	Label string
	By    string
	// Trusted says whether whoever changed the label is one of the repo's own (#728).
	Trusted bool
}

func (a PRLabelActivity) data() map[string]any {
	key := "labelledAt"
	if a.Kind == PRUnlabelled {
		key = "unlabelledAt"
	}
	return map[string]any{"pr": a.PR.json(), "label": a.Label, "by": a.By, key: a.At}
}

// PRComment is a comment on a pull request's conversation (not a review comment on a line of
// its diff, which review.comment covers).
type PRComment struct {
	ID      int
	PR      PR
	Author  string
	Body    string
	URL     string
	At      string
	Trusted bool
	// Other is a comment that is never raised (an agent's own, an issue's, or another PR's when
	// the wait names one): only its ID and At are set, so the cursor still moves past it.
	Other bool
}

// agentCommentPrefix marks a comment the agents posted themselves, not a person (#2838): every
// PR and comment is posted as alexec, so a comment's own words are the only way to tell them apart.
const agentCommentPrefix = "<!-- agent -->"

func (c PRComment) data() map[string]any {
	return map[string]any{"pr": c.PR.json(),
		"comment": map[string]any{"author": c.Author, "url": c.URL, "body": c.Body}, "commentedAt": c.At}
}

// GitHub is what the events ask of GitHub.
type GitHub interface {
	// FailedRuns are failed pull_request runs updated at or after since, in any order.
	FailedRuns(ctx context.Context, repo, branch, since string) (runs []RunRef, truncated bool, err error)
	// PassedRuns are successful pull_request runs updated at or after since, in any order.
	PassedRuns(ctx context.Context, repo, branch, since string) (runs []RunRef, truncated bool, err error)
	// RunDetails is the run's PR, and its failed jobs when jobs is true, or nil when it belongs to
	// no PR. checks.passed asks for no jobs: its payload has none (#3107).
	RunDetails(ctx context.Context, repo string, run RunRef, jobs bool) (*RunData, error)
	// CompletedRuns are workflow runs of any trigger and conclusion that finished at or after since,
	// in any order (#3444): only workflow's (a file name) when it is set, only branch's (a branch or a
	// tag) when it is set, and only run id when it is not 0.
	CompletedRuns(ctx context.Context, repo, workflow, branch string, run int, since string) (runs []CompletedRun, truncated bool, err error)
	// RunDeploys are what a finished run says it deployed (#3584): the message of each notice
	// titled deploy that its jobs wrote (::notice title=deploy::testflight:<bundle id>/<build>).
	RunDeploys(ctx context.Context, repo string, run CompletedRun) ([]string, error)
	// WaitingDeploys are runs waiting for an environment's required reviewers (#3587): only
	// workflow's (a file name) when it is set, only branch's (a branch or a tag) when it is set.
	WaitingDeploys(ctx context.Context, repo, workflow, branch string) ([]WaitingDeploy, error)
	// Deployments are the repo's Deployments updated at or after since, with their statuses
	// oldest first (#5240): only environment's when it is set.
	Deployments(ctx context.Context, repo, environment, since string) ([]Deployment, error)
	// JobConclusion is an Actions job's conclusion, as cancelled: what a failed deploy's job ended as.
	JobConclusion(ctx context.Context, repo string, job int64) (string, error)
	// JobDeploys are the deploy notices one Actions job wrote (#5241), as RunDeploys reads a run's:
	// what an ended deploy's job says it deployed, and where.
	JobDeploys(ctx context.Context, repo string, job int64) ([]string, error)
	// PRBranch is the head branch of PR number pr. checks.failed and checks.passed with a pr and
	// no branch list only that branch's runs, not the whole repo's (#3107).
	PRBranch(ctx context.Context, repo string, pr int) (string, error)
	// DefaultRepo is the repo the server's folder pushes to, owner/name (#702).
	DefaultRepo(ctx context.Context) (string, error)
	// ClosedPRs are PRs merged, and PRs closed without merging, at or after since.
	ClosedPRs(ctx context.Context, repo, since string) (merged []MergedPR, closed []ClosedPR, truncated bool, err error)
	// ConflictPRs are the open PRs and whether each conflicts with its base.
	ConflictPRs(ctx context.Context, repo string) ([]ConflictPR, error)
	// OpenPRs are the open PRs, drafts too, with their authors.
	OpenPRs(ctx context.Context, repo string) ([]OpenPR, error)
	// IssueActivity is what happened to the repo's issues at or after since, of one kind.
	IssueActivity(ctx context.Context, repo string, kind IssueKind, since string) (items []IssueActivity, truncated bool, err error)
	// PRLabelActivity is a label added to or removed from a pull request at or after since.
	PRLabelActivity(ctx context.Context, repo string, kind PRLabelKind, since string) (items []PRLabelActivity, truncated bool, err error)
	// PRComments are comments left on pull requests' conversations (not CodeRabbitComments' review
	// comments on a line) at or after since. An agent's own, an issue's, and another PR's when pr
	// is not 0 are Other, with nothing fetched for them.
	PRComments(ctx context.Context, repo, since string, pr int) (comments []PRComment, truncated bool, err error)
	// PRReviews are people's and bots' reviews of the open PRs submitted at or after since (#3860),
	// only PR number pr's when it is not 0.
	PRReviews(ctx context.Context, repo, since string, pr int) ([]PRReview, error)
	// CodeRabbitPRs are the open PRs and whether CodeRabbit has reviewed each one's head commit (#1344).
	CodeRabbitPRs(ctx context.Context, repo string) ([]ReviewedPR, error)
	// CodeRabbitComments are CodeRabbit's review comments made at or after since.
	CodeRabbitComments(ctx context.Context, repo, since string) (comments []CodeRabbitComment, truncated bool, err error)
	// Yours is what the connection's owner has in the repo (#2034).
	Yours(ctx context.Context, repo string) (Yours, error)
}

// Yours is what the connection's owner has in a repo (#2034): their login, their open PRs, the
// open PRs that ask them for a review, and the open issues assigned to them.
type Yours struct {
	Login    string
	PRs      []int
	Reviews  []OpenPR
	Assigned []Issue
}

func (y Yours) owns(pr int) bool {
	for _, n := range y.PRs {
		if n == pr {
			return true
		}
	}
	return false
}

// ownsPR says whether p is the owner's: one of their open PRs, or a PR by them or by their
// agents' bot, <login>-agents (#3860).
func (y Yours) ownsPR(p PR) bool {
	if y.owns(p.Number) {
		return true
	}
	if p.Author == "" || y.Login == "" {
		return false
	}
	return strings.EqualFold(p.Author, y.Login) || strings.EqualFold(strings.TrimSuffix(p.Author, "[bot]"), y.Login+"-agents")
}

// ErrorKind is why a GitHub call failed.
type ErrorKind int

const (
	NotSignedIn ErrorKind = iota
	RateLimited
	NotFound
	Failed
)

// GitHubError is a failed GitHub call.
type GitHubError struct {
	Kind         ErrorKind
	Message      string
	RetryAfterMs int
	// Refused is GitHub's own no (403 that is not a rate limit, or 404): the token reaches
	// GitHub but not this, such as a repository where the App is not installed.
	Refused bool
}

func (e *GitHubError) Error() string { return e.Message }

// commentChars is the most of a comment's body an event gives.
const commentChars = 4000

func clip(body string) string {
	r := []rune(body)
	if len(r) > commentChars {
		return string(r[:commentChars]) + "…"
	}
	return body
}

// isTrusted says whether GitHub's author_association and account make someone the repo's
// own (#728): its owner, a member of its organisation or a collaborator, and not a bot.
func isTrusted(association, login, typ string) bool {
	bot := typ == "Bot" || strings.HasSuffix(login, "[bot]")
	switch strings.ToUpper(association) {
	case "OWNER", "MEMBER", "COLLABORATOR":
		return !bot
	}
	return false
}

// isAgentsBot says whether an account is a person's agents' bot (#3858): the App that
// connections.BotName names <login>-agents, which REST gives as <login>-agents[bot] and
// GraphQL as the Bot <login>-agents. A bot acts only where an admin installed it.
func isAgentsBot(login, typ string) bool {
	return (typ == "Bot" || strings.HasSuffix(login, "[bot]")) &&
		(strings.HasSuffix(login, "-agents[bot]") || typ == "Bot" && strings.HasSuffix(login, "-agents"))
}

// isOwnAuthor says whether an issue or a pull request is the repo's own (#728): a person's
// who is trusted, or their agents' bot's (#3860), so a lane's wait on its PR still wakes once
// the bot opens it. The bot's comments are not: they are the agents' own, never a person's.
func isOwnAuthor(association, login, typ string) bool {
	return isTrusted(association, login, typ) || isAgentsBot(login, typ)
}

// isTrustedActor says whether a label or a close was the repo's own doing (#728). Labelling
// takes triage access, so a person who did it is trusted; closing does not, since an author
// may close their own. The agents' bot labels as its person does (#3860).
func isTrustedActor(actor, typ string, closing bool, issueAuthor string, authorTrusted bool) bool {
	if isAgentsBot(actor, typ) {
		return !closing || actor != issueAuthor || authorTrusted
	}
	if typ == "Bot" || strings.HasSuffix(actor, "[bot]") {
		return false
	}
	return !closing || actor != issueAuthor || authorTrusted
}

func reasonOf(reason string) string {
	if reason == "not_planned" {
		return "not_planned"
	}
	return "completed"
}

func isFailed(conclusion string) bool {
	switch strings.ToLower(conclusion) {
	case "failure", "timed_out", "startup_failure":
		return true
	}
	return false
}

func isSucceeded(conclusion string) bool { return strings.EqualFold(conclusion, "success") }
