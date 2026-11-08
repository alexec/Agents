package azuredevopsmcp

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"mime"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// RealAzureDevOps reads Azure DevOps's REST API (7.1) as the person, with the personal access
// token Token gives: AZURE_DEVOPS_TOKEN, with Code (read and write) and Build (read). Base is
// dev.azure.com or the person's own Azure DevOps Server. The listings events poll are shared
// for sharedFor, as the gitlab server's (#932): every wait polls on its own, and ten waits on
// one repository would otherwise fetch the same page ten times.
type RealAzureDevOps struct {
	// Base is Azure DevOps's root, with a trailing slash: https://dev.azure.com/, or a
	// server's collections' root, https://server/tfs/.
	Base   string
	Token  func() string
	Client *http.Client
	// Repo is the repository the server's folder pushes to, read from git once it is needed.
	Repo func(ctx context.Context) (string, error)

	mu      sync.Mutex
	recent  map[string]sharedBody
	running map[string]*fetch
	sharing time.Duration
	// repos is each repository's id and default branch, which do not change while it runs.
	repos map[string]repoJSON
}

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
	// perPage is the most of one page that a pull request or build listing is asked for.
	perPage = 100
	// sharedFor is under the 30 s poll, so each poll still sees a fresh page.
	sharedFor = 25 * time.Second
	// maxChecked bounds the active pull requests whose threads a poll reads, newest first.
	maxChecked = 50
	// maxRepos bounds the repositories whose ids are kept.
	maxRepos = 100
	// apiVersion is the REST API's version: Azure DevOps Services and Server 2022.1 and later.
	apiVersion = "7.1"
)

// DefaultBase is Azure DevOps Services.
const DefaultBase = "https://dev.azure.com/"

// NewRealAzureDevOps reads the Azure DevOps at base (dev.azure.com when empty) with token's answer.
func NewRealAzureDevOps(base string, token func() string, repo func(ctx context.Context) (string, error)) *RealAzureDevOps {
	return &RealAzureDevOps{Base: BaseURL(base), Token: token, Repo: repo,
		// A sign-in page is an answer to a token it does not take: never followed.
		Client: &http.Client{Timeout: 30 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		}},
		recent: map[string]sharedBody{}, running: map[string]*fetch{}, sharing: sharedFor, repos: map[string]repoJSON{}}
}

// BaseURL is base as Azure DevOps's root with a trailing slash: dev.azure.com when empty, and
// https:// when it names no scheme.
func BaseURL(base string) string {
	base = strings.TrimSpace(base)
	if base == "" {
		return DefaultBase
	}
	if !strings.Contains(base, "://") {
		base = "https://" + base
	}
	return strings.TrimSuffix(base, "/") + "/"
}

// MARK: HTTP

// NotConnected is what a call says with no token, or one Azure DevOps no longer takes.
const NotConnected = "Azure DevOps is not connected, or its token ended: connect Azure DevOps in Connectors, or set AZURE_DEVOPS_TOKEN to a personal access token with Code (read and write) and Build (read)"

func (f *RealAzureDevOps) do(ctx context.Context, method, path string, body any) ([]byte, error) {
	token := f.Token()
	if token == "" {
		return nil, &AzureDevOpsError{Kind: NotSignedIn, Message: NotConnected}
	}
	var reader io.Reader
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			return nil, &AzureDevOpsError{Kind: Failed, Message: "Azure DevOps: " + err.Error()}
		}
		reader = bytes.NewReader(data)
	}
	req, err := http.NewRequestWithContext(ctx, method, f.Base+path, reader)
	if err != nil {
		return nil, &AzureDevOpsError{Kind: Failed, Message: "Azure DevOps: " + err.Error()}
	}
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	// A personal access token is the password of Basic, with no user.
	req.Header.Set("Authorization", "Basic "+base64.StdEncoding.EncodeToString([]byte(":"+token)))
	req.Header.Set("User-Agent", "agents-azuredevops-mcp")
	res, err := f.Client.Do(req)
	if err != nil {
		return nil, &AzureDevOpsError{Kind: Failed, Message: "Azure DevOps: " + err.Error()}
	}
	defer res.Body.Close()
	data, err := io.ReadAll(io.LimitReader(res.Body, 64<<20))
	if err != nil {
		return nil, &AzureDevOpsError{Kind: Failed, Message: "Azure DevOps: " + err.Error()}
	}
	// A token it does not take is answered with a sign-in page: 203, or a redirect to it.
	kind, _, _ := mime.ParseMediaType(res.Header.Get("Content-Type"))
	if res.StatusCode == http.StatusNonAuthoritativeInfo || (res.StatusCode >= 300 && res.StatusCode < 400) ||
		(res.StatusCode < 300 && kind == "text/html") {
		return nil, &AzureDevOpsError{Kind: NotSignedIn, Message: NotConnected}
	}
	if res.StatusCode >= 200 && res.StatusCode < 300 {
		return data, nil
	}
	return nil, failure(res, data)
}

// failure is a response Azure DevOps refused, as what went wrong.
func failure(res *http.Response, body []byte) *AzureDevOpsError {
	var said struct {
		Message string `json:"message"`
	}
	_ = json.Unmarshal(body, &said)
	words := said.Message
	if len(words) > 300 {
		words = words[:300]
	}
	switch res.StatusCode {
	case http.StatusUnauthorized:
		return &AzureDevOpsError{Kind: NotSignedIn, Message: NotConnected}
	case http.StatusTooManyRequests:
		return &AzureDevOpsError{Kind: RateLimited, Message: "Azure DevOps rate limit", RetryAfterMs: retryAfter(res.Header)}
	case http.StatusNotFound:
		message := "not found on Azure DevOps"
		if words != "" {
			message += ": " + words
		}
		return &AzureDevOpsError{Kind: NotFound, Message: message}
	}
	message := fmt.Sprintf("Azure DevOps: HTTP %d", res.StatusCode)
	if words != "" {
		message += ": " + words
	}
	return &AzureDevOpsError{Kind: Failed, Message: message}
}

func retryAfter(h http.Header) int {
	if after, err := strconv.ParseFloat(h.Get("Retry-After"), 64); err == nil {
		return max(1000, int(after*1000))
	}
	return 60_000
}

// get is path's JSON; with shared, an answer fetched in the last sharedFor is used again, and
// a fetch already running is waited for.
func (f *RealAzureDevOps) get(ctx context.Context, path string, shared bool, into any) error {
	var body []byte
	var err error
	if shared {
		body, err = f.shared(path, func() ([]byte, error) { return f.do(ctx, http.MethodGet, path, nil) })
	} else {
		body, err = f.do(ctx, http.MethodGet, path, nil)
	}
	if err != nil {
		return err
	}
	if json.Unmarshal(body, into) != nil {
		return &AzureDevOpsError{Kind: Failed, Message: "Azure DevOps's answer is not JSON"}
	}
	return nil
}

func (f *RealAzureDevOps) send(ctx context.Context, method, path string, body, into any) error {
	data, err := f.do(ctx, method, path, body)
	if err != nil {
		return err
	}
	if into == nil || len(bytes.TrimSpace(data)) == 0 {
		return nil
	}
	if json.Unmarshal(data, into) != nil {
		return &AzureDevOpsError{Kind: Failed, Message: "Azure DevOps's answer is not JSON"}
	}
	return nil
}

func (f *RealAzureDevOps) shared(key string, get func() ([]byte, error)) ([]byte, error) {
	f.mu.Lock()
	now := time.Now()
	if kept, ok := f.recent[key]; ok && now.Sub(kept.at) < f.sharing {
		f.mu.Unlock()
		return kept.body, nil
	}
	if fe, ok := f.running[key]; ok {
		f.mu.Unlock()
		<-fe.done
		return fe.body, fe.err
	}
	fe := &fetch{done: make(chan struct{})}
	f.running[key] = fe
	f.mu.Unlock()

	fe.body, fe.err = get()
	close(fe.done)

	f.mu.Lock()
	delete(f.running, key)
	if fe.err == nil {
		for k, v := range f.recent {
			if now.Sub(v.at) >= f.sharing {
				delete(f.recent, k)
			}
		}
		f.recent[key] = sharedBody{time.Now(), fe.body}
	}
	f.mu.Unlock()
	return fe.body, fe.err
}

// splitRepo is a repository's organization, project and name.
func splitRepo(repo string) (org, project, name string) {
	parts := strings.SplitN(repo, "/", 3)
	for len(parts) < 3 {
		parts = append(parts, "")
	}
	return parts[0], parts[1], parts[2]
}

// projectPath is a repository's project's part of an API path: org/project/_apis/.
func projectPath(repo string) string {
	org, project, _ := splitRepo(repo)
	return url.PathEscape(org) + "/" + url.PathEscape(project) + "/_apis/"
}

// repoPath is a repository's part of an API path: org/project/_apis/git/repositories/name.
func repoPath(repo string) string {
	_, _, name := splitRepo(repo)
	return projectPath(repo) + "git/repositories/" + url.PathEscape(name)
}

// api is path with its query and the API's version.
func api(path string, query url.Values) string {
	if query == nil {
		query = url.Values{}
	}
	query.Set("api-version", apiVersion)
	return path + "?" + query.Encode()
}

// webURL is a repository's page: https://dev.azure.com/org/project/_git/name.
func (f *RealAzureDevOps) webURL(repo string) string { return WebURL(f.Base, repo) }

// WebURL is the page of a repository (organization/project/name) of the Azure DevOps at base.
func WebURL(base, repo string) string {
	org, project, name := splitRepo(repo)
	return BaseURL(base) + url.PathEscape(org) + "/" + url.PathEscape(project) + "/_git/" + url.PathEscape(name)
}

// pages lists path ($top and $skip) to its end, at most maxPages; truncated says it stopped there.
func pages[T any](ctx context.Context, f *RealAzureDevOps, path string, query url.Values) (items []T, truncated bool, err error) {
	for page := 0; page < maxPages; page++ {
		q := url.Values{}
		for k, v := range query {
			q[k] = v
		}
		q.Set("$top", strconv.Itoa(perPage))
		q.Set("$skip", strconv.Itoa(page*perPage))
		var list struct {
			Value []T `json:"value"`
		}
		if err := f.get(ctx, api(path, q), true, &list); err != nil {
			return nil, false, err
		}
		items = append(items, list.Value...)
		if len(list.Value) < perPage {
			return items, false, nil
		}
	}
	return items, true, nil
}

// MARK: Azure DevOps's JSON

type identity struct {
	ID          string `json:"id"`
	DisplayName string `json:"displayName"`
	UniqueName  string `json:"uniqueName"`
	Descriptor  string `json:"descriptor"`
	IsContainer bool   `json:"isContainer"`
}

// name is how an identity is named: its sign-in name, else its display name.
func (i identity) name() string {
	if i.UniqueName != "" && !strings.Contains(i.UniqueName, `\`) {
		return i.UniqueName
	}
	return i.DisplayName
}

type reviewerJSON struct {
	identity
	Vote        int  `json:"vote"`
	HasDeclined bool `json:"hasDeclined"`
	IsRequired  bool `json:"isRequired"`
}

type commitRef struct {
	CommitID string `json:"commitId"`
}

type labelJSON struct {
	Name   string `json:"name"`
	Active *bool  `json:"active"`
}

type repoJSON struct {
	ID            string `json:"id"`
	Name          string `json:"name"`
	DefaultBranch string `json:"defaultBranch"`
	WebURL        string `json:"webUrl"`
}

type pullJSON struct {
	ID                    int            `json:"pullRequestId"`
	Title                 string         `json:"title"`
	Description           string         `json:"description"`
	Status                string         `json:"status"`
	CreatedBy             identity       `json:"createdBy"`
	CreationDate          string         `json:"creationDate"`
	ClosedDate            string         `json:"closedDate"`
	SourceRefName         string         `json:"sourceRefName"`
	TargetRefName         string         `json:"targetRefName"`
	MergeStatus           string         `json:"mergeStatus"`
	IsDraft               bool           `json:"isDraft"`
	LastMergeSourceCommit *commitRef     `json:"lastMergeSourceCommit"`
	LastMergeCommit       *commitRef     `json:"lastMergeCommit"`
	Reviewers             []reviewerJSON `json:"reviewers"`
	Labels                []labelJSON    `json:"labels"`
	ForkSource            *struct {
		Name string `json:"name"`
	} `json:"forkSource"`
}

// branch is a ref's branch: refs/heads/feature is feature.
func branch(ref string) string { return strings.TrimPrefix(ref, "refs/heads/") }

func (p pullJSON) head() string {
	if p.LastMergeSourceCommit == nil {
		return ""
	}
	return p.LastMergeSourceCommit.CommitID
}

func (p pullJSON) labels() []string {
	out := []string{}
	for _, l := range p.Labels {
		if l.Active == nil || *l.Active {
			out = append(out, l.Name)
		}
	}
	return out
}

// fork says whether its branch is in another repository.
func (p pullJSON) fork() bool { return p.ForkSource != nil }

func (f *RealAzureDevOps) prURL(repo string, number int) string {
	return fmt.Sprintf("%s/pullrequest/%d", f.webURL(repo), number)
}

func (f *RealAzureDevOps) pr(repo string, p pullJSON) PR {
	return PR{Number: p.ID, Title: p.Title, Branch: branch(p.SourceRefName), URL: f.prURL(repo, p.ID), Fixes: closingRefs(p.Description)}
}

// trustedPR says whether a pull request is the repository's own: its branch in the
// repository, not a fork, and its author not a bot. Only a project's members can open one.
func trustedPR(p pullJSON) bool { return !p.fork() && !isBot(p.CreatedBy) }

type threadJSON struct {
	ID              int    `json:"id"`
	PublishedDate   string `json:"publishedDate"`
	LastUpdatedDate string `json:"lastUpdatedDate"`
	Status          string `json:"status"`
	IsDeleted       bool   `json:"isDeleted"`
	ThreadContext   *struct {
		FilePath       string `json:"filePath"`
		RightFileStart *struct {
			Line int `json:"line"`
		} `json:"rightFileStart"`
		LeftFileStart *struct {
			Line int `json:"line"`
		} `json:"leftFileStart"`
	} `json:"threadContext"`
	Comments []threadCommentJSON `json:"comments"`
}

type threadCommentJSON struct {
	ID              int      `json:"id"`
	ParentCommentID int      `json:"parentCommentId"`
	Author          identity `json:"author"`
	Content         string   `json:"content"`
	PublishedDate   string   `json:"publishedDate"`
	CommentType     string   `json:"commentType"`
	IsDeleted       bool     `json:"isDeleted"`
}

// onALine says whether a thread is on a line of the diff: a file and a line.
func (t threadJSON) onALine() bool {
	return !t.IsDeleted && t.ThreadContext != nil && t.ThreadContext.FilePath != "" && t.line() > 0
}

// line is the line a thread is on: the new file's, else the old file's.
func (t threadJSON) line() int {
	if c := t.ThreadContext; c != nil {
		if c.RightFileStart != nil && c.RightFileStart.Line > 0 {
			return c.RightFileStart.Line
		}
		if c.LeftFileStart != nil {
			return c.LeftFileStart.Line
		}
	}
	return 0
}

// resolved says whether a thread's status is one of the closed ones.
func (t threadJSON) resolved() bool {
	switch t.Status {
	case "fixed", "wontFix", "closed", "byDesign":
		return true
	}
	return false
}

// path is the thread's file without its leading slash.
func (t threadJSON) path() string { return strings.TrimPrefix(t.ThreadContext.FilePath, "/") }

type buildJSON struct {
	ID           int               `json:"id"`
	BuildNumber  string            `json:"buildNumber"`
	Status       string            `json:"status"`
	Result       string            `json:"result"`
	QueueTime    string            `json:"queueTime"`
	FinishTime   string            `json:"finishTime"`
	SourceBranch string            `json:"sourceBranch"`
	SourceVer    string            `json:"sourceVersion"`
	Reason       string            `json:"reason"`
	RequestedFor identity          `json:"requestedFor"`
	TriggerInfo  map[string]string `json:"triggerInfo"`
	Repository   struct {
		ID string `json:"id"`
	} `json:"repository"`
	Definition struct {
		ID   int    `json:"id"`
		Name string `json:"name"`
	} `json:"definition"`
	Links struct {
		Web struct {
			Href string `json:"href"`
		} `json:"web"`
	} `json:"_links"`
}

// prNumber is the pull request a build is of, from its trigger or its refs/pull/12/merge; 0 for none.
func (b buildJSON) prNumber() int {
	if n, err := strconv.Atoi(b.TriggerInfo["pr.number"]); err == nil {
		return n
	}
	if rest, ok := strings.CutPrefix(b.SourceBranch, "refs/pull/"); ok {
		if n, err := strconv.Atoi(strings.TrimSuffix(rest, "/merge")); err == nil {
			return n
		}
	}
	return 0
}

// ref is a build's branch or tag, with no refs/heads/ or refs/tags/: main, v0.16.0.
func (b buildJSON) ref() string {
	if tag, ok := strings.CutPrefix(b.SourceBranch, "refs/tags/"); ok {
		return tag
	}
	return branch(b.SourceBranch)
}

// fromFork says whether a build is of a pull request from a fork.
func (b buildJSON) fromFork() bool { return strings.EqualFold(b.TriggerInfo["pr.isFork"], "true") }

// buildPassed says whether a build's result passed, and done whether it passed or failed: a
// build canceled, or partly succeeded, is neither.
func buildPassed(result string) (passed, done bool) {
	return result == "succeeded", result == "succeeded" || result == "failed"
}

// statusJSON is a status another service set on a pull request, of one iteration or of all.
type statusJSON struct {
	ID           int    `json:"id"`
	State        string `json:"state"`
	Description  string `json:"description"`
	TargetURL    string `json:"targetUrl"`
	CreationDate string `json:"creationDate"`
	UpdatedDate  string `json:"updatedDate"`
	IterationID  int    `json:"iterationId"`
	Context      struct {
		Name  string `json:"name"`
		Genre string `json:"genre"`
	} `json:"context"`
}

// name is a status's context, genre/name.
func (s statusJSON) name() string {
	if s.Context.Genre != "" {
		return s.Context.Genre + "/" + s.Context.Name
	}
	return s.Context.Name
}

// at is when a status was set: its update, else its creation.
func (s statusJSON) at() string {
	if s.UpdatedDate != "" {
		return s.UpdatedDate
	}
	return s.CreationDate
}

// statusPassed is buildPassed for a status: error is a failure; pending, notSet and
// notApplicable are neither.
func statusPassed(state string) (passed, done bool) {
	return state == "succeeded", state == "succeeded" || state == "failed" || state == "error"
}

// MARK: Azure DevOps

func (f *RealAzureDevOps) DefaultRepo(ctx context.Context) (string, error) { return f.Repo(ctx) }

// repository is a repository's id and default branch, read once.
func (f *RealAzureDevOps) repository(ctx context.Context, repo string) (repoJSON, error) {
	f.mu.Lock()
	r, ok := f.repos[repo]
	f.mu.Unlock()
	if ok {
		return r, nil
	}
	if err := f.get(ctx, api(repoPath(repo), nil), false, &r); err != nil {
		return repoJSON{}, err
	}
	f.mu.Lock()
	if len(f.repos) >= maxRepos {
		f.repos = map[string]repoJSON{}
	}
	f.repos[repo] = r
	f.mu.Unlock()
	return r, nil
}

// openPulls are the active pull requests, newest first.
func (f *RealAzureDevOps) openPulls(ctx context.Context, repo string) ([]pullJSON, error) {
	list, _, err := pages[pullJSON](ctx, f, repoPath(repo)+"/pullrequests", url.Values{"searchCriteria.status": {"active"}})
	return list, err
}

// conflicts says whether an active pull request conflicts with its target; nil while Azure
// DevOps is still working it out.
func conflicts(p pullJSON) *bool {
	switch p.MergeStatus {
	case "conflicts":
		return new(true)
	case "succeeded", "rejectedByPolicy", "failure":
		return new(false)
	}
	return nil
}

func (f *RealAzureDevOps) OpenPRs(ctx context.Context, repo string) ([]OpenPR, error) {
	list, err := f.openPulls(ctx, repo)
	if err != nil {
		return nil, err
	}
	out := make([]OpenPR, 0, len(list))
	for _, p := range list {
		out = append(out, OpenPR{PR: f.pr(repo, p), Author: p.CreatedBy.name(), Draft: p.IsDraft, Conflicts: conflicts(p),
			HeadSHA: p.head(), Trusted: trustedPR(p)})
	}
	return out, nil
}

// me is the token's owner's id.
func (f *RealAzureDevOps) me(ctx context.Context, repo string) (string, error) {
	org, _, _ := splitRepo(repo)
	var c struct {
		AuthenticatedUser struct {
			ID string `json:"id"`
		} `json:"authenticatedUser"`
	}
	if err := f.get(ctx, url.PathEscape(org)+"/_apis/connectionData", true, &c); err != nil {
		return "", err
	}
	if c.AuthenticatedUser.ID == "" {
		return "", &AzureDevOpsError{Kind: NotSignedIn, Message: "Azure DevOps did not say whose the token is"}
	}
	return c.AuthenticatedUser.ID, nil
}

// Yours is the token's owner and, in one repository, their active pull requests and the
// active ones they are a reviewer of and have not voted on (#2034).
func (f *RealAzureDevOps) Yours(ctx context.Context, repo string) (Yours, error) {
	id, err := f.me(ctx, repo)
	if err != nil {
		return Yours{}, err
	}
	y := Yours{ID: id}
	pulls, err := f.openPulls(ctx, repo)
	if err != nil {
		return Yours{}, err
	}
	for _, p := range pulls {
		if strings.EqualFold(p.CreatedBy.ID, id) {
			y.PRs = append(y.PRs, p.ID)
		}
		for _, r := range p.Reviewers {
			if strings.EqualFold(r.ID, id) && r.Vote == 0 && !r.HasDeclined {
				y.Reviews = append(y.Reviews, OpenPR{PR: f.pr(repo, p), Author: p.CreatedBy.name(), Draft: p.IsDraft, HeadSHA: p.head()})
				break
			}
		}
	}
	return y, nil
}

// closedPulls are the pull requests completed or abandoned at or after since.
func (f *RealAzureDevOps) closedPulls(ctx context.Context, repo, since string) ([]pullJSON, Listed, error) {
	list, truncated, err := pages[pullJSON](ctx, f, repoPath(repo)+"/pullrequests", url.Values{
		"searchCriteria.status": {"all"}, "searchCriteria.queryTimeRangeType": {"closed"}, "searchCriteria.minTime": {since}})
	if err != nil {
		return nil, Listed{}, err
	}
	listed := Listed{Truncated: truncated}
	var out []pullJSON
	for _, p := range list {
		if p.Status == "active" || p.ClosedDate == "" {
			continue
		}
		listed = listed.saw(p.ClosedDate)
		if !before(p.ClosedDate, since) {
			out = append(out, p)
		}
	}
	return out, listed, nil
}

func (f *RealAzureDevOps) ClosedPRs(ctx context.Context, repo, since string) ([]MergedPR, []ClosedPR, Listed, error) {
	list, listed, err := f.closedPulls(ctx, repo, since)
	if err != nil {
		return nil, nil, Listed{}, err
	}
	var merged []MergedPR
	var closed []ClosedPR
	for _, p := range list {
		switch p.Status {
		case "completed":
			sha := ""
			if p.LastMergeCommit != nil {
				sha = p.LastMergeCommit.CommitID
			}
			merged = append(merged, MergedPR{PR: f.pr(repo, p), MergedAt: p.ClosedDate, MergeSHA: sha, Trusted: trustedPR(p)})
		case "abandoned":
			closed = append(closed, ClosedPR{PR: f.pr(repo, p), ClosedAt: p.ClosedDate, Trusted: trustedPR(p)})
		}
	}
	return merged, closed, listed, nil
}

// builds are the repository's builds that finished at or after since, whatever started them
// (a pull request, a push to a branch, a person) and whatever their result, newest first, at
// most one page: checks.failed and checks.passed share the one fetch.
func (f *RealAzureDevOps) builds(ctx context.Context, repo, since string) ([]buildJSON, bool, error) {
	r, err := f.repository(ctx, repo)
	if err != nil {
		return nil, false, err
	}
	q := url.Values{"repositoryId": {r.ID}, "repositoryType": {"TfsGit"}, "statusFilter": {"completed"}, "minTime": {since},
		"queryOrder": {"finishTimeDescending"}, "$top": {strconv.Itoa(perPage)}}
	var list struct {
		Value []buildJSON `json:"value"`
	}
	if err := f.get(ctx, api(projectPath(repo)+"build/builds", q), true, &list); err != nil {
		return nil, false, err
	}
	return list.Value, len(list.Value) == perPage, nil
}

// statuses are the statuses other services set on a pull request, every iteration's.
func (f *RealAzureDevOps) statuses(ctx context.Context, repo string, number int, shared bool) ([]statusJSON, error) {
	var list struct {
		Value []statusJSON `json:"value"`
	}
	err := f.get(ctx, api(fmt.Sprintf("%s/pullRequests/%d/statuses", repoPath(repo), number), nil), shared, &list)
	return list.Value, err
}

// lastIteration is a pull request's newest iteration (push): the one its head commit is.
func (f *RealAzureDevOps) lastIteration(ctx context.Context, repo string, number int) (int, error) {
	var list struct {
		Value []struct {
			ID int `json:"id"`
		} `json:"value"`
	}
	if err := f.get(ctx, api(fmt.Sprintf("%s/pullRequests/%d/iterations", repoPath(repo), number), nil), true, &list); err != nil {
		return 0, err
	}
	last := 0
	for _, i := range list.Value {
		last = max(last, i.ID)
	}
	return last, nil
}

// headCheck is a build or a status that finished, passed or failed, at an active pull
// request's head commit. key is build:<id> or status:<id>; runID is 0 for a status.
type headCheck struct {
	pr     pullJSON
	at     string
	check  Check
	runID  int
	key    string
	passed bool
}

// headChecks reads what finished at an active pull request's head commit at or after since:
// the repository's builds, a pull request's own or its branch's at its head commit, and the
// newest status of each context on the maxChecked newest active pull requests, at its newest
// iteration. A build or a status that neither passed nor failed (canceled, partly succeeded,
// pending) is not one. A build of an older push is not its head's.
func (f *RealAzureDevOps) headChecks(ctx context.Context, repo, since string) ([]headCheck, Listed, error) {
	builds, truncated, err := f.builds(ctx, repo, since)
	if err != nil {
		return nil, Listed{}, err
	}
	pulls, err := f.openPulls(ctx, repo)
	if err != nil {
		return nil, Listed{}, err
	}
	byNumber := map[int]pullJSON{}
	byBranch := map[string][]pullJSON{}
	for _, p := range pulls {
		byNumber[p.ID] = p
		// A fork's branch is not in this repository, so this repository's builds are not its.
		if !p.fork() {
			byBranch[p.SourceRefName] = append(byBranch[p.SourceRefName], p)
		}
	}
	listed := Listed{Truncated: truncated}
	var out []headCheck
	// Oldest first, so the first failed build is the run.
	for i := len(builds) - 1; i >= 0; i-- {
		b := builds[i]
		listed = listed.saw(b.FinishTime)
		passed, done := buildPassed(b.Result)
		if !done || before(b.FinishTime, since) {
			continue
		}
		var of []pullJSON
		if n := b.prNumber(); n != 0 {
			p, ok := byNumber[n]
			sha := b.TriggerInfo["pr.sourceSha"]
			if ok && (sha == "" || p.head() == "" || strings.EqualFold(sha, p.head())) {
				of = append(of, p)
			}
		} else {
			// A push's build of a pull request's branch, as a CI trigger starts it.
			for _, p := range byBranch[b.SourceBranch] {
				if p.head() != "" && strings.EqualFold(b.SourceVer, p.head()) {
					of = append(of, p)
				}
			}
		}
		for _, p := range of {
			out = append(out, headCheck{pr: p, at: normalized(b.FinishTime), check: Check{Name: b.Definition.Name, URL: b.Links.Web.Href},
				runID: b.ID, key: fmt.Sprintf("build:%d", b.ID), passed: passed})
		}
	}
	for _, p := range pulls[:min(maxChecked, len(pulls))] {
		statuses, err := f.statuses(ctx, repo, p.ID, true)
		if err != nil {
			return nil, Listed{}, err
		}
		newest := map[string]statusJSON{}
		for _, s := range statuses {
			if had, ok := newest[s.name()]; !ok || s.ID > had.ID {
				newest[s.name()] = s
			}
		}
		names := make([]string, 0, len(newest))
		for name := range newest {
			names = append(names, name)
		}
		sort.Strings(names)
		last := -1 // not read yet: only a status that would be raised reads it
		for _, name := range names {
			s := newest[name]
			listed = listed.saw(s.at())
			passed, done := statusPassed(s.State)
			if !done || before(s.at(), since) {
				continue
			}
			// A status of an iteration is of that push's commit; one with none is of the pull request.
			if s.IterationID != 0 {
				if last < 0 {
					if last, err = f.lastIteration(ctx, repo, p.ID); err != nil {
						return nil, Listed{}, err
					}
				}
				if s.IterationID != last {
					continue
				}
			}
			out = append(out, headCheck{pr: p, at: normalized(s.at()), check: Check{Name: name, URL: s.TargetURL},
				key: fmt.Sprintf("status:%d", s.ID), passed: passed})
		}
	}
	return out, listed, nil
}

// FailedChecks reads the builds and statuses that failed since at an active pull request's
// head commit, one FailedChecks a pull request.
func (f *RealAzureDevOps) FailedChecks(ctx context.Context, repo, since string) ([]FailedChecks, Listed, error) {
	checks, listed, err := f.headChecks(ctx, repo, since)
	if err != nil {
		return nil, Listed{}, err
	}
	byPR := map[int]*FailedChecks{}
	var order []int
	for _, c := range checks {
		if c.passed {
			continue
		}
		d, ok := byPR[c.pr.ID]
		if !ok {
			d = &FailedChecks{PR: f.pr(repo, c.pr), HeadSHA: c.pr.head(), Failed: []Check{}, Trusted: trustedPR(c.pr)}
			byPR[c.pr.ID] = d
			order = append(order, c.pr.ID)
		}
		// The run is the first failed build; with none, the first failed status.
		if d.RunID == 0 && (c.runID != 0 || len(d.Failed) == 0) {
			d.RunID, d.RunName, d.RunURL = c.runID, c.check.Name, c.check.URL
		}
		if c.at > d.At {
			d.At = c.at
		}
		d.Failed = append(d.Failed, c.check)
	}
	out := make([]FailedChecks, 0, len(order))
	for _, n := range order {
		out = append(out, *byPR[n])
	}
	return out, listed, nil
}

// PassedChecks reads the builds and statuses that passed since at an active pull request's
// head commit, one each.
func (f *RealAzureDevOps) PassedChecks(ctx context.Context, repo, since string) ([]PassedCheck, Listed, error) {
	checks, listed, err := f.headChecks(ctx, repo, since)
	if err != nil {
		return nil, Listed{}, err
	}
	var out []PassedCheck
	for _, c := range checks {
		if c.passed {
			out = append(out, PassedCheck{PR: f.pr(repo, c.pr), HeadSHA: c.pr.head(), At: c.at, Key: c.key,
				RunID: c.runID, RunName: c.check.Name, RunURL: c.check.URL, Trusted: trustedPR(c.pr)})
		}
	}
	return out, listed, nil
}

// CompletedBuilds reads the builds that finished since, of any trigger and any result: the
// listing checks.failed and checks.passed share (#932), or one build by its id.
func (f *RealAzureDevOps) CompletedBuilds(ctx context.Context, repo, pipeline, branch string, run int, since string) ([]CompletedBuild, Listed, error) {
	var builds []buildJSON
	listed := Listed{}
	if run != 0 {
		r, err := f.repository(ctx, repo)
		if err != nil {
			return nil, Listed{}, err
		}
		var b buildJSON
		if err := f.get(ctx, api(fmt.Sprintf("%sbuild/builds/%d", projectPath(repo), run), nil), true, &b); err != nil {
			return nil, Listed{}, err
		}
		// A build id is the project's: one of another repository is not this one's.
		if b.Repository.ID == r.ID {
			builds = append(builds, b)
		}
	} else {
		var err error
		if builds, listed.Truncated, err = f.builds(ctx, repo, since); err != nil {
			return nil, Listed{}, err
		}
	}
	var out []CompletedBuild
	for _, b := range builds {
		listed = listed.saw(b.FinishTime)
		if b.Status != "completed" || before(b.FinishTime, since) ||
			(pipeline != "" && !strings.EqualFold(b.Definition.Name, pipeline)) ||
			(branch != "" && b.ref() != branch && b.SourceBranch != branch) {
			continue
		}
		head := b.SourceVer
		if sha := b.TriggerInfo["pr.sourceSha"]; sha != "" {
			head = sha
		}
		out = append(out, CompletedBuild{ID: b.ID, Name: b.Definition.Name, Number: b.BuildNumber, Reason: b.Reason, Branch: b.ref(),
			HeadSHA: head, URL: b.Links.Web.Href, Result: b.Result, Actor: b.RequestedFor.name(), At: normalized(b.FinishTime),
			Trusted: !b.fromFork() && b.RequestedFor.ID != "" && !isBot(b.RequestedFor)})
	}
	return out, listed, nil
}

// threads are a pull request's threads, shared as listings are.
func (f *RealAzureDevOps) threads(ctx context.Context, repo string, number int, shared bool) ([]threadJSON, error) {
	var list struct {
		Value []threadJSON `json:"value"`
	}
	err := f.get(ctx, api(fmt.Sprintf("%s/pullRequests/%d/threads", repoPath(repo), number), nil), shared, &list)
	return list.Value, err
}

// ReviewComments reads the threads of the maxChecked newest active pull requests and of those
// closed since: Azure DevOps has no list of a repository's comments, nor a pull request's
// time of its last change.
func (f *RealAzureDevOps) ReviewComments(ctx context.Context, repo, since string) ([]ReviewComment, Listed, error) {
	pulls, err := f.openPulls(ctx, repo)
	if err != nil {
		return nil, Listed{}, err
	}
	pulls = pulls[:min(maxChecked, len(pulls))]
	closed, _, err := f.closedPulls(ctx, repo, since)
	if err != nil {
		return nil, Listed{}, err
	}
	var out []ReviewComment
	var listed Listed
	for _, p := range append(pulls, closed...) {
		threads, err := f.threads(ctx, repo, p.ID, true)
		if err != nil {
			return nil, Listed{}, err
		}
		for _, t := range threads {
			if !t.onALine() {
				continue
			}
			for _, c := range t.Comments {
				if c.IsDeleted || c.CommentType == "system" {
					continue
				}
				listed = listed.saw(c.PublishedDate)
				if before(c.PublishedDate, since) {
					continue
				}
				out = append(out, ReviewComment{ID: c.ID, ThreadID: t.ID, At: c.PublishedDate, PR: f.pr(repo, p), Author: c.Author.name(),
					Path: t.path(), Line: t.line(), Body: clip(c.Content), URL: fmt.Sprintf("%s?discussionId=%d", f.prURL(repo, p.ID), t.ID),
					Trusted: !p.fork() && !isBot(c.Author)})
			}
		}
	}
	return out, listed, nil
}

// MARK: The folder's repository

// GitRepo is the repository of this Azure DevOps that this folder pushes to, from its git
// remote (origin first), asked once it succeeds.
func GitRepo(base string) func(ctx context.Context) (string, error) {
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
			if path, ok := RepoOfRemote(base, strings.TrimSpace(string(out))); ok {
				repo = path
				return repo, nil
			}
		}
		cwd, _ := os.Getwd()
		host := base
		if u, err := url.Parse(BaseURL(base)); err == nil {
			host = u.Host
		}
		return "", &AzureDevOpsError{Kind: NotFound, Message: "repo is needed: " + cwd + " has no " + host + " remote"}
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

// RepoOfRemote is the repository (organization/project/name) of a remote of the Azure DevOps
// at base. Of dev.azure.com:
//
//	https://[user@]dev.azure.com/org/project/_git/name
//	git@ssh.dev.azure.com:v3/org/project/name
//	https://org.visualstudio.com/[DefaultCollection/]project/_git/name
//	org@vs-ssh.visualstudio.com:v3/org/project/name
//
// and of a server at https://server/tfs/, https://server/tfs/collection/project/_git/name and
// ssh://server:22/tfs/collection/project/_git/name. A repository named as its project leaves
// the project out: org/_git/name.
func RepoOfRemote(base, remote string) (string, bool) {
	b, err := url.Parse(BaseURL(base))
	if err != nil || b.Host == "" {
		return "", false
	}
	host, prefix := strings.ToLower(b.Hostname()), strings.Trim(b.Path, "/")
	services := host == "dev.azure.com"
	var rhost, rpath string
	if strings.Contains(remote, "://") {
		r, err := url.Parse(remote)
		if err != nil {
			return "", false
		}
		rhost, rpath = strings.ToLower(r.Hostname()), strings.Trim(r.EscapedPath(), "/")
	} else {
		// scp-like: [user@]host:path
		at := remote
		if _, after, ok := strings.Cut(remote, "@"); ok {
			at = after
		}
		h, path, ok := strings.Cut(at, ":")
		if !ok {
			return "", false
		}
		rhost, rpath = strings.ToLower(h), strings.Trim(path, "/")
	}
	var parts []string
	for _, p := range strings.Split(rpath, "/") {
		text, err := url.PathUnescape(p)
		if err != nil || text == "" {
			return "", false
		}
		parts = append(parts, text)
	}
	switch {
	case services && (rhost == "ssh.dev.azure.com" || rhost == "vs-ssh.visualstudio.com"):
		// v3/org/project/name
		if len(parts) != 4 || parts[0] != "v3" {
			return "", false
		}
		return joined(parts[1], parts[2], parts[3])
	case services && strings.HasSuffix(rhost, ".visualstudio.com"):
		org := strings.TrimSuffix(rhost, ".visualstudio.com")
		if len(parts) > 0 && strings.EqualFold(parts[0], "DefaultCollection") {
			parts = parts[1:]
		}
		return gitPath(org, parts)
	case rhost == host:
		if prefix != "" {
			p := strings.Split(prefix, "/")
			if len(parts) < len(p) || !strings.EqualFold(strings.Join(parts[:len(p)], "/"), prefix) {
				return "", false
			}
			parts = parts[len(p):]
		}
		if len(parts) == 0 {
			return "", false
		}
		return gitPath(parts[0], parts[1:])
	}
	return "", false
}

// gitPath is org's repository from what follows it: project/_git/name, or _git/name for one
// named as its project.
func gitPath(org string, parts []string) (string, bool) {
	switch {
	case len(parts) == 3 && parts[1] == "_git":
		return joined(org, parts[0], parts[2])
	case len(parts) == 2 && parts[0] == "_git":
		return joined(org, parts[1], parts[1])
	}
	return "", false
}

func joined(org, project, name string) (string, bool) {
	repo := org + "/" + project + "/" + strings.TrimSuffix(name, ".git")
	return repo, repoPattern.MatchString(repo)
}
