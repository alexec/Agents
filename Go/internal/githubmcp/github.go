package githubmcp

import (
	"context"
	"regexp"
	"strings"
	"time"
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
		"run": map[string]any{"id": d.Run.ID, "attempt": d.Run.Attempt, "name": d.Run.Name, "url": d.Run.URL},
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

// GitHub is what the events ask of GitHub.
type GitHub interface {
	// FailedRuns are failed pull_request runs updated at or after since, in any order.
	FailedRuns(ctx context.Context, repo, branch, since string) (runs []RunRef, truncated bool, err error)
	// PassedRuns are successful pull_request runs updated at or after since, in any order.
	PassedRuns(ctx context.Context, repo, branch, since string) (runs []RunRef, truncated bool, err error)
	// RunDetails is the run's PR and its failed jobs, or nil when it belongs to no PR.
	RunDetails(ctx context.Context, repo string, run RunRef) (*RunData, error)
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

// isTrustedActor says whether a label or a close was the repo's own doing (#728). Labelling
// takes triage access, so a person who did it is trusted; closing does not, since an author
// may close their own.
func isTrustedActor(actor, typ string, closing bool, issueAuthor string, authorTrusted bool) bool {
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

// timeLayout is how the events draft carries a time: ISO 8601 in UTC with milliseconds, which
// sorts as text in time order.
const timeLayout = "2006-01-02T15:04:05.000Z"

func timeString(t time.Time) string { return t.UTC().Format(timeLayout) }

func parseTime(text string) (time.Time, bool) {
	t, err := time.Parse(time.RFC3339Nano, text)
	return t, err == nil
}

// normalized is text in timeLayout, or "" when it is not a time.
func normalized(text string) string {
	t, ok := parseTime(text)
	if !ok {
		return ""
	}
	return timeString(t)
}

// before says whether a is earlier than b; a time that is not one is earliest of all.
func before(a, b string) bool {
	ta, oka := parseTime(a)
	tb, okb := parseTime(b)
	switch {
	case !oka:
		return okb
	case !okb:
		return false
	}
	return ta.Before(tb)
}
