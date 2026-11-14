package bitbucketmcp

import (
	"bytes"
	"context"
	"encoding/base64"
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

	"github.com/agentloops-dev/agent-loops/Go/internal/mcpevents"
)

// RealBitbucket reads Bitbucket Cloud's REST API 2.0 as the person, with the token Token
// gives: BITBUCKET_TOKEN, an Atlassian API token with the Bitbucket scopes (with Email, the
// account's email, as Basic auth), or a repository, project or workspace access token (with
// no email, as a Bearer token). The listings events poll are shared for sharedFor, as the
// gitlab server's (#932): every wait polls on its own, and ten waits on one repository would
// otherwise fetch the same page ten times.
type RealBitbucket struct {
	// Base is the API's root, with a trailing slash: https://api.bitbucket.org/2.0/.
	Base   string
	Token  func() string
	Email  func() string
	Client *http.Client
	// Repo is the repository the server's folder pushes to, read from git once it is needed.
	Repo func(ctx context.Context) (string, error)

	mu      sync.Mutex
	recent  map[string]sharedBody
	running map[string]*fetch
	sharing time.Duration
	members map[string]member
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
	// perPage is Bitbucket's most for one page of pull requests, issues and comments.
	perPage = 50
	// sharedFor is under the 30 s poll, so each poll still sees a fresh page.
	sharedFor = 25 * time.Second
	// memberFor is how long a person's access to a repository is kept; maxMembers bounds how many.
	memberFor  = 10 * time.Minute
	maxMembers = 1000
	// maxChecked bounds the open pull requests whose checks and conflicts a poll reads, newest
	// updated first.
	maxChecked = 50
)

// DefaultBase is Bitbucket Cloud's API.
const DefaultBase = "https://api.bitbucket.org/2.0/"

// Host is Bitbucket Cloud's git host, the one a folder's remote names.
const Host = "bitbucket.org"

// NewRealBitbucket reads the Bitbucket API at base (Bitbucket Cloud's when empty) with token's
// answer, and email's when it is an Atlassian API token.
func NewRealBitbucket(base string, token, email func() string, repo func(ctx context.Context) (string, error)) *RealBitbucket {
	if email == nil {
		email = func() string { return "" }
	}
	return &RealBitbucket{Base: BaseURL(base), Token: token, Email: email, Repo: repo, Client: &http.Client{Timeout: 30 * time.Second},
		recent: map[string]sharedBody{}, running: map[string]*fetch{}, sharing: sharedFor, members: map[string]member{}}
}

// BaseURL is base as the API's root with a trailing slash: Bitbucket Cloud's when empty, and
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

// NotConnected is what a call says with no token, or one Bitbucket no longer takes.
const NotConnected = "Bitbucket is not connected, or its token ended: connect Bitbucket in Connectors, or set BITBUCKET_TOKEN to an API token with read and write on " +
	"repositories, pull requests and issues (and BITBUCKET_EMAIL to its account's email), or to an access token"

func (b *RealBitbucket) do(ctx context.Context, method, path string, body any) ([]byte, error) {
	res, err := b.request(ctx, method, path, body, nil)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	data, err := io.ReadAll(io.LimitReader(res.Body, 64<<20))
	if err != nil {
		return nil, &BitbucketError{Kind: Failed, Message: "Bitbucket: " + err.Error()}
	}
	if res.StatusCode >= 200 && res.StatusCode < 300 {
		return data, nil
	}
	return nil, failure(res, data)
}

// request sends method to path as the person, with header's lines too, and gives the response
// with its body unread, whatever its status.
func (b *RealBitbucket) request(ctx context.Context, method, path string, body any, header http.Header) (*http.Response, error) {
	token := b.Token()
	if token == "" {
		return nil, &BitbucketError{Kind: NotSignedIn, Message: NotConnected}
	}
	var reader io.Reader
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			return nil, &BitbucketError{Kind: Failed, Message: "Bitbucket: " + err.Error()}
		}
		reader = bytes.NewReader(data)
	}
	req, err := http.NewRequestWithContext(ctx, method, b.Base+path, reader)
	if err != nil {
		return nil, &BitbucketError{Kind: Failed, Message: "Bitbucket: " + err.Error()}
	}
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	// Go drops it on a redirect to another host.
	if email := strings.TrimSpace(b.Email()); email != "" {
		req.Header.Set("Authorization", "Basic "+base64.StdEncoding.EncodeToString([]byte(email+":"+token)))
	} else {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	req.Header.Set("User-Agent", "agents-bitbucket-mcp")
	for k, v := range header {
		req.Header[k] = v
	}
	res, err := b.Client.Do(req)
	if err != nil {
		return nil, &BitbucketError{Kind: Failed, Message: "Bitbucket: " + err.Error()}
	}
	return res, nil
}

// failure is a response Bitbucket refused, as what went wrong.
func failure(res *http.Response, body []byte) *BitbucketError {
	var said struct {
		Error struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	_ = json.Unmarshal(body, &said)
	words := said.Error.Message
	if len(words) > 300 {
		words = words[:300]
	}
	switch res.StatusCode {
	case http.StatusUnauthorized:
		return &BitbucketError{Kind: NotSignedIn, Message: NotConnected}
	case http.StatusTooManyRequests:
		return &BitbucketError{Kind: RateLimited, Message: "Bitbucket rate limit", RetryAfterMs: retryAfter(res.Header)}
	case http.StatusNotFound:
		message := "not found on Bitbucket"
		if words != "" {
			message += ": " + words
		}
		return &BitbucketError{Kind: NotFound, Message: message, Refused: true}
	}
	message := fmt.Sprintf("Bitbucket: HTTP %d", res.StatusCode)
	if words != "" {
		message += ": " + words
	}
	return &BitbucketError{Kind: Failed, Message: message, Refused: res.StatusCode == http.StatusForbidden}
}

func retryAfter(h http.Header) int {
	if after, err := strconv.ParseFloat(h.Get("Retry-After"), 64); err == nil {
		return max(1000, int(after*1000))
	}
	return 60_000
}

// get is path's JSON; with shared, an answer fetched in the last sharedFor is used again, and
// a fetch already running is waited for.
func (b *RealBitbucket) get(ctx context.Context, path string, shared bool, into any) error {
	var body []byte
	var err error
	if shared {
		body, err = b.shared(path, func() ([]byte, error) { return b.do(ctx, http.MethodGet, path, nil) })
	} else {
		body, err = b.do(ctx, http.MethodGet, path, nil)
	}
	if err != nil {
		return err
	}
	if json.Unmarshal(body, into) != nil {
		return &BitbucketError{Kind: Failed, Message: "Bitbucket's answer is not JSON"}
	}
	return nil
}

// getAsOf is path's JSON shared as get shares it, but only with a fetch for the same asOf: a
// time the thing at path changed at, so what is shared is never older than what the caller
// has seen.
func (b *RealBitbucket) getAsOf(ctx context.Context, path, asOf string, into any) error {
	body, err := b.shared(path+" "+mcpevents.Normalized(asOf), func() ([]byte, error) { return b.do(ctx, http.MethodGet, path, nil) })
	if err != nil {
		return err
	}
	if json.Unmarshal(body, into) != nil {
		return &BitbucketError{Kind: Failed, Message: "Bitbucket's answer is not JSON"}
	}
	return nil
}

func (b *RealBitbucket) send(ctx context.Context, method, path string, body, into any) error {
	data, err := b.do(ctx, method, path, body)
	if err != nil {
		return err
	}
	if into == nil || len(bytes.TrimSpace(data)) == 0 {
		return nil
	}
	if json.Unmarshal(data, into) != nil {
		return &BitbucketError{Kind: Failed, Message: "Bitbucket's answer is not JSON"}
	}
	return nil
}

func (b *RealBitbucket) shared(key string, get func() ([]byte, error)) ([]byte, error) {
	b.mu.Lock()
	now := time.Now()
	if kept, ok := b.recent[key]; ok && now.Sub(kept.at) < b.sharing {
		b.mu.Unlock()
		return kept.body, nil
	}
	if fe, ok := b.running[key]; ok {
		b.mu.Unlock()
		<-fe.done
		return fe.body, fe.err
	}
	fe := &fetch{done: make(chan struct{})}
	b.running[key] = fe
	b.mu.Unlock()

	fe.body, fe.err = get()
	close(fe.done)

	b.mu.Lock()
	delete(b.running, key)
	if fe.err == nil {
		for k, v := range b.recent {
			if now.Sub(v.at) >= b.sharing {
				delete(b.recent, k)
			}
		}
		b.recent[key] = sharedBody{time.Now(), fe.body}
	}
	b.mu.Unlock()
	return fe.body, fe.err
}

// repoPath is a repository's part of an API path: repositories/workspace/name.
func repoPath(repo string) string {
	workspace, name, _ := strings.Cut(repo, "/")
	return "repositories/" + url.PathEscape(workspace) + "/" + url.PathEscape(name)
}

func query(path string, page int) string {
	sep := "?"
	if strings.Contains(path, "?") {
		sep = "&"
	}
	return fmt.Sprintf("%s%spagelen=%d&page=%d", path, sep, perPage, page)
}

// paged is one page of a Bitbucket listing; Next is set when there is another.
type paged[T any] struct {
	Values []T    `json:"values"`
	Next   string `json:"next"`
}

// all pages path to its end, at most maxPages; truncated says it stopped there.
func all[T any](ctx context.Context, b *RealBitbucket, path string, shared bool) (items []T, truncated bool, err error) {
	for page := 1; page <= maxPages; page++ {
		var list paged[T]
		if err := b.get(ctx, query(path, page), shared, &list); err != nil {
			return nil, false, err
		}
		items = append(items, list.Values...)
		if list.Next == "" {
			return items, false, nil
		}
	}
	return items, true, nil
}

// newest pages path (newest first) until an item older than since by its time; with asOf,
// each page is shared only with a fetch for the same asOf (getAsOf).
func newest[T any](ctx context.Context, b *RealBitbucket, path, since, asOf string, at func(T) string) ([]T, Listed, error) {
	var items []T
	var listed Listed
	for page := 1; page <= maxPages; page++ {
		var list paged[T]
		var err error
		if asOf != "" {
			err = b.getAsOf(ctx, query(path, page), asOf, &list)
		} else {
			err = b.get(ctx, query(path, page), true, &list)
		}
		if err != nil {
			return nil, Listed{}, err
		}
		for _, item := range list.Values {
			if since != "" && mcpevents.Before(at(item), since) {
				return items, listed, nil
			}
			items = append(items, item)
			listed = listed.Saw(at(item))
		}
		if list.Next == "" {
			return items, listed, nil
		}
	}
	listed.Truncated = true
	return items, listed, nil
}

// bbql is a BBQL filter as a query parameter.
func bbql(q string) string { return "q=" + url.QueryEscape(q) }

// MARK: Bitbucket's JSON

type user struct {
	Type        string `json:"type"`
	UUID        string `json:"uuid"`
	AccountID   string `json:"account_id"`
	Nickname    string `json:"nickname"`
	DisplayName string `json:"display_name"`
	// Links.Avatar is the person's picture, on Atlassian's avatar host or Gravatar (#4363).
	Links struct {
		Avatar struct {
			Href string `json:"href"`
		} `json:"avatar"`
	} `json:"links"`
}

// name is how an event names a person: their nickname, else their display name.
func (u *user) name() string {
	if u == nil {
		return ""
	}
	if u.Nickname != "" {
		return u.Nickname
	}
	return u.DisplayName
}

// avatar is the person's picture, "" for none.
func (u *user) avatar() string {
	if u == nil {
		return ""
	}
	return u.Links.Avatar.Href
}

// id is how Bitbucket's paths name a person: their account id, else their uuid.
func (u *user) id() string {
	if u.AccountID != "" {
		return u.AccountID
	}
	return u.UUID
}

func (u *user) same(o *user) bool {
	return u != nil && o != nil && ((u.UUID != "" && u.UUID == o.UUID) || (u.AccountID != "" && u.AccountID == o.AccountID))
}

type links struct {
	HTML struct {
		Href string `json:"href"`
	} `json:"html"`
}

type content struct {
	Raw string `json:"raw"`
}

type endpoint struct {
	Branch struct {
		Name string `json:"name"`
	} `json:"branch"`
	Commit *struct {
		Hash string `json:"hash"`
	} `json:"commit"`
	Repository *struct {
		FullName string `json:"full_name"`
	} `json:"repository"`
}

func (e endpoint) hash() string {
	if e.Commit == nil {
		return ""
	}
	return e.Commit.Hash
}

func (e endpoint) repo() string {
	if e.Repository == nil {
		return ""
	}
	return e.Repository.FullName
}

type pullJSON struct {
	ID          int      `json:"id"`
	Title       string   `json:"title"`
	Description string   `json:"description"`
	State       string   `json:"state"`
	Author      user     `json:"author"`
	Draft       bool     `json:"draft"`
	Source      endpoint `json:"source"`
	Destination endpoint `json:"destination"`
	MergeCommit *struct {
		Hash string `json:"hash"`
	} `json:"merge_commit"`
	CreatedOn    string `json:"created_on"`
	UpdatedOn    string `json:"updated_on"`
	Reviewers    []user `json:"reviewers"`
	Links        links  `json:"links"`
	CommentCount int    `json:"comment_count"`
}

func (p pullJSON) pr() PR {
	return PR{Number: p.ID, Title: p.Title, Branch: p.Source.Branch.Name, URL: p.Links.HTML.Href, Fixes: closingRefs(p.Description),
		Author: p.Author.name()}
}

// fork says whether its branch is in another repository.
func (p pullJSON) fork() bool {
	return p.Source.repo() != "" && p.Destination.repo() != "" && !strings.EqualFold(p.Source.repo(), p.Destination.repo())
}

// pullFields adds to a listing's pull requests what its short form leaves out.
const pullFields = "fields=" + "%2Bvalues.description,%2Bvalues.reviewers,%2Bvalues.draft"

type issueJSON struct {
	ID        int     `json:"id"`
	Title     string  `json:"title"`
	Content   content `json:"content"`
	State     string  `json:"state"`
	Kind      string  `json:"kind"`
	Priority  string  `json:"priority"`
	Reporter  *user   `json:"reporter"`
	Assignee  *user   `json:"assignee"`
	Component *struct {
		Name string `json:"name"`
	} `json:"component"`
	Milestone *struct {
		ID   int    `json:"id"`
		Name string `json:"name"`
	} `json:"milestone"`
	CreatedOn string `json:"created_on"`
	UpdatedOn string `json:"updated_on"`
	Links     links  `json:"links"`
}

// labels are an issue's kind and component: Bitbucket's issues have no labels.
func (i issueJSON) labels() []string {
	out := []string{}
	if i.Kind != "" {
		out = append(out, i.Kind)
	}
	if i.Component != nil && i.Component.Name != "" {
		out = append(out, i.Component.Name)
	}
	return out
}

func (i issueJSON) issue() Issue {
	assignees := []string{}
	if name := i.Assignee.name(); name != "" {
		assignees = append(assignees, name)
	}
	return Issue{Number: i.ID, Title: i.Title, Author: i.Reporter.name(), Labels: i.labels(), URL: i.Links.HTML.Href, Assignees: assignees}
}

// closedStates are an issue's states that are closed; new, open and on hold are open.
var closedStates = map[string]bool{"resolved": true, "invalid": true, "duplicate": true, "wontfix": true, "closed": true}

// stateReasons are why an issue in each closed state closed, in the one model's words (#4365).
var stateReasons = map[string]string{"resolved": "completed", "closed": "completed", "invalid": "not_planned",
	"wontfix": "not_planned", "duplicate": "duplicate"}

// openIssues is BBQL for an open issue.
const openIssues = `(state="new" OR state="open" OR state="on hold")`

// closedIssues is BBQL for a closed issue.
const closedIssues = `(state="resolved" OR state="invalid" OR state="duplicate" OR state="wontfix" OR state="closed")`

type commentJSON struct {
	ID      int     `json:"id"`
	Content content `json:"content"`
	User    *user   `json:"user"`
	Deleted bool    `json:"deleted"`
	Inline  *struct {
		Path string `json:"path"`
		From *int   `json:"from"`
		To   *int   `json:"to"`
	} `json:"inline"`
	Parent *struct {
		ID int `json:"id"`
	} `json:"parent"`
	Resolution *json.RawMessage `json:"resolution"`
	CreatedOn  string           `json:"created_on"`
	Links      links            `json:"links"`
}

// line is the line an inline comment is on: the new file's, else the old file's.
func (c commentJSON) line() int {
	switch {
	case c.Inline == nil:
		return 0
	case c.Inline.To != nil:
		return *c.Inline.To
	case c.Inline.From != nil:
		return *c.Inline.From
	}
	return 0
}

// changeJSON is one change to an issue: its state, kind, component and the like, each old and new.
type changeJSON struct {
	ID        int                                  `json:"id"`
	User      *user                                `json:"user"`
	CreatedOn string                               `json:"created_on"`
	Changes   map[string]struct{ Old, New string } `json:"changes"`
}

type statusJSON struct {
	Key         string `json:"key"`
	Name        string `json:"name"`
	State       string `json:"state"`
	URL         string `json:"url"`
	Description string `json:"description"`
	CreatedOn   string `json:"created_on"`
	UpdatedOn   string `json:"updated_on"`
}

func (s statusJSON) title() string {
	if s.Name != "" {
		return s.Name
	}
	return s.Key
}

// combined is a commit's statuses as one state: failure when one failed, pending while one
// runs, success when all succeeded, "" when it has none.
func combined(statuses []statusJSON) string {
	state := ""
	for _, s := range statuses {
		switch s.State {
		case "FAILED":
			return "failure"
		case "INPROGRESS":
			state = "pending"
		case "SUCCESSFUL", "STOPPED":
			if state == "" {
				state = "success"
			}
		}
	}
	return state
}

// pipelinesRun is a Pipelines run's build number in a status's link: …/pipelines/results/12.
var pipelinesRun = regexp.MustCompile(`/pipelines/results/([0-9]+)`)

// MARK: Who is the repository's own

// trusted says whether u is one of the repository's own (#728): a person with write access to
// it or more, and not an app or a bot. Bitbucket lets only a repository's admins read another
// person's access, so a token without admin falls back to whether they are a member of the
// workspace that owns it. Bitbucket is asked once per person per memberFor.
func (b *RealBitbucket) trusted(ctx context.Context, repo string, u *user) (bool, error) {
	if u == nil || u.id() == "" || isBot(u.name(), u.Type) {
		return false, nil
	}
	key := repo + "\x00" + u.id()
	b.mu.Lock()
	kept, ok := b.members[key]
	b.mu.Unlock()
	if ok && time.Since(kept.at) < memberFor {
		return kept.trusted, nil
	}
	trusted, err := b.access(ctx, repo, u.id())
	if err != nil {
		return false, err
	}
	b.mu.Lock()
	if len(b.members) >= maxMembers {
		b.members = map[string]member{}
	}
	b.members[key] = member{time.Now(), trusted}
	b.mu.Unlock()
	return trusted, nil
}

func (b *RealBitbucket) access(ctx context.Context, repo, id string) (bool, error) {
	refused := func(err error) bool {
		be, ok := err.(*BitbucketError)
		return ok && be.Refused
	}
	var p struct {
		Permission string `json:"permission"`
	}
	// An admin reads it; a person given access by the workspace or a project, not by the
	// repository, has no line here (404), so falls to the workspace.
	err := b.get(ctx, repoPath(repo)+"/permissions-config/users/"+url.PathEscape(id), false, &p)
	if err == nil {
		return p.Permission == "write" || p.Permission == "admin", nil
	}
	if !refused(err) {
		return false, err
	}
	workspace, _, _ := strings.Cut(repo, "/")
	var m json.RawMessage
	if err := b.get(ctx, "workspaces/"+url.PathEscape(workspace)+"/members/"+url.PathEscape(id), false, &m); err == nil {
		return true, nil
	} else if !refused(err) {
		return false, err
	}
	return false, nil
}

// trustedPR says whether a pull request is the repository's own: its branch in the
// repository, not a fork, and its author one of the repository's own.
func (b *RealBitbucket) trustedPR(ctx context.Context, repo string, p pullJSON) (bool, error) {
	if p.fork() {
		return false, nil
	}
	return b.trusted(ctx, repo, &p.Author)
}

// MARK: Bitbucket

func (b *RealBitbucket) DefaultRepo(ctx context.Context) (string, error) { return b.Repo(ctx) }

// openPulls are the open pull requests, newest updated first.
func (b *RealBitbucket) openPulls(ctx context.Context, repo string) ([]pullJSON, error) {
	list, _, err := all[pullJSON](ctx, b, repoPath(repo)+"/pullrequests?state=OPEN&sort=-updated_on&"+pullFields, true)
	return list, err
}

// conflictStates are the diffstat states of a file in conflict.
var conflictStates = map[string]bool{"merge conflict": true, "local deleted": true, "remote deleted": true}

// conflicts says whether an open pull request conflicts with its base: a file of its diffstat
// is in conflict. Bitbucket has no mergeable flag on a pull request.
func (b *RealBitbucket) conflicts(ctx context.Context, repo string, p pullJSON) (bool, error) {
	files, _, err := all[struct {
		Status string `json:"status"`
	}](ctx, b, fmt.Sprintf("%s/pullrequests/%d/diffstat", repoPath(repo), p.ID), true)
	if err != nil {
		return false, err
	}
	for _, f := range files {
		if conflictStates[f.Status] {
			return true, nil
		}
	}
	return false, nil
}

func (b *RealBitbucket) OpenPRs(ctx context.Context, repo string, withConflicts bool) ([]OpenPR, error) {
	list, err := b.openPulls(ctx, repo)
	if err != nil {
		return nil, err
	}
	out := make([]OpenPR, 0, len(list))
	for i, p := range list {
		trusted, err := b.trustedPR(ctx, repo, p)
		if err != nil {
			return nil, err
		}
		o := OpenPR{PR: p.pr(), Author: p.Author.name(), Draft: p.Draft, HeadSHA: p.Source.hash(), Trusted: trusted}
		if withConflicts && i < maxChecked {
			c, err := b.conflicts(ctx, repo, p)
			if err != nil {
				return nil, err
			}
			o.Conflicts = &c
		}
		out = append(out, o)
	}
	return out, nil
}

// me is the token's owner.
func (b *RealBitbucket) me(ctx context.Context) (user, error) {
	var me user
	if err := b.get(ctx, "user", true, &me); err != nil {
		return user{}, err
	}
	if me.UUID == "" && me.AccountID == "" {
		return user{}, &BitbucketError{Kind: NotSignedIn, Message: "Bitbucket did not say whose the token is"}
	}
	return me, nil
}

// Yours is the token's owner and, in one repository, their open pull requests, the open ones
// they are asked to review, and the open issues assigned to them (#2034).
func (b *RealBitbucket) Yours(ctx context.Context, repo string) (Yours, error) {
	me, err := b.me(ctx)
	if err != nil {
		return Yours{}, err
	}
	y := Yours{Login: me.name()}
	pulls, err := b.openPulls(ctx, repo)
	if err != nil {
		return Yours{}, err
	}
	for _, p := range pulls {
		if p.Author.same(&me) {
			y.PRs = append(y.PRs, p.ID)
		}
		for _, r := range p.Reviewers {
			if r.same(&me) {
				y.Reviews = append(y.Reviews, OpenPR{PR: p.pr(), Author: p.Author.name(), Draft: p.Draft, HeadSHA: p.Source.hash()})
				break
			}
		}
	}
	var assigned paged[issueJSON]
	q := bbql(fmt.Sprintf(`assignee.uuid=%q AND %s`, me.UUID, openIssues))
	err = b.get(ctx, fmt.Sprintf("%s/issues?%s&pagelen=%d", repoPath(repo), q, perPage), true, &assigned)
	if err != nil && !noTracker(err) {
		return Yours{}, err
	}
	for _, i := range assigned.Values {
		y.Assigned = append(y.Assigned, i.issue())
	}
	return y, nil
}

// noTracker says whether err is Bitbucket's 404 for a repository with no issue tracker.
func noTracker(err error) bool {
	be, ok := err.(*BitbucketError)
	return ok && be.Kind == NotFound
}

// closedAt is when a merged or declined pull request was closed: its activity's newest
// update to that state, shared by its update time. updated_on moves with every later
// comment, so it is the time only when the activity has none.
func (b *RealBitbucket) closedAt(ctx context.Context, repo string, p pullJSON) (string, error) {
	var activity paged[struct {
		Update *struct {
			State string `json:"state"`
			Date  string `json:"date"`
		} `json:"update"`
	}]
	path := fmt.Sprintf("%s/pullrequests/%d/activity?pagelen=%d", repoPath(repo), p.ID, perPage)
	if err := b.getAsOf(ctx, path, p.UpdatedOn, &activity); err != nil {
		return "", err
	}
	for _, a := range activity.Values {
		if a.Update != nil && a.Update.State == p.State && a.Update.Date != "" {
			return a.Update.Date, nil
		}
	}
	return p.UpdatedOn, nil
}

func (b *RealBitbucket) ClosedPRs(ctx context.Context, repo, since string) ([]MergedPR, []ClosedPR, Listed, error) {
	list, listed, err := newest(ctx, b, repoPath(repo)+"/pullrequests?state=MERGED&state=DECLINED&sort=-updated_on&"+pullFields, since, "",
		func(p pullJSON) string { return p.UpdatedOn })
	if err != nil {
		return nil, nil, Listed{}, err
	}
	var merged []MergedPR
	var closed []ClosedPR
	for _, p := range list {
		at, err := b.closedAt(ctx, repo, p)
		if err != nil {
			return nil, nil, Listed{}, err
		}
		if mcpevents.Before(at, since) {
			continue
		}
		trusted, err := b.trustedPR(ctx, repo, p)
		if err != nil {
			return nil, nil, Listed{}, err
		}
		switch p.State {
		case "MERGED":
			sha := ""
			if p.MergeCommit != nil {
				sha = p.MergeCommit.Hash
			}
			merged = append(merged, MergedPR{PR: p.pr(), MergedAt: at, MergeSHA: sha, Trusted: trusted})
		case "DECLINED":
			closed = append(closed, ClosedPR{PR: p.pr(), ClosedAt: at, Trusted: trusted})
		}
	}
	return merged, closed, listed, nil
}

// statuses are a commit's statuses: the newest of each check.
func (b *RealBitbucket) statuses(ctx context.Context, repo, sha string, shared bool) ([]statusJSON, error) {
	list, _, err := all[statusJSON](ctx, b, fmt.Sprintf("%s/commit/%s/statuses", repoPath(repo), url.PathEscape(sha)), shared)
	return list, err
}

// FailedChecks reads the statuses of the head of each of the maxChecked open pull requests
// updated last: Bitbucket has no list of failed checks for a repository.
func (b *RealBitbucket) FailedChecks(ctx context.Context, repo, since string) ([]FailedChecks, Listed, error) {
	pulls, err := b.openPulls(ctx, repo)
	if err != nil {
		return nil, Listed{}, err
	}
	var out []FailedChecks
	var listed Listed
	for _, p := range pulls[:min(maxChecked, len(pulls))] {
		sha := p.Source.hash()
		if sha == "" {
			continue
		}
		statuses, err := b.statuses(ctx, repo, sha, true)
		if err != nil {
			return nil, Listed{}, err
		}
		d := FailedChecks{PR: p.pr(), HeadSHA: sha, Failed: []Check{}}
		for _, s := range statuses {
			if s.State != "FAILED" {
				continue
			}
			if at := mcpevents.Normalized(s.UpdatedOn); at > d.At {
				d.At = at
			}
			d.Failed = append(d.Failed, Check{Name: s.title(), URL: s.URL})
			if d.RunURL == "" {
				d.RunName, d.RunURL = s.title(), s.URL
				if m := pipelinesRun.FindStringSubmatch(s.URL); m != nil {
					d.RunID, _ = strconv.Atoi(m[1])
				}
			}
		}
		if len(d.Failed) == 0 {
			continue
		}
		listed = listed.Saw(d.At)
		if d.At == "" || mcpevents.Before(d.At, since) {
			continue
		}
		if d.Trusted, err = b.trustedPR(ctx, repo, p); err != nil {
			return nil, Listed{}, err
		}
		out = append(out, d)
	}
	return out, listed, nil
}

// issuesSince are the repository's issues updated at or after since, newest first; none when
// it has no issue tracker.
func (b *RealBitbucket) issuesSince(ctx context.Context, repo, since string) ([]issueJSON, Listed, error) {
	path := fmt.Sprintf("%s/issues?%s&sort=-updated_on", repoPath(repo), bbql("updated_on>="+mcpevents.Normalized(since)))
	items, listed, err := newest(ctx, b, path, since, "", func(i issueJSON) string { return i.UpdatedOn })
	if err != nil && noTracker(err) {
		return nil, Listed{}, nil
	}
	return items, listed, err
}

func (b *RealBitbucket) IssueActivity(ctx context.Context, repo string, kind IssueKind, since string) ([]IssueActivity, Listed, error) {
	items, listed, err := b.issuesSince(ctx, repo, since)
	if err != nil {
		return nil, Listed{}, err
	}
	var out []IssueActivity
	for _, i := range items {
		switch kind {
		case IssueOpened:
			if mcpevents.Before(i.CreatedOn, since) {
				continue
			}
			trusted, err := b.trusted(ctx, repo, i.Reporter)
			if err != nil {
				return nil, Listed{}, err
			}
			out = append(out, IssueActivity{ID: strconv.Itoa(i.ID), At: i.CreatedOn, Issue: i.issue(), Kind: IssueOpened, Trusted: trusted})
		case IssueLabelled, IssueClosed:
			// A change updates the issue, so its changes are read only for the issues updated
			// since; a kind or component set anew, and a state set to a closed one, is a change.
			changes, _, err := newest(ctx, b, fmt.Sprintf("%s/issues/%d/changes?sort=-created_on", repoPath(repo), i.ID), since, i.UpdatedOn,
				func(c changeJSON) string { return c.CreatedOn })
			if err != nil {
				return nil, Listed{}, err
			}
			for _, c := range changes {
				var found []IssueActivity
				if kind == IssueLabelled {
					for _, field := range []string{"kind", "component"} {
						if ch, ok := c.Changes[field]; ok && ch.New != "" && ch.New != ch.Old {
							found = append(found, IssueActivity{ID: fmt.Sprintf("label:%d:%s", c.ID, field), Label: ch.New})
						}
					}
				} else if ch, ok := c.Changes["state"]; ok && closedStates[ch.New] && !closedStates[ch.Old] {
					found = append(found, IssueActivity{ID: strconv.Itoa(i.ID) + ":" + mcpevents.Normalized(c.CreatedOn)})
				}
				if len(found) == 0 {
					continue
				}
				trusted, err := b.trusted(ctx, repo, c.User)
				if err != nil {
					return nil, Listed{}, err
				}
				for _, a := range found {
					a.At, a.Issue, a.Kind, a.By, a.Trusted = c.CreatedOn, i.issue(), kind, c.User.name(), trusted
					out = append(out, a)
				}
			}
		case IssueCommented:
			comments, _, err := newest(ctx, b, fmt.Sprintf("%s/issues/%d/comments?sort=-created_on", repoPath(repo), i.ID), since, i.UpdatedOn,
				func(c commentJSON) string { return c.CreatedOn })
			if err != nil {
				return nil, Listed{}, err
			}
			for _, c := range comments {
				// A change with no words is a comment too.
				if strings.TrimSpace(c.Content.Raw) == "" {
					continue
				}
				trusted, err := b.trusted(ctx, repo, c.User)
				if err != nil {
					return nil, Listed{}, err
				}
				out = append(out, IssueActivity{ID: strconv.Itoa(c.ID), At: c.CreatedOn, Issue: i.issue(), Kind: IssueCommented,
					CommentAuthor: c.User.name(), CommentURL: c.Links.HTML.Href, CommentBody: clip(c.Content.Raw), Trusted: trusted})
			}
		}
	}
	return out, listed, nil
}

// inlineComments are a pull request's comments on lines of its diff, and the answers in their
// threads (which carry their line), newest first; with since, only those made at or after it.
func (b *RealBitbucket) inlineComments(ctx context.Context, repo string, p pullJSON, since string) ([]commentJSON, error) {
	comments, _, err := newest(ctx, b, fmt.Sprintf("%s/pullrequests/%d/comments?sort=-created_on", repoPath(repo), p.ID), since, p.UpdatedOn,
		func(c commentJSON) string { return c.CreatedOn })
	if err != nil {
		return nil, err
	}
	out := []commentJSON{}
	for _, c := range comments {
		if c.Inline != nil && !c.Deleted {
			out = append(out, c)
		}
	}
	return out, nil
}

// ReviewComments reads the comments of the pull requests updated since: Bitbucket has no list
// of a repository's comments, and a comment updates its pull request.
func (b *RealBitbucket) ReviewComments(ctx context.Context, repo, since string) ([]ReviewComment, Listed, error) {
	pulls, listed, err := newest(ctx, b, repoPath(repo)+"/pullrequests?state=OPEN&state=MERGED&state=DECLINED&sort=-updated_on", since, "",
		func(p pullJSON) string { return p.UpdatedOn })
	if err != nil {
		return nil, Listed{}, err
	}
	var out []ReviewComment
	for _, p := range pulls {
		comments, err := b.inlineComments(ctx, repo, p, since)
		if err != nil {
			return nil, Listed{}, err
		}
		for _, c := range comments {
			trusted := !p.fork()
			if trusted {
				if trusted, err = b.trusted(ctx, repo, c.User); err != nil {
					return nil, Listed{}, err
				}
			}
			out = append(out, ReviewComment{ID: c.ID, At: c.CreatedOn, PR: p.pr(), Author: c.User.name(), Path: c.Inline.Path, Line: c.line(),
				Body: clip(c.Content.Raw), URL: c.Links.HTML.Href, Trusted: trusted})
		}
	}
	return out, listed, nil
}

// MARK: The folder's repository

// GitRepo is the Bitbucket Cloud repository this folder pushes to, from its git remote
// (origin first), asked once it succeeds.
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
			if path, ok := RepoOfRemote(strings.TrimSpace(string(out))); ok {
				repo = path
				return repo, nil
			}
		}
		cwd, _ := os.Getwd()
		return "", &BitbucketError{Kind: NotFound, Message: "repo is needed: " + cwd + " has no " + Host + " remote"}
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

// RepoOfRemote is the repository (workspace/name) of a Bitbucket Cloud remote:
// https://[user@]bitbucket.org/workspace/name(.git), git@bitbucket.org:workspace/name(.git) or
// ssh://git@bitbucket.org/workspace/name(.git).
func RepoOfRemote(remote string) (string, bool) {
	rest := ""
	switch {
	case strings.Contains(remote, "://"):
		r, err := url.Parse(remote)
		if err != nil || !strings.EqualFold(r.Hostname(), Host) {
			return "", false
		}
		rest = strings.Trim(r.Path, "/")
	default:
		// scp-like: [user@]host:workspace/name
		at := remote
		if _, after, ok := strings.Cut(remote, "@"); ok {
			at = after
		}
		h, path, ok := strings.Cut(at, ":")
		if !ok || !strings.EqualFold(h, Host) {
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
