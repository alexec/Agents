package azuredevopsmcp

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

// The daemon's forge reads (#3803, after Bitbucket's in #3786): the pull requests of many
// repositories, the last updated first, and one pull request with its description and a page
// of its comments, in typed reads beside the tools' maps. The daemon puts them in the one model
// the Work pages draw for every forge (wire.ForgeItem). The issues are Azure Boards' work
// items, which the azureboards server reads (#3815).
//
// Azure DevOps has no list across repositories, and a pull request has no time of its last
// change: a list asks each repository, a status at a time (active; completed and abandoned),
// newest first as Azure DevOps lists them, and merges them by the time each was opened or
// closed. The cursor is how far each of these lists was read. Azure DevOps cannot filter a
// list by a tag or by words, so the list is filtered here, a page of perPage at a time.

// SearchFilter is what a list lists: the pull requests in state open, closed or all (open when
// ""), narrowed by a tag (label), words in the title or description, and a feature: the name
// of a feature:<name> tag (#3267). A closed pull request includes a completed one. A pull
// request has no assignee, so a list by one is empty.
type SearchFilter struct {
	State                           string
	Label, Assignee, Query, Feature string
}

// Item is a pull request as the forge reads list it.
type Item struct {
	Repo   string
	Number int
	// State is open, closed or merged.
	State, Title, URL, Author, UpdatedAt string
	Labels                               []string
	Comments                             int
	// Checks is passing, failing, running or none, Review is approved, changes_requested,
	// review_required or "", Mergeable is mergeable, conflicting or unknown. A list says no
	// Checks; one read on its own does.
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

// Comment is a comment on a pull request, as Markdown.
type Comment struct {
	Author, Body, At, URL string
	Bot                   bool
}

// CheckRun is the newest Azure Pipelines build of a pipeline for the pull request, or the
// newest status of a context another service set on it: State is passing, failing or running.
// Build is the build's id, 0 for a status.
type CheckRun struct {
	Name, State, URL string
	Build            int
}

// ItemDetail is a pull request with its description and a page of its comments (Thread),
// oldest first in the page. Before is the cursor of the page before it, "" at the first
// comment. ReviewThreads is the threads on lines of the diff that are not resolved.
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

// forgePullJSON is a pull request with what the forge reads ask for beyond the events'.
type forgePullJSON struct {
	pullJSON
	AutoCompleteSetBy *identity `json:"autoCompleteSetBy"`
}

func (f *RealAzureDevOps) item(repo string, p forgePullJSON) Item {
	i := Item{Repo: repo, Number: p.ID, Title: p.Title, URL: f.prURL(repo, p.ID), Author: p.CreatedBy.name(), UpdatedAt: p.updated(),
		Labels: p.labels(), Draft: p.IsDraft, AutoMerge: p.AutoCompleteSetBy != nil, Review: p.review(), Mergeable: "unknown"}
	switch p.Status {
	case "active":
		i.State = "open"
		switch p.MergeStatus {
		case "conflicts":
			i.Mergeable = "conflicting"
		case "succeeded":
			i.Mergeable = "mergeable"
		}
	case "completed":
		i.State = "merged"
	default:
		i.State = "closed"
	}
	return i
}

// updated is the newest time a pull request says: when it closed, else when it was opened.
func (p forgePullJSON) updated() string {
	if p.ClosedDate != "" {
		return p.ClosedDate
	}
	return p.CreationDate
}

// review is a pull request's review in a list's words: changes_requested when a reviewer
// rejected it or waits for its author, approved when one approved (with suggestions too),
// review_required while a reviewer is named and none has voted; "" with no reviewer.
func (p forgePullJSON) review() string {
	approved := false
	for _, r := range p.Reviewers {
		switch {
		case r.Vote < 0:
			return "changes_requested"
		case r.Vote > 0:
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

// listStatuses are the lists, by Azure DevOps's searchCriteria.status, that a state reads.
func listStatuses(state string) []string {
	switch state {
	case "closed":
		return []string{"completed", "abandoned"}
	case "all":
		return []string{"all"}
	}
	return []string{"active"}
}

// labelsOf are the tags a pull request must have.
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

// matches says whether a pull request is one the filter lists.
func (f SearchFilter) matches(i Item, description string) bool {
	for _, l := range labelsOf(f) {
		if !slices.ContainsFunc(i.Labels, func(have string) bool { return strings.EqualFold(have, l) }) {
			return false
		}
	}
	words := strings.ToLower(strings.TrimSpace(f.Query))
	return words == "" || strings.Contains(strings.ToLower(i.Title), words) || strings.Contains(strings.ToLower(description), words)
}

// listCursor is how far each list was read: the pull requests of repo|status before Skip are
// given, or are not the filter's.
type listCursor map[string]int

func (c listCursor) text() string {
	b, _ := json.Marshal(c)
	return base64.RawURLEncoding.EncodeToString(b)
}

func cursorOf(s string) (listCursor, error) {
	c := listCursor{}
	if s == "" {
		return c, nil
	}
	b, err := base64.RawURLEncoding.DecodeString(s)
	if err != nil || json.Unmarshal(b, &c) != nil {
		return nil, &AzureDevOpsError{Kind: Failed, Message: "Azure DevOps: the cursor is not one a list gave"}
	}
	for _, n := range c {
		if n < 0 {
			return nil, &AzureDevOpsError{Kind: Failed, Message: "Azure DevOps: the cursor is not one a list gave"}
		}
	}
	return c, nil
}

// listPages bounds the pages of one list a page of a search reads, when the filter leaves
// most of them out.
const listPages = 3

// found is a pull request the filter lists, and its place in its list.
type found struct {
	item Item
	at   int
}

// source is one list of a search: what it found from its cursor, where its reading ended, and
// whether that was its end.
type source struct {
	key   string
	found []found
	end   int
	done  bool
}

// read reads one list from skip until it has first that the filter lists, or its end.
func (f *RealAzureDevOps) read(ctx context.Context, repo, status string, filter SearchFilter, skip, first int) (source, error) {
	s := source{key: repo + "|" + status, end: skip}
	for range listPages {
		q := url.Values{"searchCriteria.status": {status}, "$top": {strconv.Itoa(perPage)}, "$skip": {strconv.Itoa(s.end)}}
		var list struct {
			Value []forgePullJSON `json:"value"`
		}
		if err := f.get(ctx, api(repoPath(repo)+"/pullrequests", q), false, &list); err != nil {
			return source{}, err
		}
		for n, p := range list.Value {
			if i := f.item(repo, p); filter.matches(i, p.Description) {
				s.found = append(s.found, found{i, s.end + n})
			}
		}
		s.end += len(list.Value)
		if len(list.Value) < perPage {
			s.done = true
			return s, nil
		}
		if len(s.found) >= first {
			return s, nil
		}
	}
	return s, nil
}

func updated(i Item) time.Time {
	t, _ := parseTime(i.UpdatedAt)
	return t
}

// Search is one page of the pull requests of repos (organization/project/name), at most first
// (1 to 100), after the cursor after ("" for the first page): a call or more per list.
func (f *RealAzureDevOps) Search(ctx context.Context, repos []string, filter SearchFilter, after string, first int) (SearchPage, error) {
	page := SearchPage{Items: []Item{}, Cursors: []string{}}
	if len(repos) == 0 || filter.Assignee != "" {
		return page, nil
	}
	first = max(1, min(first, perPage))
	c, err := cursorOf(after)
	if err != nil {
		return SearchPage{}, err
	}
	var sources []source
	for _, repo := range repos {
		for _, status := range listStatuses(filter.State) {
			s, err := f.read(ctx, repo, status, filter, c[repo+"|"+status], first)
			if err != nil {
				return SearchPage{}, err
			}
			sources = append(sources, s)
		}
	}
	// The newest of each list's next, in turn: each list is newest first already.
	taken := make([]int, len(sources))
	for len(page.Items) < first {
		best := -1
		for n, s := range sources {
			if taken[n] == len(s.found) {
				continue
			}
			if best < 0 || cmp.Or(updated(sources[best].found[taken[best]].item).Compare(updated(s.found[taken[n]].item)),
				cmp.Compare(s.key, sources[best].key)) < 0 {
				best = n
			}
		}
		if best < 0 {
			break
		}
		page.Items = append(page.Items, sources[best].found[taken[best]].item)
		taken[best]++
		page.Cursors = append(page.Cursors, cursorAfter(c, sources, taken).text())
	}
	for n, s := range sources {
		if taken[n] < len(s.found) || !s.done {
			if len(page.Items) > 0 {
				page.Next = page.Cursors[len(page.Cursors)-1]
			} else if !s.done {
				// None of what was read is the filter's: go on after it.
				page.Next = cursorAfter(c, sources, taken).text()
			}
			break
		}
	}
	return page, nil
}

// cursorAfter is where each list goes on once taken of its found are given: at the first it
// found and did not give, else where its reading ended.
func cursorAfter(from listCursor, sources []source, taken []int) listCursor {
	next := listCursor{}
	for k, v := range from {
		next[k] = v
	}
	for n, s := range sources {
		if taken[n] < len(s.found) {
			next[s.key] = s.found[taken[n]].at
		} else {
			next[s.key] = s.end
		}
	}
	return next
}

// IsNotFound says whether err is Azure DevOps's 404.
func IsNotFound(err error) bool {
	e, ok := err.(*AzureDevOpsError)
	return ok && e.Kind == NotFound
}

// buildState is a build in the words of a check: passing, failing or running. A build
// canceled failed; one that partly succeeded passed, with its warnings on its page.
func buildState(b buildJSON) string {
	switch {
	case b.Status != "completed":
		return "running"
	case b.Result == "failed" || b.Result == "canceled":
		return "failing"
	}
	return "passing"
}

// statusState is a status in the words of a check; "" for one that does not apply.
func statusState(state string) string {
	switch state {
	case "succeeded":
		return "passing"
	case "failed", "error":
		return "failing"
	case "notApplicable":
		return ""
	}
	return "running"
}

// combinedChecks is the checks' state: failing when one fails, running while one runs, else
// passing; none with no check.
func combinedChecks(runs []CheckRun) string {
	state := "none"
	for _, r := range runs {
		switch {
		case r.State == "failing":
			return "failing"
		case r.State == "running":
			state = "running"
		case state == "none":
			state = "passing"
		}
	}
	return state
}

// forgeComments is a page of a pull request's comments.
const forgeComments = 50

// checkRuns are a pull request's checks: the newest build of each pipeline of its merge, and
// the newest status of each context.
func (f *RealAzureDevOps) checkRuns(ctx context.Context, repo string, number int) ([]CheckRun, error) {
	builds, err := f.newestBuilds(ctx, repo, fmt.Sprintf("refs/pull/%d/merge", number))
	if err != nil {
		return nil, err
	}
	runs := []CheckRun{}
	for _, b := range builds {
		runs = append(runs, CheckRun{Name: b.Definition.Name, State: buildState(b), URL: b.Links.Web.Href, Build: b.ID})
	}
	statuses, err := f.statuses(ctx, repo, number, false)
	if err != nil {
		return nil, err
	}
	newest := map[string]statusJSON{}
	for _, s := range statuses {
		if had, ok := newest[s.name()]; !ok || s.ID > had.ID {
			newest[s.name()] = s
		}
	}
	names := make([]string, 0, len(newest))
	for name := range newest {
		names = append(names, name)
	}
	slices.Sort(names)
	for _, name := range names {
		if state := statusState(newest[name].State); state != "" {
			runs = append(runs, CheckRun{Name: name, State: state, URL: newest[name].TargetURL})
		}
	}
	return runs, nil
}

// iteration is a pull request's push: its head commit, its target's, and their merge base.
type iteration struct {
	ID              int        `json:"id"`
	SourceRefCommit *commitRef `json:"sourceRefCommit"`
	TargetRefCommit *commitRef `json:"targetRefCommit"`
	CommonRefCommit *commitRef `json:"commonRefCommit"`
}

// newestIteration is a pull request's last push; its ID is 0 when Azure DevOps says none.
func (f *RealAzureDevOps) newestIteration(ctx context.Context, repo string, number int) (iteration, error) {
	var list struct {
		Value []iteration `json:"value"`
	}
	if err := f.get(ctx, api(fmt.Sprintf("%s/pullRequests/%d/iterations", repoPath(repo), number), nil), false, &list); err != nil {
		return iteration{}, err
	}
	var last iteration
	for _, i := range list.Value {
		if i.ID > last.ID {
			last = i
		}
	}
	return last, nil
}

// changeJSON is a file a pull request changes.
type changeJSON struct {
	ChangeType   string `json:"changeType"`
	OriginalPath string `json:"originalPath"`
	Item         struct {
		Path          string `json:"path"`
		GitObjectType string `json:"gitObjectType"`
		IsFolder      bool   `json:"isFolder"`
	} `json:"item"`
}

// maxChanges bounds the files of a pull request that are read.
const maxChanges = 1000

// changes are the files a pull request's newest push changes, against its target: folders
// are not files.
func (f *RealAzureDevOps) changes(ctx context.Context, repo string, number, iter int) ([]changeJSON, error) {
	var list struct {
		ChangeEntries []changeJSON `json:"changeEntries"`
	}
	q := url.Values{"$compareTo": {"0"}, "$top": {strconv.Itoa(maxChanges)}}
	if err := f.get(ctx, api(fmt.Sprintf("%s/pullRequests/%d/iterations/%d/changes", repoPath(repo), number, iter), q), false, &list); err != nil {
		return nil, err
	}
	out := []changeJSON{}
	for _, c := range list.ChangeEntries {
		if !c.Item.IsFolder && c.Item.GitObjectType != "tree" {
			out = append(out, c)
		}
	}
	return out, nil
}

// ItemPage is a pull request of repo, with its description, the page of its comments before
// the cursor before (the newest page for ""), its checks, the threads on its lines not
// resolved, and the files it changes.
func (f *RealAzureDevOps) ItemPage(ctx context.Context, repo string, number int, before string) (ItemDetail, error) {
	var p forgePullJSON
	if err := f.get(ctx, api(fmt.Sprintf("%s/pullrequests/%d", repoPath(repo), number), nil), false, &p); err != nil {
		return ItemDetail{}, err
	}
	d := ItemDetail{Item: f.item(repo, p), Body: p.Description, Thread: []Comment{}, Head: p.head()}
	threads, err := f.threads(ctx, repo, number, false)
	if err != nil {
		return ItemDetail{}, err
	}
	// The comments not on a line, oldest first; Azure DevOps gives them all at once.
	var all []Comment
	for _, t := range threads {
		if t.IsDeleted {
			continue
		}
		if t.onALine() {
			if !t.resolved() {
				d.ReviewThreads++
			}
			continue
		}
		for _, c := range t.Comments {
			if c.IsDeleted || c.CommentType == "system" || strings.TrimSpace(c.Content) == "" {
				continue
			}
			all = append(all, Comment{Author: c.Author.name(), Body: c.Content, At: c.PublishedDate,
				URL: fmt.Sprintf("%s?discussionId=%d", f.prURL(repo, number), t.ID), Bot: isBot(c.Author)})
		}
	}
	slices.SortStableFunc(all, func(a, b Comment) int {
		ta, _ := parseTime(a.At)
		tb, _ := parseTime(b.At)
		return ta.Compare(tb)
	})
	d.Comments = len(all)
	end := len(all)
	if before != "" {
		n, err := strconv.Atoi(before)
		if err != nil || n <= 0 || n > len(all) {
			return ItemDetail{}, &AzureDevOpsError{Kind: Failed, Message: "Azure DevOps: the cursor is not one a pull request gave"}
		}
		end = n
	}
	start := max(0, end-forgeComments)
	d.Thread = append(d.Thread, all[start:end]...)
	if start > 0 {
		d.Before = strconv.Itoa(start)
	}
	if d.CheckRuns, err = f.checkRuns(ctx, repo, number); err != nil {
		return ItemDetail{}, err
	}
	d.Checks = combinedChecks(d.CheckRuns)
	last, err := f.newestIteration(ctx, repo, number)
	if err != nil {
		return ItemDetail{}, err
	}
	if last.ID > 0 {
		files, err := f.changes(ctx, repo, number, last.ID)
		if err != nil {
			return ItemDetail{}, err
		}
		d.FilesChanged = len(files)
	}
	return d, nil
}
