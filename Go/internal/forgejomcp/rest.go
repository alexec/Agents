package forgejomcp

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

// RealForgejo reads Forgejo's REST API v1 (Gitea's too: they share it) as the person, with the
// token Token gives: FORGEJO_TOKEN, an access token with the repository and issue scopes.
// Base is codeberg.org or the person's own Forgejo or Gitea. The listings events poll are
// shared for sharedFor, as the gitlab server's (#932): every wait polls on its own, and ten
// waits on one repository would otherwise fetch the same page ten times.
type RealForgejo struct {
	// Base is Forgejo's root, with a trailing slash: https://codeberg.org/.
	Base   string
	Token  func() string
	Client *http.Client
	// Repo is the repository the server's folder pushes to, read from git once it is needed.
	Repo func(ctx context.Context) (string, error)
	// Now is the clock a conflict is timed by; time.Now when nil.
	Now func() time.Time

	mu      sync.Mutex
	recent  map[string]sharedBody
	running map[string]*fetch
	sharing time.Duration
	members map[string]member
	// unmergeable is when each open pull request's head was first seen not mergeable.
	unmergeable map[string]time.Time
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
	at      time.Time
	trusted bool
}

const (
	maxPages = 10
	// perPage is Forgejo's own most for one page (MAX_RESPONSE_ITEMS).
	perPage = 50
	// sharedFor is under the 30 s poll, so each poll still sees a fresh page.
	sharedFor = 25 * time.Second
	// memberFor is how long a person's access to a repository is kept; maxMembers bounds how many.
	memberFor  = 10 * time.Minute
	maxMembers = 1000
	// maxChecked bounds the open pull requests whose checks a poll reads, newest updated first.
	maxChecked = 50
	// conflictAfter is how long a pull request must stay not mergeable to be in conflict:
	// Forgejo says not mergeable while it checks one too, which takes seconds.
	conflictAfter = time.Minute
	// maxUnmergeable bounds the pull requests timed for conflictAfter.
	maxUnmergeable = 1000
)

// DefaultBase is Codeberg, the largest Forgejo.
const DefaultBase = "https://codeberg.org/"

// NewRealForgejo reads the Forgejo at base (codeberg.org when empty) with token's answer.
func NewRealForgejo(base string, token func() string, repo func(ctx context.Context) (string, error)) *RealForgejo {
	return &RealForgejo{Base: BaseURL(base), Token: token, Repo: repo, Client: &http.Client{Timeout: 30 * time.Second},
		recent: map[string]sharedBody{}, running: map[string]*fetch{}, sharing: sharedFor, members: map[string]member{},
		unmergeable: map[string]time.Time{}}
}

// BaseURL is base as Forgejo's root with a trailing slash: codeberg.org when empty, https://
// when it names no scheme, and without an /api/v1 put on the end.
func BaseURL(base string) string {
	base = strings.TrimSpace(base)
	if base == "" {
		return DefaultBase
	}
	if !strings.Contains(base, "://") {
		base = "https://" + base
	}
	base = strings.TrimSuffix(strings.TrimSuffix(base, "/"), "/api/v1")
	return base + "/"
}

func (f *RealForgejo) now() time.Time {
	if f.Now != nil {
		return f.Now()
	}
	return time.Now()
}

// MARK: HTTP

// NotConnected is what a call says with no token, or one Forgejo no longer takes.
const NotConnected = "Forgejo is not connected, or its token ended: set FORGEJO_TOKEN to an access token with read and write on repository and issue"

func (f *RealForgejo) do(ctx context.Context, method, path string, body any) ([]byte, error) {
	token := f.Token()
	if token == "" {
		return nil, &ForgejoError{Kind: NotSignedIn, Message: NotConnected}
	}
	var reader io.Reader
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			return nil, &ForgejoError{Kind: Failed, Message: "Forgejo: " + err.Error()}
		}
		reader = bytes.NewReader(data)
	}
	req, err := http.NewRequestWithContext(ctx, method, f.Base+"api/v1/"+path, reader)
	if err != nil {
		return nil, &ForgejoError{Kind: Failed, Message: "Forgejo: " + err.Error()}
	}
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	// Go drops it on a redirect to another host.
	req.Header.Set("Authorization", "token "+token)
	req.Header.Set("User-Agent", "agents-forgejo-mcp")
	res, err := f.Client.Do(req)
	if err != nil {
		return nil, &ForgejoError{Kind: Failed, Message: "Forgejo: " + err.Error()}
	}
	defer res.Body.Close()
	data, err := io.ReadAll(io.LimitReader(res.Body, 64<<20))
	if err != nil {
		return nil, &ForgejoError{Kind: Failed, Message: "Forgejo: " + err.Error()}
	}
	if res.StatusCode >= 200 && res.StatusCode < 300 {
		return data, nil
	}
	return nil, failure(res, data)
}

// failure is a response Forgejo refused, as what went wrong.
func failure(res *http.Response, body []byte) *ForgejoError {
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
		return &ForgejoError{Kind: NotSignedIn, Message: NotConnected}
	case http.StatusTooManyRequests:
		return &ForgejoError{Kind: RateLimited, Message: "Forgejo rate limit", RetryAfterMs: retryAfter(res.Header)}
	case http.StatusNotFound:
		return &ForgejoError{Kind: NotFound, Message: "not found on Forgejo", Refused: true}
	case http.StatusForbidden:
		if strings.Contains(words, "token does not have") {
			return &ForgejoError{Kind: Failed, Message: "Forgejo refused: " + words, Refused: true}
		}
	}
	message := fmt.Sprintf("Forgejo: HTTP %d", res.StatusCode)
	if words != "" {
		message += ": " + words
	}
	return &ForgejoError{Kind: Failed, Message: message, Refused: res.StatusCode == http.StatusForbidden}
}

func retryAfter(h http.Header) int {
	if after, err := strconv.ParseFloat(h.Get("Retry-After"), 64); err == nil {
		return max(1000, int(after*1000))
	}
	return 60_000
}

// get is path's JSON; with shared, an answer fetched in the last sharedFor is used again, and
// a fetch already running is waited for.
func (f *RealForgejo) get(ctx context.Context, path string, shared bool, into any) error {
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
		return &ForgejoError{Kind: Failed, Message: "Forgejo's answer is not JSON"}
	}
	return nil
}

// getAsOf is path's JSON shared as get shares it, but only with a fetch for the same asOf: a
// time the thing at path changed at, so what is shared is never older than what the caller
// has seen.
func (f *RealForgejo) getAsOf(ctx context.Context, path, asOf string, into any) error {
	body, err := f.shared(path+" "+normalized(asOf), func() ([]byte, error) { return f.do(ctx, http.MethodGet, path, nil) })
	if err != nil {
		return err
	}
	if json.Unmarshal(body, into) != nil {
		return &ForgejoError{Kind: Failed, Message: "Forgejo's answer is not JSON"}
	}
	return nil
}

func (f *RealForgejo) send(ctx context.Context, method, path string, body, into any) error {
	data, err := f.do(ctx, method, path, body)
	if err != nil {
		return err
	}
	if into == nil || len(bytes.TrimSpace(data)) == 0 {
		return nil
	}
	if json.Unmarshal(data, into) != nil {
		return &ForgejoError{Kind: Failed, Message: "Forgejo's answer is not JSON"}
	}
	return nil
}

func (f *RealForgejo) shared(key string, get func() ([]byte, error)) ([]byte, error) {
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

// repoPath is a repository's part of an API path: repos/owner/name.
func repoPath(repo string) string {
	owner, name, _ := strings.Cut(repo, "/")
	return "repos/" + url.PathEscape(owner) + "/" + url.PathEscape(name)
}

func query(path string, page int) string {
	sep := "?"
	if strings.Contains(path, "?") {
		sep = "&"
	}
	return fmt.Sprintf("%s%slimit=%d&page=%d", path, sep, perPage, page)
}

// all pages path to its end, at most maxPages; truncated says it stopped there.
func all[T any](ctx context.Context, f *RealForgejo, path string) (items []T, truncated bool, err error) {
	for page := 1; page <= maxPages; page++ {
		var list []T
		if err := f.get(ctx, query(path, page), true, &list); err != nil {
			return nil, false, err
		}
		items = append(items, list...)
		if len(list) < perPage {
			return items, false, nil
		}
	}
	return items, true, nil
}

// newest pages path (newest first) until an item older than since by its time.
func newest[T any](ctx context.Context, f *RealForgejo, path, since string, at func(T) string) ([]T, Listed, error) {
	var items []T
	var listed Listed
	for page := 1; page <= maxPages; page++ {
		var list []T
		if err := f.get(ctx, query(path, page), true, &list); err != nil {
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

// MARK: Forgejo's JSON

type user struct {
	ID    int    `json:"id"`
	Login string `json:"login"`
}

type label struct {
	Name string `json:"name"`
}

func labelNames(ls []label) []string {
	out := []string{}
	for _, l := range ls {
		out = append(out, l.Name)
	}
	return out
}

type branchInfo struct {
	Ref    string `json:"ref"`
	SHA    string `json:"sha"`
	RepoID int    `json:"repo_id"`
}

type pullJSON struct {
	Number             int        `json:"number"`
	Title              string     `json:"title"`
	Body               string     `json:"body"`
	State              string     `json:"state"`
	HTMLURL            string     `json:"html_url"`
	User               user       `json:"user"`
	Labels             []label    `json:"labels"`
	Draft              bool       `json:"draft"`
	Mergeable          bool       `json:"mergeable"`
	Merged             bool       `json:"merged"`
	MergedAt           *string    `json:"merged_at"`
	MergeCommitSHA     string     `json:"merge_commit_sha"`
	ClosedAt           *string    `json:"closed_at"`
	CreatedAt          string     `json:"created_at"`
	UpdatedAt          string     `json:"updated_at"`
	Head               branchInfo `json:"head"`
	Base               branchInfo `json:"base"`
	RequestedReviewers []user     `json:"requested_reviewers"`
	Assignees          []user     `json:"assignees"`
	Comments           int        `json:"comments"`
}

// wipPrefixes are Forgejo's own draft marks (WORK_IN_PROGRESS_PREFIXES), on a title.
var wipPrefixes = []string{"wip:", "[wip]"}

func (p pullJSON) pr() PR {
	return PR{Number: p.Number, Title: p.Title, Branch: p.Head.Ref, URL: p.HTMLURL, Fixes: closingRefs(p.Body), Author: p.User.Login}
}

func (p pullJSON) draft() bool {
	title := strings.ToLower(strings.TrimSpace(p.Title))
	for _, prefix := range wipPrefixes {
		if strings.HasPrefix(title, prefix) {
			return true
		}
	}
	return p.Draft
}

// fork says whether its branch is in another repository.
func (p pullJSON) fork() bool { return p.Head.RepoID != p.Base.RepoID }

type issueJSON struct {
	Number    int     `json:"number"`
	Title     string  `json:"title"`
	Body      string  `json:"body"`
	State     string  `json:"state"`
	HTMLURL   string  `json:"html_url"`
	User      user    `json:"user"`
	Labels    []label `json:"labels"`
	Assignees []user  `json:"assignees"`
	CreatedAt string  `json:"created_at"`
	UpdatedAt string  `json:"updated_at"`
	ClosedAt  *string `json:"closed_at"`
	Comments  int     `json:"comments"`
	// PullRequest is set when the issue is a pull request.
	PullRequest *struct {
		Merged bool `json:"merged"`
	} `json:"pull_request"`
}

func (i issueJSON) issue() Issue {
	assignees := []string{}
	for _, a := range i.Assignees {
		if a.Login != "" {
			assignees = append(assignees, a.Login)
		}
	}
	return Issue{Number: i.Number, Title: i.Title, Author: i.User.Login, Labels: labelNames(i.Labels), URL: i.HTMLURL, Assignees: assignees}
}

type commentJSON struct {
	ID             int    `json:"id"`
	HTMLURL        string `json:"html_url"`
	IssueURL       string `json:"issue_url"`
	PullRequestURL string `json:"pull_request_url"`
	User           user   `json:"user"`
	Body           string `json:"body"`
	CreatedAt      string `json:"created_at"`
	UpdatedAt      string `json:"updated_at"`
}

// timelineJSON is one line of an issue's timeline: a comment, a label, a close.
type timelineJSON struct {
	ID        int    `json:"id"`
	Type      string `json:"type"`
	Body      string `json:"body"`
	User      *user  `json:"user"`
	CreatedAt string `json:"created_at"`
	Label     *label `json:"label"`
}

type reviewJSON struct {
	ID            int    `json:"id"`
	User          *user  `json:"user"`
	State         string `json:"state"`
	Body          string `json:"body"`
	CommitID      string `json:"commit_id"`
	CommentsCount int    `json:"comments_count"`
	SubmittedAt   string `json:"submitted_at"`
	UpdatedAt     string `json:"updated_at"`
	HTMLURL       string `json:"html_url"`
}

type reviewCommentJSON struct {
	ID               int    `json:"id"`
	Body             string `json:"body"`
	User             *user  `json:"user"`
	Resolver         *user  `json:"resolver"`
	ReviewID         int    `json:"pull_request_review_id"`
	Path             string `json:"path"`
	CommitID         string `json:"commit_id"`
	Position         int    `json:"position"`
	OriginalPosition int    `json:"original_position"`
	DiffHunk         string `json:"diff_hunk"`
	HTMLURL          string `json:"html_url"`
	CreatedAt        string `json:"created_at"`
}

// line is the line a review comment is on: the new file's, else the old file's.
func (c reviewCommentJSON) line() int {
	if c.Position > 0 {
		return c.Position
	}
	return c.OriginalPosition
}

type statusJSON struct {
	ID          int    `json:"id"`
	Context     string `json:"context"`
	State       string `json:"status"`
	TargetURL   string `json:"target_url"`
	Description string `json:"description"`
	CreatedAt   string `json:"created_at"`
	UpdatedAt   string `json:"updated_at"`
}

type combinedJSON struct {
	State    string       `json:"state"`
	SHA      string       `json:"sha"`
	Statuses []statusJSON `json:"statuses"`
}

// failedStatus says whether a commit status is a failure.
func failedStatus(state string) bool { return state == "failure" || state == "error" }

// actionsRun is a Forgejo Actions run's number in a status's link: …/actions/runs/12/jobs/0.
var actionsRun = regexp.MustCompile(`/actions/runs/([0-9]+)`)

// MARK: Who is the repository's own

// trusted says whether u is one of the repository's own (#728): a collaborator with write
// access or more, or a member of the organisation that owns it, and not a bot. Forgejo lets
// only a repository's admins read another person's access, so a token without admin falls
// back to whether they are a collaborator or a member. Forgejo is asked once per person per
// memberFor.
func (f *RealForgejo) trusted(ctx context.Context, repo string, u *user) (bool, error) {
	if u == nil || u.Login == "" || isBot(u.Login, u.ID) {
		return false, nil
	}
	key := repo + "\x00" + strings.ToLower(u.Login)
	f.mu.Lock()
	kept, ok := f.members[key]
	f.mu.Unlock()
	if ok && time.Since(kept.at) < memberFor {
		return kept.trusted, nil
	}
	trusted, err := f.access(ctx, repo, u.Login)
	if err != nil {
		return false, err
	}
	f.mu.Lock()
	if len(f.members) >= maxMembers {
		f.members = map[string]member{}
	}
	f.members[key] = member{time.Now(), trusted}
	f.mu.Unlock()
	return trusted, nil
}

func (f *RealForgejo) access(ctx context.Context, repo, login string) (bool, error) {
	owner, _, _ := strings.Cut(repo, "/")
	if strings.EqualFold(owner, login) {
		return true, nil
	}
	refused := func(err error) bool {
		fe, ok := err.(*ForgejoError)
		return ok && fe.Refused
	}
	var p struct {
		Permission string `json:"permission"`
	}
	err := f.get(ctx, repoPath(repo)+"/collaborators/"+url.PathEscape(login)+"/permission", false, &p)
	if err == nil {
		return p.Permission == "write" || p.Permission == "admin" || p.Permission == "owner", nil
	}
	if !refused(err) {
		return false, err
	}
	// 204 when they are; 404 when not.
	if _, err := f.do(ctx, http.MethodGet, repoPath(repo)+"/collaborators/"+url.PathEscape(login), nil); err == nil {
		return true, nil
	} else if !refused(err) {
		return false, err
	}
	if _, err := f.do(ctx, http.MethodGet, "orgs/"+url.PathEscape(owner)+"/members/"+url.PathEscape(login), nil); err == nil {
		return true, nil
	} else if !refused(err) {
		return false, err
	}
	return false, nil
}

// trustedPR says whether a pull request is the repository's own: its branch in the
// repository, not a fork, and its author one of the repository's own.
func (f *RealForgejo) trustedPR(ctx context.Context, repo string, p pullJSON) (bool, error) {
	if p.fork() {
		return false, nil
	}
	return f.trusted(ctx, repo, &p.User)
}

// MARK: Forgejo

func (f *RealForgejo) DefaultRepo(ctx context.Context) (string, error) { return f.Repo(ctx) }

// openPulls are the open pull requests, newest updated first.
func (f *RealForgejo) openPulls(ctx context.Context, repo string) ([]pullJSON, error) {
	list, _, err := all[pullJSON](ctx, f, repoPath(repo)+"/pulls?state=open&sort=recentupdate")
	return list, err
}

// conflicts says whether an open pull request conflicts with its base: not mergeable for
// conflictAfter at the same head. nil while it may still be being checked, and for a draft,
// which Forgejo never calls mergeable.
func (f *RealForgejo) conflicts(repo string, p pullJSON) *bool {
	if p.draft() {
		return nil
	}
	key := fmt.Sprintf("%s#%d@%s", repo, p.Number, p.Head.SHA)
	f.mu.Lock()
	defer f.mu.Unlock()
	if p.Mergeable {
		delete(f.unmergeable, key)
		return new(false)
	}
	first, ok := f.unmergeable[key]
	if !ok {
		if len(f.unmergeable) >= maxUnmergeable {
			f.unmergeable = map[string]time.Time{}
		}
		f.unmergeable[key] = f.now()
		return nil
	}
	if f.now().Sub(first) < conflictAfter {
		return nil
	}
	return new(true)
}

func (f *RealForgejo) OpenPRs(ctx context.Context, repo string) ([]OpenPR, error) {
	list, err := f.openPulls(ctx, repo)
	if err != nil {
		return nil, err
	}
	out := make([]OpenPR, 0, len(list))
	for _, p := range list {
		trusted, err := f.trustedPR(ctx, repo, p)
		if err != nil {
			return nil, err
		}
		out = append(out, OpenPR{PR: p.pr(), Author: p.User.Login, Draft: p.draft(), Conflicts: f.conflicts(repo, p),
			HeadSHA: p.Head.SHA, Trusted: trusted})
	}
	return out, nil
}

// Yours is the token's owner and, in one repository, their open pull requests, the open ones
// they are asked to review, and the open issues assigned to them (#2034).
func (f *RealForgejo) Yours(ctx context.Context, repo string) (Yours, error) {
	var me user
	if err := f.get(ctx, "user", true, &me); err != nil {
		return Yours{}, err
	}
	if me.Login == "" {
		return Yours{}, &ForgejoError{Kind: NotSignedIn, Message: "Forgejo did not say whose the token is"}
	}
	y := Yours{Login: me.Login}
	pulls, err := f.openPulls(ctx, repo)
	if err != nil {
		return Yours{}, err
	}
	for _, p := range pulls {
		if strings.EqualFold(p.User.Login, me.Login) {
			y.PRs = append(y.PRs, p.Number)
		}
		for _, r := range p.RequestedReviewers {
			if strings.EqualFold(r.Login, me.Login) {
				y.Reviews = append(y.Reviews, OpenPR{PR: p.pr(), Author: p.User.Login, Draft: p.draft(), HeadSHA: p.Head.SHA})
				break
			}
		}
	}
	var assigned []issueJSON
	path := fmt.Sprintf("%s/issues?type=issues&state=open&assigned_by=%s&limit=%d", repoPath(repo), url.QueryEscape(me.Login), perPage)
	if err := f.get(ctx, path, true, &assigned); err != nil {
		return Yours{}, err
	}
	for _, i := range assigned {
		y.Assigned = append(y.Assigned, i.issue())
	}
	return y, nil
}

func (f *RealForgejo) ClosedPRs(ctx context.Context, repo, since string) ([]MergedPR, []ClosedPR, Listed, error) {
	list, listed, err := newest(ctx, f, repoPath(repo)+"/pulls?state=closed&sort=recentupdate", since,
		func(p pullJSON) string { return p.UpdatedAt })
	if err != nil {
		return nil, nil, Listed{}, err
	}
	var merged []MergedPR
	var closed []ClosedPR
	for _, p := range list {
		switch {
		case p.Merged && p.MergedAt != nil && !before(*p.MergedAt, since):
			trusted, err := f.trustedPR(ctx, repo, p)
			if err != nil {
				return nil, nil, Listed{}, err
			}
			merged = append(merged, MergedPR{PR: p.pr(), MergedAt: *p.MergedAt, MergeSHA: p.MergeCommitSHA, Trusted: trusted})
		case !p.Merged && p.ClosedAt != nil && !before(*p.ClosedAt, since):
			trusted, err := f.trustedPR(ctx, repo, p)
			if err != nil {
				return nil, nil, Listed{}, err
			}
			closed = append(closed, ClosedPR{PR: p.pr(), ClosedAt: *p.ClosedAt, Trusted: trusted})
		}
	}
	return merged, closed, listed, nil
}

// status is a commit's combined status: the newest of each check.
func (f *RealForgejo) status(ctx context.Context, repo, sha string) (combinedJSON, error) {
	var c combinedJSON
	err := f.get(ctx, fmt.Sprintf("%s/commits/%s/status", repoPath(repo), url.PathEscape(sha)), true, &c)
	return c, err
}

// FailedChecks reads the combined status of the head of each of the maxChecked open pull
// requests updated last: Forgejo has no list of failed checks for a repository.
func (f *RealForgejo) FailedChecks(ctx context.Context, repo, since string) ([]FailedChecks, Listed, error) {
	pulls, err := f.openPulls(ctx, repo)
	if err != nil {
		return nil, Listed{}, err
	}
	var out []FailedChecks
	var listed Listed
	for _, p := range pulls[:min(maxChecked, len(pulls))] {
		if p.Head.SHA == "" {
			continue
		}
		c, err := f.status(ctx, repo, p.Head.SHA)
		if err != nil {
			return nil, Listed{}, err
		}
		if !failedStatus(c.State) {
			continue
		}
		d := FailedChecks{PR: p.pr(), HeadSHA: p.Head.SHA, Failed: []Check{}}
		for _, s := range c.Statuses {
			if !failedStatus(s.State) {
				continue
			}
			if at := normalized(s.UpdatedAt); at > d.At {
				d.At = at
			}
			d.Failed = append(d.Failed, Check{Name: s.Context, URL: s.TargetURL})
			if d.RunURL == "" {
				d.RunName, d.RunURL = s.Context, s.TargetURL
				if m := actionsRun.FindStringSubmatch(s.TargetURL); m != nil {
					d.RunID, _ = strconv.Atoi(m[1])
				}
			}
		}
		listed = listed.saw(d.At)
		if d.At == "" || before(d.At, since) {
			continue
		}
		if d.Trusted, err = f.trustedPR(ctx, repo, p); err != nil {
			return nil, Listed{}, err
		}
		out = append(out, d)
	}
	return out, listed, nil
}

// issuesSince are the repository's issues (not pull requests) updated at or after since, in
// one state.
func (f *RealForgejo) issuesSince(ctx context.Context, repo, state, since string) ([]issueJSON, Listed, error) {
	path := fmt.Sprintf("%s/issues?type=issues&state=%s&since=%s", repoPath(repo), state, url.QueryEscape(since))
	items, truncated, err := all[issueJSON](ctx, f, path)
	if err != nil {
		return nil, Listed{}, err
	}
	listed := Listed{Truncated: truncated}
	for _, i := range items {
		listed = listed.saw(i.UpdatedAt)
	}
	return items, listed, nil
}

// timeline is an issue's timeline at or after since, shared by the issue's update time:
// unchanged, its timeline is too.
func (f *RealForgejo) timeline(ctx context.Context, repo string, i issueJSON, since string) ([]timelineJSON, error) {
	var lines []timelineJSON
	path := fmt.Sprintf("%s/issues/%d/timeline?since=%s&limit=%d", repoPath(repo), i.Number, url.QueryEscape(since), perPage)
	err := f.getAsOf(ctx, path, i.UpdatedAt, &lines)
	return lines, err
}

func (f *RealForgejo) IssueActivity(ctx context.Context, repo string, kind IssueKind, since string) ([]IssueActivity, Listed, error) {
	switch kind {
	case IssueOpened:
		items, listed, err := f.issuesSince(ctx, repo, "all", since)
		if err != nil {
			return nil, Listed{}, err
		}
		var out []IssueActivity
		for _, i := range items {
			if before(i.CreatedAt, since) {
				continue
			}
			trusted, err := f.trusted(ctx, repo, &i.User)
			if err != nil {
				return nil, Listed{}, err
			}
			out = append(out, IssueActivity{ID: strconv.Itoa(i.Number), At: i.CreatedAt, Issue: i.issue(), Kind: IssueOpened, Trusted: trusted})
		}
		return out, listed, nil
	case IssueLabelled, IssueClosed:
		// Adding a label or closing it updates the issue, so its timeline is read only for
		// the issues updated since; each label added and each close is a line of it.
		state := "all"
		if kind == IssueClosed {
			state = "closed"
		}
		items, listed, err := f.issuesSince(ctx, repo, state, since)
		if err != nil {
			return nil, Listed{}, err
		}
		var out []IssueActivity
		for _, i := range items {
			lines, err := f.timeline(ctx, repo, i, since)
			if err != nil {
				return nil, Listed{}, err
			}
			for _, l := range lines {
				if before(l.CreatedAt, since) {
					continue
				}
				// A label line's body is "1" when it was added, empty when taken off.
				added := kind == IssueLabelled && l.Type == "label" && l.Body == "1" && l.Label != nil
				if !added && (kind != IssueClosed || l.Type != "close") {
					continue
				}
				trusted, err := f.trusted(ctx, repo, l.User)
				if err != nil {
					return nil, Listed{}, err
				}
				by := ""
				if l.User != nil {
					by = l.User.Login
				}
				a := IssueActivity{ID: strconv.Itoa(l.ID), At: l.CreatedAt, Issue: i.issue(), Kind: kind, By: by, Trusted: trusted}
				if added {
					a.ID, a.Label = "label:"+a.ID, l.Label.Name
				} else {
					a.ID = strconv.Itoa(i.Number) + ":" + normalized(l.CreatedAt)
				}
				out = append(out, a)
			}
		}
		return out, listed, nil
	}
	path := fmt.Sprintf("%s/issues/comments?since=%s", repoPath(repo), url.QueryEscape(since))
	comments, truncated, err := all[commentJSON](ctx, f, path)
	if err != nil {
		return nil, Listed{}, err
	}
	listed := Listed{Truncated: truncated}
	var out []IssueActivity
	// An issue is read once per poll, shared with other waits that saw the same comment on it.
	issues := map[int]issueJSON{}
	for _, c := range comments {
		listed = listed.saw(c.CreatedAt)
		if c.PullRequestURL != "" || before(c.CreatedAt, since) {
			continue
		}
		number, err := strconv.Atoi(c.IssueURL[strings.LastIndex(c.IssueURL, "/")+1:])
		if err != nil {
			continue
		}
		i, ok := issues[number]
		if !ok {
			if err := f.getAsOf(ctx, fmt.Sprintf("%s/issues/%d", repoPath(repo), number), c.CreatedAt, &i); err != nil {
				return nil, Listed{}, err
			}
			issues[number] = i
		}
		if i.PullRequest != nil {
			continue
		}
		trusted, err := f.trusted(ctx, repo, &c.User)
		if err != nil {
			return nil, Listed{}, err
		}
		out = append(out, IssueActivity{ID: strconv.Itoa(c.ID), At: c.CreatedAt, Issue: i.issue(), Kind: IssueCommented,
			CommentAuthor: c.User.Login, CommentURL: c.HTMLURL, CommentBody: clip(c.Body), Trusted: trusted})
	}
	return out, listed, nil
}

// reviewComments are a pull request's line comments, in every review updated at or after
// since; every review when since is "".
func (f *RealForgejo) reviewComments(ctx context.Context, repo string, p pullJSON, since string) ([]reviewCommentJSON, error) {
	var reviews []reviewJSON
	if err := f.getAsOf(ctx, fmt.Sprintf("%s/pulls/%d/reviews?limit=%d", repoPath(repo), p.Number, perPage), p.UpdatedAt, &reviews); err != nil {
		return nil, err
	}
	var out []reviewCommentJSON
	for _, r := range reviews {
		at := r.UpdatedAt
		if before(at, r.SubmittedAt) {
			at = r.SubmittedAt
		}
		if r.CommentsCount == 0 || (since != "" && before(at, since)) {
			continue
		}
		var comments []reviewCommentJSON
		if err := f.getAsOf(ctx, fmt.Sprintf("%s/pulls/%d/reviews/%d/comments", repoPath(repo), p.Number, r.ID), at, &comments); err != nil {
			return nil, err
		}
		out = append(out, comments...)
	}
	return out, nil
}

// ReviewComments reads the reviews of the pull requests updated since: Forgejo has no list of
// a repository's review comments, and a review updates its pull request.
func (f *RealForgejo) ReviewComments(ctx context.Context, repo, since string) ([]ReviewComment, Listed, error) {
	pulls, listed, err := newest(ctx, f, repoPath(repo)+"/pulls?state=all&sort=recentupdate", since,
		func(p pullJSON) string { return p.UpdatedAt })
	if err != nil {
		return nil, Listed{}, err
	}
	var out []ReviewComment
	for _, p := range pulls {
		comments, err := f.reviewComments(ctx, repo, p, since)
		if err != nil {
			return nil, Listed{}, err
		}
		for _, c := range comments {
			if before(c.CreatedAt, since) {
				continue
			}
			trusted := !p.fork()
			if trusted {
				if trusted, err = f.trusted(ctx, repo, c.User); err != nil {
					return nil, Listed{}, err
				}
			}
			author := ""
			if c.User != nil {
				author = c.User.Login
			}
			out = append(out, ReviewComment{ID: c.ID, At: c.CreatedAt, PR: p.pr(), Author: author, Path: c.Path, Line: c.line(),
				Body: clip(c.Body), URL: c.HTMLURL, Trusted: trusted})
		}
	}
	return out, listed, nil
}

// MARK: The folder's repository

// GitRepo is the repository of this Forgejo that this folder pushes to, from its git remote
// (origin first), asked once it succeeds.
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
		return "", &ForgejoError{Kind: NotFound, Message: "repo is needed: " + cwd + " has no " + host + " remote"}
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

// RepoOfRemote is the repository (owner/name) of a remote of the Forgejo at base:
// https://machine/owner/name(.git), git@host:owner/name(.git) or ssh://git@host(:port)/owner/name(.git).
// A Forgejo under a path (https://machine/git/) keeps that path out of the repository's.
func RepoOfRemote(base, remote string) (string, bool) {
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
		// scp-like: [user@]host:owner/name
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
	if !repoPattern.MatchString(rest) {
		return "", false
	}
	return rest, true
}
