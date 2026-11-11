package jiramcp

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"slices"
	"sort"
	"strconv"
	"strings"

	htmltomarkdown "github.com/JohannesKaufmann/html-to-markdown/v2"

	"github.com/alexec/agents/Go/internal/richtext"
)

// The daemon's forge reads and writes (#3260, after Linear's in #3209): the issues of many
// projects in one search, the last updated first, one issue with its description and a page of
// its comments, and a person's own clicks on its Work page (a comment, labels, a status). The
// daemon puts them in the one model the Work pages draw for every forge (wire.ForgeItem). Jira
// has issues only: no pull requests. A status is a step of the issue's workflow, so a page
// moves an issue by the transitions the workflow allows, not by a close and a reopen.

// SearchFilter is what a list lists: issues in state open, closed or all (open when ""),
// narrowed by a label, an assignee's display name, words in the summary, description or
// comments, and a feature: the name of a feature:<name> label (#3267). Filter is a board's
// filter, by its id (#3282): the board's issues, in place of the projects'.
type SearchFilter struct {
	State                                   string
	Label, Assignee, Query, Feature, Filter string
}

// Item is an issue as the forge reads list it, by its key (PROJ-12).
type Item struct {
	Key, Project string
	// State is open, or closed for a status in the Done category; Status is the status's own
	// name, as In Progress.
	State, Status, Title, URL, Author, UpdatedAt string
	// CreatedAt is when it was made; ClosedAt is its resolution date on a done issue, "" while
	// it is open or when a done issue has no resolution, as a team-managed project can leave it
	// (#4373).
	CreatedAt, ClosedAt string
	// AuthorAvatar is the author's picture, its 48x48; "" for none (#4363).
	AuthorAvatar string
	// StateReason is why a closed issue closed, from its resolution: completed, not_planned or
	// duplicate; "" while it is open (#4365).
	StateReason string
	// Milestone is the first fix version: the closest Jira has to a release (#3260).
	Milestone string
	Labels    []string
	Assignees []string
	Comments  int
	// Parent is the issue it is a sub-task or a child of, by key; SubTotal and SubDone are its
	// sub-tasks and the done ones.
	Parent            string
	SubTotal, SubDone int
}

// SearchPage is a page of a list, the last updated first. Cursors[i] goes on after Items[i],
// so a caller that keeps only some of the page goes on from the last it kept; Next is the
// cursor after the page, "" at the end. Total is how many issues the whole list has, on its
// first page only (#4396); nil where Jira did not say.
type SearchPage struct {
	Items   []Item
	Cursors []string
	Next    string
	Total   *int
}

// Comment is a comment on an issue, as Markdown.
type Comment struct {
	Author, Avatar, Body, At, URL string
	Bot                           bool
}

// Transition is a move the issue's workflow allows now: its id, its name (as Start Progress)
// and the status category it goes to (new, indeterminate or done).
type Transition struct {
	ID, Name, Category string
}

// ItemDetail is an issue with its description (Markdown), a page of its comments (Thread),
// oldest first in the page, and the transitions it has. Before is the cursor of the page
// before it, "" at the first comment.
type ItemDetail struct {
	Item
	Body        string
	Thread      []Comment
	Before      string
	Transitions []Transition
}

// forgeComments is a page of an issue's comments.
const forgeComments = 50

// forgeFields are what a forge read asks for.
var forgeFields = []string{"summary", "status", "labels", "assignee", "creator", "reporter", "updated", "project",
	"fixVersions", "comment", "parent", "subtasks", "resolution", "created", "resolutiondate"}

type restIssueRef struct {
	Key    string `json:"key"`
	Fields struct {
		Status *struct {
			Category *struct {
				Key string `json:"key"`
			} `json:"statusCategory"`
		} `json:"status"`
	} `json:"fields"`
}

func (r restIssueRef) done() bool {
	s := r.Fields.Status
	return s != nil && s.Category != nil && s.Category.Key == "done"
}

// stateReasonOf is a resolution's reason (#4365). Jira's resolutions are names a site can add
// to, with no category: Duplicate is duplicate; Done, Fixed and the like are completed; any
// other (Won't Do, Won't Fix, Cannot Reproduce, Incomplete, Declined) is not_planned. A done
// issue with no resolution, as a team-managed project leaves it, is completed.
func stateReasonOf(resolution string) string {
	switch strings.ToLower(strings.TrimSpace(resolution)) {
	case "duplicate":
		return "duplicate"
	case "", "done", "fixed", "resolved", "complete", "completed":
		return "completed"
	}
	return "not_planned"
}

func (r restIssue) item(site string) Item {
	f := r.Fields
	base := r.issue(site)
	i := Item{Key: r.Key, Project: base.Project, State: "open", Status: base.Status, Title: f.Summary, URL: base.URL,
		UpdatedAt: normalized(f.Updated), CreatedAt: normalized(f.Created), Labels: base.Labels, Assignees: []string{}}
	if base.StatusCategory == "done" {
		i.State, i.ClosedAt = "closed", normalized(f.ResolutionDate)
		if f.Resolution != nil {
			i.StateReason = stateReasonOf(f.Resolution.Name)
		} else {
			i.StateReason = "completed"
		}
	}
	if base.Creator != nil {
		i.Author, i.AuthorAvatar = base.Creator.Name, base.Creator.Avatar
	}
	if base.Assignee != "" {
		i.Assignees = append(i.Assignees, base.Assignee)
	}
	if len(f.FixVersions) > 0 {
		i.Milestone = f.FixVersions[0].Name
	}
	if f.Comment != nil {
		i.Comments = max(f.Comment.Total, len(f.Comment.Comments))
	}
	if f.Parent != nil {
		i.Parent = f.Parent.Key
	}
	for _, s := range f.Subtasks {
		i.SubTotal++
		if s.done() {
			i.SubDone++
		}
	}
	return i
}

// SearchJQL is the JQL for projects (by key) and f, the last updated first.
func SearchJQL(projects []string, f SearchFilter) string {
	keys := make([]string, len(projects))
	for n, p := range projects {
		keys[n] = quoted(p)
	}
	clauses := []string{"project in (" + strings.Join(keys, ", ") + ")"}
	if f.Filter != "" {
		clauses[0] = "filter = " + f.Filter
	}
	switch f.State {
	case "", "open":
		clauses = append(clauses, "statusCategory != "+categoryIDs["done"])
	case "closed":
		clauses = append(clauses, "statusCategory = "+categoryIDs["done"])
	}
	for _, label := range []string{f.Label, featureLabel(f.Feature)} {
		if label != "" {
			clauses = append(clauses, "labels = "+quoted(label))
		}
	}
	if f.Assignee != "" {
		clauses = append(clauses, "assignee = "+quoted(f.Assignee))
	}
	if q := strings.TrimSpace(f.Query); q != "" {
		clauses = append(clauses, "text ~ "+quoted(q))
	}
	return strings.Join(clauses, " AND ") + " ORDER BY updated DESC"
}

func featureLabel(name string) string {
	if name = strings.TrimSpace(name); name == "" {
		return ""
	}
	return "feature:" + name
}

// A search cursor is "<page>~<skip>": the page to ask for (Jira Cloud's page token, or Data
// Center's start, a number) and how many of its issues were read already. Jira Cloud gives a
// token per page, not per issue, so a cursor after an issue in the middle of a page names its
// page and how far into it.
func searchCursor(page string, skip int) string { return page + "~" + strconv.Itoa(skip) }

func cursorParts(cursor string) (string, int, error) {
	if cursor == "" {
		return "", 0, nil
	}
	// The last ~: a page token may hold one.
	at := strings.LastIndex(cursor, "~")
	if at < 0 {
		return "", 0, &JiraError{Kind: Failed, Message: "Jira: the cursor is not one a list gave"}
	}
	page := cursor[:at]
	n, err := strconv.Atoi(cursor[at+1:])
	if err != nil || n < 0 {
		return "", 0, &JiraError{Kind: Failed, Message: "Jira: the cursor is not one a list gave"}
	}
	return page, n, nil
}

// searchPage is one page of what jql finds, at most max, from page (Jira Cloud's page token,
// or Data Center's start), and the page after it ("" at the end).
func (j *RealJira) searchPage(ctx context.Context, jql string, read []string, max int, page string) ([]restIssue, string, error) {
	list, next, _, err := j.searchCounted(ctx, jql, read, max, page)
	return list, next, err
}

// searchCounted is searchPage and how many issues jql finds in all: Data Center says it with
// the page; Jira Cloud's /search/jql does not, so it is -1 there.
func (j *RealJira) searchCounted(ctx context.Context, jql string, read []string, max int, page string) ([]restIssue, string, int, error) {
	var out struct {
		Issues        []restIssue `json:"issues"`
		StartAt       int         `json:"startAt"`
		Total         int         `json:"total"`
		NextPageToken string      `json:"nextPageToken"`
		IsLast        *bool       `json:"isLast"`
	}
	body := map[string]any{"jql": jql, "fields": read, "maxResults": max}
	if j.Auth().Cloud {
		if page != "" {
			body["nextPageToken"] = page
		}
		if err := j.call(ctx, http.MethodPost, "/search/jql", body, &out); err != nil {
			return nil, "", 0, err
		}
		if out.NextPageToken == "" || out.IsLast != nil && *out.IsLast {
			return out.Issues, "", -1, nil
		}
		return out.Issues, out.NextPageToken, -1, nil
	}
	start := 0
	if page != "" {
		n, err := strconv.Atoi(page)
		if err != nil || n < 0 {
			return nil, "", 0, &JiraError{Kind: Failed, Message: "Jira: the cursor is not one a list gave"}
		}
		start = n
	}
	body["startAt"] = start
	if err := j.call(ctx, http.MethodPost, "/search", body, &out); err != nil {
		return nil, "", 0, err
	}
	if next := start + len(out.Issues); len(out.Issues) > 0 && next < out.Total {
		return out.Issues, strconv.Itoa(next), out.Total, nil
	}
	return out.Issues, "", out.Total, nil
}

// approximateCount is how many issues jql finds on Jira Cloud, which Jira says is approximate
// (#4396); -1 where it does not say.
func (j *RealJira) approximateCount(ctx context.Context, jql string) int {
	var out struct {
		Count *int `json:"count"`
	}
	if err := j.call(ctx, http.MethodPost, "/search/approximate-count", map[string]any{"jql": jql}, &out); err != nil || out.Count == nil {
		return -1
	}
	return *out.Count
}

// Search is one page of the issues of projects, at most first (1 to 100), after the cursor
// after ("" for the first page), in one search.
func (j *RealJira) Search(ctx context.Context, projects []string, f SearchFilter, after string, first int) (SearchPage, error) {
	page := SearchPage{Items: []Item{}, Cursors: []string{}}
	if len(projects) == 0 && f.Filter == "" {
		return page, nil
	}
	from, skip, err := cursorParts(after)
	if err != nil {
		return SearchPage{}, err
	}
	first = max(1, min(first, perPage))
	// The issues skipped are read again, as Jira Cloud cannot start in a page's middle.
	jql := SearchJQL(projects, f)
	list, next, total, err := j.searchCounted(ctx, jql, forgeFields, min(perPage, first+skip), from)
	if err != nil {
		return SearchPage{}, err
	}
	// Only the first page counts; a count that fails leaves the list without one.
	if after == "" {
		if total < 0 {
			total = j.approximateCount(ctx, jql)
		}
		if total >= 0 {
			page.Total = &total
		}
	}
	site := j.Auth().Site
	for n := skip; n < len(list) && len(page.Items) < first; n++ {
		page.Items = append(page.Items, list[n].item(site))
		page.Cursors = append(page.Cursors, searchCursor(from, n+1))
	}
	switch {
	case skip+len(page.Items) < len(list):
		page.Next = page.Cursors[len(page.Cursors)-1]
	case next != "":
		page.Next = searchCursor(next, 0)
	}
	return page, nil
}

// markdown is HTML that Jira rendered, made safe, as Markdown; text, when Jira rendered none.
func markdown(rendered, text string) string {
	if strings.TrimSpace(rendered) == "" {
		return text
	}
	md, err := htmltomarkdown.ConvertString(richtext.HTML(rendered))
	if err != nil {
		return text
	}
	return strings.TrimSpace(md)
}

// ItemPage is the issue key names, with its description, the page of its comments before the
// cursor before (the newest page for ""), and its transitions.
func (j *RealJira) ItemPage(ctx context.Context, key, before string) (ItemDetail, error) {
	var out struct {
		restIssue
		Rendered struct {
			Description string `json:"description"`
			Comment     *struct {
				Comments []struct {
					ID   string `json:"id"`
					Body string `json:"body"`
				} `json:"comments"`
			} `json:"comment"`
		} `json:"renderedFields"`
	}
	read := append(slices.Clone(forgeFields), "description")
	path := "/issue/" + url.PathEscape(key) + "?fields=" + url.QueryEscape(strings.Join(read, ",")) + "&expand=renderedFields"
	var raw json.RawMessage
	if err := j.call(ctx, http.MethodGet, path, nil, &raw); err != nil {
		return ItemDetail{}, err
	}
	// The description as text too, for when Jira renders none.
	var described struct {
		Fields struct {
			Description string `json:"description"`
		} `json:"fields"`
	}
	if json.Unmarshal(raw, &out) != nil || json.Unmarshal(raw, &described) != nil {
		return ItemDetail{}, &JiraError{Kind: Failed, Message: "Jira: the issue's answer is not one it gives"}
	}
	site := j.Auth().Site
	d := ItemDetail{Item: out.item(site), Body: markdown(out.Rendered.Description, described.Fields.Description), Thread: []Comment{}}
	var all []restComment
	if out.Fields.Comment != nil {
		all = out.Fields.Comment.Comments
	}
	rendered := map[string]string{}
	if out.Rendered.Comment != nil {
		for _, c := range out.Rendered.Comment.Comments {
			rendered[c.ID] = c.Body
		}
	}
	end := len(all)
	if before != "" {
		n, err := strconv.Atoi(before)
		if err != nil || n < 0 || n > len(all) {
			return ItemDetail{}, &JiraError{Kind: Failed, Message: "Jira: the cursor is not one a page gave"}
		}
		end = n
	}
	start := max(0, end-forgeComments)
	for _, c := range all[start:end] {
		author := c.Author.person()
		d.Thread = append(d.Thread, Comment{Author: author.name(), Avatar: author.avatar(), Body: markdown(rendered[c.ID], c.Body), At: normalized(c.Created),
			URL: d.URL + "?focusedCommentId=" + url.QueryEscape(c.ID), Bot: author != nil && author.App})
	}
	if start > 0 {
		d.Before = strconv.Itoa(start)
	}
	transitions, err := j.Transitions(ctx, key)
	if err != nil {
		return ItemDetail{}, err
	}
	d.Transitions = transitions
	return d, nil
}

// Transitions are the moves the issue's workflow allows now, in the workflow's order.
func (j *RealJira) Transitions(ctx context.Context, key string) ([]Transition, error) {
	var out struct {
		Transitions []struct {
			ID   string `json:"id"`
			Name string `json:"name"`
			To   *struct {
				Category *struct {
					Key string `json:"key"`
				} `json:"statusCategory"`
			} `json:"to"`
		} `json:"transitions"`
	}
	if err := j.call(ctx, http.MethodGet, "/issue/"+url.PathEscape(key)+"/transitions", nil, &out); err != nil {
		return nil, err
	}
	list := []Transition{}
	for _, t := range out.Transitions {
		tr := Transition{ID: t.ID, Name: t.Name}
		if t.To != nil && t.To.Category != nil {
			tr.Category = t.To.Category.Key
		}
		list = append(list, tr)
	}
	return list, nil
}

// MARK: Writes

// write asks Jira method path with body, never from or into the shared answers, and reads the
// answer, when there is one, into out. Every shared answer is forgotten, so a read after it
// shows the write.
func (j *RealJira) write(ctx context.Context, method, path string, body, out any) error {
	auth := j.Auth()
	if !auth.signedIn() {
		return &JiraError{Kind: NotSignedIn, Message: notSignedIn}
	}
	payload, err := json.Marshal(body)
	if err != nil {
		return &JiraError{Kind: Failed, Message: "Jira: " + err.Error()}
	}
	data, err := j.send(ctx, auth, method, path, payload)
	if err != nil {
		return err
	}
	j.mu.Lock()
	clear(j.recent)
	j.mu.Unlock()
	if out == nil || len(strings.TrimSpace(string(data))) == 0 {
		return nil
	}
	if err := json.Unmarshal(data, out); err != nil {
		return &JiraError{Kind: Failed, Message: "Jira: " + err.Error()}
	}
	return nil
}

// Comment adds a comment to an issue, and is its URL. Jira's version 2 takes its text as wiki
// markup, which Markdown's plain paragraphs, lists and links read well in.
func (j *RealJira) Comment(ctx context.Context, key, body string) (string, error) {
	var out struct {
		ID string `json:"id"`
	}
	if err := j.write(ctx, http.MethodPost, "/issue/"+url.PathEscape(key)+"/comment", map[string]any{"body": body}, &out); err != nil {
		return "", err
	}
	if out.ID == "" {
		return "", nil
	}
	return j.Auth().Site + "/browse/" + key + "?focusedCommentId=" + url.QueryEscape(out.ID), nil
}

// SetLabels adds labels to an issue and takes others off, in one edit.
func (j *RealJira) SetLabels(ctx context.Context, key string, add, remove []string) error {
	var ops []map[string]string
	for _, l := range add {
		ops = append(ops, map[string]string{"add": l})
	}
	for _, l := range remove {
		ops = append(ops, map[string]string{"remove": l})
	}
	return j.write(ctx, http.MethodPut, "/issue/"+url.PathEscape(key), map[string]any{"update": map[string]any{"labels": ops}}, nil)
}

// Labels are the labels an issue can have, by name: Jira Cloud's site labels, or on Data
// Center, which has no list, the labels of the project's last updated issues; with the issue's
// own. Jira's labels have no colour.
func (j *RealJira) Labels(ctx context.Context, key string) ([]string, map[string]string, error) {
	seen := map[string]bool{}
	var out struct {
		Values []string `json:"values"`
	}
	if err := j.call(ctx, http.MethodGet, "/label?maxResults=1000", nil, &out); err == nil {
		for _, l := range out.Values {
			seen[l] = true
		}
	} else {
		project, _, _ := strings.Cut(key, "-")
		list, _, err := j.searchPage(ctx, "project = "+quoted(project)+" AND labels is not EMPTY ORDER BY updated DESC", []string{"labels"}, perPage, "")
		if err != nil {
			return nil, nil, err
		}
		for _, r := range list {
			for _, l := range r.Fields.Labels {
				seen[l] = true
			}
		}
	}
	var issue restIssue
	if err := j.call(ctx, http.MethodGet, "/issue/"+url.PathEscape(key)+"?fields=labels", nil, &issue); err != nil {
		return nil, nil, err
	}
	for _, l := range issue.Fields.Labels {
		seen[l] = true
	}
	names := make([]string, 0, len(seen))
	for l := range seen {
		names = append(names, l)
	}
	sort.Strings(names)
	return names, map[string]string{}, nil
}

// Transition moves an issue by one of its workflow's transitions, by id.
func (j *RealJira) Transition(ctx context.Context, key, id string) error {
	return j.write(ctx, http.MethodPost, "/issue/"+url.PathEscape(key)+"/transitions", map[string]any{"transition": map[string]any{"id": id}}, nil)
}

// SetState closes an issue (to done) or opens it again (to To Do, else In Progress) by the
// first transition its workflow allows to that status category: the Work pages' Close and
// Reopen, for a client with no status menu.
func (j *RealJira) SetState(ctx context.Context, key string, closed bool) error {
	list, err := j.Transitions(ctx, key)
	if err != nil {
		return err
	}
	want := []string{"new", "indeterminate"}
	if closed {
		want = []string{"done"}
	}
	for _, category := range want {
		for _, t := range list {
			if t.Category == category {
				return j.Transition(ctx, key, t.ID)
			}
		}
	}
	what := "reopen"
	if closed {
		what = "close"
	}
	return &JiraError{Kind: Failed, Message: fmt.Sprintf("Jira: the workflow of %s has no transition to %s it", key, what)}
}

// MARK: Plans

// Ref is an issue another names: its key, and whether it is open (not in the Done category).
type Ref struct {
	Key  string
	Open bool
}

// PlanChild is a child of an epic or a parent, and the issues it is blocked by.
type PlanChild struct {
	Item
	BlockedBy []Ref
}

// Plan is an issue (an epic, or a parent of sub-tasks) and its children, the oldest first: the
// issues whose parent it is (Jira Cloud's epics and sub-tasks both say parent).
type Plan struct {
	Epic     Item
	Children []PlanChild
}

// restLinks is an issue's links, for its blockers: a link of the type Blocks whose inward issue
// blocks it.
type restLinks struct {
	Fields struct {
		IssueLinks []struct {
			Type struct {
				Name string `json:"name"`
			} `json:"type"`
			InwardIssue *restIssueRef `json:"inwardIssue"`
		} `json:"issuelinks"`
	} `json:"fields"`
}

// Plan reads key and its children (at most perPage), with each child's blockers.
func (j *RealJira) Plan(ctx context.Context, key string) (Plan, error) {
	epic, err := j.ItemPage(ctx, key, "")
	if err != nil {
		return Plan{}, err
	}
	var out struct {
		Issues []json.RawMessage `json:"issues"`
	}
	body := map[string]any{"jql": "parent = " + quoted(key) + " ORDER BY created ASC", "fields": append(slices.Clone(forgeFields), "issuelinks"), "maxResults": perPage}
	path := "/search"
	if j.Auth().Cloud {
		path = "/search/jql"
	}
	if err := j.call(ctx, http.MethodPost, path, body, &out); err != nil {
		return Plan{}, err
	}
	p := Plan{Epic: epic.Item, Children: []PlanChild{}}
	site := j.Auth().Site
	for _, raw := range out.Issues {
		var r restIssue
		var links restLinks
		if json.Unmarshal(raw, &r) != nil || json.Unmarshal(raw, &links) != nil {
			continue
		}
		p.Children = append(p.Children, PlanChild{Item: r.item(site), BlockedBy: links.blockers()})
	}
	return p, nil
}

func (l restLinks) blockers() []Ref {
	var out []Ref
	for _, link := range l.Fields.IssueLinks {
		if link.Type.Name == "Blocks" && link.InwardIssue != nil {
			out = append(out, Ref{Key: link.InwardIssue.Key, Open: !link.InwardIssue.done()})
		}
	}
	return out
}

// BlockersMost bounds the issues one Blockers read asks about: a page of a search.
const BlockersMost = perPage

// Blockers are the issues that block each of keys (at most BlockersMost), from their Blocks
// links, in one search by key (#4242): a standing epic's children come from a list, which does
// not read links. A key Jira does not have has none.
func (j *RealJira) Blockers(ctx context.Context, keys []string) (map[string][]Ref, error) {
	out := map[string][]Ref{}
	keys = keys[:min(len(keys), BlockersMost)]
	if len(keys) == 0 {
		return out, nil
	}
	quotedKeys := make([]string, len(keys))
	for n, k := range keys {
		quotedKeys[n] = quoted(k)
	}
	var answer struct {
		Issues []struct {
			Key string `json:"key"`
			restLinks
		} `json:"issues"`
	}
	body := map[string]any{"jql": "key in (" + strings.Join(quotedKeys, ", ") + ")", "fields": []string{"issuelinks"}, "maxResults": len(keys)}
	path := "/search"
	if j.Auth().Cloud {
		path = "/search/jql"
	}
	if err := j.call(ctx, http.MethodPost, path, body, &answer); err != nil {
		return nil, err
	}
	for _, i := range answer.Issues {
		if i.Key != "" {
			out[strings.ToUpper(i.Key)] = i.blockers()
		}
	}
	return out, nil
}

// BoardFilter is the id of the filter a board shows (#3282), from Jira Software's
// /rest/agile/1.0/board/<id>/configuration.
func (j *RealJira) BoardFilter(ctx context.Context, board string) (string, error) {
	if board == "" || strings.Trim(board, "0123456789") != "" {
		return "", &JiraError{Kind: Failed, Message: "Jira: a board's id is a number"}
	}
	var config struct {
		Filter struct {
			ID string `json:"id"`
		} `json:"filter"`
	}
	if err := j.call(ctx, http.MethodGet, agilePath+"/board/"+board+"/configuration", nil, &config); err != nil {
		return "", err
	}
	if config.Filter.ID == "" || strings.Trim(config.Filter.ID, "0123456789") != "" {
		return "", &JiraError{Kind: Failed, Message: "Jira: board " + board + " has no filter"}
	}
	return config.Filter.ID, nil
}
