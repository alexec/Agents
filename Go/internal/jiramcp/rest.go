package jiramcp

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/connections"
)

// RealJira reads Jira's REST API (version 2, which Jira Cloud and Jira Data Center both
// answer, with bodies as text rather than Cloud's version 3 document format). Answers are
// shared for sharedFor (#932), as the linear server's: every wait polls on its own, and the
// same request asked twice in one poll costs the site's rate limit once.
type RealJira struct {
	// Auth is the site and its Authorization header; an empty site or header is not signed in.
	Auth   func() Auth
	Client *http.Client

	mu      sync.Mutex
	recent  map[string]sharedBody
	sharing time.Duration
}

// Auth is how RealJira reaches a site.
type Auth struct {
	// Site is the site's address: https://example.atlassian.net, or a Data Center's own.
	Site string
	// Header is the Authorization header: Basic for Jira Cloud's email and API token, Bearer
	// for a Data Center personal access token.
	Header string
	// Cloud says it is Jira Cloud, whose search is /search/jql, paged by a token.
	Cloud bool
	// API is where requests go when it is not Site: api.atlassian.com/ex/jira/<cloud id>, for
	// an Atlassian sign-in's token (#3304). Site stays the address of the site's own pages.
	API string
}

func (a Auth) api() string {
	if a.API != "" {
		return a.API
	}
	return a.Site
}

// TokenAuth is the Auth for a site and a token: with an email, Jira Cloud's API token;
// without one, a Data Center personal access token.
func TokenAuth(site, email, token string) Auth {
	site, email, token = strings.TrimRight(strings.TrimSpace(site), "/"), strings.TrimSpace(email), strings.TrimSpace(token)
	if site == "" || token == "" {
		return Auth{Site: site}
	}
	if email != "" {
		return Auth{Site: site, Cloud: true, Header: "Basic " + base64.StdEncoding.EncodeToString([]byte(email+":"+token))}
	}
	return Auth{Site: site, Header: "Bearer " + token}
}

func (a Auth) signedIn() bool { return a.Site != "" && a.Header != "" }

type sharedBody struct {
	at   time.Time
	body json.RawMessage
}

const (
	perPage   = 100
	sharedFor = 25 * time.Second
)

// NewRealJira reads the site auth names.
func NewRealJira(auth func() Auth) *RealJira {
	return &RealJira{Auth: auth, Client: &http.Client{Timeout: 30 * time.Second}, recent: map[string]sharedBody{}, sharing: sharedFor}
}

// MARK: REST

// agilePath is where Jira Software's API is: its boards (#3282).
const agilePath = "/rest/agile/1.0"

// call asks Jira method path (under /rest/api/2, or under agilePath) with body, and reads the
// answer into out.
func (j *RealJira) call(ctx context.Context, method, path string, body any, out any) error {
	auth := j.Auth()
	if !auth.signedIn() {
		return &JiraError{Kind: NotSignedIn, Message: notSignedIn}
	}
	var payload []byte
	if body != nil {
		var err error
		if payload, err = json.Marshal(body); err != nil {
			return &JiraError{Kind: Failed, Message: "Jira: " + err.Error()}
		}
	}
	key := method + " " + auth.api() + path + " " + string(payload)
	j.mu.Lock()
	shared, have := j.recent[key]
	j.mu.Unlock()
	var data json.RawMessage
	if have && time.Since(shared.at) < j.sharing {
		data = shared.body
	} else {
		var err error
		if data, err = j.send(ctx, auth, method, path, payload); err != nil {
			return err
		}
		j.mu.Lock()
		for k, v := range j.recent {
			if time.Since(v.at) >= j.sharing {
				delete(j.recent, k)
			}
		}
		j.recent[key] = sharedBody{at: time.Now(), body: data}
		j.mu.Unlock()
	}
	if err := json.Unmarshal(data, out); err != nil {
		return &JiraError{Kind: Failed, Message: "Jira: " + err.Error()}
	}
	return nil
}

func (j *RealJira) send(ctx context.Context, auth Auth, method, path string, payload []byte) (json.RawMessage, error) {
	var body io.Reader
	if payload != nil {
		body = bytes.NewReader(payload)
	}
	// A path under agilePath is Jira Software's; any other is under /rest/api/2.
	if !strings.HasPrefix(path, agilePath+"/") {
		path = "/rest/api/2" + path
	}
	req, err := http.NewRequestWithContext(ctx, method, auth.api()+path, body)
	if err != nil {
		return nil, &JiraError{Kind: Failed, Message: "Jira: " + err.Error()}
	}
	if payload != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Authorization", auth.Header)
	req.Header.Set("User-Agent", "agents-jira-mcp")
	res, err := j.Client.Do(req)
	if err != nil {
		return nil, &JiraError{Kind: Failed, Message: "Jira: " + err.Error()}
	}
	defer res.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(res.Body, 32<<20))
	if err != nil {
		return nil, &JiraError{Kind: Failed, Message: "Jira: " + err.Error()}
	}
	if res.StatusCode >= 200 && res.StatusCode < 300 {
		return raw, nil
	}
	return nil, jiraError(res, raw)
}

// jiraError is a failed answer as a JiraError.
func jiraError(res *http.Response, raw []byte) *JiraError {
	var reply struct {
		ErrorMessages []string          `json:"errorMessages"`
		Errors        map[string]string `json:"errors"`
		Message       string            `json:"message"`
	}
	_ = json.Unmarshal(raw, &reply)
	words := reply.ErrorMessages
	for _, v := range reply.Errors {
		words = append(words, v)
	}
	if reply.Message != "" {
		words = append(words, reply.Message)
	}
	sort.Strings(words)
	message := fmt.Sprintf("Jira answered %d", res.StatusCode)
	if len(words) > 0 {
		message = "Jira: " + strings.Join(words, "; ")
	}
	switch {
	case res.StatusCode == http.StatusTooManyRequests:
		retry := 60000
		if s, err := strconv.Atoi(res.Header.Get("Retry-After")); err == nil && s > 0 {
			retry = s * 1000
		}
		return &JiraError{Kind: RateLimited, Message: "Jira's rate limit is reached", RetryAfterMs: retry}
	case res.StatusCode == http.StatusUnauthorized:
		return &JiraError{Kind: NotSignedIn, Message: "Jira refused the token: make a new API token, or check JIRA_EMAIL"}
	case res.StatusCode == http.StatusForbidden:
		return &JiraError{Kind: NotSignedIn, Message: message}
	case res.StatusCode == http.StatusNotFound || res.StatusCode == http.StatusBadRequest && strings.Contains(strings.ToLower(message), "does not exist"):
		return &JiraError{Kind: NotFound, Message: message}
	}
	return &JiraError{Kind: Failed, Message: message}
}

// MARK: What is read

type restUser struct {
	AccountID   string `json:"accountId"`
	Name        string `json:"name"`
	DisplayName string `json:"displayName"`
	Email       string `json:"emailAddress"`
	AccountType string `json:"accountType"`
	// AvatarURLs are the person's picture by size; the forge reads take 48x48 (#4363).
	AvatarURLs map[string]string `json:"avatarUrls"`
}

// person is the user, or nobody. An account id is Jira Cloud's; a name, Data Center's.
func (u *restUser) person() *Person {
	if u == nil {
		return nil
	}
	id := u.AccountID
	if id == "" {
		id = u.Name
	}
	return &Person{ID: id, Name: u.DisplayName, Email: u.Email, App: u.AccountType == "app", Customer: u.AccountType == "customer",
		Avatar: u.AvatarURLs["48x48"]}
}

type restComment struct {
	ID      string    `json:"id"`
	Body    string    `json:"body"`
	Created string    `json:"created"`
	Author  *restUser `json:"author"`
}

type restIssue struct {
	ID     string `json:"id"`
	Key    string `json:"key"`
	Fields struct {
		Summary string `json:"summary"`
		Status  *struct {
			Name     string `json:"name"`
			Category *struct {
				Key string `json:"key"`
			} `json:"statusCategory"`
		} `json:"status"`
		Labels   []string  `json:"labels"`
		Assignee *restUser `json:"assignee"`
		Creator  *restUser `json:"creator"`
		Reporter *restUser `json:"reporter"`
		Created  string    `json:"created"`
		Updated  string    `json:"updated"`
		Priority *struct {
			Name string `json:"name"`
		} `json:"priority"`
		Project *struct {
			Key string `json:"key"`
		} `json:"project"`
		Comment *struct {
			Comments []restComment `json:"comments"`
			Total    int           `json:"total"`
		} `json:"comment"`
		// The forge reads' (forge.go): the milestone, the parent, the sub-tasks and the resolution.
		FixVersions []struct {
			Name string `json:"name"`
		} `json:"fixVersions"`
		Resolution *struct {
			Name string `json:"name"`
		} `json:"resolution"`
		ResolutionDate string         `json:"resolutiondate"`
		Parent         *restIssueRef  `json:"parent"`
		Subtasks       []restIssueRef `json:"subtasks"`
	} `json:"fields"`
	Changelog *struct {
		Histories []restHistory `json:"histories"`
	} `json:"changelog"`
}

type restHistory struct {
	ID      string    `json:"id"`
	Created string    `json:"created"`
	Author  *restUser `json:"author"`
	Items   []struct {
		Field      string `json:"field"`
		From       string `json:"from"`
		FromString string `json:"fromString"`
		To         string `json:"to"`
		ToString   string `json:"toString"`
	} `json:"items"`
}

// fields are what every search reads; comment is added for comments.
var fields = []string{"summary", "status", "labels", "assignee", "creator", "reporter", "created", "updated", "priority", "project"}

func (r restIssue) issue(site string) Issue {
	f := r.Fields
	i := Issue{ID: r.ID, Key: r.Key, Title: f.Summary, URL: site + "/browse/" + r.Key, CreatedAt: f.Created, Labels: []string{}}
	if f.Project != nil {
		i.Project = f.Project.Key
	} else if p, _, ok := strings.Cut(r.Key, "-"); ok {
		i.Project = p
	}
	if f.Status != nil {
		i.Status = f.Status.Name
		if f.Status.Category != nil {
			i.StatusCategory = f.Status.Category.Key
		}
	}
	i.Labels = append(i.Labels, f.Labels...)
	sort.Strings(i.Labels)
	if a := f.Assignee.person(); a != nil {
		i.Assignee, i.AssigneeID = a.Name, a.ID
	}
	i.Creator = f.Creator.person()
	if i.Creator == nil {
		i.Creator = f.Reporter.person()
	}
	return i
}

// quoted is s as a JQL string.
func quoted(s string) string {
	return `"` + strings.NewReplacer(`\`, `\\`, `"`, `\"`).Replace(s) + `"`
}

// search is the issues jql finds, at most max, with expand (changelog, renderedFields), and
// whether there were more. Jira Cloud's is /search/jql; Data Center's is /search.
func (j *RealJira) search(ctx context.Context, jql string, read []string, expand string, max int) ([]restIssue, bool, error) {
	var out struct {
		Issues        []restIssue `json:"issues"`
		Total         int         `json:"total"`
		NextPageToken string      `json:"nextPageToken"`
		IsLast        *bool       `json:"isLast"`
	}
	if j.Auth().Cloud {
		body := map[string]any{"jql": jql, "fields": read, "maxResults": max}
		if expand != "" {
			body["expand"] = expand
		}
		if err := j.call(ctx, http.MethodPost, "/search/jql", body, &out); err != nil {
			return nil, false, err
		}
		more := out.NextPageToken != "" && (out.IsLast == nil || !*out.IsLast)
		return out.Issues, more, nil
	}
	body := map[string]any{"jql": jql, "fields": read, "maxResults": max}
	if expand != "" {
		body["expand"] = strings.Split(expand, ",")
	}
	if err := j.call(ctx, http.MethodPost, "/search", body, &out); err != nil {
		return nil, false, err
	}
	return out.Issues, out.Total > len(out.Issues), nil
}

// Myself is the user of the token.
func (j *RealJira) Myself(ctx context.Context) (*Person, error) {
	var u restUser
	if err := j.call(ctx, http.MethodGet, "/myself", nil, &u); err != nil {
		return nil, err
	}
	return u.person(), nil
}

// sinceClause is JQL for at or after since, by field (created or updated). JQL's times are
// to the minute, in the user's own time zone, so it asks by minutes ago, which needs no zone,
// with a minute to spare; the exact time is checked here.
func sinceClause(field, since string, now time.Time) string {
	t, ok := parseTime(since)
	minutes := 1
	if ok {
		minutes = int(math.Ceil(now.Sub(t).Minutes())) + 1
	}
	return fmt.Sprintf("%s >= -%dm", field, max(1, minutes))
}

func projectClause(project string) string {
	if project == "" {
		return ""
	}
	return " AND project = " + quoted(project)
}

// Activity reads what happened since, of one kind: issues created, comments, or the changelog
// of issues updated (labels added, assigned to the token's user).
func (j *RealJira) Activity(ctx context.Context, kind Kind, project, since string) ([]Activity, bool, error) {
	site := j.Auth().Site
	now := time.Now()
	switch kind {
	case Opened:
		list, more, err := j.search(ctx, sinceClause("created", since, now)+projectClause(project)+" ORDER BY created ASC", fields, "", perPage)
		if err != nil {
			return nil, false, err
		}
		var items []Activity
		for _, r := range list {
			i := r.issue(site)
			items = append(items, Activity{ID: i.ID, At: i.CreatedAt, Issue: i, Kind: Opened, By: i.Creator})
		}
		return items, more, nil
	case Commented:
		list, more, err := j.search(ctx, sinceClause("updated", since, now)+projectClause(project)+" ORDER BY updated ASC",
			append(append([]string{}, fields...), "comment"), "", perPage)
		if err != nil {
			return nil, false, err
		}
		var items []Activity
		for _, r := range list {
			i := r.issue(site)
			if r.Fields.Comment == nil {
				continue
			}
			for _, c := range r.Fields.Comment.Comments {
				if before(c.Created, since) {
					continue
				}
				items = append(items, Activity{ID: c.ID, At: c.Created, Issue: i, Kind: Commented, By: c.Author.person(),
					CommentURL: i.URL + "?focusedCommentId=" + url.QueryEscape(c.ID), CommentBody: clip(c.Body)})
			}
		}
		return items, more, nil
	}
	return j.changed(ctx, kind, project, since, now)
}

// changed reads the changelog of the issues updated since: a label added is labelled, an
// assignee set to the token's user is assigned. Both share the one search, so a poll of both
// costs one (and one more for the user, for assigned).
func (j *RealJira) changed(ctx context.Context, kind Kind, project, since string, now time.Time) ([]Activity, bool, error) {
	var me *Person
	if kind == Assigned {
		var err error
		if me, err = j.Myself(ctx); err != nil {
			return nil, false, err
		}
	}
	site := j.Auth().Site
	list, more, err := j.search(ctx, sinceClause("updated", since, now)+projectClause(project)+" ORDER BY updated ASC", fields, "changelog", perPage)
	if err != nil {
		return nil, false, err
	}
	var items []Activity
	for _, r := range list {
		if r.Changelog == nil {
			continue
		}
		i := r.issue(site)
		for _, h := range r.Changelog.Histories {
			if before(h.Created, since) {
				continue
			}
			by := h.Author.person()
			for n, it := range h.Items {
				switch {
				case kind == Labelled && it.Field == "labels":
					for _, label := range added(it.FromString, it.ToString) {
						items = append(items, Activity{ID: h.ID + ":" + label, At: h.Created, Issue: i, Kind: Labelled, By: by, Label: label})
					}
				// To the connection's owner (#2034), by anyone.
				case kind == Assigned && it.Field == "assignee" && me != nil && me.ID != "" && it.To == me.ID:
					items = append(items, Activity{ID: h.ID + ":" + strconv.Itoa(n), At: h.Created, Issue: i, Kind: Assigned, By: by})
				}
			}
		}
	}
	return items, more, nil
}

// added is the labels in to that are not in from: Jira's changelog gives a label change as the
// labels before and after, separated by spaces (a label has none).
func added(from, to string) []string {
	had := map[string]bool{}
	for _, l := range strings.Fields(from) {
		had[l] = true
	}
	var out []string
	for _, l := range strings.Fields(to) {
		if !had[l] {
			out = append(out, l)
			had[l] = true
		}
	}
	return out
}

// NewestIssue is the site's newest issue, or nil when it has none: the one real read that
// proves an Atlassian connection (#3304).
func (j *RealJira) NewestIssue(ctx context.Context) (*Issue, error) {
	list, _, err := j.search(ctx, "created IS NOT EMPTY ORDER BY created DESC", fields, "", 1)
	if err != nil || len(list) == 0 {
		return nil, err
	}
	i := list[0].issue(j.Auth().Site)
	return &i, nil
}

// ConnectionAuth is the Auth for the person's Atlassian connection (#3304): a 3LO token goes
// to api.atlassian.com for the site's cloud id; a token on one site goes to the site, Basic
// with the account's email (Jira Cloud) or Bearer (a Data Center personal access token).
func ConnectionAuth(c connections.Connection) Auth {
	site := strings.TrimRight(c.URL, "/")
	header := connections.JiraHeader(c)
	if site == "" || header == "" {
		return Auth{Site: site}
	}
	a := Auth{Site: site, Header: header, Cloud: c.Resource != "" || c.User != ""}
	if c.Resource != "" {
		a.API = connections.JiraAPI(c)
	}
	return a
}
