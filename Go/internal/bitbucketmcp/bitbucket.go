package bitbucketmcp

import (
	"context"
	"regexp"
	"strings"

	"github.com/agentloops-dev/agent-loops/Go/internal/mcpevents"
)

// What the events read from Bitbucket Cloud (#2828), in the gitlab server's shape
// (Go/internal/gitlabmcp/gitlab.go) and the forgejo server's (Go/internal/forgejomcp).
// RealBitbucket reads it over the REST API 2.0 with a token; tests use a fake.

// PR is a pull request as every event names it.
type PR struct {
	Number int
	Title  string
	Branch string
	URL    string
	// Fixes is the issues its description says it closes (#2349), where the list read it.
	Fixes []string
	// Author is who opened it, for mine on a pull request no longer open (#3797); not in its JSON.
	Author string
}

func (p PR) json() map[string]any {
	j := map[string]any{"number": p.Number, "title": p.Title, "branch": p.Branch, "url": p.URL}
	if len(p.Fixes) > 0 {
		j["fixes"] = p.Fixes
	}
	return j
}

// closingPattern is Bitbucket's words that close an issue when the pull request merges, then
// the issue: #12 in its own repository, or workspace/name#12.
var closingPattern = regexp.MustCompile(`(?i)\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?):?\s+(?:issue\s+)?([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#([0-9]{1,9})\b`)

// mostFixes bounds the issues read from one description.
const mostFixes = 20

// closingRefs is the issues a description closes, each once, in order: "#12", or
// "workspace/name#12" for another repository's.
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

// OpenPR is an open pull request, drafts too, as pr.opened and pr.conflicted see it.
// Conflicts is nil when it was not read: only when asked, and for the maxChecked updated
// last. Here and below, Trusted says whether the pull request is the repository's own: its
// branch in the repository, not a fork, and its author a person with write access or more,
// never an app or a bot (#728).
type OpenPR struct {
	PR        PR
	Author    string
	Draft     bool
	Conflicts *bool
	HeadSHA   string
	Trusted   bool
	// SkipsBlocked is a draft, or one labelled needs-approval: never pr.blocked (#5321).
	// ChangesRequested is a reviewer asking its author for changes, where the forge says it.
	SkipsBlocked     bool
	ChangesRequested bool
}

// blocking is why it cannot merge until its author acts (pr.blocked, #5321): a conflict not
// yet worked out keeps the state it had.
func (o OpenPR) blocking() mcpevents.Blocking {
	b := mcpevents.Blocking{HeadSHA: o.HeadSHA, ChangesRequested: o.ChangesRequested}
	if o.Conflicts == nil {
		b.Unknown = true
	} else {
		b.Conflict = *o.Conflicts
	}
	if b.ChangesRequested {
		b.ReviewURL = o.PR.URL
	}
	return b
}

// MergedPR is a pull request that merged.
type MergedPR struct {
	PR       PR
	MergedAt string
	MergeSHA string
	Trusted  bool
}

// ClosedPR is a pull request declined: closed without being merged.
type ClosedPR struct {
	PR       PR
	ClosedAt string
	Trusted  bool
}

// Check is one failed commit status: Bitbucket Pipelines' or any CI's.
type Check struct{ Name, URL string }

// FailedChecks is a checks.failed event's data: an open pull request whose head commit has a
// failed status, and its failed statuses. At is the newest of their times, so a check run
// again that fails again is a new one.
type FailedChecks struct {
	PR      PR
	HeadSHA string
	At      string
	// RunID is the Pipelines run (its build number) the first failed status links to, 0 for another CI.
	RunID   int
	RunName string
	RunURL  string
	Failed  []Check
	Trusted bool
}

func (d FailedChecks) json() map[string]any {
	jobs := make([]any, len(d.Failed))
	for i, j := range d.Failed {
		jobs[i] = map[string]any{"name": j.Name, "url": j.URL}
	}
	return map[string]any{
		"pr": d.PR.json(), "headSha": d.HeadSHA,
		"run":        map[string]any{"id": d.RunID, "name": d.RunName, "url": d.RunURL},
		"failedJobs": jobs,
	}
}

// Issue is an issue as the issue events name it. Bitbucket's issues have no labels: Labels
// are its kind (bug, enhancement, proposal, task) and its component.
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

// IssueActivity is one thing that happened to an issue.
type IssueActivity struct {
	ID    string
	At    string
	Issue Issue
	Kind  IssueKind
	// By for a close or a label added; Label for a label added.
	By, Label string
	// CommentAuthor, CommentURL and CommentBody (clipped) for a comment.
	CommentAuthor, CommentURL, CommentBody string
	// Trusted says whether whoever did it is one of the repository's own (#728).
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
		d["by"], d["closedAt"] = a.By, a.At
	}
	return d
}

// ReviewComment is a comment on a line of a pull request's diff, or an answer in its thread.
type ReviewComment struct {
	ID      int
	At      string
	PR      PR
	Author  string
	Path    string
	Line    int
	Body    string
	URL     string
	Trusted bool
}

func (c ReviewComment) data() map[string]any {
	return map[string]any{"pr": c.PR.json(), "commentedAt": c.At,
		"comment": map[string]any{"id": c.ID, "author": c.Author, "path": c.Path, "line": c.Line, "body": c.Body, "url": c.URL}}
}

// Listed is how far a listing read (mcpevents.Listed): Newest is the newest time of anything it
// listed, wanted or not (in mcpevents.TimeLayout, "" when it listed nothing), and Truncated says
// it stopped at maxPages before it reached since.
type Listed = mcpevents.Listed

// Bitbucket is what the events ask of Bitbucket Cloud.
type Bitbucket interface {
	// DefaultRepo is the repository the server's folder pushes to, as workspace/name.
	DefaultRepo(ctx context.Context) (string, error)
	// OpenPRs are the open pull requests, drafts too; withConflicts, with whether each conflicts.
	OpenPRs(ctx context.Context, repo string, withConflicts bool) ([]OpenPR, error)
	// ClosedPRs are pull requests merged, and declined, at or after since.
	ClosedPRs(ctx context.Context, repo, since string) (merged []MergedPR, closed []ClosedPR, listed Listed, err error)
	// FailedChecks are the open pull requests whose head commit failed its checks, in any order.
	FailedChecks(ctx context.Context, repo, since string) (failed []FailedChecks, listed Listed, err error)
	// CompletedPipelines are the Pipelines runs that finished at or after since, of pipeline
	// (its name), branch (or tag) and run (a build number) when each is set (#4217).
	CompletedPipelines(ctx context.Context, repo, pipeline, branch string, run int, since string) (pipelines []CompletedPipeline, listed Listed, err error)
	// PipelineDeploys are what a finished run deployed, as deploy refs.
	PipelineDeploys(ctx context.Context, repo string, c CompletedPipeline) ([]string, error)
	// Deployments are the repository's newest deployments, in the deploy model (#5244).
	Deployments(ctx context.Context, repo string) ([]mcpevents.ForgeDeploy, error)
	// IssueActivity is what happened to the repository's issues at or after since, of one kind.
	IssueActivity(ctx context.Context, repo string, kind IssueKind, since string) (items []IssueActivity, listed Listed, err error)
	// ReviewComments are the comments on pull requests' diffs made at or after since.
	ReviewComments(ctx context.Context, repo, since string) (comments []ReviewComment, listed Listed, err error)
	// Yours is what the token's owner has in the repository (#2034).
	Yours(ctx context.Context, repo string) (Yours, error)
}

// Yours is what the token's owner has in a repository (#2034): their name, their open pull
// requests, the open ones they are asked to review, and the open issues assigned to them.
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

// ErrorKind is why a Bitbucket call failed.
type ErrorKind int

const (
	NotSignedIn ErrorKind = iota
	RateLimited
	NotFound
	Failed
)

// BitbucketError is a failed Bitbucket call.
type BitbucketError struct {
	Kind         ErrorKind
	Message      string
	RetryAfterMs int
	// Refused is Bitbucket's no to this token for this repository: 403 or 404.
	Refused bool
}

func (e *BitbucketError) Error() string { return e.Message }

// commentChars is the most of a comment's body an event gives.
const commentChars = 4000

func clip(body string) string {
	r := []rune(body)
	if len(r) > commentChars {
		return string(r[:commentChars]) + "…"
	}
	return body
}

// botName is a bot's name: Renovate's, Dependabot's and others named as one.
var botName = regexp.MustCompile(`[-_]bot$|\[bot\]$`)

// isBot says whether an account is a bot: an app (an access token's own user, a Forge or
// Connect app, Pipelines), a team, or one named as a bot.
func isBot(name, kind string) bool {
	return (kind != "" && kind != "user") || botName.MatchString(strings.ToLower(name))
}
