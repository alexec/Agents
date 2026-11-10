package azureboardsmcp

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

// The daemon's forge reads and writes (#3815, after Jira's in #3260): the work items of many
// projects, the last changed first, one work item with its description and a page of its
// comments, its plan (its children, each blocked by its predecessors), and a person's own
// clicks on its Work page: a comment, tags, a state, and a new child. The daemon puts them in
// the one model the Work pages draw for every forge (wire.ForgeItem). A project is named
// organization/project, in lower case: Azure DevOps's names do not care about case. Unlike the
// events and the tools, these name the project in each call, so one RealBoards reads every
// project the folders name.

// SearchFilter is what a list lists: work items in state open, closed or all (open when ""),
// narrowed by a tag, an assignee (a display or sign-in name), words in the title or
// description, and a feature: the name of a feature:<name> tag (#3267).
type SearchFilter struct {
	State                           string
	Label, Assignee, Query, Feature string
	// Areas narrows the list to a board's team (#3816): the work items in its area paths.
	Areas []Area
}

// Item is a work item as the forge reads list it.
type Item struct {
	ID int
	// Project is organization/project, in lower case.
	Project string
	// State is open, or closed for a state of the Completed or Removed category; Status is
	// the state's own name, as Active; Type is its type, as User Story.
	State, Status, Type, Title, URL, Author, UpdatedAt string
	// AuthorAvatar is the author's picture, on the organization; "" for none (#4363).
	AuthorAvatar string
	Labels       []string
	Assignees    []string
	Comments     int
	// Parent is the work item it is a child of, 0 for none; SubTotal and SubDone are its
	// children and the closed ones, where the read says them (a plan's).
	Parent            int
	SubTotal, SubDone int
}

// SearchPage is a page of a list, the last changed first. Cursors[i] goes on after Items[i],
// so a caller that keeps only some of the page goes on from the last it kept; Next is the
// cursor after the page, "" at the end.
type SearchPage struct {
	Items   []Item
	Cursors []string
	Next    string
}

// ForgeComment is a comment on a work item, as Markdown.
type ForgeComment struct {
	Author, Avatar, Body, At, URL string
	Bot                           bool
}

// Transition is a state the work item can move to: its name (which is its id too), and the
// category it is in, as the Work pages say Jira's: new, indeterminate or done.
type Transition struct {
	ID, Name, Category string
}

// ItemDetail is a work item with its description (Markdown), a page of its comments (Thread),
// oldest first in the page, and the states of its type it can move to. Before is the cursor of
// the page before it, "" at the first comment.
type ItemDetail struct {
	Item
	Body        string
	Thread      []ForgeComment
	Before      string
	Transitions []Transition
}

const (
	// forgeComments is a page of a work item's comments.
	forgeComments = 50
	// forgeListMost bounds a page of a list.
	forgeListMost = 100
	// wiqlMost is the most work items WIQL finds in one query.
	wiqlMost = 20000
	// tagsVersion is the tags API's, a preview in 7.1.
	tagsVersion = "7.1-preview.1"
)

const (
	fieldProject  = "System.TeamProject"
	fieldComments = "System.CommentCount"
	fieldParent   = "System.Parent"
	// The links a plan reads and writes: a child's parent, and a work item's predecessor
	// (the one it waits for, as Jira's "is blocked by").
	relParent      = "System.LinkTypes.Hierarchy-Reverse"
	relChild       = "System.LinkTypes.Hierarchy-Forward"
	relPredecessor = "System.LinkTypes.Dependency-Reverse"
)

// forgeFields are what a forge read asks for.
var forgeFields = append(slices.Clone(itemFields), fieldProject, fieldComments, fieldParent)

// patch is a JSON Patch, which Azure DevOps changes a work item by.
type patch []map[string]any

// orgOf is a project's organization.
func orgOf(project string) string {
	org, _, _ := strings.Cut(project, "/")
	return org
}

// orgPath is an organization's part of an API path: org/_apis/.
func orgPath(org string) string { return url.PathEscape(org) + "/_apis/" }

// workItemURL is a work item's API address, as a link names it.
func (f *RealBoards) workItemURL(org string, id int) string {
	return f.Base + orgPath(org) + "wit/workItems/" + itoa(id)
}

func (w workItemJSON) number(field string) int {
	var n int
	_ = json.Unmarshal(w.Fields[field], &n)
	return n
}

// project is the work item's organization/project, in lower case.
func (w workItemJSON) project(org string) string {
	return strings.ToLower(org + "/" + w.text(fieldProject))
}

// category is a state category as the Work pages say Jira's.
func category(c string) string {
	switch c {
	case "Proposed":
		return "new"
	case "Completed", "Removed":
		return "done"
	}
	return "indeterminate"
}

func (f *RealBoards) forgeItem(org string, w workItemJSON, states map[string]map[string]string) Item {
	project := w.project(org)
	kind, state := w.text(fieldType), w.text(fieldState)
	author := w.who(fieldCreatedBy).person()
	i := Item{ID: w.ID, Project: project, State: "open", Status: state, Type: kind, Title: w.text(fieldTitle),
		URL: f.webURL(project, w.ID), Author: author.name(), AuthorAvatar: author.avatar(), UpdatedAt: normalized(w.text(fieldChanged)),
		Labels: tags(w.text(fieldTags)), Assignees: []string{}, Comments: w.number(fieldComments), Parent: w.number(fieldParent)}
	if closedIn(states, kind, state) {
		i.State = "closed"
	}
	if a := w.who(fieldAssigned).person(); a != nil {
		i.Assignees = append(i.Assignees, a.name())
	}
	return i
}

// orgStates is the states' categories of every project of org in projects, by type: a type's
// state is closed when it is closed in any of them.
func (f *RealBoards) orgStates(ctx context.Context, projects []string) (map[string]map[string]string, error) {
	out := map[string]map[string]string{}
	for _, p := range projects {
		states, err := f.categories(ctx, p)
		if err != nil {
			return nil, err
		}
		for kind, list := range states {
			if out[kind] == nil {
				out[kind] = map[string]string{}
			}
			for state, c := range list {
				if old := out[kind][state]; old == "" || closedIn(states, kind, state) {
					out[kind][state] = c
				}
			}
		}
	}
	return out, nil
}

// SearchWhere is the WIQL condition for projects (all of one organization) and f, with the
// names of the closed states.
func SearchWhere(projects []string, f SearchFilter, closed []string) string {
	names := make([]string, len(projects))
	for n, p := range projects {
		_, name, _ := strings.Cut(p, "/")
		names[n] = wiqlQuoted(name)
	}
	where := []string{"[System.TeamProject] IN (" + strings.Join(names, ", ") + ")"}
	if len(closed) > 0 && f.State != "all" {
		quoted := make([]string, len(closed))
		for i, s := range closed {
			quoted[i] = wiqlQuoted(s)
		}
		op := "NOT IN"
		if f.State == "closed" {
			op = "IN"
		}
		where = append(where, "[System.State] "+op+" ("+strings.Join(quoted, ", ")+")")
	}
	// The label epic is an Epic work item too (#3939): Azure Boards says an epic by its type.
	if strings.EqualFold(strings.TrimSpace(f.Label), epicLevel) {
		where = append(where, "([System.WorkItemType] = "+wiqlQuoted(EpicType)+" OR [System.Tags] CONTAINS "+wiqlQuoted(f.Label)+")")
	} else if f.Label != "" {
		where = append(where, "[System.Tags] CONTAINS "+wiqlQuoted(f.Label))
	}
	if tag := featureTag(f.Feature); tag != "" {
		where = append(where, "[System.Tags] CONTAINS "+wiqlQuoted(tag))
	}
	if f.Assignee != "" {
		where = append(where, "[System.AssignedTo] = "+wiqlQuoted(f.Assignee))
	}
	if len(f.Areas) > 0 {
		where = append(where, areasWhere(f.Areas))
	}
	if q := strings.TrimSpace(f.Query); q != "" {
		where = append(where, "([System.Title] CONTAINS "+wiqlQuoted(q)+" OR [System.Description] CONTAINS WORDS "+wiqlQuoted(q)+")")
	}
	return strings.Join(where, " AND ")
}

// EpicType is the work item type that is an epic in every process (Agile, Scrum, CMMI and Basic),
// and epicLevel the label that says the level on every forge.
const (
	EpicType  = "Epic"
	epicLevel = "epic"
)

func featureTag(name string) string {
	if name = strings.TrimSpace(name); name == "" {
		return ""
	}
	return "feature:" + name
}

// orgQuery is the ids WIQL's where finds in an organization, the last changed first, at most top.
func (f *RealBoards) orgQuery(ctx context.Context, org, where string, top int) ([]int, error) {
	var answer struct {
		WorkItems []struct {
			ID int `json:"id"`
		} `json:"workItems"`
	}
	wiql := "SELECT [System.Id] FROM WorkItems WHERE " + where + " ORDER BY [System.ChangedDate] DESC, [System.Id] DESC"
	q := url.Values{"$top": {itoa(min(top, wiqlMost))}, "timePrecision": {"true"}}
	if err := f.call(ctx, http.MethodPost, api(orgPath(org)+"wit/wiql", q, apiVersion), map[string]string{"query": wiql}, false, &answer); err != nil {
		return nil, err
	}
	ids := make([]int, 0, len(answer.WorkItems))
	for _, w := range answer.WorkItems {
		ids = append(ids, w.ID)
	}
	return ids, nil
}

// orgItems is the work items of ids in an organization, in ids' order: with fields, or with
// every field and their links when relations.
func (f *RealBoards) orgItems(ctx context.Context, org string, ids []int, fields []string, relations bool) ([]withRelations, error) {
	var out []withRelations
	for len(ids) > 0 {
		chunk := ids[:min(len(ids), 200)] // the most one batch reads
		ids = ids[len(chunk):]
		var answer struct {
			Value []withRelations `json:"value"`
		}
		body := map[string]any{"ids": chunk, "errorPolicy": "omit"}
		if relations {
			// Azure DevOps reads every field with the links: it takes no fields with them.
			body["$expand"] = "relations"
		} else {
			body["fields"] = fields
		}
		if err := f.call(ctx, http.MethodPost, api(orgPath(org)+"wit/workitemsbatch", nil, apiVersion), body, false, &answer); err != nil {
			return nil, err
		}
		for _, w := range answer.Value {
			if w.ID != 0 { // an id it could not read is null with omit
				out = append(out, w)
			}
		}
	}
	return out, nil
}

// A search cursor is url-encoded offsets, one per organization: acme=50&contoso=12, how many
// of each organization's work items were read already.
func cursorOffsets(cursor string) (map[string]int, error) {
	out := map[string]int{}
	if cursor == "" {
		return out, nil
	}
	v, err := url.ParseQuery(cursor)
	if err != nil {
		return nil, &BoardsError{Kind: Failed, Message: "Azure Boards: the cursor is not one a list gave"}
	}
	for org := range v {
		n, err := strconv.Atoi(v.Get(org))
		if err != nil || n < 0 {
			return nil, &BoardsError{Kind: Failed, Message: "Azure Boards: the cursor is not one a list gave"}
		}
		out[org] = n
	}
	return out, nil
}

func cursorText(offsets map[string]int) string {
	v := url.Values{}
	for org, n := range offsets {
		v.Set(org, itoa(n))
	}
	return v.Encode()
}

// Search is one page of the work items of projects (organization/project), at most first (1 to
// 100), after the cursor after ("" for the first page): one query per organization, merged by
// when they changed.
func (f *RealBoards) Search(ctx context.Context, projects []string, sf SearchFilter, after string, first int) (SearchPage, error) {
	page := SearchPage{Items: []Item{}, Cursors: []string{}}
	offsets, err := cursorOffsets(after)
	if err != nil {
		return SearchPage{}, err
	}
	first = max(1, min(first, forgeListMost))
	byOrg := map[string][]string{}
	for _, p := range projects {
		p = strings.ToLower(strings.Trim(p, "/"))
		if org := orgOf(p); org != "" && !slices.Contains(byOrg[org], p) {
			byOrg[org] = append(byOrg[org], p)
		}
	}
	orgs := make([]string, 0, len(byOrg))
	for org := range byOrg {
		orgs = append(orgs, org)
	}
	sort.Strings(orgs)
	type found struct {
		org  string
		item Item
	}
	var all []found
	more := map[string]bool{}
	for _, org := range orgs {
		states, err := f.orgStates(ctx, byOrg[org])
		if err != nil {
			return SearchPage{}, err
		}
		from := offsets[org]
		// The work items read already are found again: WIQL has no cursor.
		ids, err := f.orgQuery(ctx, org, SearchWhere(byOrg[org], sf, closedStates(states)), from+first+1)
		if err != nil {
			return SearchPage{}, err
		}
		ids = ids[min(from, len(ids)):]
		more[org] = len(ids) > first
		list, err := f.orgItems(ctx, org, ids[:min(first, len(ids))], forgeFields, false)
		if err != nil {
			return SearchPage{}, err
		}
		for _, w := range list {
			all = append(all, found{org, f.forgeItem(org, w.workItemJSON, states)})
		}
	}
	sort.SliceStable(all, func(i, j int) bool { return all[i].item.UpdatedAt > all[j].item.UpdatedAt })
	taken := map[string]int{}
	for _, x := range all[:min(first, len(all))] {
		taken[x.org]++
		at := map[string]int{}
		for _, org := range orgs {
			at[org] = offsets[org] + taken[org]
		}
		page.Items = append(page.Items, x.item)
		page.Cursors = append(page.Cursors, cursorText(at))
	}
	for _, x := range all[min(first, len(all)):] {
		more[x.org] = true
	}
	for _, org := range orgs {
		if more[org] {
			if n := len(page.Cursors); n > 0 {
				page.Next = page.Cursors[n-1]
			} else {
				page.Next = cursorText(offsets)
			}
			break
		}
	}
	return page, nil
}

// markdown is HTML that Azure DevOps keeps (a description, a comment), made safe, as Markdown.
func markdown(html string) string {
	if strings.TrimSpace(html) == "" {
		return ""
	}
	md, err := htmltomarkdown.ConvertString(richtext.HTML(html))
	if err != nil {
		return html
	}
	return strings.TrimSpace(md)
}

// relation is a link of a work item to another.
type relation struct {
	Rel string `json:"rel"`
	URL string `json:"url"`
}

// linked is the id of the work item a link names, 0 for a link to something else.
func (r relation) linked() int {
	i := strings.LastIndex(r.URL, "/workItems/")
	if i < 0 {
		return 0
	}
	n, _ := strconv.Atoi(r.URL[i+len("/workItems/"):])
	return n
}

type withRelations struct {
	workItemJSON
	Rev       int        `json:"rev"`
	Relations []relation `json:"relations"`
}

// read is one work item with every field and its links.
func (f *RealBoards) read(ctx context.Context, project string, id int) (withRelations, error) {
	var w withRelations
	q := url.Values{"$expand": {"relations"}}
	if err := f.call(ctx, http.MethodGet, api(orgPath(orgOf(project))+"wit/workitems/"+itoa(id), q, apiVersion), nil, false, &w); err != nil {
		return withRelations{}, err
	}
	if w.ID == 0 || !strings.EqualFold(w.project(orgOf(project)), project) {
		return withRelations{}, &BoardsError{Kind: NotFound, Message: fmt.Sprintf("Azure Boards: no work item %d in %s", id, project)}
	}
	return w, nil
}

// ItemPage is a work item, with its description, the page of its comments before the cursor
// before (the newest page for ""), and the states it can move to.
func (f *RealBoards) ItemPage(ctx context.Context, project string, id int, before string) (ItemDetail, error) {
	project = strings.ToLower(project)
	w, err := f.read(ctx, project, id)
	if err != nil {
		return ItemDetail{}, err
	}
	types, err := f.typesOf(ctx, project)
	if err != nil {
		return ItemDetail{}, err
	}
	states, _ := f.categories(ctx, project)
	d := ItemDetail{Item: f.forgeItem(orgOf(project), w.workItemJSON, states), Body: markdown(w.text(fieldDesc)), Thread: []ForgeComment{},
		Transitions: []Transition{}}
	for _, r := range w.Relations {
		if r.Rel == relChild {
			d.SubTotal++
		}
	}
	for _, s := range types[d.Type] {
		if s.Name != d.Status {
			d.Transitions = append(d.Transitions, Transition{ID: s.Name, Name: s.Name, Category: category(s.Category)})
		}
	}
	var list struct {
		Comments []struct {
			commentJSON
			Format string `json:"format"`
		} `json:"comments"`
		Next string `json:"continuationToken"`
	}
	q := url.Values{"$top": {itoa(forgeComments)}, "order": {"desc"}}
	if before != "" {
		q.Set("continuationToken", before)
	}
	if err := f.call(ctx, http.MethodGet, api(projectPath(project)+"wit/workItems/"+itoa(id)+"/comments", q, commentsVersion), nil, false, &list); err != nil {
		return ItemDetail{}, err
	}
	// Newest first in the answer; oldest first on the page.
	for n := len(list.Comments) - 1; n >= 0; n-- {
		c := list.Comments[n]
		if c.IsDeleted {
			continue
		}
		body := c.Text
		if c.Format != "markdown" {
			body = markdown(body)
		}
		p := c.CreatedBy.person()
		d.Thread = append(d.Thread, ForgeComment{Author: p.name(), Avatar: p.avatar(), Body: body, At: normalized(c.CreatedDate), URL: d.URL, Bot: p != nil && p.Bot})
	}
	d.Before = list.Next
	return d, nil
}

// MARK: Writes

// change applies ops to a work item, never from or into the shared answers.
func (f *RealBoards) change(ctx context.Context, project string, id int, ops patch) error {
	return f.call(ctx, http.MethodPatch, api(projectPath(project)+"wit/workitems/"+itoa(id), nil, apiVersion), ops, false, nil)
}

// Comment adds a comment, in Markdown, to a work item, and is its page.
func (f *RealBoards) Comment(ctx context.Context, project string, id int, body string) (string, error) {
	project = strings.ToLower(project)
	q := url.Values{"format": {"markdown"}}
	if err := f.call(ctx, http.MethodPost, api(projectPath(project)+"wit/workItems/"+itoa(id)+"/comments", q, commentsVersion),
		map[string]string{"text": body}, false, nil); err != nil {
		return "", err
	}
	return f.webURL(project, id), nil
}

// SetTags adds tags to a work item and takes others off, in one change.
func (f *RealBoards) SetTags(ctx context.Context, project string, id int, add, remove []string) error {
	project = strings.ToLower(project)
	w, err := f.read(ctx, project, id)
	if err != nil {
		return err
	}
	list := []string{}
	for _, t := range tags(w.text(fieldTags)) {
		if !containsFold(remove, t) {
			list = append(list, t)
		}
	}
	for _, t := range add {
		if !containsFold(list, t) {
			list = append(list, t)
		}
	}
	// The test makes a change made since the read fail, not be lost.
	return f.change(ctx, project, id, patch{{"op": "test", "path": "/rev", "value": w.Rev},
		{"op": "add", "path": "/fields/" + fieldTags, "value": strings.Join(list, "; ")}})
}

// Labels are the tags a work item can have: its project's, and its own. Azure DevOps's tags
// have no colour.
func (f *RealBoards) Labels(ctx context.Context, project string, id int) ([]string, map[string]string, error) {
	project = strings.ToLower(project)
	seen := map[string]bool{}
	var answer struct {
		Value []struct {
			Name string `json:"name"`
		} `json:"value"`
	}
	// The project's list is a nicety: the work item's own tags still come when it cannot be read.
	if err := f.call(ctx, http.MethodGet, api(projectPath(project)+"wit/tags", nil, tagsVersion), nil, false, &answer); err == nil {
		for _, t := range answer.Value {
			seen[t.Name] = true
		}
	}
	w, err := f.read(ctx, project, id)
	if err != nil {
		return nil, nil, err
	}
	for _, t := range tags(w.text(fieldTags)) {
		seen[t] = true
	}
	names := make([]string, 0, len(seen))
	for t := range seen {
		names = append(names, t)
	}
	sort.Strings(names)
	return names, map[string]string{}, nil
}

// Transition moves a work item to a state of its type, by name.
func (f *RealBoards) Transition(ctx context.Context, project string, id int, state string) error {
	project = strings.ToLower(project)
	w, err := f.read(ctx, project, id)
	if err != nil {
		return err
	}
	types, err := f.typesOf(ctx, project)
	if err != nil {
		return err
	}
	kind := w.text(fieldType)
	if !slices.ContainsFunc(types[kind], func(s State) bool { return s.Name == state }) {
		return &BoardsError{Kind: Failed, Message: fmt.Sprintf("Azure Boards: a %s has no state %q", kind, state)}
	}
	return f.change(ctx, project, id, patch{{"op": "add", "path": "/fields/" + fieldState, "value": state}})
}

// SetState closes a work item (its type's first state of the Completed category) or opens it
// again (its first of the Proposed category, else InProgress): the Work pages' Close and
// Reopen, for a client with no state menu.
func (f *RealBoards) SetState(ctx context.Context, project string, id int, closed bool) error {
	project = strings.ToLower(project)
	w, err := f.read(ctx, project, id)
	if err != nil {
		return err
	}
	types, err := f.typesOf(ctx, project)
	if err != nil {
		return err
	}
	kind := w.text(fieldType)
	want := []string{"Proposed", "InProgress"}
	if closed {
		want = []string{"Completed"}
	}
	for _, c := range want {
		for _, s := range types[kind] {
			if s.Category == c {
				return f.change(ctx, project, id, patch{{"op": "add", "path": "/fields/" + fieldState, "value": s.Name}})
			}
		}
	}
	what := "reopen"
	if closed {
		what = "close"
	}
	return &BoardsError{Kind: Failed, Message: fmt.Sprintf("Azure Boards: a %s has no state to %s it in", kind, what)}
}

// MARK: Plans

// Ref is a work item another names, and whether it is open.
type Ref struct {
	Project string
	ID      int
	Open    bool
}

// PlanChild is a child of a work item, and the work items it is blocked by: its predecessors.
type PlanChild struct {
	Item
	BlockedBy []Ref
}

// Plan is a work item and its children, by their ids, the oldest first.
type Plan struct {
	Epic     Item
	Children []PlanChild
}

// Plan reads a work item and its children (at most 200), with each child's predecessors.
func (f *RealBoards) Plan(ctx context.Context, project string, id int) (Plan, error) {
	project = strings.ToLower(project)
	org := orgOf(project)
	w, err := f.read(ctx, project, id)
	if err != nil {
		return Plan{}, err
	}
	statesOf := map[string]map[string]map[string]string{}
	states := func(p string) map[string]map[string]string {
		if _, ok := statesOf[p]; !ok {
			// A child in a project the token cannot read the types of is open.
			statesOf[p], _ = f.categories(ctx, p)
		}
		return statesOf[p]
	}
	p := Plan{Epic: f.forgeItem(org, w.workItemJSON, states(project)), Children: []PlanChild{}}
	var ids []int
	for _, r := range w.Relations {
		if n := r.linked(); r.Rel == relChild && n > 0 {
			ids = append(ids, n)
		}
	}
	slices.Sort(ids)
	children, err := f.orgItems(ctx, org, ids[:min(len(ids), 200)], nil, true)
	if err != nil {
		return Plan{}, err
	}
	by, err := f.predecessors(ctx, org, children, states)
	if err != nil {
		return Plan{}, err
	}
	for _, c := range children {
		pc := PlanChild{Item: f.forgeItem(org, c.workItemJSON, states(c.project(org))), BlockedBy: by[c.ID]}
		p.Children = append(p.Children, pc)
		p.Epic.SubTotal++
		if pc.State == "closed" {
			p.Epic.SubDone++
		}
	}
	return p, nil
}

// predecessors are the work items that block each of items, its predecessors, with a read of
// all of them at once for their states. A predecessor that cannot be read is left out.
func (f *RealBoards) predecessors(ctx context.Context, org string, items []withRelations,
	states func(string) map[string]map[string]string) (map[int][]Ref, error) {
	var blockers []int
	for _, c := range items {
		for _, r := range c.Relations {
			if n := r.linked(); r.Rel == relPredecessor && n > 0 && !slices.Contains(blockers, n) {
				blockers = append(blockers, n)
			}
		}
	}
	open := map[int]Ref{}
	if len(blockers) > 0 {
		list, err := f.orgItems(ctx, org, blockers, []string{fieldType, fieldState, fieldProject}, false)
		if err != nil {
			return nil, err
		}
		for _, b := range list {
			bp := b.project(org)
			open[b.ID] = Ref{Project: bp, ID: b.ID, Open: !closedIn(states(bp), b.text(fieldType), b.text(fieldState))}
		}
	}
	out := map[int][]Ref{}
	for _, c := range items {
		for _, r := range c.Relations {
			if n := r.linked(); r.Rel == relPredecessor && n > 0 {
				if ref, ok := open[n]; ok {
					out[c.ID] = append(out[c.ID], ref)
				}
			}
		}
	}
	return out, nil
}

// BlockersMost bounds the work items one Blockers read asks about: a batch.
const BlockersMost = 200

// Blockers are the predecessors of each of ids in project's organization (at most BlockersMost),
// as Plan reads a child's (#4242): a read of their links, and one of the predecessors' states.
// A standing epic's children come from a list, which does not read links. An id that cannot
// be read has none.
func (f *RealBoards) Blockers(ctx context.Context, project string, ids []int) (map[int][]Ref, error) {
	org := orgOf(strings.ToLower(project))
	ids = ids[:min(len(ids), BlockersMost)]
	if len(ids) == 0 {
		return map[int][]Ref{}, nil
	}
	items, err := f.orgItems(ctx, org, ids, nil, true)
	if err != nil {
		return nil, err
	}
	statesOf := map[string]map[string]map[string]string{}
	states := func(p string) map[string]map[string]string {
		if _, ok := statesOf[p]; !ok {
			statesOf[p], _ = f.categories(ctx, p)
		}
		return statesOf[p]
	}
	by, err := f.predecessors(ctx, org, items, states)
	if err != nil {
		return nil, err
	}
	out := map[int][]Ref{}
	for _, i := range items {
		out[i.ID] = append([]Ref{}, by[i.ID]...)
	}
	return out, nil
}

// childTypes are the work item types a new child of a level is, the first the process has:
// Agile's, Scrum's, CMMI's and Basic's.
var childTypes = map[string][]string{
	"":      {"User Story", "Product Backlog Item", "Requirement", "Issue"},
	"story": {"User Story", "Product Backlog Item", "Requirement", "Issue"},
	"spike": {"User Story", "Product Backlog Item", "Requirement", "Issue"},
	"task":  {"Task"},
	"bug":   {"Bug", "Issue"},
}

// AddChild makes a work item titled title, with tags, a child of parent: of the type its level
// (story, task, spike or bug, "" for none) is in the project's process. It is the new one's id
// and page.
func (f *RealBoards) AddChild(ctx context.Context, project string, parent int, title string, labels []string, level string) (int, string, error) {
	project = strings.ToLower(project)
	types, err := f.typesOf(ctx, project)
	if err != nil {
		return 0, "", err
	}
	kind := ""
	for _, t := range childTypes[level] {
		if _, ok := types[t]; ok {
			kind = t
			break
		}
	}
	if kind == "" {
		return 0, "", &BoardsError{Kind: Failed, Message: "Azure Boards: the project's process has no work item type for this child"}
	}
	ops := patch{{"op": "add", "path": "/fields/" + fieldTitle, "value": title},
		{"op": "add", "path": "/relations/-", "value": relation{Rel: relParent, URL: f.workItemURL(orgOf(project), parent)}}}
	if len(labels) > 0 {
		ops = append(ops, map[string]any{"op": "add", "path": "/fields/" + fieldTags, "value": strings.Join(labels, "; ")})
	}
	var made struct {
		ID int `json:"id"`
	}
	if err := f.call(ctx, http.MethodPost, api(projectPath(project)+"wit/workitems/"+url.PathEscape("$"+kind), nil, apiVersion), ops, false, &made); err != nil {
		return 0, "", err
	}
	return made.ID, f.webURL(project, made.ID), nil
}

// SetParent makes a work item of the organization a child of parent, in place of the parent it had.
func (f *RealBoards) SetParent(ctx context.Context, project string, id, parent int) error {
	project = strings.ToLower(project)
	w, err := f.read(ctx, project, id)
	if err != nil {
		return err
	}
	ops := patch{{"op": "test", "path": "/rev", "value": w.Rev}}
	// From the last, so each index is still the link's.
	for n := len(w.Relations) - 1; n >= 0; n-- {
		if w.Relations[n].Rel == relParent {
			if w.Relations[n].linked() == parent {
				return nil
			}
			ops = append(ops, map[string]any{"op": "remove", "path": "/relations/" + itoa(n)})
		}
	}
	ops = append(ops, map[string]any{"op": "add", "path": "/relations/-", "value": relation{Rel: relParent, URL: f.workItemURL(orgOf(project), parent)}})
	return f.change(ctx, project, id, ops)
}

// SetBlockedBy makes blocker a predecessor of a work item, or with blocked false no longer one.
func (f *RealBoards) SetBlockedBy(ctx context.Context, project string, id, blocker int, blocked bool) error {
	project = strings.ToLower(project)
	w, err := f.read(ctx, project, id)
	if err != nil {
		return err
	}
	at := slices.IndexFunc(w.Relations, func(r relation) bool { return r.Rel == relPredecessor && r.linked() == blocker })
	switch {
	case blocked && at >= 0, !blocked && at < 0:
		return nil
	case blocked:
		return f.change(ctx, project, id, patch{{"op": "add", "path": "/relations/-",
			"value": relation{Rel: relPredecessor, URL: f.workItemURL(orgOf(project), blocker)}}})
	}
	return f.change(ctx, project, id, patch{{"op": "test", "path": "/rev", "value": w.Rev}, {"op": "remove", "path": "/relations/" + itoa(at)}})
}
