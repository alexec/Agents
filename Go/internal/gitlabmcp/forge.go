package gitlabmcp

import (
	"cmp"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/mcpevents"
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
// description, and a feature: the name of a feature:<name> label (#3267). A closed merge request
// includes a merged one. Board is a group board's scope (#3282): its labels and milestone.
type SearchFilter struct {
	MRs                             bool
	State                           string
	Label, Assignee, Query, Feature string
	Board                           BoardScope
}

// BoardScope is what a group board shows (#3282): the issues with all of Labels, and in
// Milestone when it is not "". An empty scope is every issue of the group.
type BoardScope struct {
	Labels    []string
	Milestone string
}

// Item is an issue or a merge request as the forge reads list it.
type Item struct {
	Project string
	Number  int
	MR      bool
	// State is open, closed or merged.
	State, Title, URL, Author, Milestone, UpdatedAt string
	// CreatedAt is when it opened; ClosedAt when it closed or merged, "" while open (#4373).
	CreatedAt, ClosedAt string
	// AuthorAvatar is the author's picture, on the GitLab or on Gravatar; "" for none (#4363).
	AuthorAvatar string
	Labels       []string
	LabelColors  map[string]string
	Assignees    []string
	Comments     int
	// A merge request's: Checks is passing, failing, running, skipped or none (only on one
	// read on its own: a list does not say its pipeline); Review is changes_requested,
	// review_required or ""; Mergeable is mergeable, conflicting or unknown.
	Draft, AutoMerge          bool
	Checks, Review, Mergeable string
	// HeadRef is the branch it merges from and BaseRef the one it merges into; a merged one's
	// MergedBy is who merged it and MergeCommit the commit it made (#4409).
	HeadRef, BaseRef, MergedBy, MergeCommit string
	// An issue's place in the hierarchy of work items (#3267): the issue it is a child of
	// (ParentProject "" for none), and its children, SubDone of them closed. Only an issue's own
	// read and a plan say them: GitLab's REST lists do not.
	ParentProject     string
	ParentNumber      int
	SubTotal, SubDone int
}

// SearchPage is a page of a list, the last updated first. Cursors[i] goes on after Items[i],
// so a caller that keeps only some of the page goes on from the last it kept; Next is the
// cursor after the page, "" at the end. Total is how many items the whole list has, on its
// first page only (#4396); nil where GitLab does not say.
type SearchPage struct {
	Items   []Item
	Cursors []string
	Next    string
	Total   *int
}

// Comment is a comment on an item, as Markdown.
type Comment struct {
	Author, Avatar, Body, At, URL string
	Bot                           bool
}

// Check is one of a merge request's pipeline jobs: State is passing, failing, running or skipped.
// StartedAt and FinishedAt are a job's times, "" before it starts and while it runs (#4682).
type Check struct{ Name, State, URL, StartedAt, FinishedAt string }

// Reviewer is a person asked to review a merge request or who reviewed it (#4682): State is
// approved, changes_requested, commented, or pending while asked and not answered.
type Reviewer struct{ Login, Avatar, State string }

// Size is a merge request's lines added and deleted, and its commits (#4682).
type Size struct{ Additions, Deletions, Commits int }

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
	// A merge request's head commit and head pipeline (0 for none), which a merge, an approval,
	// a retry and a log name (#3130).
	Head     string
	Pipeline int
	// An issue's (#4626): Children are its child work items, in GitLab's order (empty on a GitLab
	// without work items), and ClosedBy the merge requests that close it.
	Children, ClosedBy []Linked
	// A merge request's (#4682), from the one read more of its page: its Size, its Reviewers, and
	// the issues of its project that its description closes. All nil when GitLab does not say them.
	Size      *Size
	Reviewers []Reviewer
	Closes    []Linked
}

// Linked is an item that another names, with its title: State is open, closed or merged.
type Linked struct {
	Project           string
	Number            int
	MR                bool
	State, Title, URL string
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
	CreatedAt      string `json:"created_at"`
	ClosedAt       string `json:"closed_at"`
	MergedAt       string `json:"merged_at"`
	UserNotesCount int    `json:"user_notes_count"`
	// A merge request's.
	Draft                     bool   `json:"draft"`
	WorkInProgress            bool   `json:"work_in_progress"`
	HasConflicts              bool   `json:"has_conflicts"`
	DetailedMergeStatus       string `json:"detailed_merge_status"`
	MergeStatus               string `json:"merge_status"`
	MergeWhenPipelineSucceeds bool   `json:"merge_when_pipeline_succeeds"`
	ChangesCount              string `json:"changes_count"`
	SourceBranch              string `json:"source_branch"`
	TargetBranch              string `json:"target_branch"`
	MergeUser                 *user  `json:"merge_user"`
	MergeCommitSHA            string `json:"merge_commit_sha"`
	SquashCommitSHA           string `json:"squash_commit_sha"`
	SHA                       string `json:"sha"`
	HeadPipeline              *struct {
		ID     int    `json:"id"`
		Status string `json:"status"`
	} `json:"head_pipeline"`
}

func (j forgeJSON) item(project string, mr bool) Item {
	i := Item{Project: project, Number: j.IID, MR: mr, Title: j.Title, URL: j.WebURL, Author: j.Author.Username,
		AuthorAvatar: j.Author.avatar(j.WebURL),
		UpdatedAt:    j.UpdatedAt, CreatedAt: j.CreatedAt, Comments: j.UserNotesCount, Assignees: []string{}, Labels: []string{}, LabelColors: map[string]string{}}
	switch j.State {
	case "merged", "closed":
		i.State = j.State
		// A merged merge request has merged_at, and closed_at only when it was closed first.
		i.ClosedAt = cmp.Or(j.MergedAt, j.ClosedAt)
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
	i.HeadRef, i.BaseRef = j.SourceBranch, j.TargetBranch
	if i.State == "merged" {
		// A squashed merge request's commit on the target is its squash commit.
		i.MergeCommit = cmp.Or(j.MergeCommitSHA, j.SquashCommitSHA)
		if j.MergeUser != nil {
			i.MergedBy = j.MergeUser.Username
		}
	}
	i.Mergeable = "unknown"
	if c := m.conflicts(); c != nil {
		i.Mergeable = map[bool]string{true: "conflicting", false: "mergeable"}[*c]
	}
	if j.HeadPipeline != nil {
		i.Checks = pipelineState(j.HeadPipeline.Status)
	}
	return i
}

// listCursor is where a list goes on: before the time Before (in mcpevents.TimeLayout), leaving out Seen,
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
	if _, ok := mcpevents.ParseTime(c.Before); !ok {
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
	t, _ := mcpevents.ParseTime(i.UpdatedAt)
	t = t.Truncate(time.Millisecond)
	next := listCursor{Before: mcpevents.TimeString(t)}
	// GitLab keeps microseconds and says milliseconds: what is asked for is up to the
	// millisecond after, and what was given in it is left out.
	if old, ok := mcpevents.ParseTime(c.Before); ok && !old.After(t.Add(time.Millisecond)) {
		next.Seen = append(next.Seen, c.Seen...)
	}
	for _, p := range page {
		pt, ok := mcpevents.ParseTime(p.UpdatedAt)
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
		t, _ := mcpevents.ParseTime(before)
		q.Set("updated_before", mcpevents.TimeString(t.Add(time.Millisecond)))
	}
	// GitLab's labels are all of them, by commas.
	var labels []string
	if f.Label != "" {
		labels = append(labels, f.Label)
	}
	if f.Feature != "" {
		labels = append(labels, "feature:"+f.Feature)
	}
	labels = append(labels, f.Board.Labels...)
	if f.Board.Milestone != "" {
		q.Set("milestone", f.Board.Milestone)
	}
	if len(labels) > 0 {
		q.Set("labels", strings.Join(labels, ","))
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
	// The first page counts each project's list in each state; later pages leave the count out.
	total := 0
	if after != "" {
		total = -1
	}
	for _, project := range projects {
		for _, state := range listStates(f) {
			var list []forgeJSON
			path := listPath(project, f, state, c.Before, ask)
			if total < 0 {
				err = g.get(ctx, path, false, &list)
			} else {
				var n int
				if n, err = g.getCounted(ctx, path, &list); n < 0 {
					total = -1
				} else {
					total += n
				}
			}
			if err != nil {
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
		ta, _ := mcpevents.ParseTime(a.UpdatedAt)
		tb, _ := mcpevents.ParseTime(b.UpdatedAt)
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
	if total >= 0 {
		page.Total = &total
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
	if !mr {
		// The hierarchy is a nicety: a page still reads on a GitLab without work items.
		d.Children, d.ClosedBy = []Linked{}, []Linked{}
		if h, err := g.hierarchy(ctx, project, number); err == nil {
			h.into(&d.Item)
			for _, c := range h.children {
				d.Children = append(d.Children, Linked{Project: c.Project, Number: c.Number, State: c.State, Title: c.Title, URL: c.URL})
			}
		}
		// The merge requests that close it (#4626): the one read more of an issue's page, a nicety too.
		if closedBy, err := g.closedBy(ctx, project, number); err == nil {
			d.ClosedBy = closedBy
		}
	}
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
		d.Thread = append(d.Thread, Comment{Author: n.Author.Username, Avatar: n.Author.avatar(j.WebURL), Body: n.Body, At: n.CreatedAt,
			URL: fmt.Sprintf("%s#note_%d", j.WebURL, n.ID), Bot: isBot(n.Author.Username, n.Author.Bot)})
	}
	if !mr {
		return d, nil
	}
	d.FilesChanged, _ = strconv.Atoi(strings.TrimSuffix(j.ChangesCount, "+"))
	d.Head = j.SHA
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
		d.Pipeline = p.ID
		var jobs []jobJSON
		if err := g.get(ctx, fmt.Sprintf("projects/%s/pipelines/%d/jobs?per_page=100", pid(project), p.ID), false, &jobs); err != nil {
			return ItemDetail{}, err
		}
		for _, job := range jobs {
			state := pipelineState(job.Status)
			if job.Status == "failed" && job.AllowFailure {
				state = "skipped"
			}
			check := Check{Name: job.Stage + ": " + job.Name, State: state, URL: job.WebURL, StartedAt: job.StartedAt}
			if state != "running" && job.StartedAt != "" {
				check.FinishedAt = job.FinishedAt
			}
			d.CheckRuns = append(d.CheckRuns, check)
		}
	}
	// The size, reviewers and closing issues are the one read more of a merge request's page, and a
	// nicety: a page still reads when GitLab does not give them.
	if r, err := g.mergeRequestRead(ctx, project, number, j.Description); err == nil {
		d.Size, d.Reviewers, d.Closes = r.size, r.reviewers, r.closes
	}
	return d, nil
}

// mrReadQuery is a merge request's size and reviewers, and the titles of the issues of its
// project that its description closes (#4682): GitLab's REST says none of them in one read.
const mrReadQuery = `query($path: ID!, $iid: String!, $closes: [String!], $hasCloses: Boolean!) { project(fullPath: $path) {
  mergeRequest(iid: $iid) { diffStatsSummary { additions deletions } commitCount
    reviewers(first: 100) { nodes { username avatarUrl webUrl mergeRequestInteraction { reviewState } } }
    approvedBy(first: 100) { nodes { username avatarUrl webUrl } } }
  issues(iids: $closes, first: 20) @include(if: $hasCloses) { nodes { iid title state webUrl } } } }`

type gqlPerson struct {
	Username  string `json:"username"`
	AvatarURL string `json:"avatarUrl"`
	WebURL    string `json:"webUrl"`
}

// avatar is the person's picture as an absolute URL: GitLab can give its own upload's path.
func (p gqlPerson) avatar() string {
	return user{AvatarURL: p.AvatarURL}.avatar(p.WebURL)
}

// reviewStates are GitLab's review states in the one model's words; unreviewed, started and
// unapproved are pending.
var reviewStates = map[string]string{"APPROVED": "approved", "REQUESTED_CHANGES": "changes_requested", "REVIEWED": "commented"}

type mrRead struct {
	size      *Size
	reviewers []Reviewer
	closes    []Linked
}

func (g *RealGitLab) mergeRequestRead(ctx context.Context, project string, number int, description string) (mrRead, error) {
	// The issues of this project the description closes, in its order; another project's would
	// need a read each.
	var iids []string
	for _, ref := range closingRefs(description) {
		path, n, _ := strings.Cut(ref, "#")
		if path == "" || strings.EqualFold(path, project) {
			iids = append(iids, n)
		}
	}
	var data struct {
		Project *struct {
			MergeRequest *struct {
				DiffStatsSummary *struct {
					Additions int `json:"additions"`
					Deletions int `json:"deletions"`
				} `json:"diffStatsSummary"`
				CommitCount *int `json:"commitCount"`
				Reviewers   struct {
					Nodes []struct {
						gqlPerson
						Interaction *struct {
							ReviewState string `json:"reviewState"`
						} `json:"mergeRequestInteraction"`
					} `json:"nodes"`
				} `json:"reviewers"`
				ApprovedBy struct {
					Nodes []gqlPerson `json:"nodes"`
				} `json:"approvedBy"`
			} `json:"mergeRequest"`
			Issues struct {
				Nodes []struct {
					IID    string `json:"iid"`
					Title  string `json:"title"`
					State  string `json:"state"`
					WebURL string `json:"webUrl"`
				} `json:"nodes"`
			} `json:"issues"`
		} `json:"project"`
	}
	vars := map[string]any{"path": project, "iid": strconv.Itoa(number), "closes": iids, "hasCloses": len(iids) > 0}
	if err := g.graphql(ctx, mrReadQuery, vars, &data); err != nil {
		return mrRead{}, err
	}
	if data.Project == nil || data.Project.MergeRequest == nil {
		return mrRead{}, &GitLabError{Kind: NotFound, Message: "not found on GitLab"}
	}
	m := data.Project.MergeRequest
	var out mrRead
	if m.DiffStatsSummary != nil && m.CommitCount != nil {
		out.size = &Size{Additions: m.DiffStatsSummary.Additions, Deletions: m.DiffStatsSummary.Deletions, Commits: *m.CommitCount}
	}
	// Each reviewer once, by their review; an approval makes a pending reviewer approved, and one
	// who approved and is no reviewer is a reviewer too.
	out.reviewers = []Reviewer{}
	seen := map[string]int{}
	for _, r := range m.Reviewers.Nodes {
		if _, ok := seen[r.Username]; r.Username == "" || ok {
			continue
		}
		seen[r.Username] = len(out.reviewers)
		state := "pending"
		if r.Interaction != nil && reviewStates[r.Interaction.ReviewState] != "" {
			state = reviewStates[r.Interaction.ReviewState]
		}
		out.reviewers = append(out.reviewers, Reviewer{Login: r.Username, Avatar: r.avatar(), State: state})
	}
	for _, a := range m.ApprovedBy.Nodes {
		if i, ok := seen[a.Username]; ok {
			if out.reviewers[i].State == "pending" {
				out.reviewers[i].State = "approved"
			}
		} else if a.Username != "" {
			seen[a.Username] = len(out.reviewers)
			out.reviewers = append(out.reviewers, Reviewer{Login: a.Username, Avatar: a.avatar(), State: "approved"})
		}
	}
	out.closes = []Linked{}
	byIID := map[string]Linked{}
	for _, i := range data.Project.Issues.Nodes {
		n, err := strconv.Atoi(i.IID)
		if err != nil || n < 1 {
			continue
		}
		state := "open"
		if i.State == "closed" {
			state = "closed"
		}
		byIID[i.IID] = Linked{Project: project, Number: n, State: state, Title: i.Title, URL: i.WebURL}
	}
	for _, iid := range iids {
		if l, ok := byIID[iid]; ok {
			out.closes = append(out.closes, l)
			delete(byIID, iid)
		}
	}
	return out, nil
}

// IsNotFound says whether err is GitLab's 404.
func IsNotFound(err error) bool {
	e, ok := err.(*GitLabError)
	return ok && e.Kind == NotFound
}

// Ref is a work item another names, a child or a blocker: open says it is not closed.
type Ref struct {
	Project string
	Number  int
	Open    bool
}

// PlanChild is a child issue with the issues that block it (#3267).
type PlanChild struct {
	Item
	BlockedBy []Ref
}

// Plan is an issue (an epic) and its child issues, in GitLab's order (#3267).
type Plan struct {
	Epic     Item
	Children []PlanChild
}

// Work items (GitLab 17 and later) say an issue's parent, its children, and its "blocked by"
// links, which are GitLab Premium's: on Free, every link relates, and none blocks. REST says
// none of them, so they are read with GraphQL.
const hierarchyQuery = `query($path: ID!, $iid: String!) { project(fullPath: $path) { workItems(iids: [$iid], first: 1) { nodes {
  widgets { __typename ... on WorkItemWidgetHierarchy {
    parent { iid state namespace { fullPath } }
    children(first: 100) { nodes { iid state title webUrl namespace { fullPath }
      widgets { __typename ... on WorkItemWidgetLinkedItems { linkedItems(first: 50) { nodes { linkType
        workItem { iid state namespace { fullPath } } } } } } } } } } } } } }`

type workItemRef struct {
	IID       string `json:"iid"`
	State     string `json:"state"`
	Namespace *struct {
		FullPath string `json:"fullPath"`
	} `json:"namespace"`
}

func (w workItemRef) ref() (Ref, bool) {
	n, err := strconv.Atoi(w.IID)
	if err != nil || n < 1 || w.Namespace == nil || w.Namespace.FullPath == "" {
		return Ref{}, false
	}
	return Ref{Project: w.Namespace.FullPath, Number: n, Open: w.State != "CLOSED"}, true
}

// hierarchyOf is an issue's parent and children, each child with its blockers.
type hierarchyOf struct {
	parent   *Ref
	children []PlanChild
}

func (h hierarchyOf) into(i *Item) {
	if h.parent != nil {
		i.ParentProject, i.ParentNumber = h.parent.Project, h.parent.Number
	}
	i.SubTotal, i.SubDone = len(h.children), 0
	for _, c := range h.children {
		if c.State == "closed" {
			i.SubDone++
		}
	}
}

func (g *RealGitLab) graphql(ctx context.Context, query string, vars map[string]any, into any) error {
	body, err := g.do(ctx, http.MethodPost, "/api/graphql", map[string]any{"query": query, "variables": vars})
	if err != nil {
		return err
	}
	var out struct {
		Data   json.RawMessage `json:"data"`
		Errors []struct {
			Message string `json:"message"`
		} `json:"errors"`
	}
	if json.Unmarshal(body, &out) != nil {
		return &GitLabError{Kind: Failed, Message: "GitLab's answer is not JSON"}
	}
	if len(out.Errors) > 0 {
		return &GitLabError{Kind: Failed, Message: "GitLab: " + out.Errors[0].Message}
	}
	if json.Unmarshal(out.Data, into) != nil {
		return &GitLabError{Kind: Failed, Message: "GitLab's answer is not JSON"}
	}
	return nil
}

// hierarchy is issue number of project's parent and its children (at most 100), each with its
// blockers (at most 50), as refs: the children's own fields are read by REST.
func (g *RealGitLab) hierarchy(ctx context.Context, project string, number int) (hierarchyOf, error) {
	var data struct {
		Project *struct {
			WorkItems struct {
				Nodes []struct {
					Widgets []struct {
						Typename string       `json:"__typename"`
						Parent   *workItemRef `json:"parent"`
						Children struct {
							Nodes []struct {
								workItemRef
								Title   string `json:"title"`
								WebURL  string `json:"webUrl"`
								Widgets []struct {
									LinkedItems struct {
										Nodes []struct {
											LinkType string      `json:"linkType"`
											WorkItem workItemRef `json:"workItem"`
										} `json:"nodes"`
									} `json:"linkedItems"`
								} `json:"widgets"`
							} `json:"nodes"`
						} `json:"children"`
					} `json:"widgets"`
				} `json:"nodes"`
			} `json:"workItems"`
		} `json:"project"`
	}
	if err := g.graphql(ctx, hierarchyQuery, map[string]any{"path": project, "iid": strconv.Itoa(number)}, &data); err != nil {
		return hierarchyOf{}, err
	}
	if data.Project == nil || len(data.Project.WorkItems.Nodes) == 0 {
		return hierarchyOf{}, &GitLabError{Kind: NotFound, Message: fmt.Sprintf("no issue #%d in %s", number, project)}
	}
	var h hierarchyOf
	for _, w := range data.Project.WorkItems.Nodes[0].Widgets {
		if w.Typename != "WorkItemWidgetHierarchy" {
			continue
		}
		if w.Parent != nil {
			if r, ok := w.Parent.ref(); ok {
				h.parent = &r
			}
		}
		for _, c := range w.Children.Nodes {
			r, ok := c.ref()
			if !ok {
				continue
			}
			child := PlanChild{Item: Item{Project: r.Project, Number: r.Number, State: map[bool]string{true: "open", false: "closed"}[r.Open],
				Title: c.Title, URL: c.WebURL}, BlockedBy: []Ref{}}
			for _, cw := range c.Widgets {
				for _, l := range cw.LinkedItems.Nodes {
					if b, ok := l.WorkItem.ref(); ok && strings.EqualFold(l.LinkType, "is_blocked_by") {
						child.BlockedBy = append(child.BlockedBy, b)
					}
				}
			}
			h.children = append(h.children, child)
		}
	}
	return h, nil
}

// closedBy are the merge requests that close issue number of project when they merge (#4626).
func (g *RealGitLab) closedBy(ctx context.Context, project string, number int) ([]Linked, error) {
	var mrs []struct {
		IID        int    `json:"iid"`
		Title      string `json:"title"`
		State      string `json:"state"`
		WebURL     string `json:"web_url"`
		References struct {
			Full string `json:"full"`
		} `json:"references"`
	}
	if err := g.get(ctx, fmt.Sprintf("projects/%s/issues/%d/closed_by?per_page=100", pid(project), number), false, &mrs); err != nil {
		return nil, err
	}
	out := []Linked{}
	for _, m := range mrs {
		// references.full is group/project!4; a merge request of this project says only !4.
		path, _, ok := strings.Cut(m.References.Full, "!")
		if !ok || path == "" {
			path = project
		}
		state := map[string]string{"opened": "open", "merged": "merged"}[m.State]
		if state == "" {
			state = "closed"
		}
		out = append(out, Linked{Project: path, Number: m.IID, MR: true, State: state, Title: m.Title, URL: m.WebURL})
	}
	return out, nil
}

// Plan is the issue number of project, its child issues and each one's blockers: one GraphQL
// query, and a REST list for each project the children are in, for their fields.
func (g *RealGitLab) Plan(ctx context.Context, project string, number int) (Plan, error) {
	var j forgeJSON
	if err := g.get(ctx, fmt.Sprintf("projects/%s/issues/%d", pid(project), number), false, &j); err != nil {
		return Plan{}, err
	}
	p := Plan{Epic: j.item(project, false), Children: []PlanChild{}}
	h, err := g.hierarchy(ctx, project, number)
	if err != nil {
		return Plan{}, err
	}
	h.into(&p.Epic)
	read := map[string]Item{}
	var projects []string
	iids := map[string][]string{}
	for _, c := range h.children {
		if _, seen := iids[c.Project]; !seen {
			projects = append(projects, c.Project)
		}
		iids[c.Project] = append(iids[c.Project], strconv.Itoa(c.Number))
	}
	for _, at := range projects {
		q := url.Values{"iids[]": iids[at], "state": {"all"}, "with_labels_details": {"true"}, "per_page": {strconv.Itoa(perPage)}}
		var list []forgeJSON
		if err := g.get(ctx, fmt.Sprintf("projects/%s/issues?%s", pid(at), q.Encode()), false, &list); err != nil {
			return Plan{}, err
		}
		for _, j := range list {
			i := j.item(at, false)
			read[i.key()] = i
		}
	}
	for _, c := range h.children {
		if i, ok := read[c.key()]; ok {
			c.Item = i
		}
		c.ParentProject, c.ParentNumber = project, number
		p.Children = append(p.Children, c)
	}
	return p, nil
}

// BlockersMost bounds the issues one Blockers read asks about.
const BlockersMost = 100

// blockersQuery is the "blocked by" links of many of a project's work items at once (#4242).
const blockersQuery = `query($path: ID!, $iids: [String!], $first: Int) { project(fullPath: $path) { workItems(iids: $iids, first: $first) { nodes { iid
  widgets { __typename ... on WorkItemWidgetLinkedItems { linkedItems(first: 50) { nodes { linkType
    workItem { iid state namespace { fullPath } } } } } } } } } }`

// Blockers are the issues that block each of numbers in project (at most BlockersMost, each with
// at most 50 blockers), in one GraphQL query (#4242): a standing epic's children come from a
// list, which does not read links. A number that is not an issue has none.
func (g *RealGitLab) Blockers(ctx context.Context, project string, numbers []int) (map[int][]Ref, error) {
	out := map[int][]Ref{}
	numbers = numbers[:min(len(numbers), BlockersMost)]
	if len(numbers) == 0 {
		return out, nil
	}
	iids := make([]string, len(numbers))
	for n, i := range numbers {
		iids[n] = strconv.Itoa(i)
	}
	var data struct {
		Project *struct {
			WorkItems struct {
				Nodes []struct {
					IID     string `json:"iid"`
					Widgets []struct {
						LinkedItems struct {
							Nodes []struct {
								LinkType string      `json:"linkType"`
								WorkItem workItemRef `json:"workItem"`
							} `json:"nodes"`
						} `json:"linkedItems"`
					} `json:"widgets"`
				} `json:"nodes"`
			} `json:"workItems"`
		} `json:"project"`
	}
	if err := g.graphql(ctx, blockersQuery, map[string]any{"path": project, "iids": iids, "first": len(iids)}, &data); err != nil {
		return nil, err
	}
	if data.Project == nil {
		return nil, &GitLabError{Kind: NotFound, Message: "no project " + project}
	}
	for _, w := range data.Project.WorkItems.Nodes {
		n, err := strconv.Atoi(w.IID)
		if err != nil {
			continue
		}
		by := []Ref{}
		for _, cw := range w.Widgets {
			for _, l := range cw.LinkedItems.Nodes {
				if b, ok := l.WorkItem.ref(); ok && strings.EqualFold(l.LinkType, "is_blocked_by") {
					by = append(by, b)
				}
			}
		}
		out[n] = by
	}
	return out, nil
}

// parentsQuery is the parent of many of a project's work items at once (#4335).
const parentsQuery = `query($path: ID!, $iids: [String!], $first: Int) { project(fullPath: $path) { workItems(iids: $iids, first: $first) { nodes { iid
  widgets { __typename ... on WorkItemWidgetHierarchy { parent { iid state namespace { fullPath } } } } } } } }`

// Parents are the parent of each of numbers in project that has one (at most BlockersMost), in
// one GraphQL query (#4335): a standing epic's parent: none, as GitLab's REST lists do not say an
// issue's parent. A number that is not an issue, or has no parent, is not in the answer.
func (g *RealGitLab) Parents(ctx context.Context, project string, numbers []int) (map[int]Ref, error) {
	out := map[int]Ref{}
	numbers = numbers[:min(len(numbers), BlockersMost)]
	if len(numbers) == 0 {
		return out, nil
	}
	iids := make([]string, len(numbers))
	for n, i := range numbers {
		iids[n] = strconv.Itoa(i)
	}
	var data struct {
		Project *struct {
			WorkItems struct {
				Nodes []struct {
					IID     string `json:"iid"`
					Widgets []struct {
						Parent *workItemRef `json:"parent"`
					} `json:"widgets"`
				} `json:"nodes"`
			} `json:"workItems"`
		} `json:"project"`
	}
	if err := g.graphql(ctx, parentsQuery, map[string]any{"path": project, "iids": iids, "first": len(iids)}, &data); err != nil {
		return nil, err
	}
	if data.Project == nil {
		return nil, &GitLabError{Kind: NotFound, Message: "no project " + project}
	}
	for _, w := range data.Project.WorkItems.Nodes {
		n, err := strconv.Atoi(w.IID)
		if err != nil {
			continue
		}
		for _, pw := range w.Widgets {
			if pw.Parent == nil {
				continue
			}
			if p, ok := pw.Parent.ref(); ok {
				out[n] = p
			}
		}
	}
	return out, nil
}

// GroupBoard is a group board's scope (#3282): GET /groups/:group/boards/:id. GitLab's own
// milestones "Any", "None", "Upcoming" and "Started" are not one milestone, so they scope
// nothing here.
func (g *RealGitLab) GroupBoard(ctx context.Context, group string, id int) (BoardScope, error) {
	var board struct {
		Labels []struct {
			Name string `json:"name"`
		} `json:"labels"`
		Milestone *struct {
			ID    int    `json:"id"`
			Title string `json:"title"`
		} `json:"milestone"`
	}
	if err := g.get(ctx, fmt.Sprintf("groups/%s/boards/%d", pid(group), id), true, &board); err != nil {
		return BoardScope{}, err
	}
	scope := BoardScope{}
	for _, l := range board.Labels {
		if l.Name != "" {
			scope.Labels = append(scope.Labels, l.Name)
		}
	}
	if m := board.Milestone; m != nil && m.ID > 0 {
		scope.Milestone = m.Title
	}
	return scope, nil
}
