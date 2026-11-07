package azuredevopsmcp

import (
	"context"
	"regexp"
	"strings"
	"time"
)

// What the events read from Azure DevOps (#2829), in the gitlab server's shape
// (Go/internal/gitlabmcp/gitlab.go). RealAzureDevOps reads it over the REST API (7.1) with a
// personal access token; tests use a fake. dev.azure.com and Azure DevOps Server share that
// API, so one server is for both.

// PR is a pull request as every event names it.
type PR struct {
	Number int
	Title  string
	Branch string
	URL    string
	// Fixes is the work items its description says it closes (#2349), where the list read it.
	Fixes []string
}

func (p PR) json() map[string]any {
	j := map[string]any{"number": p.Number, "title": p.Title, "branch": p.Branch, "url": p.URL}
	if len(p.Fixes) > 0 {
		j["fixes"] = p.Fixes
	}
	return j
}

// closingPattern is the words that close a work item when the pull request merges, then the
// work item: #12, or AB#12 as Azure Boards writes one from GitHub.
var closingPattern = regexp.MustCompile(`(?i)\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?):?\s+(?:AB)?#([0-9]{1,9})\b`)

// mostFixes bounds the work items read from one description.
const mostFixes = 20

// closingRefs is the work items a description closes, each once, in order: "#12".
func closingRefs(body string) []string {
	var out []string
	seen := map[string]bool{}
	for _, m := range closingPattern.FindAllStringSubmatch(body, -1) {
		ref := "#" + strings.TrimLeft(m[1], "0")
		if ref == "#" || seen[ref] {
			continue
		}
		seen[ref] = true
		out = append(out, ref)
		if len(out) == mostFixes {
			break
		}
	}
	return out
}

// OpenPR is an active pull request, drafts too, as pr.opened and pr.conflicted see it.
// Conflicts is nil while Azure DevOps is still working it out. Here and below, Trusted says
// whether the pull request is the repository's own: its branch in the repository, not a
// fork, and its author not a bot (#728). Azure DevOps lets only a project's members write to
// it, so no one else can open a pull request or comment on one.
type OpenPR struct {
	PR        PR
	Author    string
	Draft     bool
	Conflicts *bool
	HeadSHA   string
	Trusted   bool
}

// MergedPR is a pull request that was completed.
type MergedPR struct {
	PR       PR
	MergedAt string
	MergeSHA string
	Trusted  bool
}

// ClosedPR is a pull request abandoned without being merged.
type ClosedPR struct {
	PR       PR
	ClosedAt string
	Trusted  bool
}

// Check is one Azure Pipelines build, or one status another service set: its pipeline's
// name or the status's genre/name, and its page.
type Check struct{ Name, URL string }

// FailedChecks is a checks.failed event's data: an active pull request whose head commit's
// builds or statuses failed, and those. At is the newest of their times, so a build run
// again that fails again is a new one.
type FailedChecks struct {
	PR      PR
	HeadSHA string
	At      string
	// RunID is the first failed build's id, RunName its pipeline's name; with no failed
	// build, RunID is 0 and RunName the first failed status's name.
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

// PassedCheck is a checks.passed event's data: a build or a status that passed at an active
// pull request's head commit. Key is build:<id> or status:<id>; RunID is 0 for a status.
type PassedCheck struct {
	PR      PR
	HeadSHA string
	At      string
	Key     string
	RunID   int
	RunName string
	RunURL  string
	Trusted bool
}

func (d PassedCheck) json() map[string]any {
	return map[string]any{"pr": d.PR.json(), "headSha": d.HeadSHA,
		"run": map[string]any{"id": d.RunID, "name": d.RunName, "url": d.RunURL}}
}

// ReviewComment is a comment on a line of a pull request's diff, or an answer in its thread.
// ID is the comment's number in its thread, ThreadID the thread's.
type ReviewComment struct {
	ID       int
	ThreadID int
	At       string
	PR       PR
	Author   string
	Path     string
	Line     int
	Body     string
	URL      string
	Trusted  bool
}

func (c ReviewComment) data() map[string]any {
	return map[string]any{"pr": c.PR.json(), "commentedAt": c.At,
		"comment": map[string]any{"id": c.ID, "threadId": c.ThreadID, "author": c.Author, "path": c.Path, "line": c.Line,
			"body": c.Body, "url": c.URL}}
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

// AzureDevOps is what the events ask of Azure DevOps.
type AzureDevOps interface {
	// DefaultRepo is the repository the server's folder pushes to, as organization/project/name.
	DefaultRepo(ctx context.Context) (string, error)
	// OpenPRs are the active pull requests, drafts too, with whether each conflicts.
	OpenPRs(ctx context.Context, repo string) ([]OpenPR, error)
	// ClosedPRs are pull requests completed, and abandoned, at or after since.
	ClosedPRs(ctx context.Context, repo, since string) (merged []MergedPR, closed []ClosedPR, listed Listed, err error)
	// FailedChecks are the active pull requests whose head commit failed a build or a status
	// at or after since, in any order.
	FailedChecks(ctx context.Context, repo, since string) (failed []FailedChecks, listed Listed, err error)
	// PassedChecks are the builds and statuses that passed at an active pull request's head
	// commit at or after since, in any order.
	PassedChecks(ctx context.Context, repo, since string) (passed []PassedCheck, listed Listed, err error)
	// ReviewComments are the comments on pull requests' diffs made at or after since.
	ReviewComments(ctx context.Context, repo, since string) (comments []ReviewComment, listed Listed, err error)
	// Yours is what the token's owner has in the repository (#2034).
	Yours(ctx context.Context, repo string) (Yours, error)
}

// Yours is what the token's owner has in a repository (#2034): their id, their active pull
// requests, and the active ones they are a reviewer of and have not voted on.
type Yours struct {
	ID      string
	PRs     []int
	Reviews []OpenPR
}

func (y Yours) owns(pr int) bool {
	for _, n := range y.PRs {
		if n == pr {
			return true
		}
	}
	return false
}

// ErrorKind is why an Azure DevOps call failed.
type ErrorKind int

const (
	NotSignedIn ErrorKind = iota
	RateLimited
	NotFound
	Failed
)

// AzureDevOpsError is a failed Azure DevOps call.
type AzureDevOpsError struct {
	Kind         ErrorKind
	Message      string
	RetryAfterMs int
}

func (e *AzureDevOpsError) Error() string { return e.Message }

// commentChars is the most of a comment's body an event gives.
const commentChars = 4000

func clip(body string) string {
	r := []rune(body)
	if len(r) > commentChars {
		return string(r[:commentChars]) + "…"
	}
	return body
}

// botName is a bot's name: a build service's ("Project Collection Build Service (acme)",
// "app Build Service (acme)"), and others named as a bot.
var botName = regexp.MustCompile(`build service|[-_ ]bot$|\[bot\]$`)

// isBot says whether an identity is a bot: one named as one, a build service's (Build\…), or
// a service or a group, whose descriptors start svc., s2s. or vssgp..
func isBot(i identity) bool {
	unique, descriptor := strings.ToLower(i.UniqueName), strings.ToLower(i.Descriptor)
	return i.IsContainer || strings.HasPrefix(unique, `build\`) || strings.HasPrefix(descriptor, "svc.") ||
		strings.HasPrefix(descriptor, "s2s.") || strings.HasPrefix(descriptor, "vssgp.") ||
		botName.MatchString(strings.ToLower(i.DisplayName))
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
