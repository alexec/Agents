package gitlabmcp

import (
	"cmp"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"time"
)

// The daemon's forge reads (#3209, after GitHub's in #3129): the issues or merge requests of
// many projects, the last updated first, and one item with its body and a page of its comments,
// in typed reads beside the views' maps. The daemon puts them in the one model the Work pages
// draw for every forge (wire.ForgeItem).
//
// GitLab has no list of issues or merge requests across chosen projects (the /issues and
// /merge_requests lists are the person's own, or a group's), so a list asks each project, and
// merges them by updated_at. The cursor is a time, not a page: each project is asked for what
// was updated at or before it, so the pages of many projects go on from one place.

// SearchFilter is what a list lists: merge requests or issues, in state open, closed or all
// (open when ""), narrowed by a label, an assignee's username and words in the title or
// description. A closed merge request includes a merged one.
type SearchFilter struct {
	MRs                    bool
	State                  string
	Label, Assignee, Query string
}

// Item is an issue or a merge request as the forge reads list it.
type Item struct {
	Project string
	Number  int
	MR      bool
	// State is open, closed or merged.
	State, Title, URL, Author, Milestone, UpdatedAt string
	Labels                                          []string
	LabelColors                                     map[string]string
	Assignees                                       []string
	Comments                                        int
	// A merge request's: Checks is passing, failing, running, skipped or none (only on one
	// read on its own: a list does not say its pipeline); Review is changes_requested,
	// review_required or ""; Mergeable is mergeable, conflicting or unknown.
	Draft, AutoMerge          bool
	Checks, Review, Mergeable string
}

// SearchPage is a page of a list, the last updated first. Cursors[i] goes on after Items[i],
// so a caller that keeps only some of the page goes on from the last it kept; Next is the
// cursor after the page, "" at the end.
type SearchPage struct {
	Items   []Item
	Cursors []string
	Next    string
}

// Comment is a comment on an item, as Markdown.
type Comment struct {
	Author, Body, At, URL string
	Bot                   bool
}

// Check is one of a merge request's pipeline jobs: State is passing, failing, running or skipped.
type Check struct{ Name, State, URL string }

// ItemDetail is an item with its body and a page of its comments (Thread), oldest first in the
// page. Before is the cursor of the page before it, "" at the first comment. CheckRuns are a
// merge request's head pipeline's jobs.
type ItemDetail struct {
	Item
	Body          string
	Thread        []Comment
	Before        string
	CheckRuns     []Check
	ReviewThreads int
	FilesChanged  int
}

// forgeComments is a page of an item's comments.
const forgeComments = 50

type labelJSON struct {
	Name  string `json:"name"`
	Color string `json:"color"`
}

// UnmarshalJSON reads a label with its details, or a single read's label, which is its name.
func (l *labelJSON) UnmarshalJSON(b []byte) error {
	if len(b) > 0 && b[0] == '"' {
		return json.Unmarshal(b, &l.Name)
	}
	type plain labelJSON
	return json.Unmarshal(b, (*plain)(l))
}

// forgeJSON is what an issue and a merge request both say in a list with label details.
type forgeJSON struct {
	IID         int         `json:"iid"`
	Title       string      `json:"title"`
	Description string      `json:"description"`
	State       string      `json:"state"`
	WebURL      string      `json:"web_url"`
	Author      user        `json:"author"`
	Assignees   []user      `json:"assignees"`
	Labels      []labelJSON `json:"labels"`
	Milestone   *struct {
		Title string `json:"title"`
	} `json:"milestone"`
	UpdatedAt      string `json:"updated_at"`
	UserNotesCount int    `json:"user_notes_count"`
	// A merge request's.
	Draft                     bool   `json:"draft"`
	WorkInProgress            bool   `json:"work_in_progress"`
	HasConflicts              bool   `json:"has_conflicts"`
	DetailedMergeStatus       string `json:"detailed_merge_status"`
	MergeStatus               string `json:"merge_status"`
	MergeWhenPipelineSucceeds bool   `json:"merge_when_pipeline_succeeds"`
	ChangesCount              string `json:"changes_count"`
	HeadPipeline              *struct {
		ID     int    `json:"id"`
		Status string `json:"status"`
	} `json:"head_pipeline"`
}

func (j forgeJSON) item(project string, mr bool) Item {
	i := Item{Project: project, Number: j.IID, MR: mr, Title: j.Title, URL: j.WebURL, Author: j.Author.Username,
		UpdatedAt: j.UpdatedAt, Comments: j.UserNotesCount, Assignees: []string{}, Labels: []string{}, LabelColors: map[string]string{}}
	switch j.State {
	case "merged", "closed":
		i.State = j.State
	default:
		i.State = "open"
	}
	for _, l := range j.Labels {
		i.Labels = append(i.Labels, l.Name)
		if l.Color != "" {
			i.LabelColors[l.Name] = strings.ToLower(l.Color)
		}
	}
	for _, a := range j.Assignees {
		if a.Username != "" {
			i.Assignees = append(i.Assignees, a.Username)
		}
	}
	if j.Milestone != nil {
		i.Milestone = j.Milestone.Title
	}
	if !mr {
		return i
	}
	m := mergeRequest{Draft: j.Draft, WorkInProgress: j.WorkInProgress, HasConflicts: j.HasConflicts,
		DetailedMergeStatus: j.DetailedMergeStatus, MergeStatus: j.MergeStatus, MergeWhenPipelineSucceeds: j.MergeWhenPipelineSucceeds}
	i.Draft, i.AutoMerge, i.Review = m.draft(), m.autoMerge(), m.review()
	i.Mergeable = "unknown"
	if c := m.conflicts(); c != nil {
		i.Mergeable = map[bool]string{true: "conflicting", false: "mergeable"}[*c]
	}
	if j.HeadPipeline != nil {
		i.Checks = pipelineState(j.HeadPipeline.Status)
	}
	return i
}

// listCursor is where a list goes on: before the time Before (in timeLayout), leaving out Seen,
// the items given already that were updated in its millisecond or the one after it.
type listCursor struct {
	Before string   `json:"before"`
	Seen   []string `json:"seen,omitempty"`
}

func (c listCursor) text() string {
	b, _ := json.Marshal(c)
	return base64.RawURLEncoding.EncodeToString(b)
}

func cursorOf(s string) (listCursor, error) {
	var c listCursor
	if s == "" {
		return c, nil
	}
	b, err := base64.RawURLEncoding.DecodeString(s)
	if err != nil || json.Unmarshal(b, &c) != nil {
		return c, &GitLabError{Kind: Failed, Message: "GitLab: the cursor is not one a list gave"}
	}
	if _, ok := parseTime(c.Before); !ok {
		return c, &GitLabError{Kind: Failed, Message: "GitLab: the cursor is not one a list gave"}
	}
	return c, nil
}

// key is an item's name in a cursor's Seen.
func (i Item) key() string {
	return i.Project + map[bool]string{false: "#", true: "!"}[i.MR] + strconv.Itoa(i.Number)
}

// after is the cursor after item i, given the cursor the page began at.
func (c listCursor) after(i Item, page []Item) listCursor {
	t, _ := parseTime(i.UpdatedAt)
	t = t.Truncate(time.Millisecond)
	next := listCursor{Before: timeString(t)}
	// GitLab keeps microseconds and says milliseconds: what is asked for is up to the
	// millisecond after, and what was given in it is left out.
	if old, ok := parseTime(c.Before); ok && !old.After(t.Add(time.Millisecond)) {
		next.Seen = append(next.Seen, c.Seen...)
	}
	for _, p := range page {
		pt, ok := parseTime(p.UpdatedAt)
		if pt = pt.Truncate(time.Millisecond); ok && !pt.Before(t) && !pt.After(t.Add(time.Millisecond)) && !slices.Contains(next.Seen, p.key()) {
			next.Seen = append(next.Seen, p.key())
		}
	}
	return next
}

// listStates are GitLab's states for f: a closed merge request is closed or merged, two lists.
func listStates(f SearchFilter) []string {
	switch {
	case f.State == "all":
		return []string{"all"}
	case f.State == "closed" && f.MRs:
		return []string{"closed", "merged"}
	case f.State == "closed":
		return []string{"closed"}
	}
	return []string{"opened"}
}

// listPath is a project's list in state, the last updated first, up to and in the millisecond
// after before.
func listPath(project string, f SearchFilter, state, before string, first int) string {
	kind := map[bool]string{false: "issues", true: "merge_requests"}[f.MRs]
	q := url.Values{"state": {state}, "order_by": {"updated_at"}, "sort": {"desc"}, "with_labels_details": {"true"},
		"per_page": {strconv.Itoa(first)}}
	if before != "" {
		t, _ := parseTime(before)
		q.Set("updated_before", timeString(t.Add(time.Millisecond)))
	}
	if f.Label != "" {
		q.Set("labels", f.Label)
	}
	if f.Assignee != "" {
		q.Set("assignee_username", f.Assignee)
	}
	if s := strings.TrimSpace(f.Query); s != "" {
		q.Set("search", s)
	}
	return fmt.Sprintf("projects/%s/%s?%s", pid(project), kind, q.Encode())
}

// Search is one page of the issues or merge requests of projects, at most first (1 to 100),
// after the cursor after ("" for the first page): one call per project and state.
func (g *RealGitLab) Search(ctx context.Context, projects []string, f SearchFilter, after string, first int) (SearchPage, error) {
	page := SearchPage{Items: []Item{}, Cursors: []string{}}
	if len(projects) == 0 {
		return page, nil
	}
	first = max(1, min(first, perPage))
	c, err := cursorOf(after)
	if err != nil {
		return SearchPage{}, err
	}
	// Each project gives enough that, with what was seen left out, first are new.
	ask := min(perPage, first+len(c.Seen))
	var all []Item
	more := false
	for _, project := range projects {
		for _, state := range listStates(f) {
			var list []forgeJSON
			if err := g.get(ctx, listPath(project, f, state, c.Before, ask), false, &list); err != nil {
				return SearchPage{}, err
			}
			more = more || len(list) >= ask
			for _, j := range list {
				if i := j.item(project, f.MRs); !slices.Contains(c.Seen, i.key()) {
					all = append(all, i)
				}
			}
		}
	}
	slices.SortStableFunc(all, func(a, b Item) int {
		ta, _ := parseTime(a.UpdatedAt)
		tb, _ := parseTime(b.UpdatedAt)
		return cmp.Or(tb.Compare(ta), cmp.Compare(a.key(), b.key()))
	})
	if len(all) > first {
		all, more = all[:first], true
	}
	for n, i := range all {
		page.Items = append(page.Items, i)
		page.Cursors = append(page.Cursors, c.after(i, all[:n+1]).text())
	}
	if more && len(page.Items) > 0 {
		page.Next = page.Cursors[len(page.Cursors)-1]
	}
	return page, nil
}

// ItemPage is an issue or a merge request of project, with its description, the page of its
// comments before the cursor before (the newest page for ""), and a merge request's pipeline
// jobs, review threads and files changed.
func (g *RealGitLab) ItemPage(ctx context.Context, project string, number int, mr bool, before string) (ItemDetail, error) {
	page := 1
	if before != "" {
		n, err := strconv.Atoi(before)
		if err != nil || n < 1 {
			return ItemDetail{}, &GitLabError{Kind: Failed, Message: "GitLab: the cursor is not one an item gave"}
		}
		page = n
	}
	kind := map[bool]string{false: "issues", true: "merge_requests"}[mr]
	var j forgeJSON
	if err := g.get(ctx, fmt.Sprintf("projects/%s/%s/%d", pid(project), kind, number), false, &j); err != nil {
		return ItemDetail{}, err
	}
	d := ItemDetail{Item: j.item(project, mr), Body: j.Description, Thread: []Comment{}}
	var notes []noteJSON
	path := fmt.Sprintf("projects/%s/%s/%d/notes?sort=desc&order_by=created_at&per_page=%d&page=%d", pid(project), kind, number, forgeComments, page)
	if err := g.get(ctx, path, false, &notes); err != nil {
		return ItemDetail{}, err
	}
	if len(notes) == forgeComments {
		d.Before = strconv.Itoa(page + 1)
	}
	for _, n := range slices.Backward(notes) {
		// GitLab's own notes (a label, a close) and a line's comments are not the conversation.
		if n.System || n.Type == "DiffNote" {
			continue
		}
		d.Thread = append(d.Thread, Comment{Author: n.Author.Username, Body: n.Body, At: n.CreatedAt,
			URL: fmt.Sprintf("%s#note_%d", j.WebURL, n.ID), Bot: isBot(n.Author.Username, n.Author.Bot)})
	}
	if !mr {
		return d, nil
	}
	d.FilesChanged, _ = strconv.Atoi(strings.TrimSuffix(j.ChangesCount, "+"))
	discussions, err := g.discussions(ctx, project, number)
	if err != nil {
		return ItemDetail{}, err
	}
	for _, t := range discussions {
		if len(t.Notes) > 0 && t.Notes[0].Type == "DiffNote" {
			d.ReviewThreads++
		}
	}
	d.CheckRuns = []Check{}
	if p := j.HeadPipeline; p != nil {
		var jobs []jobJSON
		if err := g.get(ctx, fmt.Sprintf("projects/%s/pipelines/%d/jobs?per_page=100", pid(project), p.ID), false, &jobs); err != nil {
			return ItemDetail{}, err
		}
		for _, job := range jobs {
			state := pipelineState(job.Status)
			if job.Status == "failed" && job.AllowFailure {
				state = "skipped"
			}
			d.CheckRuns = append(d.CheckRuns, Check{Name: job.Stage + ": " + job.Name, State: state, URL: job.WebURL})
		}
	}
	return d, nil
}

// IsNotFound says whether err is GitLab's 404.
func IsNotFound(err error) bool {
	e, ok := err.(*GitLabError)
	return ok && e.Kind == NotFound
}
