package githubmcp

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/connections"
)

// RealGitHub reads GitHub's REST and GraphQL APIs as the person, with the token of the
// host's GitHub connection (#1335; no account of its own, and no gh). GET bodies are kept with their ETags, so an
// unchanged listing costs no rate limit (GitHub doesn't count 304s). The listings events poll
// are shared for sharedFor (#932): every wait polls on its own, and ten waits on one repo
// would otherwise fetch the same page ten times.
type RealGitHub struct {
	// API is the REST API's root, with a trailing slash: https://api.github.com/.
	API    string
	Token  func() string
	Client *http.Client
	// Repo is the repo the server's folder pushes to, read from git once it is needed.
	Repo        func(ctx context.Context) (string, error)
	IssueReader IssueReader

	mu        sync.Mutex
	etags     map[string]etagged
	etagOrder []string
	etagBytes int
	recent    map[string]sharedBody
	running   map[string]*fetch
	sharing   time.Duration
}

type etagged struct{ etag, body string }

type sharedBody struct {
	at   time.Time
	body []byte
}

type fetch struct {
	done chan struct{}
	body []byte
	err  error
}

const (
	maxPages = 10
	perPage  = 100
	// sharedFor is under the 30 s poll, so each poll still sees a fresh page.
	sharedFor = 25 * time.Second
	// etagCount and etagCap bound the ETag cache (#1654): a PR's diff is many MB, and it would push
	// the listings events poll out. A body over etagLargest is not kept.
	etagCount   = 200
	etagCap     = 8 << 20
	etagLargest = 256 << 10
	// rerunWindow is how far back past since a run may have been created and still be rerun into view.
	rerunWindow = 24 * time.Hour
)

// NewRealGitHub reads api (https://api.github.com/ when empty) with token's answer.
func NewRealGitHub(api string, token func() string, repo func(ctx context.Context) (string, error), issueReader ...IssueReader) *RealGitHub {
	if api == "" {
		api = "https://api.github.com/"
	}
	if !strings.HasSuffix(api, "/") {
		api += "/"
	}
	g := &RealGitHub{API: api, Token: token, Repo: repo, Client: &http.Client{Timeout: 30 * time.Second},
		etags: map[string]etagged{}, recent: map[string]sharedBody{}, running: map[string]*fetch{}, sharing: sharedFor}
	if len(issueReader) > 0 {
		g.IssueReader = issueReader[0]
	}
	return g
}

// MARK: HTTP

func (g *RealGitHub) do(ctx context.Context, method, path string, body []byte, cache bool) ([]byte, error) {
	req, err := g.request(ctx, method, path, body)
	if err != nil {
		return nil, err
	}
	var cached etagged
	var have bool
	if cache {
		g.mu.Lock()
		cached, have = g.etags[path]
		g.mu.Unlock()
		if have {
			req.Header.Set("If-None-Match", cached.etag)
		}
	}
	res, err := g.Client.Do(req)
	if err != nil {
		return nil, &GitHubError{Kind: Failed, Message: "GitHub: " + err.Error()}
	}
	defer res.Body.Close()
	data, err := io.ReadAll(io.LimitReader(res.Body, 64<<20))
	if err != nil {
		return nil, &GitHubError{Kind: Failed, Message: "GitHub: " + err.Error()}
	}
	if res.StatusCode == http.StatusNotModified && have {
		return []byte(cached.body), nil
	}
	if res.StatusCode >= 200 && res.StatusCode < 300 {
		if etag := res.Header.Get("ETag"); cache && etag != "" {
			g.remember(path, etag, string(data))
		}
		return data, nil
	}
	return nil, failure(res, data)
}

// request is a request to GitHub's API as the person.
func (g *RealGitHub) request(ctx context.Context, method, path string, body []byte) (*http.Request, error) {
	token := g.Token()
	if token == "" {
		return nil, &GitHubError{Kind: NotSignedIn, Message: NotConnected}
	}
	var reader io.Reader
	if body != nil {
		reader = bytes.NewReader(body)
	}
	req, err := http.NewRequestWithContext(ctx, method, g.API+path, reader)
	if err != nil {
		return nil, &GitHubError{Kind: Failed, Message: "GitHub: " + err.Error()}
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	req.Header.Set("User-Agent", "agents-github-mcp")
	return req, nil
}

// tailOf is the last n bytes of path's body, from its first whole line (#1655). The body is
// streamed through, so a job's log of many MB is never held whole.
func (g *RealGitHub) tailOf(ctx context.Context, path string, n int) ([]byte, error) {
	req, err := g.request(ctx, http.MethodGet, path, nil)
	if err != nil {
		return nil, err
	}
	res, err := g.Client.Do(req)
	if err != nil {
		return nil, &GitHubError{Kind: Failed, Message: "GitHub: " + err.Error()}
	}
	defer res.Body.Close()
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		data, _ := io.ReadAll(io.LimitReader(res.Body, 64<<10))
		return nil, failure(res, data)
	}
	data, err := lastBytes(res.Body, n)
	if err != nil {
		return nil, &GitHubError{Kind: Failed, Message: "GitHub: " + err.Error()}
	}
	return data, nil
}

// lastBytes is r's last n bytes; when r is longer, the cut line at the start is left out.
func lastBytes(r io.Reader, n int) ([]byte, error) {
	buf := make([]byte, 0, 2*n)
	cut := false
	for {
		if len(buf) == cap(buf) {
			buf = append(buf[:0], buf[len(buf)-n:]...)
			cut = true
		}
		read, err := r.Read(buf[len(buf):cap(buf)])
		buf = buf[:len(buf)+read]
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, err
		}
	}
	if len(buf) > n {
		buf = buf[len(buf)-n:]
		cut = true
	}
	if cut {
		if i := bytes.IndexByte(buf, '\n'); i >= 0 {
			buf = buf[i+1:]
		}
	}
	return buf, nil
}

func (g *RealGitHub) remember(path, etag, body string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if old, ok := g.etags[path]; ok {
		for i, p := range g.etagOrder {
			if p == path {
				g.etagOrder = append(g.etagOrder[:i], g.etagOrder[i+1:]...)
				break
			}
		}
		delete(g.etags, path)
		g.etagBytes -= len(old.body)
	}
	if len(body) > etagLargest {
		return
	}
	g.etagOrder = append(g.etagOrder, path)
	g.etags[path] = etagged{etag, body}
	g.etagBytes += len(body)
	for len(g.etagOrder) > etagCount || g.etagBytes > etagCap {
		g.etagBytes -= len(g.etags[g.etagOrder[0]].body)
		delete(g.etags, g.etagOrder[0])
		g.etagOrder = g.etagOrder[1:]
	}
}

// failure is a response GitHub refused, as what went wrong.
func failure(res *http.Response, body []byte) *GitHubError {
	switch {
	case res.StatusCode == http.StatusUnauthorized:
		return &GitHubError{Kind: NotSignedIn, Message: NotConnected}
	case res.StatusCode == http.StatusForbidden || res.StatusCode == http.StatusTooManyRequests:
		ms := retryAfter(res.Header)
		if ms > 0 || bytes.Contains(bytes.ToLower(body), []byte("rate limit")) {
			if ms == 0 {
				ms = 60_000
			}
			return &GitHubError{Kind: RateLimited, Message: "GitHub rate limit", RetryAfterMs: ms}
		}
	case res.StatusCode == http.StatusNotFound:
		return &GitHubError{Kind: NotFound, Message: "not found on GitHub", Refused: true}
	}
	return &GitHubError{Kind: Failed, Message: fmt.Sprintf("GitHub: HTTP %d", res.StatusCode),
		Refused: res.StatusCode == http.StatusForbidden}
}

func retryAfter(h http.Header) int {
	if after, err := strconv.ParseFloat(h.Get("Retry-After"), 64); err == nil {
		return max(1000, int(after*1000))
	}
	if h.Get("X-RateLimit-Remaining") == "0" {
		if reset, err := strconv.ParseFloat(h.Get("X-RateLimit-Reset"), 64); err == nil && reset > 0 {
			return max(1000, int(reset*1000-float64(time.Now().UnixMilli())))
		}
	}
	return 0
}

// get is path's JSON; with shared, an answer fetched in the last sharedFor is used again, and
// a fetch already running is waited for.
func (g *RealGitHub) get(ctx context.Context, path string, shared bool, into any) error {
	var body []byte
	var err error
	if shared {
		body, err = g.shared(path, func() ([]byte, error) { return g.do(ctx, http.MethodGet, path, nil, true) })
	} else {
		body, err = g.do(ctx, http.MethodGet, path, nil, true)
	}
	if err != nil {
		return err
	}
	if json.Unmarshal(body, into) != nil {
		return &GitHubError{Kind: Failed, Message: "GitHub's answer is not JSON"}
	}
	return nil
}

func (g *RealGitHub) shared(key string, get func() ([]byte, error)) ([]byte, error) {
	g.mu.Lock()
	now := time.Now()
	if kept, ok := g.recent[key]; ok && now.Sub(kept.at) < g.sharing {
		g.mu.Unlock()
		return kept.body, nil
	}
	if f, ok := g.running[key]; ok {
		g.mu.Unlock()
		<-f.done
		return f.body, f.err
	}
	f := &fetch{done: make(chan struct{})}
	g.running[key] = f
	g.mu.Unlock()

	f.body, f.err = get()
	close(f.done)

	g.mu.Lock()
	delete(g.running, key)
	if f.err == nil {
		for k, v := range g.recent {
			if now.Sub(v.at) >= g.sharing {
				delete(g.recent, k)
			}
		}
		g.recent[key] = sharedBody{time.Now(), f.body}
	}
	g.mu.Unlock()
	return f.body, f.err
}

// MARK: GitHub's JSON

type user struct {
	Login string `json:"login"`
	Type  string `json:"type"`
}

type ref struct {
	Ref string `json:"ref"`
	Sha string `json:"sha"`
	// Repo is the repo the head branch is in: a fork's for a fork's PR, null once it is deleted.
	Repo *struct {
		FullName string `json:"full_name"`
	} `json:"repo"`
}

type pull struct {
	Number      int     `json:"number"`
	Title       string  `json:"title"`
	HTMLURL     string  `json:"html_url"`
	Head        ref     `json:"head"`
	User        user    `json:"user"`
	Association string  `json:"author_association"`
	Draft       bool    `json:"draft"`
	UpdatedAt   string  `json:"updated_at"`
	MergedAt    *string `json:"merged_at"`
	ClosedAt    *string `json:"closed_at"`
	MergeSHA    string  `json:"merge_commit_sha"`
	Body        string  `json:"body"`
}

func (p pull) pr() PR {
	return PR{Number: p.Number, Title: p.Title, Branch: p.Head.Ref, URL: p.HTMLURL, Fixes: closingRefs(p.Body)}
}

// trusted says whether the PR is the repo's own: its branch in repo, not a fork, and its
// author one of the repo's own people.
func (p pull) trusted(repo string) bool {
	own := p.Head.Repo != nil && strings.EqualFold(p.Head.Repo.FullName, repo)
	return own && isTrusted(p.Association, p.User.Login, p.User.Type)
}

type label struct {
	Name string `json:"name"`
	// Color is GitHub's 6-digit hex, without the # (#2686).
	Color string `json:"color"`
}

type issueJSON struct {
	Number      int             `json:"number"`
	Title       string          `json:"title"`
	HTMLURL     string          `json:"html_url"`
	User        user            `json:"user"`
	Association string          `json:"author_association"`
	Labels      []label         `json:"labels"`
	State       string          `json:"state"`
	Assignees   []user          `json:"assignees"`
	CreatedAt   string          `json:"created_at"`
	StateReason string          `json:"state_reason"`
	PullRequest json.RawMessage `json:"pull_request"`
	Comments    int             `json:"comments"`
	UpdatedAt   string          `json:"updated_at"`
	Milestone   *issueMilestone `json:"milestone"`
}

type issueMilestone struct {
	Title string `json:"title"`
}

func (m *issueMilestone) title() string {
	if m == nil {
		return ""
	}
	return m.Title
}

func (i issueJSON) isPR() bool { return len(i.PullRequest) > 0 && string(i.PullRequest) != "null" }

func (i issueJSON) issue() Issue {
	labels := make([]string, len(i.Labels))
	for n, l := range i.Labels {
		labels[n] = l.Name
	}
	assignees := []string{}
	for _, a := range i.Assignees {
		if a.Login != "" {
			assignees = append(assignees, a.Login)
		}
	}
	return Issue{Number: i.Number, Title: i.Title, Author: i.User.Login, Labels: labels, URL: i.HTMLURL, Assignees: assignees}
}

func (i issueJSON) trusted() bool { return isTrusted(i.Association, i.User.Login, i.User.Type) }

func query(path string, page int) string {
	sep := "?"
	if strings.Contains(path, "?") {
		sep = "&"
	}
	return fmt.Sprintf("%s%sper_page=%d&page=%d", path, sep, perPage, page)
}

// MARK: GitHub

func (g *RealGitHub) DefaultRepo(ctx context.Context) (string, error) { return g.Repo(ctx) }

func (g *RealGitHub) FailedRuns(ctx context.Context, repo, branch, since string) ([]RunRef, bool, error) {
	type run struct {
		ID           int    `json:"id"`
		Attempt      int    `json:"run_attempt"`
		Name         string `json:"name"`
		DisplayTitle string `json:"display_title"`
		HTMLURL      string `json:"html_url"`
		HeadSHA      string `json:"head_sha"`
		HeadBranch   string `json:"head_branch"`
		Status       string `json:"status"`
		Conclusion   string `json:"conclusion"`
		UpdatedAt    string `json:"updated_at"`
		CreatedAt    string `json:"created_at"`
		PullRequests []struct {
			Number int `json:"number"`
		} `json:"pull_requests"`
	}
	floor := ""
	if t, ok := parseTime(since); ok {
		floor = timeString(t.Add(-rerunWindow))
	}
	path := fmt.Sprintf("repos/%s/actions/runs?event=pull_request&status=failure", repo)
	if branch != "" {
		path += "&branch=" + url.QueryEscape(branch)
	}
	var runs []RunRef
	for page := 1; page <= maxPages; page++ {
		var list struct {
			Runs []run `json:"workflow_runs"`
		}
		if err := g.get(ctx, query(path, page), true, &list); err != nil {
			return nil, false, err
		}
		for _, r := range list.Runs {
			if r.Status != "completed" || !isFailed(r.Conclusion) || before(r.UpdatedAt, since) {
				continue
			}
			name := r.Name
			if name == "" {
				name = r.DisplayTitle
			}
			attempt := r.Attempt
			if attempt == 0 {
				attempt = 1
			}
			number := 0
			if len(r.PullRequests) > 0 {
				number = r.PullRequests[0].Number
			}
			runs = append(runs, RunRef{ID: r.ID, Attempt: attempt, Name: name, URL: r.HTMLURL, HeadSHA: r.HeadSHA,
				Branch: r.HeadBranch, PRNumber: number, UpdatedAt: r.UpdatedAt})
		}
		// Runs are listed newest created first; a rerun keeps its created_at.
		if len(list.Runs) < perPage || before(list.Runs[len(list.Runs)-1].CreatedAt, floor) {
			return runs, false, nil
		}
	}
	return runs, true, nil
}

func (g *RealGitHub) RunDetails(ctx context.Context, repo string, run RunRef) (*FailedRunData, error) {
	number := run.PRNumber
	if number == 0 {
		// A fork's PR isn't on the run; find it by the head commit.
		var pulls []pull
		if err := g.get(ctx, fmt.Sprintf("repos/%s/commits/%s/pulls", repo, run.HeadSHA), false, &pulls); err != nil {
			return nil, err
		}
		for _, p := range pulls {
			if p.Head.Ref == run.Branch {
				number = p.Number
				break
			}
		}
		if number == 0 && len(pulls) > 0 {
			number = pulls[0].Number
		}
	}
	if number == 0 {
		return nil, nil
	}
	var jobs struct {
		Jobs []struct {
			Name       string `json:"name"`
			HTMLURL    string `json:"html_url"`
			Conclusion string `json:"conclusion"`
		} `json:"jobs"`
	}
	if err := g.get(ctx, fmt.Sprintf("repos/%s/actions/runs/%d/jobs?filter=latest&per_page=100", repo, run.ID), false, &jobs); err != nil {
		return nil, err
	}
	var p pull
	if err := g.get(ctx, fmt.Sprintf("repos/%s/pulls/%d", repo, number), false, &p); err != nil {
		return nil, err
	}
	failed := []Job{}
	for _, j := range jobs.Jobs {
		if isFailed(j.Conclusion) {
			failed = append(failed, Job{Name: j.Name, URL: j.HTMLURL})
		}
	}
	pr := p.pr()
	if pr.Number == 0 {
		pr.Number = number
	}
	return &FailedRunData{PR: pr, HeadSHA: run.HeadSHA, Run: run, FailedJobs: failed, Trusted: p.trusted(repo)}, nil
}

func (g *RealGitHub) ClosedPRs(ctx context.Context, repo, since string) ([]MergedPR, []ClosedPR, bool, error) {
	var merged []MergedPR
	var closed []ClosedPR
	path := fmt.Sprintf("repos/%s/pulls?state=closed&sort=updated&direction=desc", repo)
	for page := 1; page <= maxPages; page++ {
		var list []pull
		if err := g.get(ctx, query(path, page), true, &list); err != nil {
			return nil, nil, false, err
		}
		for _, p := range list {
			if before(p.UpdatedAt, since) {
				return merged, closed, false, nil
			}
			switch {
			case p.MergedAt != nil:
				if !before(*p.MergedAt, since) {
					merged = append(merged, MergedPR{PR: p.pr(), MergedAt: *p.MergedAt, MergeSHA: p.MergeSHA, Trusted: p.trusted(repo)})
				}
			case p.ClosedAt != nil && !before(*p.ClosedAt, since):
				closed = append(closed, ClosedPR{PR: p.pr(), ClosedAt: *p.ClosedAt, Trusted: p.trusted(repo)})
			}
		}
		if len(list) < perPage {
			return merged, closed, false, nil
		}
	}
	return merged, closed, true, nil
}

func (g *RealGitHub) OpenPRs(ctx context.Context, repo string) ([]OpenPR, error) {
	var out []OpenPR
	path := fmt.Sprintf("repos/%s/pulls?state=open&sort=created&direction=desc", repo)
	for page := 1; page <= maxPages; page++ {
		var list []pull
		if err := g.get(ctx, query(path, page), true, &list); err != nil {
			return nil, err
		}
		for _, p := range list {
			out = append(out, OpenPR{PR: p.pr(), Author: p.User.Login, Draft: p.Draft, Trusted: p.trusted(repo)})
		}
		if len(list) < perPage {
			break
		}
	}
	return out, nil
}

// conflictQuery is the open PRs and whether each can merge: REST's listing does not say.
const conflictQuery = `query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) {
  pullRequests(states: OPEN, first: 100, orderBy: {field: CREATED_AT, direction: DESC}) {
    nodes { number title headRefName url mergeable isCrossRepository authorAssociation author { login __typename } } } } }`

func (g *RealGitHub) ConflictPRs(ctx context.Context, repo string) ([]ConflictPR, error) {
	owner, name, ok := strings.Cut(repo, "/")
	if !ok {
		return nil, &GitHubError{Kind: NotFound, Message: "repo is owner/name"}
	}
	request, _ := json.Marshal(map[string]any{"query": conflictQuery, "variables": map[string]string{"owner": owner, "name": name}})
	body, err := g.shared("graphql pulls "+repo, func() ([]byte, error) {
		return g.do(ctx, http.MethodPost, "graphql", request, false)
	})
	if err != nil {
		return nil, err
	}
	var answer struct {
		Data struct {
			Repository *struct {
				PullRequests struct {
					Nodes []struct {
						Number      int    `json:"number"`
						Title       string `json:"title"`
						HeadRefName string `json:"headRefName"`
						URL         string `json:"url"`
						Mergeable   string `json:"mergeable"`
						CrossRepo   bool   `json:"isCrossRepository"`
						Association string `json:"authorAssociation"`
						Author      *struct {
							Login    string `json:"login"`
							Typename string `json:"__typename"`
						} `json:"author"`
					} `json:"nodes"`
				} `json:"pullRequests"`
			} `json:"repository"`
		} `json:"data"`
		Errors []struct {
			Type    string `json:"type"`
			Message string `json:"message"`
		} `json:"errors"`
	}
	if json.Unmarshal(body, &answer) != nil {
		return nil, &GitHubError{Kind: Failed, Message: "GitHub's answer is not JSON"}
	}
	if len(answer.Errors) > 0 {
		if answer.Errors[0].Type == "NOT_FOUND" {
			return nil, &GitHubError{Kind: NotFound, Message: "not found on GitHub"}
		}
		return nil, &GitHubError{Kind: Failed, Message: "GitHub: " + answer.Errors[0].Message}
	}
	if answer.Data.Repository == nil {
		return nil, &GitHubError{Kind: NotFound, Message: "not found on GitHub"}
	}
	var out []ConflictPR
	for _, n := range answer.Data.Repository.PullRequests.Nodes {
		c := ConflictPR{PR: PR{Number: n.Number, Title: n.Title, Branch: n.HeadRefName, URL: n.URL}}
		// A deleted account is no author: not trusted.
		if n.Author != nil && !n.CrossRepo {
			c.Trusted = isTrusted(n.Association, n.Author.Login, n.Author.Typename)
		}
		// UNKNOWN while GitHub works it out: neither yes nor no.
		switch n.Mergeable {
		case "CONFLICTING":
			c.Conflicts = new(true)
		case "MERGEABLE":
			c.Conflicts = new(false)
		}
		out = append(out, c)
	}
	return out, nil
}

// yoursQuery is the connection's owner and, in one repo, their open PRs, the open PRs that ask
// them for a review, and the open issues assigned to them (#2034): GitHub's search, as @me.
const yoursQuery = `query($mine: String!, $reviews: String!, $assigned: String!) { viewer { login }
  mine: search(query: $mine, type: ISSUE, first: 100) { nodes { ... on PullRequest { number } } }
  reviews: search(query: $reviews, type: ISSUE, first: 100) { nodes { ... on PullRequest {
    number title headRefName url author { login } } } }
  assigned: search(query: $assigned, type: ISSUE, first: 100) { nodes { ... on Issue {
    number title url author { login } labels(first: 20) { nodes { name } } assignees(first: 10) { nodes { login } } } } } }`

func (g *RealGitHub) Yours(ctx context.Context, repo string) (Yours, error) {
	in := "repo:" + repo + " is:open "
	request, _ := json.Marshal(map[string]any{"query": yoursQuery, "variables": map[string]string{
		"mine": in + "is:pr author:@me", "reviews": in + "is:pr review-requested:@me", "assigned": in + "is:issue assignee:@me"}})
	body, err := g.shared("graphql yours "+repo, func() ([]byte, error) {
		return g.do(ctx, http.MethodPost, "graphql", request, false)
	})
	if err != nil {
		return Yours{}, err
	}
	type login struct {
		Login string `json:"login"`
	}
	var answer struct {
		Data struct {
			Viewer login `json:"viewer"`
			Mine   struct {
				Nodes []struct {
					Number int `json:"number"`
				} `json:"nodes"`
			} `json:"mine"`
			Reviews struct {
				Nodes []struct {
					Number      int    `json:"number"`
					Title       string `json:"title"`
					HeadRefName string `json:"headRefName"`
					URL         string `json:"url"`
					Author      *login `json:"author"`
				} `json:"nodes"`
			} `json:"reviews"`
			Assigned struct {
				Nodes []struct {
					Number int    `json:"number"`
					Title  string `json:"title"`
					URL    string `json:"url"`
					Author *login `json:"author"`
					Labels struct {
						Nodes []struct {
							Name string `json:"name"`
						} `json:"nodes"`
					} `json:"labels"`
					Assignees struct {
						Nodes []login `json:"nodes"`
					} `json:"assignees"`
				} `json:"nodes"`
			} `json:"assigned"`
		} `json:"data"`
		Errors []struct {
			Message string `json:"message"`
		} `json:"errors"`
	}
	if json.Unmarshal(body, &answer) != nil {
		return Yours{}, &GitHubError{Kind: Failed, Message: "GitHub's answer is not JSON"}
	}
	if len(answer.Errors) > 0 {
		return Yours{}, &GitHubError{Kind: Failed, Message: "GitHub: " + answer.Errors[0].Message}
	}
	y := Yours{Login: answer.Data.Viewer.Login}
	for _, n := range answer.Data.Mine.Nodes {
		if n.Number > 0 {
			y.PRs = append(y.PRs, n.Number)
		}
	}
	for _, n := range answer.Data.Reviews.Nodes {
		if n.Number == 0 {
			continue
		}
		r := OpenPR{PR: PR{Number: n.Number, Title: n.Title, Branch: n.HeadRefName, URL: n.URL}}
		if n.Author != nil {
			r.Author = n.Author.Login
		}
		y.Reviews = append(y.Reviews, r)
	}
	for _, n := range answer.Data.Assigned.Nodes {
		if n.Number == 0 {
			continue
		}
		i := Issue{Number: n.Number, Title: n.Title, URL: n.URL, Labels: []string{}, Assignees: []string{}}
		if n.Author != nil {
			i.Author = n.Author.Login
		}
		for _, l := range n.Labels.Nodes {
			i.Labels = append(i.Labels, l.Name)
		}
		for _, a := range n.Assignees.Nodes {
			i.Assignees = append(i.Assignees, a.Login)
		}
		y.Assigned = append(y.Assigned, i)
	}
	return y, nil
}

// newest pages path (newest first) until an item older than since by its time.
func newest[T any](ctx context.Context, g *RealGitHub, path, since string, at func(T) string) ([]T, bool, error) {
	var items []T
	for page := 1; page <= maxPages; page++ {
		var list []T
		if err := g.get(ctx, query(path, page), true, &list); err != nil {
			return nil, false, err
		}
		for _, item := range list {
			if before(at(item), since) {
				return items, false, nil
			}
			items = append(items, item)
		}
		if len(list) < perPage {
			return items, false, nil
		}
	}
	return items, true, nil
}

func (g *RealGitHub) IssueActivity(ctx context.Context, repo string, kind IssueKind, since string) ([]IssueActivity, bool, error) {
	switch kind {
	case IssueOpened:
		items, truncated, err := newest(ctx, g, fmt.Sprintf("repos/%s/issues?state=all&sort=created&direction=desc", repo), since,
			func(i issueJSON) string { return i.CreatedAt })
		if err != nil {
			return nil, false, err
		}
		var out []IssueActivity
		for _, i := range items {
			if !i.isPR() {
				out = append(out, IssueActivity{ID: strconv.Itoa(i.Number), At: i.CreatedAt, Issue: i.issue(), Kind: IssueOpened,
					Trusted: i.trusted()})
			}
		}
		return out, truncated, nil
	case IssueCommented:
		type comment struct {
			ID          int    `json:"id"`
			HTMLURL     string `json:"html_url"`
			IssueURL    string `json:"issue_url"`
			Body        string `json:"body"`
			User        user   `json:"user"`
			Association string `json:"author_association"`
			CreatedAt   string `json:"created_at"`
		}
		// since lists comments updated since; an edited old one is dropped by its created_at.
		path := fmt.Sprintf("repos/%s/issues/comments?sort=created&direction=desc&since=%s", repo, url.QueryEscape(since))
		items, truncated, err := newest(ctx, g, path, since, func(c comment) string { return c.CreatedAt })
		if err != nil {
			return nil, false, err
		}
		var out []IssueActivity
		issues := map[string]issueJSON{}
		for _, c := range items {
			// A comment doesn't say whether its issue is a pull request; the issue does (and is cached).
			path := strings.TrimPrefix(c.IssueURL, g.API)
			path = strings.TrimPrefix(path, "https://api.github.com/")
			i, ok := issues[path]
			if !ok {
				if err := g.get(ctx, path, false, &i); err != nil {
					return nil, false, err
				}
				issues[path] = i
			}
			if i.isPR() {
				continue
			}
			out = append(out, IssueActivity{ID: strconv.Itoa(c.ID), At: c.CreatedAt, Issue: i.issue(), Kind: IssueCommented,
				CommentAuthor: c.User.Login, CommentURL: c.HTMLURL, CommentBody: clip(c.Body),
				Trusted: isTrusted(c.Association, c.User.Login, c.User.Type)})
		}
		return out, truncated, nil
	}
	type issueEvent struct {
		ID          int        `json:"id"`
		Event       string     `json:"event"`
		Actor       user       `json:"actor"`
		Label       label      `json:"label"`
		StateReason string     `json:"state_reason"`
		CreatedAt   string     `json:"created_at"`
		Issue       *issueJSON `json:"issue"`
	}
	items, truncated, err := newest(ctx, g, fmt.Sprintf("repos/%s/issues/events", repo), since,
		func(e issueEvent) string { return e.CreatedAt })
	if err != nil {
		return nil, false, err
	}
	wanted := "labeled"
	if kind == IssueClosed {
		wanted = "closed"
	}
	var out []IssueActivity
	for _, e := range items {
		if e.Event != wanted || e.Issue == nil || e.Issue.isPR() {
			continue
		}
		a := IssueActivity{ID: strconv.Itoa(e.ID), At: e.CreatedAt, Issue: e.Issue.issue(), Kind: kind, By: e.Actor.Login,
			Trusted: isTrustedActor(e.Actor.Login, e.Actor.Type, kind == IssueClosed, e.Issue.User.Login, e.Issue.trusted())}
		if kind == IssueLabelled {
			a.Label = e.Label.Name
		} else {
			reason := e.StateReason
			if reason == "" {
				reason = e.Issue.StateReason
			}
			a.Reason = reasonOf(reason)
		}
		out = append(out, a)
	}
	return out, truncated, nil
}

// MARK: The host's connection

// NotConnected is what a call says with no token: the person connects GitHub in Agents.
const NotConnected = "GitHub is not connected, or its sign-in ended: connect GitHub in Agents (Connectors)"

// Token is the access token of the host's GitHub connection (#1335), read from the host's
// store (connections.EnvName) again after a minute or once it has ended, so a sign-in or a
// renewal is seen without a restart. "" when there is none. The host refreshes it.
func Token() func() string {
	return connections.TokenReader(connections.FromEnv(), connections.GitHub)
}

// GitRepo is the GitHub repo this folder pushes to, from its git remote (origin first),
// asked once it succeeds.
func GitRepo() func(ctx context.Context) (string, error) {
	var mu sync.Mutex
	var repo string
	return func(ctx context.Context) (string, error) {
		mu.Lock()
		defer mu.Unlock()
		if repo != "" {
			return repo, nil
		}
		for _, remote := range gitRemotes(ctx) {
			out, err := exec.CommandContext(ctx, "git", "remote", "get-url", remote).Output()
			if err != nil {
				continue
			}
			if name, ok := RepoOfRemote(strings.TrimSpace(string(out))); ok {
				repo = name
				return repo, nil
			}
		}
		cwd, _ := os.Getwd()
		return "", &GitHubError{Kind: NotFound, Message: "repo is needed: " + cwd + " has no GitHub remote"}
	}
}

// gitRemotes is the folder's remotes, origin first.
func gitRemotes(ctx context.Context) []string {
	out, err := exec.CommandContext(ctx, "git", "remote").Output()
	if err != nil {
		return nil
	}
	remotes := []string{}
	for _, r := range strings.Fields(string(out)) {
		if r == "origin" {
			remotes = append([]string{r}, remotes...)
		} else {
			remotes = append(remotes, r)
		}
	}
	return remotes
}

// RepoOfRemote is owner/name of a github.com remote: https://github.com/o/n(.git),
// git@github.com:o/n(.git) or ssh://git@github.com/o/n(.git).
func RepoOfRemote(remote string) (string, bool) {
	rest := ""
	for _, prefix := range []string{"https://github.com/", "http://github.com/", "git@github.com:",
		"ssh://git@github.com/", "git://github.com/"} {
		if r, ok := strings.CutPrefix(remote, prefix); ok {
			rest = r
			break
		}
	}
	if rest == "" && strings.HasPrefix(remote, "https://") {
		// https://user@github.com/o/n: a remote with a name in it.
		if _, r, ok := strings.Cut(strings.TrimPrefix(remote, "https://"), "@github.com/"); ok {
			rest = r
		}
	}
	rest = strings.TrimSuffix(strings.TrimSuffix(rest, "/"), ".git")
	owner, name, ok := strings.Cut(rest, "/")
	if !ok || owner == "" || name == "" || strings.Contains(name, "/") {
		return "", false
	}
	return owner + "/" + name, true
}
