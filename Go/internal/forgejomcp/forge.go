package forgejomcp

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

// The daemon's forge reads (#3753, after GitLab's in #3209): the issues or pull requests of
// many repositories, the last updated first, and one item with its body and a page of its
// comments, in typed reads beside the tools' maps. The daemon puts them in the one model the
// Work pages draw for every forge (wire.ForgeItem).
//
// Forgejo's list across repositories (/repos/issues/search) cannot name the repositories, so a
// list asks each repository (/repos/:owner/:repo/issues, which lists pull requests too), and
// merges them by updated_at. The cursor is a time, not a page, as the gitlab server's: each
// repository is asked for what was updated at or before it, so the pages of many repositories
// go on from one place.

// SearchFilter is what a list lists: pull requests or issues, in state open, closed or all
// (open when ""), narrowed by a label, an assignee's login and words in the title or body, and
// a feature: the name of a feature:<name> label (#3267). A closed pull request includes a
// merged one.
type SearchFilter struct {
	PRs                             bool
	State                           string
	Label, Assignee, Query, Feature string
}

// Item is an issue or a pull request as the forge reads list it.
type Item struct {
	Repo   string
	Number int
	PR     bool
	// State is open, closed or merged.
	State, Title, URL, Author, Milestone, UpdatedAt string
	// CreatedAt is when it opened; ClosedAt when it closed or merged, "" while open (#4373).
	CreatedAt, ClosedAt string
	// AuthorAvatar is the author's picture, on the Forgejo or on Gravatar; "" for none (#4363).
	AuthorAvatar string
	Labels       []string
	LabelColors  map[string]string
	Assignees    []string
	Comments     int
	// A pull request's: Checks is passing, failing, running or none, Review is approved,
	// changes_requested, review_required or "", Mergeable is mergeable, conflicting or unknown.
	// A list says only Draft; one read on its own says the rest.
	Draft, AutoMerge          bool
	Checks, Review, Mergeable string
	// Only one read on its own says these.
	// HeadRef is the branch it merges from and BaseRef the one it merges into; a merged one's
	// MergedBy is who merged it and MergeCommit the commit it made (#4409).
	HeadRef, BaseRef, MergedBy, MergeCommit string
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
	Author, Avatar, Body, At, URL string
	Bot                           bool
}

// CheckRun is one commit status of a pull request's head: State is passing, failing or running.
type CheckRun struct{ Name, State, URL string }

// ItemDetail is an item with its body and a page of its comments (Thread), oldest first in the
// page. Before is the cursor of the page before it, "" at the first comment. CheckRuns are a
// pull request's head's commit statuses, and Head is that commit.
type ItemDetail struct {
	Item
	Body          string
	Thread        []Comment
	Before        string
	CheckRuns     []CheckRun
	ReviewThreads int
	FilesChanged  int
	Head          string
	// On an issue's read (#4626), from its timeline: LinkedPulls are the pull requests that
	// name it, each once, and Events what happened on it, oldest first. Empty when the timeline
	// cannot be read.
	LinkedPulls []Linked
	Events      []Event
	// A pull request's (#4682): its Size (nil when its commits cannot be read, the one read more
	// of its page) and its Reviewers.
	Size      *Size
	Reviewers []Reviewer
}

// Size is a pull request's lines added and deleted, and its commits (#4682).
type Size struct{ Additions, Deletions, Commits int }

// Reviewer is a person or team asked to review a pull request or who reviewed it (#4682): State
// is approved, changes_requested, commented, or pending while asked and not answered.
type Reviewer struct{ Login, Avatar, State string }

// Linked is a pull request that names an issue: State is open, closed or merged.
type Linked struct {
	Repo              string
	Number            int
	Title, State, URL string
}

// Event is one event on an issue's timeline (#4626). Kind is labeled, unlabeled, assigned,
// unassigned, closed, reopened or referenced; Label (with its #rrggbb LabelColor) or Assignee is
// whom it names; Source is the issue or pull request that named it.
type Event struct {
	Kind, Actor, At   string
	Label, LabelColor string
	Assignee          string
	SourceRepo        string
	SourceNumber      int
	SourcePR          bool
}

// forgeComments is a page of an item's comments: Forgejo's own most.
const forgeComments = perPage

type labelJSON struct {
	ID    int    `json:"id"`
	Name  string `json:"name"`
	Color string `json:"color"`
}

// forgeJSON is what an issue says, and a pull request in the issues list.
type forgeJSON struct {
	Number    int         `json:"number"`
	Title     string      `json:"title"`
	Body      string      `json:"body"`
	State     string      `json:"state"`
	HTMLURL   string      `json:"html_url"`
	User      user        `json:"user"`
	Labels    []labelJSON `json:"labels"`
	Assignees []user      `json:"assignees"`
	Milestone *struct {
		Title string `json:"title"`
	} `json:"milestone"`
	UpdatedAt   string `json:"updated_at"`
	CreatedAt   string `json:"created_at"`
	ClosedAt    string `json:"closed_at"`
	Comments    int    `json:"comments"`
	PullRequest *struct {
		Merged   bool   `json:"merged"`
		MergedAt string `json:"merged_at"`
		Draft    bool   `json:"draft"`
	} `json:"pull_request"`
}

func (j forgeJSON) item(repo string) Item {
	i := Item{Repo: repo, Number: j.Number, PR: j.PullRequest != nil, Title: j.Title, URL: j.HTMLURL, Author: j.User.Login,
		AuthorAvatar: j.User.AvatarURL,
		UpdatedAt:    j.UpdatedAt, CreatedAt: j.CreatedAt, Comments: j.Comments, Assignees: []string{}, Labels: []string{}, LabelColors: map[string]string{}}
	i.State = "open"
	switch {
	case j.PullRequest != nil && j.PullRequest.Merged:
		i.State, i.ClosedAt = "merged", cmp.Or(j.PullRequest.MergedAt, j.ClosedAt)
	case j.State == "closed":
		i.State, i.ClosedAt = "closed", j.ClosedAt
	}
	for _, l := range j.Labels {
		i.Labels = append(i.Labels, l.Name)
		if l.Color != "" {
			i.LabelColors[l.Name] = "#" + strings.ToLower(strings.TrimPrefix(l.Color, "#"))
		}
	}
	for _, a := range j.Assignees {
		if a.Login != "" {
			i.Assignees = append(i.Assignees, a.Login)
		}
	}
	if j.Milestone != nil {
		i.Milestone = j.Milestone.Title
	}
	if i.PR {
		i.Draft = j.PullRequest.Draft || pullJSON{Title: j.Title}.draft()
		i.Mergeable = "unknown"
	}
	return i
}

// listCursor is where a list goes on: at or before the time Before, leaving out Seen, the items
// given already that were updated in its second. Forgejo keeps seconds, and its before is
// "at or before".
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
		return c, &ForgejoError{Kind: Failed, Message: "Forgejo: the cursor is not one a list gave"}
	}
	if _, ok := parseTime(c.Before); !ok {
		return c, &ForgejoError{Kind: Failed, Message: "Forgejo: the cursor is not one a list gave"}
	}
	return c, nil
}

// key is an item's name in a cursor's Seen: issues and pull requests share their numbers.
func (i Item) key() string { return i.Repo + "#" + strconv.Itoa(i.Number) }

func updated(i Item) time.Time {
	t, _ := parseTime(i.UpdatedAt)
	return t.Truncate(time.Second)
}

// after is the cursor after item i, given the cursor the page began at and the page to i.
func (c listCursor) after(i Item, page []Item) listCursor {
	t := updated(i)
	next := listCursor{Before: t.UTC().Format(time.RFC3339)}
	if old, ok := parseTime(c.Before); ok && old.Equal(t) {
		next.Seen = append(next.Seen, c.Seen...)
	}
	for _, p := range page {
		if updated(p).Equal(t) && !slices.Contains(next.Seen, p.key()) {
			next.Seen = append(next.Seen, p.key())
		}
	}
	return next
}

// labelsOf are the labels an item must have: Forgejo's labels filter is any of them, so it is
// asked for the first, and the page keeps only the items with all.
func labelsOf(f SearchFilter) []string {
	var labels []string
	if f.Label != "" {
		labels = append(labels, f.Label)
	}
	if f.Feature != "" {
		labels = append(labels, "feature:"+f.Feature)
	}
	return labels
}

// listPath is a repository's list, the last updated first, at or before before.
func listPath(repo string, f SearchFilter, before string, first int) string {
	state := f.State
	if state == "" {
		state = "open"
	}
	q := url.Values{"state": {state}, "type": {map[bool]string{false: "issues", true: "pulls"}[f.PRs]},
		"sort": {"recentupdate"}, "limit": {strconv.Itoa(first)}}
	if before != "" {
		q.Set("before", before)
	}
	if labels := labelsOf(f); len(labels) > 0 {
		q.Set("labels", labels[0])
	}
	if f.Assignee != "" {
		q.Set("assigned_by", f.Assignee)
	}
	if s := strings.TrimSpace(f.Query); s != "" {
		q.Set("q", s)
	}
	return repoPath(repo) + "/issues?" + q.Encode()
}

// hasAll says whether i has every one of labels.
func hasAll(i Item, labels []string) bool {
	for _, l := range labels {
		if !slices.ContainsFunc(i.Labels, func(n string) bool { return strings.EqualFold(n, l) }) {
			return false
		}
	}
	return true
}

// Search is one page of the issues or pull requests of repos, at most first (1 to 50), after
// the cursor after ("" for the first page): one call per repository.
func (f *RealForgejo) Search(ctx context.Context, repos []string, filter SearchFilter, after string, first int) (SearchPage, error) {
	page := SearchPage{Items: []Item{}, Cursors: []string{}}
	if len(repos) == 0 {
		return page, nil
	}
	first = max(1, min(first, perPage))
	c, err := cursorOf(after)
	if err != nil {
		return SearchPage{}, err
	}
	// Each repository gives enough that, with what was seen left out, first are new.
	ask := min(perPage, first+len(c.Seen))
	labels := labelsOf(filter)
	var found []Item
	more := false
	for _, repo := range repos {
		var list []forgeJSON
		if err := f.get(ctx, listPath(repo, filter, c.Before, ask), false, &list); err != nil {
			return SearchPage{}, err
		}
		more = more || len(list) >= ask
		for _, j := range list {
			if i := j.item(repo); i.PR == filter.PRs && !slices.Contains(c.Seen, i.key()) && hasAll(i, labels) {
				found = append(found, i)
			}
		}
	}
	slices.SortStableFunc(found, func(a, b Item) int {
		return cmp.Or(updated(b).Compare(updated(a)), cmp.Compare(a.key(), b.key()))
	})
	if len(found) > first {
		found, more = found[:first], true
	}
	for n, i := range found {
		page.Items = append(page.Items, i)
		page.Cursors = append(page.Cursors, c.after(i, found[:n+1]).text())
	}
	if more && len(page.Items) > 0 {
		page.Next = page.Cursors[len(page.Cursors)-1]
	}
	return page, nil
}

// IsNotFound says whether err is Forgejo's 404.
func IsNotFound(err error) bool {
	e, ok := err.(*ForgejoError)
	return ok && e.Kind == NotFound
}

// checkState is a commit status in the words of a check: passing, failing or running.
func checkState(state string) string {
	switch state {
	case "success", "warning":
		return "passing"
	case "failure", "error":
		return "failing"
	}
	return "running"
}

// ItemPage is an issue or a pull request of repo, with its body, the page of its comments
// before the cursor before (the newest page for ""), and a pull request's commit statuses,
// reviews and files changed.
func (f *RealForgejo) ItemPage(ctx context.Context, repo string, number int, pr bool, before string) (ItemDetail, error) {
	var j forgeJSON
	if err := f.get(ctx, fmt.Sprintf("%s/issues/%d", repoPath(repo), number), false, &j); err != nil {
		return ItemDetail{}, err
	}
	if (j.PullRequest != nil) != pr {
		return ItemDetail{}, &ForgejoError{Kind: NotFound, Message: fmt.Sprintf("%s#%d is not %s", repo, number,
			map[bool]string{false: "an issue", true: "a pull request"}[pr])}
	}
	d := ItemDetail{Item: j.item(repo), Body: j.Body, Thread: []Comment{}}
	// Forgejo lists comments oldest first; the newest page is the last.
	last := max(1, (j.Comments+forgeComments-1)/forgeComments)
	page := last
	if before != "" {
		n, err := strconv.Atoi(before)
		if err != nil || n < 1 || n > last {
			return ItemDetail{}, &ForgejoError{Kind: Failed, Message: "Forgejo: the cursor is not one an item gave"}
		}
		page = n
	}
	var comments []commentJSON
	if err := f.get(ctx, fmt.Sprintf("%s/issues/%d/comments?limit=%d&page=%d", repoPath(repo), number, forgeComments, page), false, &comments); err != nil {
		return ItemDetail{}, err
	}
	if page > 1 {
		d.Before = strconv.Itoa(page - 1)
	}
	for _, c := range comments {
		d.Thread = append(d.Thread, Comment{Author: c.User.Login, Avatar: c.User.AvatarURL, Body: c.Body, At: c.CreatedAt, URL: c.HTMLURL, Bot: isBot(c.User.Login, c.User.ID)})
	}
	if !pr {
		// The timeline is a nicety: a page still reads when Forgejo does not give it.
		d.LinkedPulls, d.Events = []Linked{}, []Event{}
		var timeline []forgeTimelineJSON
		if err := f.get(ctx, fmt.Sprintf("%s/issues/%d/timeline?limit=%d", repoPath(repo), number, perPage), false, &timeline); err == nil {
			d.LinkedPulls, d.Events = timelineOf(repo, timeline)
		}
		return d, nil
	}
	var p struct {
		pullJSON
		ChangedFiles   int `json:"changed_files"`
		Additions      int `json:"additions"`
		Deletions      int `json:"deletions"`
		RequestedTeams []struct {
			Name string `json:"name"`
		} `json:"requested_reviewers_teams"`
	}
	if err := f.get(ctx, fmt.Sprintf("%s/pulls/%d", repoPath(repo), number), false, &p); err != nil {
		return ItemDetail{}, err
	}
	d.Draft = p.draft()
	d.Head, d.FilesChanged = p.Head.SHA, p.ChangedFiles
	d.HeadRef, d.BaseRef = p.Head.Ref, p.Base.Ref
	if d.State == "merged" {
		d.MergeCommit = p.MergeCommitSHA
		if p.MergedBy != nil {
			d.MergedBy = p.MergedBy.Login
		}
	}
	if d.State == "open" {
		d.Mergeable = map[bool]string{true: "mergeable", false: "conflicting"}[p.Mergeable]
	}
	d.CheckRuns = []CheckRun{}
	d.Checks = "none"
	if p.Head.SHA != "" {
		s, err := f.status(ctx, repo, p.Head.SHA)
		if err != nil {
			return ItemDetail{}, err
		}
		for _, st := range s.Statuses {
			d.CheckRuns = append(d.CheckRuns, CheckRun{Name: st.Context, State: checkState(st.State), URL: st.TargetURL})
		}
		if len(s.Statuses) > 0 {
			d.Checks = checkState(s.State)
		}
	}
	reviews, _, err := all[reviewJSON](ctx, f, fmt.Sprintf("%s/pulls/%d/reviews", repoPath(repo), number))
	if err != nil {
		return ItemDetail{}, err
	}
	d.Review, d.ReviewThreads = reviewOf(reviews, len(p.RequestedReviewers) > 0)
	teams := make([]string, 0, len(p.RequestedTeams))
	for _, t := range p.RequestedTeams {
		teams = append(teams, t.Name)
	}
	d.Reviewers = reviewersOf(p.RequestedReviewers, teams, reviews)
	// The commits are the one read more of a pull request's page, and a nicety: without them it
	// has no size.
	if commits, _, err := all[struct {
		SHA string `json:"sha"`
	}](ctx, f, fmt.Sprintf("%s/pulls/%d/commits?verification=false&files=false", repoPath(repo), number)); err == nil {
		d.Size = &Size{Additions: p.Additions, Deletions: p.Deletions, Commits: len(commits)}
	}
	return d, nil
}

// reviewersOf is each reviewer of a pull request once: the people and teams asked and not
// answered since are pending, as Forgejo shows them; the others by their newest review that
// approves or asks for changes, else a comment. A dismissed review, and one not sent yet, say
// nothing.
func reviewersOf(requested []user, teams []string, reviews []reviewJSON) []Reviewer {
	out := []Reviewer{}
	seen := map[string]bool{}
	for _, u := range requested {
		if u.Login != "" && !seen[u.Login] {
			seen[u.Login] = true
			out = append(out, Reviewer{Login: u.Login, Avatar: u.AvatarURL, State: "pending"})
		}
	}
	for _, t := range teams {
		if t != "" && !seen[t] {
			seen[t] = true
			out = append(out, Reviewer{Login: t, State: "pending"})
		}
	}
	newest := map[string]int{}
	for _, r := range reviews {
		state := reviewStates[r.State]
		if r.User == nil || r.User.Login == "" || seen[r.User.Login] || state == "" || r.Dismissed {
			continue
		}
		if i, ok := newest[r.User.Login]; ok {
			// A comment after an approval or a request for changes does not take its place.
			if state != "commented" || out[i].State == "commented" {
				out[i].State = state
			}
			continue
		}
		newest[r.User.Login] = len(out)
		out = append(out, Reviewer{Login: r.User.Login, Avatar: r.User.AvatarURL, State: state})
	}
	return out
}

// reviewStates are Forgejo's review states in the one model's words.
var reviewStates = map[string]string{"APPROVED": "approved", "REQUEST_CHANGES": "changes_requested", "COMMENT": "commented"}

// forgeTimelineJSON is one entry of an issue's timeline. A label entry's body is "1" when the label
// was added and "" when it was taken off; ref_issue is the issue or pull request that named it.
type forgeTimelineJSON struct {
	Type            string     `json:"type"`
	Body            string     `json:"body"`
	User            *user      `json:"user"`
	CreatedAt       string     `json:"created_at"`
	Label           *labelJSON `json:"label"`
	Assignee        *user      `json:"assignee"`
	RemovedAssignee bool       `json:"removed_assignee"`
	RefIssue        *struct {
		forgeJSON
		Repository *struct {
			FullName string `json:"full_name"`
		} `json:"repository"`
	} `json:"ref_issue"`
}

// timelineOf is an issue's linked pull requests and events from its timeline, oldest first. An
// entry of a kind the wire has no word for is left out.
func timelineOf(repo string, timeline []forgeTimelineJSON) ([]Linked, []Event) {
	pulls, events := []Linked{}, []Event{}
	seen := map[string]bool{}
	for _, t := range timeline {
		e := Event{At: t.CreatedAt}
		if t.User != nil {
			e.Actor = t.User.Login
		}
		switch t.Type {
		case "label":
			if t.Label == nil {
				continue
			}
			e.Kind = map[bool]string{true: "labeled", false: "unlabeled"}[t.Body == "1"]
			e.Label = t.Label.Name
			if t.Label.Color != "" {
				e.LabelColor = "#" + strings.ToLower(strings.TrimPrefix(t.Label.Color, "#"))
			}
		case "assignees":
			if t.Assignee == nil {
				continue
			}
			e.Kind = map[bool]string{false: "assigned", true: "unassigned"}[t.RemovedAssignee]
			e.Assignee = t.Assignee.Login
		case "close":
			e.Kind = "closed"
		case "reopen":
			e.Kind = "reopened"
		case "pull_ref", "issue_ref", "comment_ref":
			if t.RefIssue == nil || t.RefIssue.Number < 1 {
				continue
			}
			from := repo
			if t.RefIssue.Repository != nil && t.RefIssue.Repository.FullName != "" {
				from = t.RefIssue.Repository.FullName
			}
			ref := t.RefIssue.item(from)
			e.Kind, e.SourceRepo, e.SourceNumber, e.SourcePR = "referenced", from, ref.Number, ref.PR
			if key := ref.key(); ref.PR && !seen[key] {
				seen[key] = true
				pulls = append(pulls, Linked{Repo: from, Number: ref.Number, Title: ref.Title, State: ref.State, URL: ref.URL})
			}
		default:
			continue
		}
		events = append(events, e)
	}
	return pulls, events
}

// reviewOf is a pull request's review in a list's words, from each reviewer's last review, and
// how many line comments its reviews made.
func reviewOf(reviews []reviewJSON, requested bool) (string, int) {
	last := map[string]string{}
	threads := 0
	for _, r := range reviews {
		threads += r.CommentsCount
		if r.User == nil {
			continue
		}
		switch r.State {
		case "APPROVED", "REQUEST_CHANGES":
			last[r.User.Login] = r.State
		}
	}
	approved := false
	for _, s := range last {
		if s == "REQUEST_CHANGES" {
			return "changes_requested", threads
		}
		approved = true
	}
	switch {
	case requested:
		return "review_required", threads
	case approved:
		return "approved", threads
	}
	return "", threads
}
