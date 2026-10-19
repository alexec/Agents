package githubmcp

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// What the views read and do on GitHub (#1341): the open pull requests and issues, one pull
// request's page, a failed run's log, and a person's merge, review and comment. As the
// signed-in gh user, with the same token as the events (#1335 changes where it comes from).

// Views is what the views ask of GitHub. RealGitHub is one; tests use a fake API under it.
type Views interface {
	DefaultRepo(ctx context.Context) (string, error)
	BoardPRs(ctx context.Context, repo string) (Board, error)
	OpenIssues(ctx context.Context, repo, label string) ([]ListedIssue, error)
	PRPage(ctx context.Context, repo string, number int) (map[string]any, error)
	PRDiff(ctx context.Context, repo string, number int) (map[string]any, error)
	FailedLog(ctx context.Context, repo string, runID int, job string) (string, error)
	RerunFailed(ctx context.Context, repo string, runID int) (map[string]any, error)
	MergePR(ctx context.Context, repo string, number int, auto bool) (map[string]any, error)
	ReviewPR(ctx context.Context, repo string, number int, approve bool, body string) (map[string]any, error)
	CommentOnPR(ctx context.Context, repo string, number int, body string) (map[string]any, error)
}

// Board is the open pull requests, newest updated first, and who is signed in.
type Board struct {
	Viewer string
	PRs    []BoardPR
}

// BoardPR is an open pull request as the board lists it.
type BoardPR struct {
	PR
	Base, Author, UpdatedAt string
	Draft, AutoMerge        bool
	// Checks is passing, failing, running or none; FailedRunID is a failing one's run.
	Checks      string
	FailedRunID int
	// Conflicts is nil while GitHub works it out.
	Conflicts *bool
	// Review is approved, changes_requested, review_required or "".
	Review string
}

func (p BoardPR) json() map[string]any {
	j := p.PR.json()
	j["base"], j["author"], j["updatedAt"], j["draft"], j["autoMerge"], j["checks"] =
		p.Base, p.Author, p.UpdatedAt, p.Draft, p.AutoMerge, p.Checks
	if p.FailedRunID != 0 {
		j["failedRunId"] = p.FailedRunID
	}
	if p.Conflicts != nil {
		j["conflicts"] = *p.Conflicts
	}
	if p.Review != "" {
		j["review"] = p.Review
	}
	return j
}

// ListedIssue is an open issue as the issues view lists it.
type ListedIssue struct {
	Issue
	Comments  int
	UpdatedAt string
}

func (i ListedIssue) json() map[string]any {
	j := i.Issue.json()
	j["comments"], j["updatedAt"] = i.Comments, i.UpdatedAt
	return j
}

// MARK: Checks

// checkItem is one of a commit's checks, as GraphQL's statusCheckRollup gives it: a check run
// or a commit status.
type checkItem struct {
	Typename   string `json:"__typename"`
	Name       string `json:"name"`
	Status     string `json:"status"`
	Conclusion string `json:"conclusion"`
	DetailsURL string `json:"detailsUrl"`
	Context    string `json:"context"`
	State      string `json:"state"`
	TargetURL  string `json:"targetUrl"`
}

var runInURL = regexp.MustCompile(`/actions/runs/([0-9]+)`)

// state is passing, failing, running or skipped.
func (c checkItem) state() string {
	if c.Typename == "StatusContext" {
		switch strings.ToUpper(c.State) {
		case "SUCCESS":
			return "passing"
		case "FAILURE", "ERROR":
			return "failing"
		}
		return "running"
	}
	switch {
	case strings.ToUpper(c.Status) != "COMPLETED":
		return "running"
	case isFailed(c.Conclusion) || strings.EqualFold(c.Conclusion, "ACTION_REQUIRED"):
		return "failing"
	case strings.EqualFold(c.Conclusion, "SUCCESS"):
		return "passing"
	}
	return "skipped"
}

func (c checkItem) json() map[string]any {
	if c.Typename == "StatusContext" {
		return map[string]any{"name": c.Context, "state": c.state(), "url": c.TargetURL}
	}
	j := map[string]any{"name": c.Name, "state": c.state(), "url": c.DetailsURL}
	if m := runInURL.FindStringSubmatch(c.DetailsURL); m != nil {
		j["runId"], _ = strconv.Atoi(m[1])
	}
	return j
}

// rollup is a PR's checks in one word, and a failing run's id.
func rollup(items []checkItem) (string, int) {
	if len(items) == 0 {
		return "none", 0
	}
	running, failing, runID := false, false, 0
	for _, c := range items {
		switch c.state() {
		case "running":
			running = true
		case "failing":
			failing = true
			if m := runInURL.FindStringSubmatch(c.DetailsURL); runID == 0 && m != nil {
				runID, _ = strconv.Atoi(m[1])
			}
		}
	}
	switch {
	case failing:
		return "failing", runID
	case running:
		return "running", 0
	}
	return "passing", 0
}

// MARK: GraphQL

type gqlError struct {
	Type    string `json:"type"`
	Message string `json:"message"`
}

// graphql runs query with vars, and reads its data into into.
func (g *RealGitHub) graphql(ctx context.Context, query string, vars map[string]any, into any) error {
	request, _ := json.Marshal(map[string]any{"query": query, "variables": vars})
	body, err := g.do(ctx, http.MethodPost, "graphql", request, false)
	if err != nil {
		return err
	}
	var answer struct {
		Data   json.RawMessage `json:"data"`
		Errors []gqlError      `json:"errors"`
	}
	if json.Unmarshal(body, &answer) != nil {
		return &GitHubError{Kind: Failed, Message: "GitHub's answer is not JSON"}
	}
	if len(answer.Errors) > 0 {
		if answer.Errors[0].Type == "NOT_FOUND" {
			return &GitHubError{Kind: NotFound, Message: "not found on GitHub"}
		}
		return &GitHubError{Kind: Failed, Message: "GitHub: " + answer.Errors[0].Message}
	}
	if json.Unmarshal(answer.Data, into) != nil {
		return &GitHubError{Kind: Failed, Message: "GitHub's answer is not JSON"}
	}
	return nil
}

func ownerName(repo string) (string, string, error) {
	owner, name, ok := strings.Cut(repo, "/")
	if !ok || owner == "" || name == "" {
		return "", "", &GitHubError{Kind: NotFound, Message: "repo is owner/name"}
	}
	return owner, name, nil
}

type gqlActor struct {
	Login    string `json:"login"`
	Typename string `json:"__typename"`
}

func (a *gqlActor) login() string {
	if a == nil {
		return ""
	}
	return a.Login
}

// isBot: a GitHub App, such as CodeRabbit (#1344), writes as a Bot.
func (a *gqlActor) isBot() bool { return a != nil && a.Typename == "Bot" }

// rollupFields are a PR's last commit's checks.
const rollupFields = `commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) { nodes {
  __typename ... on CheckRun { name status conclusion detailsUrl } ... on StatusContext { context state targetUrl } } } } } } }`

type gqlRollup struct {
	Nodes []struct {
		Commit struct {
			StatusCheckRollup *struct {
				Contexts struct {
					Nodes []checkItem `json:"nodes"`
				} `json:"contexts"`
			} `json:"statusCheckRollup"`
		} `json:"commit"`
	} `json:"nodes"`
}

func (r gqlRollup) items() []checkItem {
	if len(r.Nodes) == 0 || r.Nodes[0].Commit.StatusCheckRollup == nil {
		return nil
	}
	return r.Nodes[0].Commit.StatusCheckRollup.Contexts.Nodes
}

func conflictsOf(mergeable string) *bool {
	switch mergeable {
	case "CONFLICTING":
		return new(true)
	case "MERGEABLE":
		return new(false)
	}
	return nil
}

// MARK: The board

const boardQuery = `query($owner: String!, $name: String!) { viewer { login } repository(owner: $owner, name: $name) {
  pullRequests(states: OPEN, first: 100, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes {
    number title url headRefName baseRefName isDraft updatedAt mergeable reviewDecision
    author { login __typename } autoMergeRequest { enabledAt } ` + rollupFields + ` } } } }`

func (g *RealGitHub) BoardPRs(ctx context.Context, repo string) (Board, error) {
	owner, name, err := ownerName(repo)
	if err != nil {
		return Board{}, err
	}
	var data struct {
		Viewer     gqlActor `json:"viewer"`
		Repository *struct {
			PullRequests struct {
				Nodes []struct {
					Number      int       `json:"number"`
					Title       string    `json:"title"`
					URL         string    `json:"url"`
					HeadRefName string    `json:"headRefName"`
					BaseRefName string    `json:"baseRefName"`
					IsDraft     bool      `json:"isDraft"`
					UpdatedAt   string    `json:"updatedAt"`
					Mergeable   string    `json:"mergeable"`
					Review      string    `json:"reviewDecision"`
					Author      *gqlActor `json:"author"`
					AutoMerge   *struct{} `json:"autoMergeRequest"`
					Commits     gqlRollup `json:"commits"`
				} `json:"nodes"`
			} `json:"pullRequests"`
		} `json:"repository"`
	}
	if err := g.graphql(ctx, boardQuery, map[string]any{"owner": owner, "name": name}, &data); err != nil {
		return Board{}, err
	}
	if data.Repository == nil {
		return Board{}, &GitHubError{Kind: NotFound, Message: "not found on GitHub"}
	}
	b := Board{Viewer: data.Viewer.Login, PRs: []BoardPR{}}
	for _, n := range data.Repository.PullRequests.Nodes {
		checks, runID := rollup(n.Commits.items())
		b.PRs = append(b.PRs, BoardPR{
			PR:   PR{Number: n.Number, Title: n.Title, Branch: n.HeadRefName, URL: n.URL},
			Base: n.BaseRefName, Author: n.Author.login(), UpdatedAt: n.UpdatedAt, Draft: n.IsDraft,
			AutoMerge: n.AutoMerge != nil, Checks: checks, FailedRunID: runID, Conflicts: conflictsOf(n.Mergeable),
			Review: strings.ToLower(n.Review),
		})
	}
	return b, nil
}

// MARK: Issues

func (g *RealGitHub) OpenIssues(ctx context.Context, repo, label string) ([]ListedIssue, error) {
	if _, _, err := ownerName(repo); err != nil {
		return nil, err
	}
	// The listing has pull requests in it too: up to three pages, for 100 issues.
	q := fmt.Sprintf("state=open&sort=updated&direction=desc&per_page=%d", perPage)
	if label != "" {
		q += "&labels=" + url.QueryEscape(label)
	}
	out := []ListedIssue{}
	for page := 1; page <= 3 && len(out) < perPage; page++ {
		var list []issueJSON
		if err := g.get(ctx, fmt.Sprintf("repos/%s/issues?%s&page=%d", repo, q, page), false, &list); err != nil {
			return nil, err
		}
		for _, i := range list {
			if !i.isPR() && len(out) < perPage {
				out = append(out, ListedIssue{Issue: i.issue(), Comments: i.Comments, UpdatedAt: i.UpdatedAt})
			}
		}
		if len(list) < perPage {
			break
		}
	}
	return out, nil
}

// MARK: A pull request's page

const pageQuery = `query($owner: String!, $name: String!, $number: Int!) { viewer { login } repository(owner: $owner, name: $name) {
  pullRequest(number: $number) {
    number title url headRefName baseRefName state isDraft body createdAt additions deletions mergeable reviewDecision
    author { login __typename } autoMergeRequest { enabledAt }
    files(first: 100) { totalCount nodes { path additions deletions changeType } }
    comments(first: 100) { nodes { author { login __typename } body createdAt url } }
    reviews(first: 100) { nodes { author { login __typename } body state submittedAt url } }
    reviewThreads(first: 100) { nodes { isResolved isOutdated path line originalLine
      comments(first: 50) { nodes { author { login __typename } body createdAt url } } } }
    ` + rollupFields + ` } } }`

type gqlComment struct {
	Author    *gqlActor `json:"author"`
	Body      string    `json:"body"`
	CreatedAt string    `json:"createdAt"`
	URL       string    `json:"url"`
}

func (c gqlComment) json(at string) map[string]any {
	return map[string]any{"author": c.Author.login(), "bot": c.Author.isBot(), "body": c.Body, "at": at, "url": c.URL}
}

func (g *RealGitHub) PRPage(ctx context.Context, repo string, number int) (map[string]any, error) {
	owner, name, err := ownerName(repo)
	if err != nil {
		return nil, err
	}
	var data struct {
		Viewer     gqlActor `json:"viewer"`
		Repository *struct {
			PullRequest *struct {
				Number      int       `json:"number"`
				Title       string    `json:"title"`
				URL         string    `json:"url"`
				HeadRefName string    `json:"headRefName"`
				BaseRefName string    `json:"baseRefName"`
				State       string    `json:"state"`
				IsDraft     bool      `json:"isDraft"`
				Body        string    `json:"body"`
				CreatedAt   string    `json:"createdAt"`
				Additions   int       `json:"additions"`
				Deletions   int       `json:"deletions"`
				Mergeable   string    `json:"mergeable"`
				Review      string    `json:"reviewDecision"`
				Author      *gqlActor `json:"author"`
				AutoMerge   *struct{} `json:"autoMergeRequest"`
				Files       struct {
					TotalCount int `json:"totalCount"`
					Nodes      []struct {
						Path       string `json:"path"`
						Additions  int    `json:"additions"`
						Deletions  int    `json:"deletions"`
						ChangeType string `json:"changeType"`
					} `json:"nodes"`
				} `json:"files"`
				Comments struct {
					Nodes []gqlComment `json:"nodes"`
				} `json:"comments"`
				Reviews struct {
					Nodes []struct {
						gqlComment
						State       string `json:"state"`
						SubmittedAt string `json:"submittedAt"`
					} `json:"nodes"`
				} `json:"reviews"`
				Threads struct {
					Nodes []struct {
						IsResolved   bool   `json:"isResolved"`
						IsOutdated   bool   `json:"isOutdated"`
						Path         string `json:"path"`
						Line         *int   `json:"line"`
						OriginalLine *int   `json:"originalLine"`
						Comments     struct {
							Nodes []gqlComment `json:"nodes"`
						} `json:"comments"`
					} `json:"nodes"`
				} `json:"reviewThreads"`
				Commits gqlRollup `json:"commits"`
			} `json:"pullRequest"`
		} `json:"repository"`
	}
	if err := g.graphql(ctx, pageQuery, map[string]any{"owner": owner, "name": name, "number": number}, &data); err != nil {
		return nil, err
	}
	if data.Repository == nil || data.Repository.PullRequest == nil {
		return nil, &GitHubError{Kind: NotFound, Message: fmt.Sprintf("no pull request #%d in %s", number, repo)}
	}
	p := data.Repository.PullRequest
	items := p.Commits.items()
	checks, runID := rollup(items)
	runs := make([]any, len(items))
	for i, c := range items {
		runs[i] = c.json()
	}
	files := make([]any, len(p.Files.Nodes))
	for i, f := range p.Files.Nodes {
		files[i] = map[string]any{"path": f.Path, "additions": f.Additions, "deletions": f.Deletions,
			"change": strings.ToLower(f.ChangeType)}
	}
	// The conversation: comments and reviews with words or a verdict, oldest first.
	type note struct {
		at   string
		json map[string]any
	}
	var notes []note
	for _, c := range p.Comments.Nodes {
		notes = append(notes, note{c.CreatedAt, c.json(c.CreatedAt)})
	}
	for _, r := range p.Reviews.Nodes {
		review := strings.ToLower(r.State)
		if strings.TrimSpace(r.Body) == "" && review != "approved" && review != "changes_requested" {
			continue // a review that is only its line comments: they are in threads
		}
		j := r.json(r.SubmittedAt)
		j["review"] = review
		notes = append(notes, note{r.SubmittedAt, j})
	}
	sort.SliceStable(notes, func(i, j int) bool { return before(notes[i].at, notes[j].at) })
	conversation := make([]any, len(notes))
	for i, n := range notes {
		conversation[i] = n.json
	}
	threads := []any{}
	for _, t := range p.Threads.Nodes {
		comments := make([]any, len(t.Comments.Nodes))
		for i, c := range t.Comments.Nodes {
			comments[i] = c.json(c.CreatedAt)
		}
		j := map[string]any{"path": t.Path, "resolved": t.IsResolved, "outdated": t.IsOutdated, "comments": comments}
		if t.Line != nil {
			j["line"] = *t.Line
		} else if t.OriginalLine != nil {
			j["line"] = *t.OriginalLine
		}
		threads = append(threads, j)
	}
	state := strings.ToLower(p.State)
	if state != "merged" && state != "closed" {
		state = "open"
	}
	page := map[string]any{
		"repo": repo, "number": p.Number, "title": p.Title, "url": p.URL, "branch": p.HeadRefName, "base": p.BaseRefName,
		"author": p.Author.login(), "state": state, "draft": p.IsDraft, "body": p.Body, "createdAt": p.CreatedAt,
		"additions": p.Additions, "deletions": p.Deletions, "checks": checks, "autoMerge": p.AutoMerge != nil,
		"checkRuns": runs, "files": files, "filesTotal": p.Files.TotalCount,
		"comments": conversation, "threads": threads, "viewer": data.Viewer.Login,
	}
	if runID != 0 {
		page["failedRunId"] = runID
	}
	if c := conflictsOf(p.Mergeable); c != nil {
		page["conflicts"] = *c
	}
	if p.Review != "" {
		page["review"] = strings.ToLower(p.Review)
	}
	return page, nil
}

// MARK: Logs and reruns

// logLines is how much of each failed job's log is given: its end, where the failure is.
const logLines = 300

var (
	escapes  = regexp.MustCompile("\x1b\\[[0-9;?]*[ -/]*[@-~]|\x1b\\][^\x07\x1b]*(\x07|\x1b\\\\)")
	controls = regexp.MustCompile("[\x00-\x08\x0b-\x1f\x7f]")
)

// plain is text without terminal escapes or other control characters, tabs and newlines kept.
func plain(text string) string {
	return controls.ReplaceAllString(escapes.ReplaceAllString(text, ""), "")
}

// tail is text's last n lines, without its trailing newlines.
func tail(text string, n int) string {
	lines := strings.Split(strings.TrimRight(text, "\n"), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n")
}

func (g *RealGitHub) FailedLog(ctx context.Context, repo string, runID int, job string) (string, error) {
	if _, _, err := ownerName(repo); err != nil {
		return "", err
	}
	var jobs struct {
		Jobs []struct {
			ID         int    `json:"id"`
			Name       string `json:"name"`
			HTMLURL    string `json:"html_url"`
			Conclusion string `json:"conclusion"`
		} `json:"jobs"`
	}
	if err := g.get(ctx, fmt.Sprintf("repos/%s/actions/runs/%d/jobs?filter=latest&per_page=100", repo, runID), false, &jobs); err != nil {
		return "", err
	}
	var parts []string
	for _, j := range jobs.Jobs {
		if !isFailed(j.Conclusion) || (job != "" && j.Name != job) {
			continue
		}
		body, err := g.do(ctx, http.MethodGet, fmt.Sprintf("repos/%s/actions/jobs/%d/logs", repo, j.ID), nil, false)
		if err != nil {
			return "", err
		}
		parts = append(parts, fmt.Sprintf("== %s (%s), last %d lines ==\n%s", j.Name, j.HTMLURL, logLines, tail(plain(string(body)), logLines)))
	}
	if len(parts) == 0 {
		return fmt.Sprintf("No failed jobs in run %d.", runID), nil
	}
	return strings.Join(parts, "\n\n"), nil
}

func (g *RealGitHub) RerunFailed(ctx context.Context, repo string, runID int) (map[string]any, error) {
	if _, _, err := ownerName(repo); err != nil {
		return nil, err
	}
	if _, err := g.do(ctx, http.MethodPost, fmt.Sprintf("repos/%s/actions/runs/%d/rerun-failed-jobs", repo, runID), []byte("{}"), false); err != nil {
		return nil, err
	}
	return map[string]any{"rerun": true, "url": fmt.Sprintf("https://github.com/%s/actions/runs/%d", repo, runID)}, nil
}

// MARK: A person's actions

func prURL(repo string, number int) string {
	return fmt.Sprintf("https://github.com/%s/pull/%d", repo, number)
}

// MergePR squash-merges it and deletes its branch on GitHub; with auto, GitHub does that once
// its checks pass. It never touches a local branch.
func (g *RealGitHub) MergePR(ctx context.Context, repo string, number int, auto bool) (map[string]any, error) {
	if _, _, err := ownerName(repo); err != nil {
		return nil, err
	}
	var p struct {
		NodeID string `json:"node_id"`
		Head   ref    `json:"head"`
	}
	if err := g.get(ctx, fmt.Sprintf("repos/%s/pulls/%d", repo, number), false, &p); err != nil {
		return nil, err
	}
	if auto {
		const enable = `mutation($id: ID!) { enablePullRequestAutoMerge(input: {pullRequestId: $id, mergeMethod: SQUASH}) {
  pullRequest { number } } }`
		var out struct{}
		if err := g.graphql(ctx, enable, map[string]any{"id": p.NodeID}, &out); err != nil {
			return nil, err
		}
		return map[string]any{"merged": false, "auto": true, "url": prURL(repo, number)}, nil
	}
	body, _ := json.Marshal(map[string]string{"merge_method": "squash"})
	if _, err := g.do(ctx, http.MethodPut, fmt.Sprintf("repos/%s/pulls/%d/merge", repo, number), body, false); err != nil {
		return nil, err
	}
	// Its branch goes when it is this repo's own, as --delete-branch does.
	if p.Head.Repo != nil && p.Head.Repo.FullName == repo && p.Head.Ref != "" {
		_, _ = g.do(ctx, http.MethodDelete, fmt.Sprintf("repos/%s/git/refs/heads/%s", repo, p.Head.Ref), nil, false)
	}
	return map[string]any{"merged": true, "auto": false, "url": prURL(repo, number)}, nil
}

func (g *RealGitHub) ReviewPR(ctx context.Context, repo string, number int, approve bool, words string) (map[string]any, error) {
	if _, _, err := ownerName(repo); err != nil {
		return nil, err
	}
	event := "REQUEST_CHANGES"
	if approve {
		event = "APPROVE"
	}
	review := map[string]string{"event": event}
	if words != "" {
		review["body"] = words
	}
	body, _ := json.Marshal(review)
	if _, err := g.do(ctx, http.MethodPost, fmt.Sprintf("repos/%s/pulls/%d/reviews", repo, number), body, false); err != nil {
		return nil, err
	}
	return map[string]any{"event": strings.ToLower(event), "url": prURL(repo, number)}, nil
}

func (g *RealGitHub) CommentOnPR(ctx context.Context, repo string, number int, words string) (map[string]any, error) {
	if _, _, err := ownerName(repo); err != nil {
		return nil, err
	}
	body, _ := json.Marshal(map[string]string{"body": words})
	answer, err := g.do(ctx, http.MethodPost, fmt.Sprintf("repos/%s/issues/%d/comments", repo, number), body, false)
	if err != nil {
		return nil, err
	}
	var c struct {
		HTMLURL string `json:"html_url"`
	}
	json.Unmarshal(answer, &c)
	return map[string]any{"url": c.HTMLURL}, nil
}

// MARK: The diff

// diffLines is the most lines of hunks a diff gives, all files together; past it, a file
// is listed with no hunks and the diff says it was cut.
const diffLines = 5000

// DiffLine is one line of a hunk: context, added or removed.
type DiffLine struct {
	Kind string `json:"kind"`
	Text string `json:"text"`
}

// Hunk is one @@ block of a file's patch, as #1472's diff component takes it.
type Hunk struct {
	OldStart int        `json:"oldStart"`
	NewStart int        `json:"newStart"`
	Lines    []DiffLine `json:"lines"`
}

var hunkHead = regexp.MustCompile(`^@@ -([0-9]+)(?:,[0-9]+)? \+([0-9]+)(?:,[0-9]+)? @@`)

// hunks reads a file's patch, as GitHub gives it: from its first @@ on.
func hunks(patch string) []Hunk {
	out := []Hunk{}
	for _, line := range strings.Split(patch, "\n") {
		if m := hunkHead.FindStringSubmatch(line); m != nil {
			oldStart, _ := strconv.Atoi(m[1])
			newStart, _ := strconv.Atoi(m[2])
			out = append(out, Hunk{OldStart: oldStart, NewStart: newStart, Lines: []DiffLine{}})
			continue
		}
		if len(out) == 0 || strings.HasPrefix(line, `\`) { // "\ No newline at end of file"
			continue
		}
		h := &out[len(out)-1]
		switch {
		case strings.HasPrefix(line, "+"):
			h.Lines = append(h.Lines, DiffLine{"added", line[1:]})
		case strings.HasPrefix(line, "-"):
			h.Lines = append(h.Lines, DiffLine{"removed", line[1:]})
		case strings.HasPrefix(line, " "):
			h.Lines = append(h.Lines, DiffLine{"context", line[1:]})
		}
		// A bare empty line is the patch's own last newline, not a line of the file.
	}
	return out
}

func (g *RealGitHub) PRDiff(ctx context.Context, repo string, number int) (map[string]any, error) {
	if _, _, err := ownerName(repo); err != nil {
		return nil, err
	}
	type fileJSON struct {
		Filename  string `json:"filename"`
		Previous  string `json:"previous_filename"`
		Status    string `json:"status"`
		Additions int    `json:"additions"`
		Deletions int    `json:"deletions"`
		Patch     string `json:"patch"`
	}
	var all []fileJSON
	// GitHub lists at most 3000 files, 100 a page.
	for page := 1; page <= 30; page++ {
		var list []fileJSON
		if err := g.get(ctx, fmt.Sprintf("repos/%s/pulls/%d/files?per_page=%d&page=%d", repo, number, perPage, page), false, &list); err != nil {
			return nil, err
		}
		all = append(all, list...)
		if len(list) < perPage {
			break
		}
	}
	files := make([]any, 0, len(all))
	left, cut := diffLines, false
	for _, f := range all {
		j := map[string]any{"path": f.Filename, "change": f.Status, "additions": f.Additions, "deletions": f.Deletions}
		if f.Previous != "" {
			j["previousPath"] = f.Previous
		}
		h := hunks(f.Patch)
		n := 0
		for _, hunk := range h {
			n += len(hunk.Lines)
		}
		switch {
		case f.Patch == "":
			j["hunks"], j["note"] = []Hunk{}, "No lines to show: a binary file, a rename, or too long for GitHub to give."
		case n > left:
			j["hunks"], j["note"], cut = []Hunk{}, "Not shown: the diff is too long. Open it on GitHub.", true
		default:
			j["hunks"] = h
			left -= n
		}
		files = append(files, j)
	}
	return map[string]any{"repo": repo, "number": number, "url": prURL(repo, number) + "/files", "files": files, "cut": cut}, nil
}
