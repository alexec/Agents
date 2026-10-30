package gitlabmcp

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
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// RealGitLab reads GitLab's REST API v4 as the person, with the token Token gives: the GitLab
// connection's (#1630), or GITLAB_TOKEN (a personal, group or project access token with the
// api scope).
// Base is gitlab.com or a self-managed GitLab. The listings events poll are shared for
// sharedFor, as the github server's (#932): every wait polls on its own, and ten waits on
// one project would otherwise fetch the same page ten times.
type RealGitLab struct {
	// Base is GitLab's root, with a trailing slash: https://gitlab.com/.
	Base   string
	Token  func() string
	Client *http.Client
	// Project is the project the server's folder pushes to, read from git once it is needed.
	Project func(ctx context.Context) (string, error)

	mu      sync.Mutex
	recent  map[string]sharedBody
	running map[string]*fetch
	sharing time.Duration
	members map[string]member
	pages   map[string]openList
	kept    map[string]keptDiff
}

// openList is a page of open merge requests as GitLab last gave it, with its ETag.
type openList struct {
	at   time.Time
	etag string
	list []mergeRequest
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

type member struct {
	at    time.Time
	level int
}

const (
	maxPages = 10
	perPage  = 100
	// sharedFor is under the 30 s poll, so each poll still sees a fresh page.
	sharedFor = 25 * time.Second
	// memberFor is how long a person's access to a project is kept; maxMembers bounds how many.
	memberFor  = 10 * time.Minute
	maxMembers = 1000
	// maxKeptPages bounds the pages of open merge requests kept: ten for each of 50 projects.
	maxKeptPages = 500
)

// DefaultBase is gitlab.com.
const DefaultBase = "https://gitlab.com/"

// NewRealGitLab reads the GitLab at base (gitlab.com when empty) with token's answer.
func NewRealGitLab(base string, token func() string, project func(ctx context.Context) (string, error)) *RealGitLab {
	return &RealGitLab{Base: BaseURL(base), Token: token, Project: project, Client: &http.Client{Timeout: 30 * time.Second},
		recent: map[string]sharedBody{}, running: map[string]*fetch{}, sharing: sharedFor, members: map[string]member{}, pages: map[string]openList{}, kept: map[string]keptDiff{}}
}

// BaseURL is base as GitLab's root with a trailing slash: gitlab.com when empty, https:// when
// it names no scheme, and without an /api/v4 put on the end.
func BaseURL(base string) string {
	base = strings.TrimSpace(base)
	if base == "" {
		return DefaultBase
	}
	if !strings.Contains(base, "://") {
		base = "https://" + base
	}
	base = strings.TrimSuffix(strings.TrimSuffix(base, "/"), "/api/v4")
	return base + "/"
}

// MARK: HTTP

// NotConnected is what a call says with no token, or one GitLab no longer takes.
const NotConnected = "GitLab is not connected, or its token ended: connect GitLab in Connectors, or set GITLAB_TOKEN to an access token with the api scope"

func (g *RealGitLab) do(ctx context.Context, method, path string, body any) ([]byte, error) {
	res, err := g.request(ctx, method, path, body, "")
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	return answer(res)
}

// request asks GitLab, with If-None-Match when etag is set; the caller closes the answer's body.
func (g *RealGitLab) request(ctx context.Context, method, path string, body any, etag string) (*http.Response, error) {
	token := g.Token()
	if token == "" {
		return nil, &GitLabError{Kind: NotSignedIn, Message: NotConnected}
	}
	var reader io.Reader
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			return nil, &GitLabError{Kind: Failed, Message: "GitLab: " + err.Error()}
		}
		reader = bytes.NewReader(data)
	}
	req, err := http.NewRequestWithContext(ctx, method, g.Base+"api/v4/"+path, reader)
	if err != nil {
		return nil, &GitLabError{Kind: Failed, Message: "GitLab: " + err.Error()}
	}
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if etag != "" {
		req.Header.Set("If-None-Match", etag)
	}
	// A personal access token and an OAuth token both go as a bearer token; Go drops it on a
	// redirect to another host.
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("User-Agent", "agents-gitlab-mcp")
	res, err := g.Client.Do(req)
	if err != nil {
		return nil, &GitLabError{Kind: Failed, Message: "GitLab: " + err.Error()}
	}
	return res, nil
}

// answer is a response's body when GitLab took the request, and what went wrong when not.
func answer(res *http.Response) ([]byte, error) {
	data, err := io.ReadAll(io.LimitReader(res.Body, 64<<20))
	if err != nil {
		return nil, &GitLabError{Kind: Failed, Message: "GitLab: " + err.Error()}
	}
	if res.StatusCode >= 200 && res.StatusCode < 300 {
		return data, nil
	}
	return nil, failure(res, data)
}

// failure is a response GitLab refused, as what went wrong.
func failure(res *http.Response, body []byte) *GitLabError {
	var said struct {
		Message any    `json:"message"`
		Error   string `json:"error"`
	}
	_ = json.Unmarshal(body, &said)
	words := said.Error
	if said.Message != nil {
		words = fmt.Sprint(said.Message)
	}
	if len(words) > 300 {
		words = words[:300]
	}
	switch res.StatusCode {
	case http.StatusUnauthorized:
		return &GitLabError{Kind: NotSignedIn, Message: NotConnected}
	case http.StatusTooManyRequests:
		return &GitLabError{Kind: RateLimited, Message: "GitLab rate limit", RetryAfterMs: retryAfter(res.Header)}
	case http.StatusNotFound:
		return &GitLabError{Kind: NotFound, Message: "not found on GitLab", Refused: true}
	case http.StatusForbidden:
		if strings.Contains(words, "insufficient_scope") {
			return &GitLabError{Kind: Failed, Message: "GitLab refused: the token needs the api scope", Refused: true}
		}
	}
	message := fmt.Sprintf("GitLab: HTTP %d", res.StatusCode)
	if words != "" {
		message += ": " + words
	}
	return &GitLabError{Kind: Failed, Message: message, Refused: res.StatusCode == http.StatusForbidden}
}

func retryAfter(h http.Header) int {
	if after, err := strconv.ParseFloat(h.Get("Retry-After"), 64); err == nil {
		return max(1000, int(after*1000))
	}
	if reset, err := strconv.ParseFloat(h.Get("RateLimit-Reset"), 64); err == nil && reset > 0 {
		return max(1000, int(reset*1000-float64(time.Now().UnixMilli())))
	}
	return 60_000
}

// get is path's JSON; with shared, an answer fetched in the last sharedFor is used again, and
// a fetch already running is waited for.
func (g *RealGitLab) get(ctx context.Context, path string, shared bool, into any) error {
	var body []byte
	var err error
	if shared {
		body, err = g.shared(path, func() ([]byte, error) { return g.do(ctx, http.MethodGet, path, nil) })
	} else {
		body, err = g.do(ctx, http.MethodGet, path, nil)
	}
	if err != nil {
		return err
	}
	if json.Unmarshal(body, into) != nil {
		return &GitLabError{Kind: Failed, Message: "GitLab's answer is not JSON"}
	}
	return nil
}

// getAsOf is path's JSON shared as get shares it, but only with a fetch for the same asOf: a
// time the thing at path changed at, or something newer than it was seen at, so what is
// shared is never older than what the caller has seen.
func (g *RealGitLab) getAsOf(ctx context.Context, path, asOf string, into any) error {
	body, err := g.shared(path+" "+normalized(asOf), func() ([]byte, error) { return g.do(ctx, http.MethodGet, path, nil) })
	if err != nil {
		return err
	}
	if json.Unmarshal(body, into) != nil {
		return &GitLabError{Kind: Failed, Message: "GitLab's answer is not JSON"}
	}
	return nil
}

func (g *RealGitLab) send(ctx context.Context, method, path string, body, into any) error {
	data, err := g.do(ctx, method, path, body)
	if err != nil {
		return err
	}
	if json.Unmarshal(data, into) != nil {
		return &GitLabError{Kind: Failed, Message: "GitLab's answer is not JSON"}
	}
	return nil
}

func (g *RealGitLab) shared(key string, get func() ([]byte, error)) ([]byte, error) {
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

// pid is a project, by path or id, as one part of an API path: group%2Fname.
func pid(project string) string {
	return strings.ReplaceAll(url.PathEscape(project), "/", "%2F")
}

func query(path string, page int) string {
	sep := "?"
	if strings.Contains(path, "?") {
		sep = "&"
	}
	return fmt.Sprintf("%s%sper_page=%d&page=%d", path, sep, perPage, page)
}

// newest pages path (newest first) until an item older than since by its time.
func newest[T any](ctx context.Context, g *RealGitLab, path, since string, at func(T) string) ([]T, Listed, error) {
	var items []T
	var listed Listed
	for page := 1; page <= maxPages; page++ {
		var list []T
		if err := g.get(ctx, query(path, page), true, &list); err != nil {
			return nil, Listed{}, err
		}
		for _, item := range list {
			if before(at(item), since) {
				return items, listed, nil
			}
			items = append(items, item)
			listed = listed.saw(at(item))
		}
		if len(list) < perPage {
			return items, listed, nil
		}
	}
	listed.Truncated = true
	return items, listed, nil
}

// labelled is every label added to an issue at or after since: the issues updated since, and
// each one's label events (GitLab has no project-wide list of them). Adding a label updates
// the issue, so none is missed; an issue updated for another reason costs one more read. The
// label events are shared by the issue's update time: unchanged, its labels are too.
func (g *RealGitLab) labelled(ctx context.Context, project, since string) ([]IssueActivity, Listed, error) {
	path := fmt.Sprintf("projects/%s/issues?updated_after=%s&order_by=updated_at&sort=desc", pid(project), url.QueryEscape(since))
	items, listed, err := newest(ctx, g, path, since, func(i issueJSON) string { return i.UpdatedAt })
	if err != nil {
		return nil, Listed{}, err
	}
	var out []IssueActivity
	for _, i := range items {
		var events []struct {
			ID        int    `json:"id"`
			Action    string `json:"action"`
			CreatedAt string `json:"created_at"`
			User      user   `json:"user"`
			Label     *struct {
				Name string `json:"name"`
			} `json:"label"`
		}
		if err := g.getAsOf(ctx, fmt.Sprintf("projects/%s/issues/%d/resource_label_events?per_page=%d", pid(project), i.IID, perPage), i.UpdatedAt, &events); err != nil {
			return nil, Listed{}, err
		}
		for _, e := range events {
			if e.Action != "add" || e.Label == nil || before(e.CreatedAt, since) {
				continue
			}
			trusted, err := g.trusted(ctx, project, &e.User)
			if err != nil {
				return nil, Listed{}, err
			}
			out = append(out, IssueActivity{ID: "label:" + strconv.Itoa(e.ID), At: e.CreatedAt, Issue: i.issue(), Kind: IssueLabelled,
				By: e.User.Username, Label: e.Label.Name, Trusted: trusted})
		}
	}
	return out, listed, nil
}

// MARK: GitLab's JSON

type user struct {
	ID       int    `json:"id"`
	Username string `json:"username"`
	Name     string `json:"name"`
	Bot      bool   `json:"bot"`
}

type mergeRequest struct {
	IID                 int    `json:"iid"`
	Title               string `json:"title"`
	Description         string `json:"description"`
	State               string `json:"state"`
	SourceBranch        string `json:"source_branch"`
	TargetBranch        string `json:"target_branch"`
	WebURL              string `json:"web_url"`
	Author              user   `json:"author"`
	Draft               bool   `json:"draft"`
	WorkInProgress      bool   `json:"work_in_progress"`
	SourceProjectID     int    `json:"source_project_id"`
	TargetProjectID     int    `json:"target_project_id"`
	HasConflicts        bool   `json:"has_conflicts"`
	DetailedMergeStatus string `json:"detailed_merge_status"`
	// MergeWhenPipelineSucceeds is auto-merge, on until it merges.
	MergeWhenPipelineSucceeds bool     `json:"merge_when_pipeline_succeeds"`
	Squash                    bool     `json:"squash"`
	MergeStatus               string   `json:"merge_status"`
	MergedAt                  *string  `json:"merged_at"`
	ClosedAt                  *string  `json:"closed_at"`
	MergeCommitSHA            string   `json:"merge_commit_sha"`
	SquashCommitSHA           string   `json:"squash_commit_sha"`
	SHA                       string   `json:"sha"`
	Labels                    []string `json:"labels"`
	CreatedAt                 string   `json:"created_at"`
	UpdatedAt                 string   `json:"updated_at"`
	HeadPipeline              *struct {
		ID     int    `json:"id"`
		Status string `json:"status"`
		WebURL string `json:"web_url"`
	} `json:"head_pipeline"`
}

func (m mergeRequest) mr() MR {
	return MR{Number: m.IID, Title: m.Title, Branch: m.SourceBranch, URL: m.WebURL, Fixes: closingRefs(m.Description)}
}

func (m mergeRequest) draft() bool { return m.Draft || m.WorkInProgress }

// conflicts says whether it conflicts with its target; nil while GitLab works it out.
func (m mergeRequest) conflicts() *bool {
	switch m.DetailedMergeStatus {
	case "unchecked", "checking", "preparing", "approvals_syncing":
		return nil
	case "conflict":
		return new(true)
	}
	switch m.MergeStatus {
	case "unchecked", "checking", "cannot_be_merged_recheck":
		return nil
	}
	return new(m.HasConflicts)
}

func (m mergeRequest) mergeSHA() string {
	for _, sha := range []string{m.MergeCommitSHA, m.SquashCommitSHA, m.SHA} {
		if sha != "" {
			return sha
		}
	}
	return ""
}

type issueJSON struct {
	IID         int      `json:"iid"`
	Title       string   `json:"title"`
	Description string   `json:"description"`
	State       string   `json:"state"`
	WebURL      string   `json:"web_url"`
	Author      user     `json:"author"`
	Labels      []string `json:"labels"`
	Assignees   []user   `json:"assignees"`
	CreatedAt   string   `json:"created_at"`
	UpdatedAt   string   `json:"updated_at"`
	ClosedAt    *string  `json:"closed_at"`
	ClosedBy    *user    `json:"closed_by"`
	// UserNotesCount is how many comments people left on it.
	UserNotesCount int `json:"user_notes_count"`
}

func (i issueJSON) issue() Issue {
	labels := append([]string{}, i.Labels...)
	assignees := []string{}
	for _, a := range i.Assignees {
		if a.Username != "" {
			assignees = append(assignees, a.Username)
		}
	}
	return Issue{Number: i.IID, Title: i.Title, Author: i.Author.Username, Labels: labels, URL: i.WebURL, Assignees: assignees}
}

// MARK: Who is the project's own

// trusted says whether u is one of the project's own (#728): a member, directly or through a
// group, with Reporter access or more, and not a bot. GitLab is asked once per person per
// memberFor.
func (g *RealGitLab) trusted(ctx context.Context, project string, u *user) (bool, error) {
	if u == nil || u.ID == 0 || isBot(u.Username, u.Bot) {
		return false, nil
	}
	key := project + "\x00" + strconv.Itoa(u.ID)
	g.mu.Lock()
	kept, ok := g.members[key]
	g.mu.Unlock()
	if ok && time.Since(kept.at) < memberFor {
		return kept.level >= reporterAccess, nil
	}
	var m struct {
		AccessLevel int `json:"access_level"`
	}
	err := g.get(ctx, fmt.Sprintf("projects/%s/members/all/%d", pid(project), u.ID), false, &m)
	if gl, ok := err.(*GitLabError); ok && gl.Kind == NotFound {
		m.AccessLevel, err = 0, nil
	}
	if err != nil {
		return false, err
	}
	g.mu.Lock()
	if len(g.members) >= maxMembers {
		g.members = map[string]member{}
	}
	g.members[key] = member{time.Now(), m.AccessLevel}
	g.mu.Unlock()
	return m.AccessLevel >= reporterAccess, nil
}

// trustedMR says whether a merge request is the project's own: its branch in the project, not
// a fork, and its author one of the project's own.
func (g *RealGitLab) trustedMR(ctx context.Context, project string, m mergeRequest) (bool, error) {
	if m.SourceProjectID != m.TargetProjectID {
		return false, nil
	}
	return g.trusted(ctx, project, &m.Author)
}

// MARK: GitLab

func (g *RealGitLab) DefaultProject(ctx context.Context) (string, error) { return g.Project(ctx) }

func (g *RealGitLab) OpenMRs(ctx context.Context, project string) ([]OpenMR, error) {
	var out []OpenMR
	path := fmt.Sprintf("projects/%s/merge_requests?state=opened&order_by=created_at&sort=desc", pid(project))
	for page := 1; page <= maxPages; page++ {
		list, err := g.openPage(ctx, query(path, page))
		if err != nil {
			return nil, err
		}
		for _, m := range list {
			trusted, err := g.trustedMR(ctx, project, m)
			if err != nil {
				return nil, err
			}
			out = append(out, OpenMR{MR: m.mr(), Author: m.Author.Username, Draft: m.draft(), Conflicts: m.conflicts(), Trusted: trusted})
		}
		if len(list) < perPage {
			break
		}
	}
	return out, nil
}

// Yours is the connection's owner and, in one project, their open merge requests, the open ones
// they are a reviewer of, and the open issues assigned to them (#2034): one page of each.
func (g *RealGitLab) Yours(ctx context.Context, project string) (Yours, error) {
	var me user
	if err := g.get(ctx, "user", true, &me); err != nil {
		return Yours{}, err
	}
	if me.Username == "" {
		return Yours{}, &GitLabError{Kind: NotSignedIn, Message: "GitLab did not say who the connection is"}
	}
	y := Yours{Login: me.Username}
	who := url.QueryEscape(me.Username)
	mrs := fmt.Sprintf("projects/%s/merge_requests?state=opened&per_page=%d", pid(project), perPage)
	var mine, reviews []mergeRequest
	if err := g.get(ctx, mrs+"&author_username="+who, true, &mine); err != nil {
		return Yours{}, err
	}
	if err := g.get(ctx, mrs+"&reviewer_username="+who, true, &reviews); err != nil {
		return Yours{}, err
	}
	var assigned []issueJSON
	issues := fmt.Sprintf("projects/%s/issues?state=opened&per_page=%d&assignee_username=%s", pid(project), perPage, who)
	if err := g.get(ctx, issues, true, &assigned); err != nil {
		return Yours{}, err
	}
	for _, m := range mine {
		y.MRs = append(y.MRs, m.IID)
	}
	for _, m := range reviews {
		y.Reviews = append(y.Reviews, OpenMR{MR: m.mr(), Author: m.Author.Username, Draft: m.draft()})
	}
	for _, i := range assigned {
		y.Assigned = append(y.Assigned, i.issue())
	}
	return y, nil
}

// openPage is a page of open merge requests. It is asked for with the ETag of the last answer
// (P20261020-2): pr.opened and pr.conflicted list every open merge request each poll, and
// GitLab answers 304 with no body while none changed, so the kept page is used again.
func (g *RealGitLab) openPage(ctx context.Context, path string) ([]mergeRequest, error) {
	g.mu.Lock()
	kept, ok := g.pages[path]
	g.mu.Unlock()
	if ok && time.Since(kept.at) < g.sharing {
		return kept.list, nil
	}
	res, err := g.request(ctx, http.MethodGet, path, nil, kept.etag)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	if res.StatusCode == http.StatusNotModified && ok {
		g.keepPage(path, openList{at: time.Now(), etag: kept.etag, list: kept.list})
		return kept.list, nil
	}
	body, err := answer(res)
	if err != nil {
		return nil, err
	}
	var list []mergeRequest
	if json.Unmarshal(body, &list) != nil {
		return nil, &GitLabError{Kind: Failed, Message: "GitLab's answer is not JSON"}
	}
	for i := range list {
		list[i].Description = "" // not used by the events, and the most of a page
	}
	g.keepPage(path, openList{at: time.Now(), etag: res.Header.Get("ETag"), list: list})
	return list, nil
}

func (g *RealGitLab) keepPage(path string, page openList) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if _, ok := g.pages[path]; !ok && len(g.pages) >= maxKeptPages {
		g.pages = map[string]openList{}
	}
	g.pages[path] = page
}

func (g *RealGitLab) ClosedMRs(ctx context.Context, project, since string) ([]MergedMR, []ClosedMR, Listed, error) {
	var merged []MergedMR
	var closed []ClosedMR
	var listed Listed
	for _, st := range []string{"merged", "closed"} {
		path := fmt.Sprintf("projects/%s/merge_requests?state=%s&order_by=updated_at&sort=desc&updated_after=%s",
			pid(project), st, url.QueryEscape(since))
		list, more, err := newest(ctx, g, path, since, func(m mergeRequest) string { return m.UpdatedAt })
		if err != nil {
			return nil, nil, Listed{}, err
		}
		listed = listed.saw(more.Newest)
		listed.Truncated = listed.Truncated || more.Truncated
		for _, m := range list {
			switch {
			case st == "merged" && m.MergedAt != nil && !before(*m.MergedAt, since):
				trusted, err := g.trustedMR(ctx, project, m)
				if err != nil {
					return nil, nil, Listed{}, err
				}
				merged = append(merged, MergedMR{MR: m.mr(), MergedAt: *m.MergedAt, MergeSHA: m.mergeSHA(), Trusted: trusted})
			case st == "closed" && m.ClosedAt != nil && !before(*m.ClosedAt, since):
				trusted, err := g.trustedMR(ctx, project, m)
				if err != nil {
					return nil, nil, Listed{}, err
				}
				closed = append(closed, ClosedMR{MR: m.mr(), ClosedAt: *m.ClosedAt, Trusted: trusted})
			}
		}
	}
	return merged, closed, listed, nil
}

// mrRef is a merge request pipeline's ref: refs/merge-requests/12/head (or /merge, /train).
var mrRef = regexp.MustCompile(`^refs/merge-requests/([0-9]+)/`)

type pipelineJSON struct {
	ID        int    `json:"id"`
	IID       int    `json:"iid"`
	Name      string `json:"name"`
	Status    string `json:"status"`
	Source    string `json:"source"`
	Ref       string `json:"ref"`
	SHA       string `json:"sha"`
	WebURL    string `json:"web_url"`
	CreatedAt string `json:"created_at"`
	UpdatedAt string `json:"updated_at"`
}

func (p pipelineJSON) pipeline() Pipeline {
	name := p.Name
	if name == "" {
		name = fmt.Sprintf("Pipeline #%d", p.ID)
	}
	out := Pipeline{ID: p.ID, Name: name, URL: p.WebURL, SHA: p.SHA, Ref: p.Ref, UpdatedAt: p.UpdatedAt}
	if m := mrRef.FindStringSubmatch(p.Ref); m != nil {
		out.MRNumber, _ = strconv.Atoi(m[1])
	}
	return out
}

func (g *RealGitLab) FailedPipelines(ctx context.Context, project, since string) ([]Pipeline, Listed, error) {
	path := fmt.Sprintf("projects/%s/pipelines?status=failed&order_by=updated_at&sort=desc&updated_after=%s",
		pid(project), url.QueryEscape(since))
	list, listed, err := newest(ctx, g, path, since, func(p pipelineJSON) string { return p.UpdatedAt })
	if err != nil {
		return nil, Listed{}, err
	}
	out := make([]Pipeline, 0, len(list))
	for _, p := range list {
		if p.Status == "failed" {
			out = append(out, p.pipeline())
		}
	}
	return out, listed, nil
}

type jobJSON struct {
	ID           int    `json:"id"`
	Name         string `json:"name"`
	Stage        string `json:"stage"`
	Status       string `json:"status"`
	WebURL       string `json:"web_url"`
	AllowFailure bool   `json:"allow_failure"`
}

func (g *RealGitLab) PipelineDetails(ctx context.Context, project string, p Pipeline) (*FailedPipelineData, error) {
	number := p.MRNumber
	if number == 0 {
		// A branch pipeline names no merge request; its commit's open one from that branch is it.
		var mrs []mergeRequest
		if err := g.get(ctx, fmt.Sprintf("projects/%s/repository/commits/%s/merge_requests", pid(project), url.PathEscape(p.SHA)), false, &mrs); err != nil {
			return nil, err
		}
		for _, m := range mrs {
			if m.SourceBranch == p.Ref && m.State == "opened" {
				number = m.IID
				break
			}
		}
	}
	if number == 0 {
		return nil, nil
	}
	var m mergeRequest
	if err := g.get(ctx, fmt.Sprintf("projects/%s/merge_requests/%d", pid(project), number), false, &m); err != nil {
		return nil, err
	}
	var jobs []jobJSON
	if err := g.get(ctx, fmt.Sprintf("projects/%s/pipelines/%d/jobs?scope[]=failed&per_page=100", pid(project), p.ID), false, &jobs); err != nil {
		return nil, err
	}
	failed := []Job{}
	for _, j := range jobs {
		if j.Status == "failed" && !j.AllowFailure {
			failed = append(failed, Job{Name: j.Name, URL: j.WebURL})
		}
	}
	trusted, err := g.trustedMR(ctx, project, m)
	if err != nil {
		return nil, err
	}
	mr := m.mr()
	if mr.Number == 0 {
		mr.Number = number
	}
	return &FailedPipelineData{MR: mr, Pipeline: p, FailedJobs: failed, Trusted: trusted}, nil
}

func (g *RealGitLab) IssueActivity(ctx context.Context, project string, kind IssueKind, since string) ([]IssueActivity, Listed, error) {
	switch kind {
	case IssueOpened:
		path := fmt.Sprintf("projects/%s/issues?created_after=%s&order_by=created_at&sort=desc", pid(project), url.QueryEscape(since))
		items, listed, err := newest(ctx, g, path, since, func(i issueJSON) string { return i.CreatedAt })
		if err != nil {
			return nil, Listed{}, err
		}
		var out []IssueActivity
		for _, i := range items {
			trusted, err := g.trusted(ctx, project, &i.Author)
			if err != nil {
				return nil, Listed{}, err
			}
			out = append(out, IssueActivity{ID: strconv.Itoa(i.IID), At: i.CreatedAt, Issue: i.issue(), Kind: IssueOpened, Trusted: trusted})
		}
		return out, listed, nil
	case IssueLabelled:
		return g.labelled(ctx, project, since)
	case IssueClosed:
		path := fmt.Sprintf("projects/%s/issues?state=closed&updated_after=%s&order_by=updated_at&sort=desc", pid(project), url.QueryEscape(since))
		items, listed, err := newest(ctx, g, path, since, func(i issueJSON) string { return i.UpdatedAt })
		if err != nil {
			return nil, Listed{}, err
		}
		var out []IssueActivity
		for _, i := range items {
			if i.ClosedAt == nil || before(*i.ClosedAt, since) {
				continue
			}
			trusted, err := g.trusted(ctx, project, i.ClosedBy)
			if err != nil {
				return nil, Listed{}, err
			}
			by := ""
			if i.ClosedBy != nil {
				by = i.ClosedBy.Username
			}
			out = append(out, IssueActivity{ID: strconv.Itoa(i.IID) + ":" + normalized(*i.ClosedAt), At: *i.ClosedAt, Issue: i.issue(),
				Kind: IssueClosed, By: by, Trusted: trusted})
		}
		return out, listed, nil
	}
	notes, listed, err := g.notes(ctx, project, since)
	if err != nil {
		return nil, Listed{}, err
	}
	var out []IssueActivity
	// An issue is read once per poll, shared with other waits that saw the same newest comment
	// on it (notes are newest first), so it is never older than that comment.
	issues := map[int]issueJSON{}
	for _, n := range notes {
		if n.NoteableType != "Issue" {
			continue
		}
		i, ok := issues[n.NoteableIID]
		if !ok {
			if err := g.getAsOf(ctx, fmt.Sprintf("projects/%s/issues/%d", pid(project), n.NoteableIID), n.CreatedAt, &i); err != nil {
				return nil, Listed{}, err
			}
			issues[n.NoteableIID] = i
		}
		trusted, err := g.trusted(ctx, project, &n.Author)
		if err != nil {
			return nil, Listed{}, err
		}
		out = append(out, IssueActivity{ID: strconv.Itoa(n.ID), At: n.CreatedAt, Issue: i.issue(), Kind: IssueCommented,
			CommentAuthor: n.Author.Username, CommentURL: fmt.Sprintf("%s#note_%d", i.WebURL, n.ID), CommentBody: clip(n.Body), Trusted: trusted})
	}
	return out, listed, nil
}

func (g *RealGitLab) ReviewComments(ctx context.Context, project, since string) ([]ReviewComment, Listed, error) {
	notes, listed, err := g.notes(ctx, project, since)
	if err != nil {
		return nil, Listed{}, err
	}
	var out []ReviewComment
	// A merge request is read as an issue is in IssueActivity.
	mrs := map[int]mergeRequest{}
	for _, n := range notes {
		if n.NoteableType != "MergeRequest" || n.Type != "DiffNote" {
			continue
		}
		m, ok := mrs[n.NoteableIID]
		if !ok {
			if err := g.getAsOf(ctx, fmt.Sprintf("projects/%s/merge_requests/%d", pid(project), n.NoteableIID), n.CreatedAt, &m); err != nil {
				return nil, Listed{}, err
			}
			mrs[n.NoteableIID] = m
		}
		trusted := m.SourceProjectID == m.TargetProjectID
		if trusted {
			if trusted, err = g.trusted(ctx, project, &n.Author); err != nil {
				return nil, Listed{}, err
			}
		}
		c := ReviewComment{ID: n.ID, At: n.CreatedAt, MR: m.mr(), Author: n.Author.Username, Body: clip(n.Body),
			URL: fmt.Sprintf("%s#note_%d", m.WebURL, n.ID), Trusted: trusted}
		if p := n.Position; p != nil {
			c.Path, c.Line = p.NewPath, p.NewLine
			if c.Line == 0 {
				c.Path, c.Line = p.OldPath, p.OldLine
			}
		}
		out = append(out, c)
	}
	return out, listed, nil
}

type noteJSON struct {
	ID           int    `json:"id"`
	Type         string `json:"type"`
	Body         string `json:"body"`
	Author       user   `json:"author"`
	CreatedAt    string `json:"created_at"`
	System       bool   `json:"system"`
	Resolved     bool   `json:"resolved"`
	NoteableType string `json:"noteable_type"`
	NoteableIID  int    `json:"noteable_iid"`
	Position     *struct {
		NewPath string `json:"new_path"`
		OldPath string `json:"old_path"`
		NewLine int    `json:"new_line"`
		OldLine int    `json:"old_line"`
	} `json:"position"`
}

// notes are the people's comments on the project's issues and merge requests made at or
// after since, read from its activity (one listing for the whole project, not one per issue).
// GitLab's own notes (a label, a close) are left out.
func (g *RealGitLab) notes(ctx context.Context, project, since string) ([]noteJSON, Listed, error) {
	type activity struct {
		CreatedAt string    `json:"created_at"`
		Note      *noteJSON `json:"note"`
	}
	// after is a day, and not that day: the day before since's.
	after := ""
	if t, ok := parseTime(since); ok {
		after = "&after=" + t.UTC().AddDate(0, 0, -1).Format("2006-01-02")
	}
	path := fmt.Sprintf("projects/%s/events?action=commented&sort=desc%s", pid(project), after)
	items, listed, err := newest(ctx, g, path, since, func(a activity) string { return a.CreatedAt })
	if err != nil {
		return nil, Listed{}, err
	}
	var out []noteJSON
	for _, a := range items {
		if a.Note == nil || a.Note.System {
			continue
		}
		n := *a.Note
		if n.CreatedAt == "" {
			n.CreatedAt = a.CreatedAt
		}
		out = append(out, n)
	}
	return out, listed, nil
}

// MARK: The folder's project

// GitProject is the project of this GitLab that this folder pushes to, from its git remote
// (origin first), asked once it succeeds.
func GitProject(base string) func(ctx context.Context) (string, error) {
	var mu sync.Mutex
	var project string
	return func(ctx context.Context) (string, error) {
		mu.Lock()
		defer mu.Unlock()
		if project != "" {
			return project, nil
		}
		for _, remote := range gitRemotes(ctx) {
			out, err := exec.CommandContext(ctx, "git", "remote", "get-url", remote).Output()
			if err != nil {
				continue
			}
			if path, ok := ProjectOfRemote(base, strings.TrimSpace(string(out))); ok {
				project = path
				return project, nil
			}
		}
		cwd, _ := os.Getwd()
		host := base
		if u, err := url.Parse(BaseURL(base)); err == nil {
			host = u.Host
		}
		return "", &GitLabError{Kind: NotFound, Message: "project is needed: " + cwd + " has no " + host + " remote"}
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

// ProjectOfRemote is the project path (group/sub/name) of a remote of the GitLab at base:
// https://machine/group/name(.git), git@host:group/name(.git) or ssh://git@host(:port)/group/name(.git).
// A GitLab under a path (https://machine/gitlab/) keeps that path out of the project's.
func ProjectOfRemote(base, remote string) (string, bool) {
	u, err := url.Parse(BaseURL(base))
	if err != nil || u.Host == "" {
		return "", false
	}
	host, prefix := u.Hostname(), strings.Trim(u.Path, "/")
	rest := ""
	switch {
	case strings.Contains(remote, "://"):
		r, err := url.Parse(remote)
		if err != nil || !strings.EqualFold(r.Hostname(), host) {
			return "", false
		}
		rest = strings.Trim(r.Path, "/")
		if prefix != "" && strings.HasPrefix(r.Scheme, "http") {
			var ok bool
			if rest, ok = strings.CutPrefix(rest, prefix+"/"); !ok {
				return "", false
			}
		}
	default:
		// scp-like: [user@]host:group/name
		at := remote
		if _, after, ok := strings.Cut(remote, "@"); ok {
			at = after
		}
		h, path, ok := strings.Cut(at, ":")
		if !ok || !strings.EqualFold(h, host) {
			return "", false
		}
		rest = strings.Trim(path, "/")
	}
	rest = strings.TrimSuffix(rest, ".git")
	if !projectPattern.MatchString(rest) || !strings.Contains(rest, "/") {
		return "", false
	}
	return rest, true
}
