package azureboardsmcp

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
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/azuredevopsmcp"
)

// RealBoards reads Azure Boards over Azure DevOps's REST API (7.1) as the person, with the
// personal access token Token gives: AZURE_DEVOPS_TOKEN, with Work Items (read and write).
// Base is dev.azure.com or the person's own Azure DevOps Server, as the azuredevops server's
// (azuredevopsmcp.BaseURL). Project is organization/project. The reads that events poll are
// shared for sharedFor, as the azuredevops server's (#932): each event polls on its own, and
// five events would otherwise read the same work items five times.
type RealBoards struct {
	Base    string
	Token   func() string
	Client  *http.Client
	Project func(ctx context.Context) (string, error)

	mu      sync.Mutex
	recent  map[string]sharedBody
	running map[string]*fetch
	sharing time.Duration
	me      string
	// types is each project's work item types and their states, in order, by project (lower
	// case), as they were read.
	types map[string]typesRead
}

// typesRead is a project's work item types, each type's states in its process's order, and when
// they were read.
type typesRead struct {
	at    time.Time
	types map[string][]State
}

// State is a state of a work item type: its name (Active) and its category (Proposed,
// InProgress, Resolved, Completed or Removed).
type State struct {
	Name, Category string
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
	// maxChecked bounds the work items a poll reads, the ones changed last.
	maxChecked = 50
	// maxListed bounds the work items list_work_items gives.
	maxListed = 50
	// maxPages and perPage bound one work item's updates read.
	maxPages = 5
	perPage  = 200
	// sharedFor is under the minute's poll, so each poll still sees fresh work items.
	sharedFor = 25 * time.Second
	// statesFor is how long the work item types' states are used before they are read again.
	statesFor = 10 * time.Minute
	// apiVersion is the REST API's version: Azure DevOps Services and Server 2022.1 and later.
	apiVersion = "7.1"
	// commentsVersion is the comments API's, a preview in 7.1.
	commentsVersion = "7.1-preview.4"
)

// NewRealBoards reads the Azure DevOps at base (dev.azure.com when empty) with token's answer.
func NewRealBoards(base string, token func() string, project func(ctx context.Context) (string, error)) *RealBoards {
	return &RealBoards{Base: azuredevopsmcp.BaseURL(base), Token: token, Project: project,
		// A sign-in page is an answer to a token it does not take: never followed.
		Client: &http.Client{Timeout: 30 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		}},
		recent: map[string]sharedBody{}, running: map[string]*fetch{}, sharing: sharedFor}
}

// ProjectOf is project (organization/project) when it is set, else the project of the folder's
// Azure DevOps Repos remote, read from git once it is needed.
func ProjectOf(base, project string) func(ctx context.Context) (string, error) {
	project = strings.Trim(strings.TrimSpace(project), "/")
	repo := azuredevopsmcp.GitRepo(base)
	return func(ctx context.Context) (string, error) {
		if project != "" {
			if org, name, ok := strings.Cut(project, "/"); !ok || org == "" || name == "" || strings.Contains(name, "/") {
				return "", &BoardsError{Kind: NotFound, Message: "AZURE_BOARDS_PROJECT is organization/project, not " + project}
			}
			return project, nil
		}
		r, err := repo(ctx)
		if err != nil {
			return "", &BoardsError{Kind: NotFound, Message: "the project is needed: set AZURE_BOARDS_PROJECT to organization/project (" + err.Error() + ")"}
		}
		org, rest, _ := strings.Cut(r, "/")
		name, _, _ := strings.Cut(rest, "/")
		return org + "/" + name, nil
	}
}

// MARK: HTTP

// NotConnected is what a call says with no token, or one Azure DevOps no longer takes.
const NotConnected = "Azure DevOps is not connected, or its token ended: set AZURE_DEVOPS_TOKEN to a personal access token with Work Items (read and write)"

func (f *RealBoards) do(ctx context.Context, method, path string, body any) ([]byte, error) {
	token := f.Token()
	if token == "" {
		return nil, &BoardsError{Kind: NotSignedIn, Message: NotConnected}
	}
	var reader io.Reader
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			return nil, &BoardsError{Kind: Failed, Message: "Azure DevOps: " + err.Error()}
		}
		reader = bytes.NewReader(data)
	}
	req, err := http.NewRequestWithContext(ctx, method, f.Base+path, reader)
	if err != nil {
		return nil, &BoardsError{Kind: Failed, Message: "Azure DevOps: " + err.Error()}
	}
	req.Header.Set("Accept", "application/json")
	if _, ok := body.(patch); ok {
		// A work item is changed by a JSON Patch.
		req.Header.Set("Content-Type", "application/json-patch+json")
	} else if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	// A personal access token is the password of Basic, with no user.
	req.Header.Set("Authorization", "Basic "+base64.StdEncoding.EncodeToString([]byte(":"+token)))
	req.Header.Set("User-Agent", "agents-azureboards-mcp")
	res, err := f.Client.Do(req)
	if err != nil {
		return nil, &BoardsError{Kind: Failed, Message: "Azure DevOps: " + err.Error()}
	}
	defer res.Body.Close()
	data, err := io.ReadAll(io.LimitReader(res.Body, 64<<20))
	if err != nil {
		return nil, &BoardsError{Kind: Failed, Message: "Azure DevOps: " + err.Error()}
	}
	// A token it does not take is answered with a sign-in page: 203, or a redirect to it.
	kind, _, _ := mime.ParseMediaType(res.Header.Get("Content-Type"))
	if res.StatusCode == http.StatusNonAuthoritativeInfo || (res.StatusCode >= 300 && res.StatusCode < 400) ||
		(res.StatusCode < 300 && kind == "text/html") {
		return nil, &BoardsError{Kind: NotSignedIn, Message: NotConnected}
	}
	if res.StatusCode >= 200 && res.StatusCode < 300 {
		return data, nil
	}
	return nil, failure(res, data)
}

// failure is a response Azure DevOps refused, as what went wrong.
func failure(res *http.Response, body []byte) *BoardsError {
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
		return &BoardsError{Kind: NotSignedIn, Message: NotConnected}
	case http.StatusTooManyRequests:
		return &BoardsError{Kind: RateLimited, Message: "Azure DevOps rate limit", RetryAfterMs: retryAfter(res.Header)}
	case http.StatusNotFound:
		message := "not found on Azure DevOps"
		if words != "" {
			message += ": " + words
		}
		return &BoardsError{Kind: NotFound, Message: message}
	}
	message := fmt.Sprintf("Azure DevOps: HTTP %d", res.StatusCode)
	if words != "" {
		message += ": " + words
	}
	return &BoardsError{Kind: Failed, Message: message}
}

func retryAfter(h http.Header) int {
	if after, err := strconv.ParseFloat(h.Get("Retry-After"), 64); err == nil {
		return max(1000, int(after*1000))
	}
	return 60_000
}

// call is method path's JSON answer in into; with shared, an answer fetched in the last
// sharedFor is used again, and a fetch already running is waited for.
func (f *RealBoards) call(ctx context.Context, method, path string, body any, shared bool, into any) error {
	get := func() ([]byte, error) { return f.do(ctx, method, path, body) }
	var data []byte
	var err error
	if shared {
		key := method + " " + path
		if body != nil {
			b, _ := json.Marshal(body)
			key += " " + string(b)
		}
		data, err = f.shared(key, get)
	} else {
		data, err = get()
	}
	if err != nil {
		return err
	}
	if into == nil || len(bytes.TrimSpace(data)) == 0 {
		return nil
	}
	if json.Unmarshal(data, into) != nil {
		return &BoardsError{Kind: Failed, Message: "Azure DevOps's answer is not JSON"}
	}
	return nil
}

func (f *RealBoards) shared(key string, get func() ([]byte, error)) ([]byte, error) {
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

// projectPath is a project's part of an API path: org/project/_apis/.
func projectPath(project string) string {
	org, name, _ := strings.Cut(project, "/")
	return url.PathEscape(org) + "/" + url.PathEscape(name) + "/_apis/"
}

// api is path with its query and the API's version.
func api(path string, query url.Values, version string) string {
	if query == nil {
		query = url.Values{}
	}
	query.Set("api-version", version)
	return path + "?" + query.Encode()
}

// webURL is a work item's page: https://dev.azure.com/org/project/_workitems/edit/12.
func (f *RealBoards) webURL(project string, id int) string {
	org, name, _ := strings.Cut(project, "/")
	return f.Base + url.PathEscape(org) + "/" + url.PathEscape(name) + "/_workitems/edit/" + itoa(id)
}

func itoa(n int) string { return strconv.Itoa(n) }

// MARK: Azure DevOps's JSON

type identity struct {
	ID          string `json:"id"`
	DisplayName string `json:"displayName"`
	UniqueName  string `json:"uniqueName"`
	Descriptor  string `json:"descriptor"`
	IsContainer bool   `json:"isContainer"`
}

// person is an identity as who did something: its sign-in name, else its display name.
func (i identity) person() *Person {
	if i.ID == "" && i.DisplayName == "" && i.UniqueName == "" {
		return nil
	}
	name := i.DisplayName
	if i.UniqueName != "" && !strings.Contains(i.UniqueName, `\`) {
		name = i.UniqueName
	}
	return &Person{ID: i.ID, Name: name, Bot: isBot(i)}
}

// The fields a work item is read with.
const (
	fieldTitle     = "System.Title"
	fieldType      = "System.WorkItemType"
	fieldState     = "System.State"
	fieldArea      = "System.AreaPath"
	fieldTags      = "System.Tags"
	fieldAssigned  = "System.AssignedTo"
	fieldCreatedBy = "System.CreatedBy"
	fieldCreated   = "System.CreatedDate"
	fieldChanged   = "System.ChangedDate"
	fieldDesc      = "System.Description"
)

var itemFields = []string{fieldTitle, fieldType, fieldState, fieldArea, fieldTags, fieldAssigned, fieldCreatedBy, fieldCreated, fieldChanged}

type workItemJSON struct {
	ID     int                        `json:"id"`
	Fields map[string]json.RawMessage `json:"fields"`
}

func (w workItemJSON) text(field string) string {
	var s string
	_ = json.Unmarshal(w.Fields[field], &s)
	return s
}

func (w workItemJSON) who(field string) identity {
	var i identity
	_ = json.Unmarshal(w.Fields[field], &i)
	return i
}

// tags is a work item's tags: Azure DevOps keeps them as one string, "a; b".
func tags(text string) []string {
	out := []string{}
	for _, t := range strings.Split(text, ";") {
		if t = strings.TrimSpace(t); t != "" {
			out = append(out, t)
		}
	}
	return out
}

type changeJSON struct {
	OldValue json.RawMessage `json:"oldValue"`
	NewValue json.RawMessage `json:"newValue"`
}

type updateJSON struct {
	ID        int                   `json:"id"`
	RevisedBy identity              `json:"revisedBy"`
	Fields    map[string]changeJSON `json:"fields"`
}

func rawText(raw json.RawMessage) string {
	var s string
	_ = json.Unmarshal(raw, &s)
	return s
}

func rawWho(raw json.RawMessage) identity {
	var i identity
	_ = json.Unmarshal(raw, &i)
	return i
}

// at is when an update was made: its ChangedDate's new value. Its revisedDate is when the
// next one replaced it, not this one's time.
func (u updateJSON) at() string { return rawText(u.Fields[fieldChanged].NewValue) }

type commentJSON struct {
	ID          int      `json:"id"`
	Text        string   `json:"text"`
	CreatedBy   identity `json:"createdBy"`
	CreatedDate string   `json:"createdDate"`
	IsDeleted   bool     `json:"isDeleted"`
}

// MARK: Reads

// wiqlQuoted is text as a WIQL string, its quotes doubled.
func wiqlQuoted(text string) string { return "'" + strings.ReplaceAll(text, "'", "''") + "'" }

// query is the ids of the project's work items WIQL's where finds, newest changed first, at
// most top; truncated says there were more.
func (f *RealBoards) query(ctx context.Context, project, where string, top int, shared bool) ([]int, bool, error) {
	_, name, _ := strings.Cut(project, "/")
	wiql := "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = " + wiqlQuoted(name)
	if where != "" {
		wiql += " AND " + where
	}
	wiql += " ORDER BY [System.ChangedDate] DESC"
	var answer struct {
		WorkItems []struct {
			ID int `json:"id"`
		} `json:"workItems"`
	}
	q := url.Values{"$top": {itoa(top + 1)}, "timePrecision": {"true"}}
	if err := f.call(ctx, http.MethodPost, api(projectPath(project)+"wit/wiql", q, apiVersion), map[string]string{"query": wiql}, shared, &answer); err != nil {
		return nil, false, err
	}
	ids := make([]int, 0, len(answer.WorkItems))
	for _, w := range answer.WorkItems {
		ids = append(ids, w.ID)
	}
	if len(ids) > top {
		return ids[:top], true, nil
	}
	return ids, false, nil
}

// items is the work items of ids, in ids' order, with fields.
func (f *RealBoards) items(ctx context.Context, project string, ids []int, fields []string, shared bool) ([]workItemJSON, error) {
	if len(ids) == 0 {
		return nil, nil
	}
	var answer struct {
		Value []workItemJSON `json:"value"`
	}
	body := map[string]any{"ids": ids, "fields": fields, "errorPolicy": "omit"}
	if err := f.call(ctx, http.MethodPost, api(projectPath(project)+"wit/workitemsbatch", nil, apiVersion), body, shared, &answer); err != nil {
		return nil, err
	}
	out := answer.Value[:0]
	for _, w := range answer.Value {
		if w.ID != 0 { // an id it could not read is null with omit
			out = append(out, w)
		}
	}
	return out, nil
}

// typesOf is a project's work item types and their states, in their process's order, read
// again after statesFor.
func (f *RealBoards) typesOf(ctx context.Context, project string) (map[string][]State, error) {
	key := strings.ToLower(project)
	f.mu.Lock()
	if kept, ok := f.types[key]; ok && time.Since(kept.at) < statesFor {
		f.mu.Unlock()
		return kept.types, nil
	}
	f.mu.Unlock()
	var answer struct {
		Value []struct {
			Name   string  `json:"name"`
			States []State `json:"states"`
		} `json:"value"`
	}
	if err := f.call(ctx, http.MethodGet, api(projectPath(project)+"wit/workitemtypes", nil, apiVersion), nil, true, &answer); err != nil {
		return nil, err
	}
	types := map[string][]State{}
	for _, t := range answer.Value {
		types[t.Name] = t.States
	}
	f.mu.Lock()
	if f.types == nil {
		f.types = map[string]typesRead{}
	}
	f.types[key] = typesRead{at: time.Now(), types: types}
	f.mu.Unlock()
	return types, nil
}

// categories is each work item type's states' categories (Proposed, InProgress, Resolved,
// Completed, Removed).
func (f *RealBoards) categories(ctx context.Context, project string) (map[string]map[string]string, error) {
	types, err := f.typesOf(ctx, project)
	if err != nil {
		return nil, err
	}
	states := map[string]map[string]string{}
	for name, list := range types {
		states[name] = map[string]string{}
		for _, s := range list {
			states[name][s.Name] = s.Category
		}
	}
	return states, nil
}

// closedIn says whether state is a closed one of its type: of the Completed or Removed category.
func closedIn(states map[string]map[string]string, kind, state string) bool {
	c := states[kind][state]
	return c == "Completed" || c == "Removed"
}

// closedStates is every type's closed states' names, sorted.
func closedStates(states map[string]map[string]string) []string {
	seen := map[string]bool{}
	for kind, list := range states {
		for state := range list {
			if closedIn(states, kind, state) {
				seen[state] = true
			}
		}
	}
	out := make([]string, 0, len(seen))
	for s := range seen {
		out = append(out, s)
	}
	sort.Strings(out)
	return out
}

func (f *RealBoards) workItem(project string, w workItemJSON, states map[string]map[string]string) WorkItem {
	assignee := w.who(fieldAssigned)
	kind, state := w.text(fieldType), w.text(fieldState)
	return WorkItem{ID: w.ID, Title: w.text(fieldTitle), Type: kind, State: state, Closed: closedIn(states, kind, state),
		Area: w.text(fieldArea), Tags: tags(w.text(fieldTags)), Assignee: assignee.person().name(), AssigneeID: assignee.ID,
		URL: f.webURL(project, w.ID), CreatedAt: w.text(fieldCreated), Creator: w.who(fieldCreatedBy).person()}
}

// me is the token's owner's id.
func (f *RealBoards) myID(ctx context.Context, project string) (string, error) {
	f.mu.Lock()
	me := f.me
	f.mu.Unlock()
	if me != "" {
		return me, nil
	}
	org, _, _ := strings.Cut(project, "/")
	var c struct {
		AuthenticatedUser struct {
			ID string `json:"id"`
		} `json:"authenticatedUser"`
	}
	if err := f.call(ctx, http.MethodGet, url.PathEscape(org)+"/_apis/connectionData", nil, true, &c); err != nil {
		return "", err
	}
	if c.AuthenticatedUser.ID == "" {
		return "", &BoardsError{Kind: NotSignedIn, Message: "Azure DevOps did not say whose the token is"}
	}
	f.mu.Lock()
	f.me = c.AuthenticatedUser.ID
	f.mu.Unlock()
	return c.AuthenticatedUser.ID, nil
}

// updates is a work item's updates, oldest first; truncated says it stopped at maxPages.
func (f *RealBoards) updates(ctx context.Context, project string, id int) ([]updateJSON, bool, error) {
	var all []updateJSON
	for page := 0; page < maxPages; page++ {
		var list struct {
			Value []updateJSON `json:"value"`
		}
		q := url.Values{"$top": {itoa(perPage)}, "$skip": {itoa(page * perPage)}}
		if err := f.call(ctx, http.MethodGet, api(projectPath(project)+"wit/workItems/"+itoa(id)+"/updates", q, apiVersion), nil, true, &list); err != nil {
			return nil, false, err
		}
		all = append(all, list.Value...)
		if len(list.Value) < perPage {
			return all, false, nil
		}
	}
	return all, true, nil
}

// comments is a work item's newest comments, newest first, at most top.
func (f *RealBoards) comments(ctx context.Context, project string, id, top int, shared bool) ([]commentJSON, error) {
	var list struct {
		Comments []commentJSON `json:"comments"`
	}
	q := url.Values{"$top": {itoa(top)}, "order": {"desc"}}
	if err := f.call(ctx, http.MethodGet, api(projectPath(project)+"wit/workItems/"+itoa(id)+"/comments", q, commentsVersion), nil, shared, &list); err != nil {
		return nil, err
	}
	out := list.Comments[:0]
	for _, c := range list.Comments {
		if !c.IsDeleted {
			out = append(out, c)
		}
	}
	return out, nil
}

// Activity is what happened to the project's work items at or after since, of one kind: of
// the maxChecked work items created (opened) or changed (the rest) since, changed last first.
func (f *RealBoards) Activity(ctx context.Context, kind Kind, since string) ([]Activity, bool, error) {
	project, err := f.Project(ctx)
	if err != nil {
		return nil, false, err
	}
	field := fieldChanged
	if kind == Opened {
		field = fieldCreated
	}
	ids, truncated, err := f.query(ctx, project, "["+field+"] >= "+wiqlQuoted(since), maxChecked, true)
	if err != nil {
		return nil, false, err
	}
	list, err := f.items(ctx, project, ids, itemFields, true)
	if err != nil {
		return nil, false, err
	}
	states, err := f.categories(ctx, project)
	if err != nil {
		return nil, false, err
	}
	me := ""
	if kind == Assigned {
		if me, err = f.myID(ctx, project); err != nil {
			return nil, false, err
		}
	}
	var out []Activity
	for _, w := range list {
		item := f.workItem(project, w, states)
		switch kind {
		case Opened:
			out = append(out, Activity{ID: itoa(item.ID), At: item.CreatedAt, WorkItem: item, Kind: Opened, By: item.Creator})
		case Commented:
			comments, err := f.comments(ctx, project, item.ID, perPage, true)
			if err != nil {
				return nil, false, err
			}
			for _, c := range comments {
				if normalized(c.CreatedDate) < since {
					break // newest first: the rest are older
				}
				out = append(out, Activity{ID: itoa(item.ID) + "/" + itoa(c.ID), At: c.CreatedDate, WorkItem: item, Kind: Commented,
					By: c.CreatedBy.person(), CommentURL: item.URL, CommentBody: clip(c.Text, commentChars)})
			}
		default:
			updates, more, err := f.updates(ctx, project, item.ID)
			if err != nil {
				return nil, false, err
			}
			truncated = truncated || more
			for _, u := range updates {
				if at := u.at(); normalized(at) >= since {
					out = append(out, fromUpdate(kind, item, u, at, me, states)...)
				}
			}
		}
	}
	return out, truncated, nil
}

// fromUpdate is what one update did of kind: the tags it added, a move to a closed state, or
// an assignment to me.
func fromUpdate(kind Kind, item WorkItem, u updateJSON, at, me string, states map[string]map[string]string) []Activity {
	id := itoa(item.ID) + "/" + itoa(u.ID)
	by := u.RevisedBy.person()
	switch kind {
	case Labelled:
		change, ok := u.Fields[fieldTags]
		if !ok {
			return nil
		}
		old := tags(rawText(change.OldValue))
		var out []Activity
		for _, t := range tags(rawText(change.NewValue)) {
			if !containsFold(old, t) {
				out = append(out, Activity{ID: id + "/" + strings.ToLower(t), At: at, WorkItem: item, Kind: Labelled, By: by, Label: t})
			}
		}
		return out
	case Closed:
		change, ok := u.Fields[fieldState]
		if !ok {
			return nil
		}
		state := rawText(change.NewValue)
		if closedIn(states, item.Type, state) && !closedIn(states, item.Type, rawText(change.OldValue)) {
			return []Activity{{ID: id, At: at, WorkItem: item, Kind: Closed, By: by, State: state}}
		}
	case Assigned:
		change, ok := u.Fields[fieldAssigned]
		if ok && me != "" && rawWho(change.NewValue).ID == me && rawWho(change.OldValue).ID != me {
			return []Activity{{ID: id, At: at, WorkItem: item, Kind: Assigned, By: by}}
		}
	}
	return nil
}

// MARK: The tools' reads and writes

// Filter is what list_work_items asks for.
type Filter struct {
	State, Label, Type, Area string
	Mine                     bool
}

// List is the project's work items that filter names, changed last first, at most maxListed.
func (f *RealBoards) List(ctx context.Context, filter Filter) ([]WorkItem, bool, error) {
	project, err := f.Project(ctx)
	if err != nil {
		return nil, false, err
	}
	states, err := f.categories(ctx, project)
	if err != nil {
		return nil, false, err
	}
	var where []string
	if closed := closedStates(states); len(closed) > 0 && filter.State != "all" {
		quoted := make([]string, len(closed))
		for i, s := range closed {
			quoted[i] = wiqlQuoted(s)
		}
		op := "NOT IN"
		if filter.State == "closed" {
			op = "IN"
		}
		where = append(where, "[System.State] "+op+" ("+strings.Join(quoted, ", ")+")")
	}
	if filter.Label != "" {
		where = append(where, "[System.Tags] CONTAINS "+wiqlQuoted(filter.Label))
	}
	if filter.Type != "" {
		where = append(where, "[System.WorkItemType] = "+wiqlQuoted(filter.Type))
	}
	if filter.Area != "" {
		where = append(where, "[System.AreaPath] UNDER "+wiqlQuoted(filter.Area))
	}
	if filter.Mine {
		where = append(where, "[System.AssignedTo] = @Me")
	}
	ids, truncated, err := f.query(ctx, project, strings.Join(where, " AND "), maxListed, false)
	if err != nil {
		return nil, false, err
	}
	list, err := f.items(ctx, project, ids, itemFields, false)
	if err != nil {
		return nil, false, err
	}
	out := make([]WorkItem, len(list))
	for i, w := range list {
		out[i] = f.workItem(project, w, states)
	}
	return out, truncated, nil
}

// Comment is a work item's comment as get_work_item gives it.
type Comment struct {
	ID          int
	Author, At  string
	Body        string
	AuthorIsBot bool
}

// Get is one work item, its description and its newest comments.
func (f *RealBoards) Get(ctx context.Context, id int, comments int) (WorkItem, string, []Comment, error) {
	project, err := f.Project(ctx)
	if err != nil {
		return WorkItem{}, "", nil, err
	}
	states, err := f.categories(ctx, project)
	if err != nil {
		return WorkItem{}, "", nil, err
	}
	list, err := f.items(ctx, project, []int{id}, append(itemFields[:len(itemFields):len(itemFields)], fieldDesc), false)
	if err != nil {
		return WorkItem{}, "", nil, err
	}
	if len(list) == 0 {
		return WorkItem{}, "", nil, &BoardsError{Kind: NotFound, Message: fmt.Sprintf("no work item %d in %s", id, project)}
	}
	read, err := f.comments(ctx, project, id, comments, false)
	if err != nil {
		return WorkItem{}, "", nil, err
	}
	out := make([]Comment, len(read))
	for i, c := range read {
		p := c.CreatedBy.person()
		out[i] = Comment{ID: c.ID, Author: p.name(), At: c.CreatedDate, Body: c.Text, AuthorIsBot: p != nil && p.Bot}
	}
	return f.workItem(project, list[0], states), list[0].text(fieldDesc), out, nil
}

// AddComment comments on a work item, in Markdown, and is the comment's id.
func (f *RealBoards) AddComment(ctx context.Context, id int, body string) (int, string, error) {
	project, err := f.Project(ctx)
	if err != nil {
		return 0, "", err
	}
	var made commentJSON
	q := url.Values{"format": {"markdown"}}
	if err := f.call(ctx, http.MethodPost, api(projectPath(project)+"wit/workItems/"+itoa(id)+"/comments", q, commentsVersion),
		map[string]string{"text": body}, false, &made); err != nil {
		return 0, "", err
	}
	return made.ID, f.webURL(project, id), nil
}
