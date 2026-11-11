package bitbucketmcp

import (
	"cmp"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"slices"
	"strconv"
	"strings"
	"time"
)

// The daemon's forge reads (#3786, after Forgejo's in #3753): the issues or pull requests of
// many repositories, the last updated first, and one item with its body and a page of its
// comments, in typed reads beside the tools' maps. The daemon puts them in the one model the
// Work pages draw for every forge (wire.ForgeItem).
//
// Bitbucket has no list across repositories, so a list asks each repository, with a BBQL
// filter, and merges them by updated_on. The cursor is a time, as the forgejo server's: each
// repository is asked for what was updated at or before it, so the pages of many repositories
// go on from one place. Bitbucket numbers issues and pull requests apart; a node's kind says
// which it is.
//
// Bitbucket's issues have no labels: an issue's labels are its kind (bug, enhancement,
// proposal, task) and its component, as the events say them. A pull request has none, nor an
// assignee, so a list by a label, a feature or an assignee has no pull requests.

// SearchFilter is what a list lists: pull requests or issues, in state open, closed or all
// (open when ""), narrowed by a label, an assignee's nickname and words in the title or body,
// and a feature: the name of a feature:<name> component (#3267). A closed pull request
// includes a merged one.
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
	// CreatedAt is when it opened (#4373). Bitbucket says no time that it closed or merged, only
	// updated_on, so ClosedAt is always "".
	CreatedAt, ClosedAt string
	// AuthorAvatar is the author's picture, on Atlassian's avatar host or Gravatar; "" for none (#4363).
	AuthorAvatar string
	// StateReason is why a closed issue closed, from its state: completed, not_planned or
	// duplicate; "" for an open issue or a pull request (#4365).
	StateReason string
	Labels      []string
	Assignees   []string
	Comments    int
	// A pull request's: Checks is passing, failing, running or none, Review is approved,
	// changes_requested, review_required or "", Mergeable is mergeable, conflicting or unknown.
	// A list says only Draft and Review; one read on its own says the rest.
	Draft                     bool
	Checks, Review, Mergeable string
	// HeadRef is the branch it merges from and BaseRef the one it merges into; a merged one's
	// MergeCommit is the commit it made (#4409), as Bitbucket gives it (12 hex digits). Bitbucket
	// says nobody that merged it.
	HeadRef, BaseRef, MergeCommit string
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
// Run is the Pipelines run it links to, 0 for another CI's.
type CheckRun struct {
	Name, State, URL string
	Run              int
}

// ItemDetail is an item with its body and a page of its comments (Thread), oldest first in the
// page. Before is the cursor of the page before it, "" at the first comment. CheckRuns are a
// pull request's head's commit statuses, and Head is that commit, as Bitbucket gives it (12
// characters).
type ItemDetail struct {
	Item
	Body          string
	Thread        []Comment
	Before        string
	CheckRuns     []CheckRun
	ReviewThreads int
	FilesChanged  int
	Head          string
}

// participant is a pull request's reviewer or other participant, and what they said.
type participant struct {
	User     user   `json:"user"`
	Role     string `json:"role"`
	Approved bool   `json:"approved"`
	State    string `json:"state"`
}

// forgePullJSON is a pull request with what a list asks for beyond the short form.
type forgePullJSON struct {
	pullJSON
	Participants []participant `json:"participants"`
}

// forgePullFields adds to a list's pull requests what its short form leaves out.
const forgePullFields = pullFields + ",%2Bvalues.participants"

func (p forgePullJSON) item(repo string) Item {
	i := Item{Repo: repo, Number: p.ID, PR: true, Title: p.Title, URL: p.Links.HTML.Href, Author: p.Author.name(), AuthorAvatar: p.Author.avatar(), UpdatedAt: p.UpdatedOn, CreatedAt: p.CreatedOn,
		Comments: p.CommentCount, Labels: []string{}, Assignees: []string{}, Draft: p.Draft, Mergeable: "unknown"}
	switch p.State {
	case "OPEN":
		i.State = "open"
	case "MERGED":
		i.State = "merged"
	default:
		i.State = "closed"
	}
	i.Review = p.review()
	i.HeadRef, i.BaseRef = p.Source.Branch.Name, p.Destination.Branch.Name
	if i.State == "merged" && p.MergeCommit != nil {
		i.MergeCommit = p.MergeCommit.Hash
	}
	return i
}

// review is a pull request's review in a list's words: changes_requested when a participant
// asked for changes, approved when one approved, review_required while reviewers are named and
// none has; "" with no reviewer.
func (p forgePullJSON) review() string {
	approved := false
	for _, r := range p.Participants {
		switch {
		case r.State == "changes_requested":
			return "changes_requested"
		case r.Approved || r.State == "approved":
			approved = true
		}
	}
	switch {
	case approved:
		return "approved"
	case len(p.Reviewers) > 0:
		return "review_required"
	}
	return ""
}

// forgeItem is an issue as a list says it.
func (i issueJSON) forgeItem(repo string) Item {
	it := Item{Repo: repo, Number: i.ID, Title: i.Title, URL: i.Links.HTML.Href, Author: i.Reporter.name(), AuthorAvatar: i.Reporter.avatar(), UpdatedAt: i.UpdatedOn, CreatedAt: i.CreatedOn,
		Labels: i.labels(), Assignees: i.issue().Assignees, State: "open"}
	if closedStates[i.State] {
		it.State, it.StateReason = "closed", stateReasons[i.State]
	}
	if i.Milestone != nil {
		it.Milestone = i.Milestone.Name
	}
	return it
}

// listCursor is where a list goes on: at or before the time Before, leaving out Seen, the items
// given already that were updated at that time.
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
		return c, &BitbucketError{Kind: Failed, Message: "Bitbucket: the cursor is not one a list gave"}
	}
	if _, ok := parseTime(c.Before); !ok {
		return c, &BitbucketError{Kind: Failed, Message: "Bitbucket: the cursor is not one a list gave"}
	}
	return c, nil
}

// key is an item's name in a cursor's Seen.
func (i Item) key() string { return i.Repo + "#" + strconv.Itoa(i.Number) }

func updated(i Item) time.Time {
	t, _ := parseTime(i.UpdatedAt)
	return t
}

// bbqlTime is a time as BBQL compares it: UTC, to the microsecond Bitbucket keeps.
func bbqlTime(t time.Time) string { return t.UTC().Format("2006-01-02T15:04:05.999999Z07:00") }

// after is the cursor after item i, given the cursor the page began at and the page to i.
func (c listCursor) after(i Item, page []Item) listCursor {
	t := updated(i)
	next := listCursor{Before: bbqlTime(t)}
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

// labelsOf are the labels an item must have: a kind or a component each.
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

// none says whether a filter can match no pull request: they have no labels or assignee.
func (f SearchFilter) none() bool {
	return f.PRs && (f.Label != "" || f.Feature != "" || f.Assignee != "")
}

// listPath is a repository's list, the last updated first, at or before before. The assignee
// is matched on the page, as a list says it, not in BBQL.
func listPath(repo string, f SearchFilter, before string, first int) string {
	var q []string
	words := strings.TrimSpace(f.Query)
	if f.PRs {
		if words != "" {
			q = append(q, fmt.Sprintf("(title ~ %q OR description ~ %q)", words, words))
		}
	} else {
		switch f.State {
		case "", "open":
			q = append(q, openIssues)
		case "closed":
			q = append(q, closedIssues)
		}
		for _, l := range labelsOf(f) {
			q = append(q, fmt.Sprintf("(kind=%q OR component.name=%q)", l, l))
		}
		if words != "" {
			q = append(q, fmt.Sprintf("(title ~ %q OR content.raw ~ %q)", words, words))
		}
	}
	if before != "" {
		q = append(q, "updated_on<="+before)
	}
	path := fmt.Sprintf("%s/issues?sort=-updated_on&pagelen=%d", repoPath(repo), first)
	if f.PRs {
		states := map[string]string{"": "state=OPEN", "open": "state=OPEN", "closed": "state=MERGED&state=DECLINED&state=SUPERSEDED",
			"all": "state=OPEN&state=MERGED&state=DECLINED&state=SUPERSEDED"}[f.State]
		if states == "" {
			states = "state=OPEN"
		}
		path = fmt.Sprintf("%s/pullrequests?%s&sort=-updated_on&pagelen=%d&%s", repoPath(repo), states, first, forgePullFields)
	}
	if len(q) > 0 {
		path += "&" + bbql(strings.Join(q, " AND "))
	}
	return path
}

// list is one repository's page of a list.
func (b *RealBitbucket) list(ctx context.Context, repo string, f SearchFilter, before string, first int) ([]Item, error) {
	path := listPath(repo, f, before, first)
	var items []Item
	if f.PRs {
		var page paged[forgePullJSON]
		if err := b.get(ctx, path, false, &page); err != nil {
			return nil, err
		}
		for _, p := range page.Values {
			items = append(items, p.item(repo))
		}
		return items, nil
	}
	var page paged[issueJSON]
	if err := b.get(ctx, path, false, &page); err != nil {
		if noTracker(err) {
			// A repository with its issue tracker off has no issues.
			return nil, nil
		}
		return nil, err
	}
	for _, i := range page.Values {
		items = append(items, i.forgeItem(repo))
	}
	return items, nil
}

// Search is one page of the issues or pull requests of repos, at most first (1 to 50), after
// the cursor after ("" for the first page): one call per repository.
func (b *RealBitbucket) Search(ctx context.Context, repos []string, filter SearchFilter, after string, first int) (SearchPage, error) {
	page := SearchPage{Items: []Item{}, Cursors: []string{}}
	if len(repos) == 0 || filter.none() {
		return page, nil
	}
	first = max(1, min(first, perPage))
	c, err := cursorOf(after)
	if err != nil {
		return SearchPage{}, err
	}
	// Each repository gives enough that, with what was seen left out, first are new.
	ask := min(perPage, first+len(c.Seen))
	var found []Item
	more := false
	for _, repo := range repos {
		list, err := b.list(ctx, repo, filter, c.Before, ask)
		if err != nil {
			return SearchPage{}, err
		}
		more = more || len(list) >= ask
		for _, i := range list {
			if slices.Contains(c.Seen, i.key()) {
				continue
			}
			if filter.Assignee != "" && !slices.ContainsFunc(i.Assignees, func(a string) bool { return strings.EqualFold(a, filter.Assignee) }) {
				continue
			}
			found = append(found, i)
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

// IsNotFound says whether err is Bitbucket's 404.
func IsNotFound(err error) bool {
	e, ok := err.(*BitbucketError)
	return ok && e.Kind == NotFound
}

// checkState is a commit status in the words of a check: passing, failing or running.
func checkState(state string) string {
	switch state {
	case "SUCCESSFUL", "STOPPED", "success":
		return "passing"
	case "FAILED", "failure":
		return "failing"
	}
	return "running"
}

// PipelineRun is the Pipelines run (its build number) a status's link names, 0 for another CI's.
func PipelineRun(link string) int {
	if m := pipelinesRun.FindStringSubmatch(link); m != nil {
		n, _ := strconv.Atoi(m[1])
		return n
	}
	return 0
}

// forgeComments is a page of an item's comments: Bitbucket's most.
const forgeComments = perPage

// ItemPage is an issue or a pull request of repo, with its body, the page of its comments
// before the cursor before (the newest page for ""), and a pull request's commit statuses,
// reviews and files changed.
func (b *RealBitbucket) ItemPage(ctx context.Context, repo string, number int, pr bool, before string) (ItemDetail, error) {
	page := 1
	if before != "" {
		n, err := strconv.Atoi(before)
		if err != nil || n < 2 {
			return ItemDetail{}, &BitbucketError{Kind: Failed, Message: "Bitbucket: the cursor is not one an item gave"}
		}
		page = n
	}
	kind := map[bool]string{false: "issues", true: "pullrequests"}[pr]
	var d ItemDetail
	var p forgePullJSON
	if pr {
		if err := b.get(ctx, fmt.Sprintf("%s/pullrequests/%d", repoPath(repo), number), false, &p); err != nil {
			return ItemDetail{}, err
		}
		d = ItemDetail{Item: p.item(repo), Body: p.Description}
	} else {
		var i issueJSON
		if err := b.get(ctx, fmt.Sprintf("%s/issues/%d", repoPath(repo), number), false, &i); err != nil {
			return ItemDetail{}, err
		}
		d = ItemDetail{Item: i.forgeItem(repo), Body: i.Content.Raw}
	}
	d.Thread = []Comment{}
	// The newest page first: Bitbucket sorts by created_on, and the page is given oldest first.
	var comments struct {
		paged[commentJSON]
		Size int `json:"size"`
	}
	path := fmt.Sprintf("%s/%s/%d/comments?sort=-created_on&pagelen=%d&page=%d", repoPath(repo), kind, number, forgeComments, page)
	if err := b.get(ctx, path, false, &comments); err != nil {
		return ItemDetail{}, err
	}
	if comments.Next != "" {
		d.Before = strconv.Itoa(page + 1)
	}
	if !pr {
		d.Comments = comments.Size
	}
	for _, c := range slices.Backward(comments.Values) {
		if c.Inline != nil {
			if c.Parent == nil && c.Resolution == nil && !c.Deleted {
				d.ReviewThreads++
			}
			continue
		}
		// A change to an issue with no words is a comment too.
		if c.Deleted || strings.TrimSpace(c.Content.Raw) == "" {
			continue
		}
		var by user
		if c.User != nil {
			by = *c.User
		}
		d.Thread = append(d.Thread, Comment{Author: by.name(), Avatar: by.avatar(), Body: c.Content.Raw, At: c.CreatedOn, URL: c.Links.HTML.Href, Bot: isBot(by.name(), by.Type)})
	}
	if !pr {
		return d, nil
	}
	d.Head = p.Source.hash()
	files, _, err := all[struct {
		Status string `json:"status"`
	}](ctx, b, fmt.Sprintf("%s/pullrequests/%d/diffstat", repoPath(repo), number), false)
	if err != nil {
		return ItemDetail{}, err
	}
	d.FilesChanged = len(files)
	if d.State == "open" {
		d.Mergeable = "mergeable"
		for _, f := range files {
			if conflictStates[f.Status] {
				d.Mergeable = "conflicting"
			}
		}
	}
	d.CheckRuns = []CheckRun{}
	d.Checks = "none"
	if d.Head != "" {
		statuses, err := b.statuses(ctx, repo, d.Head, false)
		if err != nil {
			return ItemDetail{}, err
		}
		for _, s := range statuses {
			d.CheckRuns = append(d.CheckRuns, CheckRun{Name: s.title(), State: checkState(s.State), URL: s.URL, Run: PipelineRun(s.URL)})
		}
		if state := combined(statuses); state != "" {
			d.Checks = checkState(state)
		}
	}
	return d, nil
}
