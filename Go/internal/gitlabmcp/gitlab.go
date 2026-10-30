package gitlabmcp

import (
	"context"
	"regexp"
	"strings"
	"time"
)

// What the events read from GitLab (#1629). RealGitLab reads it over the REST API v4 with a
// token; tests use a fake. A merge request is named as the github server names a pull request
// (pr, number), so a workflow's words are the same on both forges.

// MR is a merge request as every event names it: number is its iid, the number GitLab shows
// as !12.
type MR struct {
	Number int
	Title  string
	Branch string
	URL    string
	// Fixes is the issues its description says it closes (#2349), where the list read it.
	Fixes []string
}

func (m MR) json() map[string]any {
	j := map[string]any{"number": m.Number, "title": m.Title, "branch": m.Branch, "url": m.URL}
	if len(m.Fixes) > 0 {
		j["fixes"] = m.Fixes
	}
	return j
}

// closingPattern is GitLab's words that close an issue when the merge request merges, then
// the issue: #12 in its own project, or group/project#12.
var closingPattern = regexp.MustCompile(`(?i)\b(?:close[sd]?|closing|fix(?:e[sd]|ing)?|resolve[sd]?|resolving|implement(?:s|ed|ing)?):?\s+([A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)+)?#([0-9]{1,9})\b`)

// mostFixes bounds the issues read from one description.
const mostFixes = 20

// closingRefs is the issues a description closes, each once, in order: "#12", or
// "group/project#12" for another project's.
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

// OpenMR is an open merge request, drafts too, as pr.opened and pr.conflicted see it.
// Conflicts is nil while GitLab is still working it out. Here and below, Trusted says whether
// the merge request is the project's own: its branch in the project, not a fork, and its
// author a member with Reporter access or more, never a bot (#728).
type OpenMR struct {
	MR        MR
	Author    string
	Draft     bool
	Conflicts *bool
	Trusted   bool
}

// MergedMR is a merge request that merged.
type MergedMR struct {
	MR       MR
	MergedAt string
	MergeSHA string
	Trusted  bool
}

// ClosedMR is a merge request closed without being merged.
type ClosedMR struct {
	MR       MR
	ClosedAt string
	Trusted  bool
}

// Pipeline is a failed pipeline as listed, before its merge request and jobs are looked up.
type Pipeline struct {
	ID        int
	Name      string
	URL       string
	SHA       string
	Ref       string
	UpdatedAt string
	// MRNumber is the merge request its ref names (refs/merge-requests/12/head); 0 for a
	// branch pipeline, whose merge request is found by its commit.
	MRNumber int
}

// Job is a failed job of a pipeline.
type Job struct{ Name, URL string }

// FailedPipelineData is a checks.failed event's data: the pipeline's merge request and its
// failed jobs.
type FailedPipelineData struct {
	MR         MR
	Pipeline   Pipeline
	FailedJobs []Job
	Trusted    bool
}

func (d FailedPipelineData) json() map[string]any {
	jobs := make([]any, len(d.FailedJobs))
	for i, j := range d.FailedJobs {
		jobs[i] = map[string]any{"name": j.Name, "url": j.URL}
	}
	return map[string]any{
		"pr": d.MR.json(), "headSha": d.Pipeline.SHA,
		"run":        map[string]any{"id": d.Pipeline.ID, "name": d.Pipeline.Name, "url": d.Pipeline.URL},
		"failedJobs": jobs,
	}
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
	// Trusted says whether whoever did it is one of the project's own (#728).
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

// ReviewComment is a comment on a line of a merge request's diff, or an answer in its thread.
type ReviewComment struct {
	ID      int
	At      string
	MR      MR
	Author  string
	Path    string
	Line    int
	Body    string
	URL     string
	Trusted bool
}

func (c ReviewComment) data() map[string]any {
	return map[string]any{"pr": c.MR.json(), "commentedAt": c.At,
		"comment": map[string]any{"id": c.ID, "author": c.Author, "path": c.Path, "line": c.Line, "body": c.Body, "url": c.URL}}
}

// Listed is how far a listing read: Newest is the newest time of anything it listed, wanted
// or not (in timeLayout, "" when it listed nothing), and Truncated says it stopped at maxPages
// before it reached since.
type Listed struct {
	Newest    string
	Truncated bool
}

// saw is l with t seen too.
func (l Listed) saw(t string) Listed {
	if t = normalized(t); t > l.Newest {
		l.Newest = t
	}
	return l
}

// GitLab is what the events ask of GitLab.
type GitLab interface {
	// DefaultProject is the project the server's folder pushes to, as group/name.
	DefaultProject(ctx context.Context) (string, error)
	// OpenMRs are the open merge requests, drafts too, with whether each conflicts.
	OpenMRs(ctx context.Context, project string) ([]OpenMR, error)
	// ClosedMRs are merge requests merged, and closed without merging, at or after since.
	ClosedMRs(ctx context.Context, project, since string) (merged []MergedMR, closed []ClosedMR, listed Listed, err error)
	// FailedPipelines are failed pipelines updated at or after since, in any order.
	FailedPipelines(ctx context.Context, project, since string) (pipelines []Pipeline, listed Listed, err error)
	// PipelineDetails is the pipeline's merge request and failed jobs, or nil when it belongs to none.
	PipelineDetails(ctx context.Context, project string, p Pipeline) (*FailedPipelineData, error)
	// IssueActivity is what happened to the project's issues at or after since, of one kind.
	IssueActivity(ctx context.Context, project string, kind IssueKind, since string) (items []IssueActivity, listed Listed, err error)
	// ReviewComments are the comments on merge requests' diffs made at or after since.
	ReviewComments(ctx context.Context, project, since string) (comments []ReviewComment, listed Listed, err error)
	// Yours is what the connection's owner has in the project (#2034).
	Yours(ctx context.Context, project string) (Yours, error)
}

// Yours is what the connection's owner has in a project (#2034): their username, their open
// merge requests, the open ones they are a reviewer of, and the open issues assigned to them.
type Yours struct {
	Login    string
	MRs      []int
	Reviews  []OpenMR
	Assigned []Issue
}

func (y Yours) owns(mr int) bool {
	for _, n := range y.MRs {
		if n == mr {
			return true
		}
	}
	return false
}

// ErrorKind is why a GitLab call failed.
type ErrorKind int

const (
	NotSignedIn ErrorKind = iota
	RateLimited
	NotFound
	Failed
)

// GitLabError is a failed GitLab call.
type GitLabError struct {
	Kind         ErrorKind
	Message      string
	RetryAfterMs int
	// Refused is GitLab's no to this token for this project: 403 or 404, as a set-up says it.
	Refused bool
}

func (e *GitLabError) Error() string { return e.Message }

// commentChars is the most of a comment's body an event gives.
const commentChars = 4000

func clip(body string) string {
	r := []rune(body)
	if len(r) > commentChars {
		return string(r[:commentChars]) + "…"
	}
	return body
}

// Access levels of a project member, as GitLab numbers them.
const (
	reporterAccess = 20
)

// botName is a GitLab bot's username: a project or group access token's
// (project_12_bot_…), GitLab's own (ghost, support-bot, alert-bot…) or one named as a bot.
var botName = regexp.MustCompile(`^(project|group)_\d+_bot|[-_]bot$|^ghost$`)

func isBot(username string, bot bool) bool {
	return bot || botName.MatchString(strings.ToLower(username))
}

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
