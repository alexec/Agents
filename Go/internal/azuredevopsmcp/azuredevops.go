package azuredevopsmcp

import (
	"context"
	"regexp"
	"strings"

	"github.com/agentloops-dev/agent-loops/Go/internal/mcpevents"
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
	// AuthorID is who opened it, for mine on a pull request no longer active (#3797); not in its JSON.
	AuthorID string
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

// CompletedBuild is an Azure Pipelines build that finished, whatever started it and whatever
// its result, as run.completed sees it (#3810): a build of main, a tag or a manual run, which
// no pull request owns. Name is its pipeline's name, Number its build number, Reason what
// started it (manual, individualCI, schedule, pullRequest…), Branch its branch or tag with no
// refs/heads/ or refs/tags/. Trusted says whether it is the repository's own: not a fork's
// pull request's, and asked for by a person, not a bot (#728).
type CompletedBuild struct {
	ID                                    int
	Name, Number, Reason, Branch, HeadSHA string
	URL, Result, Actor, At                string
	Trusted                               bool
}

// data is run.completed's payload; deploys are what the build says it deployed (#3820).
func (b CompletedBuild) data(deploys []string) map[string]any {
	if deploys == nil {
		deploys = []string{}
	}
	return map[string]any{"run": map[string]any{
		"id": b.ID, "name": b.Name, "number": b.Number, "event": b.Reason, "branch": b.Branch, "headSha": b.HeadSHA,
		"url": b.URL, "conclusion": b.Result, "actor": b.Actor,
	}, "completedAt": b.At, "deploys": deploys}
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

// Listed is how far a listing read (mcpevents.Listed): Newest is the newest time of anything it
// listed, wanted or not (in mcpevents.TimeLayout, "" when it listed nothing), and Truncated says
// it stopped at maxPages before it reached since.
type Listed = mcpevents.Listed

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
	// CompletedBuilds are the builds that finished at or after since, of pipeline (its name),
	// branch (or tag) and run (a build's id) when each is set, in any order.
	CompletedBuilds(ctx context.Context, repo, pipeline, branch string, run int, since string) (builds []CompletedBuild, listed Listed, err error)
	// BuildDeploys are what a build's jobs say they deployed (#3820): the message of each
	// warning with the code deploy (##vso[task.logissue type=warning;code=deploy]<ref>).
	BuildDeploys(ctx context.Context, repo string, build int) ([]string, error)
	// WaitingDeploys are builds waiting for an environment's approvals (#3820): only
	// pipeline's and branch's when each is set.
	WaitingDeploys(ctx context.Context, repo, pipeline, branch string) ([]WaitingDeploy, error)
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
