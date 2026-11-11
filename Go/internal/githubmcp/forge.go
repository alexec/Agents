package githubmcp

import (
	"context"
	"fmt"
	"strings"
)

// The daemon's forge reads (#3129): the issues and pull requests of many repos in one search,
// and one item with its body and a page of its comments. The daemon puts them in the one model
// the Work pages draw for every forge (wire.ForgeItem); the views' own reads stay as they are.
// One GraphQL search for every repo, not a call per repo, so a person with 20 folders on 20
// repos costs one call a refresh.

// SearchFilter is what a search lists: pull requests or issues, in state open, closed or all
// (open when ""), narrowed by a label, an assignee's login and words, and by a feature: the
// name of a feature:<name> label (#3267), and by a GitHub Projects board: Project is its
// <owner>/<number> (#3282).
type SearchFilter struct {
	PRs                                      bool
	State                                    string
	Label, Assignee, Query, Feature, Project string
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
	// AuthorAvatar is the author's picture (avatars.githubusercontent.com), "" for none (#4363).
	AuthorAvatar string
	// StateReason is why a closed issue closed: completed, not_planned or duplicate; "" for an
	// open issue, a pull request, or none (#4365).
	StateReason string
	Labels      []string
	LabelColors map[string]string
	Assignees   []string
	Comments    int
	// A pull request's: Checks is passing, failing, running or none; Review is approved,
	// changes_requested, review_required or ""; Mergeable is mergeable, conflicting or unknown.
	Draft, AutoMerge          bool
	Checks, Review, Mergeable string
	// An issue's place in the hierarchy (#3267): the issue it is a sub-issue of (ParentRepo ""
	// for none), and its sub-issues, SubDone of them closed.
	ParentRepo        string
	ParentNumber      int
	SubTotal, SubDone int
}

// SearchPage is a page of a search, the last updated first. Cursors[i] goes on after Items[i],
// so a caller that keeps only some of the page (the daemon, merging forges by time, #3209) goes
// on from the last it kept; Next is the cursor of the page after it, "" at the end.
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

// Check is one of a pull request's checks: State is passing, failing, running or skipped.
type Check struct{ Name, State, URL string }

// ItemDetail is an item with its body and a page of its comments (Thread), oldest first in the
// page. Before is the cursor of the page before it, "" at the first comment. CheckRuns are a pull
// request's checks, each one. Head is its head commit, which a merge or a review names (#3130);
// MergeMethods are merge, squash or rebase, as the repo allows them, the default first.
type ItemDetail struct {
	Item
	// An issue's own (#4373): its sub-issues, the pull requests that close it, and its newest
	// timeline events, oldest first.
	Children, LinkedPulls []Linked
	Events                []Event
	Body                  string
	Thread                []Comment
	Before                string
	CheckRuns             []Check
	ReviewThreads         int
	FilesChanged          int
	Head                  string
	MergeMethods          []string
}

// Linked is an item an issue names: a sub-issue, or a pull request that closes it (#4373). State
// is open, closed or merged.
type Linked struct {
	Repo              string
	Number            int
	PR                bool
	Title, State, URL string
}

// Event is one event on an issue's timeline (#4373). Kind is labeled, unlabeled, assigned,
// unassigned, closed, reopened or referenced; Label (with its #rrggbb LabelColor) or Assignee is
// whom it names; Source is the issue or pull request that referenced it, or that closed it.
type Event struct {
	Kind, Actor, At   string
	Label, LabelColor string
	Assignee          string
	SourceRepo        string
	SourceNumber      int
	SourcePR          bool
}

// Events are at most issueTimeline of an issue's newest, and at most issueLinked of its sub-issues
// and of the pull requests that close it.
const (
	issueTimeline = 100
	issueLinked   = 50
)

// linkedFields are what a sub-issue and a closing pull request say on an issue's read.
const linkedFields = `number title url repository { nameWithOwner }`

// issueReadFields are an issue's own read (#4373): its sub-issues, the pull requests that close
// it, and its timeline's events of the kinds the one model has.
var issueReadFields = fmt.Sprintf(`children: subIssues(first: %[1]d) { nodes { issueState: state `+linkedFields+` } }
  linkedPulls: closedByPullRequestsReferences(first: %[1]d, includeClosedPrs: true) { nodes { pullState: state `+linkedFields+` } }
  events: timelineItems(last: %[2]d, itemTypes: [LABELED_EVENT, UNLABELED_EVENT, ASSIGNED_EVENT, UNASSIGNED_EVENT, CLOSED_EVENT, REOPENED_EVENT, CROSS_REFERENCED_EVENT]) {
    nodes { __typename
      ... on LabeledEvent { actor { login } createdAt label { name color } }
      ... on UnlabeledEvent { actor { login } createdAt label { name color } }
      ... on AssignedEvent { actor { login } createdAt assignee { `+assigneeFields+` } }
      ... on UnassignedEvent { actor { login } createdAt assignee { `+assigneeFields+` } }
      ... on ClosedEvent { actor { login } createdAt closer { __typename ... on PullRequest { number repository { nameWithOwner } } } }
      ... on ReopenedEvent { actor { login } createdAt }
      ... on CrossReferencedEvent { actor { login } createdAt source { __typename
        ... on Issue { number repository { nameWithOwner } } ... on PullRequest { number repository { nameWithOwner } } } } } }`,
	issueLinked, issueTimeline)

// assigneeFields are an Assignee's login, which each of its types has.
const assigneeFields = `... on User { login } ... on Bot { login } ... on Mannequin { login } ... on Organization { login }`

// itemFields are what an issue and a pull request both say, in a search and on their own. Their
// states are of two types, so each has its own name: issueState and pullState.
const itemFields = `number title url createdAt closedAt updatedAt author { login __typename avatarUrl } repository { nameWithOwner }
  ` + labelFields + ` assignees(first: 20) { nodes { login } } milestone { title } commentCount: comments { totalCount }`

// issueFields are an issue's own: its parent and how many of its sub-issues are closed (#3267),
// and why it closed (#4365).
const issueFields = `parent { number repository { nameWithOwner } } subIssuesSummary { total completed } stateReason`

// pullFields are a pull request's own, for a list: its checks in one word, not each of them.
const pullFields = `isDraft mergeable reviewDecision autoMergeRequest { enabledAt }
  checkState: commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }`

const searchQuery = `query($q: String!, $first: Int!, $after: String) {
  search(query: $q, type: ISSUE, first: $first, after: $after) { pageInfo { hasNextPage endCursor } edges { cursor node {
    __typename ... on Issue { issueState: state ` + itemFields + ` ` + issueFields + ` }
    ... on PullRequest { pullState: state ` + itemFields + ` ` + pullFields + ` } } } } }`

// commentFields are the newest page of an item's comments, before $before.
const commentFields = `comments(last: 50, before: $before) { pageInfo { hasPreviousPage startCursor }
  nodes { author { login __typename avatarUrl } body createdAt url } }`

var itemQuery = `query($owner: String!, $name: String!, $number: Int!, $before: String) {
  repository(owner: $owner, name: $name) { issueOrPullRequest(number: $number) {
    __typename ... on Issue { issueState: state ` + itemFields + ` ` + issueFields + ` body ` + commentFields + `
      ` + issueReadFields + ` }
    ... on PullRequest { pullState: state ` + itemFields + ` ` + pullFields + ` body ` + commentFields + `
      reviewThreads { totalCount } changedFiles headRefOid ` + rollupFields + ` } }
    viewerDefaultMergeMethod squashMergeAllowed mergeCommitAllowed rebaseMergeAllowed } }`

type gqlItem struct {
	Typename   string `json:"__typename"`
	Number     int    `json:"number"`
	Title      string `json:"title"`
	URL        string `json:"url"`
	IssueState string `json:"issueState"`
	// StateReason is an issue's COMPLETED, NOT_PLANNED, DUPLICATE or REOPENED.
	StateReason string    `json:"stateReason"`
	PullState   string    `json:"pullState"`
	UpdatedAt   string    `json:"updatedAt"`
	CreatedAt   string    `json:"createdAt"`
	ClosedAt    string    `json:"closedAt"`
	Author      *gqlActor `json:"author"`
	Repository  struct {
		NameWithOwner string `json:"nameWithOwner"`
	} `json:"repository"`
	Labels    gqlLabels `json:"labels"`
	Assignees struct {
		Nodes []gqlActor `json:"nodes"`
	} `json:"assignees"`
	Milestone *struct {
		Title string `json:"title"`
	} `json:"milestone"`
	CommentCount struct {
		TotalCount int `json:"totalCount"`
	} `json:"commentCount"`
	IsDraft    bool      `json:"isDraft"`
	Mergeable  string    `json:"mergeable"`
	Review     string    `json:"reviewDecision"`
	AutoMerge  *struct{} `json:"autoMergeRequest"`
	CheckState struct {
		Nodes []struct {
			Commit struct {
				StatusCheckRollup *struct {
					State string `json:"state"`
				} `json:"statusCheckRollup"`
			} `json:"commit"`
		} `json:"nodes"`
	} `json:"checkState"`
	Parent *struct {
		Number     int `json:"number"`
		Repository struct {
			NameWithOwner string `json:"nameWithOwner"`
		} `json:"repository"`
	} `json:"parent"`
	SubIssues *struct {
		Total     int `json:"total"`
		Completed int `json:"completed"`
	} `json:"subIssuesSummary"`
}

func (n gqlItem) item() Item {
	i := Item{Repo: n.Repository.NameWithOwner, Number: n.Number, PR: n.Typename == "PullRequest",
		State: strings.ToLower(n.IssueState + n.PullState), Title: n.Title, URL: n.URL, Author: n.Author.login(), AuthorAvatar: n.Author.avatar(), UpdatedAt: n.UpdatedAt,
		CreatedAt: n.CreatedAt, ClosedAt: n.ClosedAt,
		Comments: n.CommentCount.TotalCount, Assignees: []string{}}
	if i.State != "merged" && i.State != "closed" {
		i.State = "open"
	}
	i.Labels, i.LabelColors = labelsOf(n.Labels.Nodes)
	for _, a := range n.Assignees.Nodes {
		i.Assignees = append(i.Assignees, a.Login)
	}
	if n.Milestone != nil {
		i.Milestone = n.Milestone.Title
	}
	if n.Parent != nil && n.Parent.Number > 0 {
		i.ParentRepo, i.ParentNumber = n.Parent.Repository.NameWithOwner, n.Parent.Number
	}
	if n.SubIssues != nil {
		i.SubTotal, i.SubDone = n.SubIssues.Total, n.SubIssues.Completed
	}
	if !i.PR {
		if i.State == "closed" {
			i.StateReason = stateReasonOf(n.StateReason)
		}
		return i
	}
	i.Draft, i.AutoMerge, i.Review = n.IsDraft, n.AutoMerge != nil, strings.ToLower(n.Review)
	i.Mergeable = "unknown"
	if c := conflictsOf(n.Mergeable); c != nil {
		i.Mergeable = map[bool]string{true: "conflicting", false: "mergeable"}[*c]
	}
	i.Checks = "none"
	if len(n.CheckState.Nodes) > 0 && n.CheckState.Nodes[0].Commit.StatusCheckRollup != nil {
		switch n.CheckState.Nodes[0].Commit.StatusCheckRollup.State {
		case "SUCCESS":
			i.Checks = "passing"
		case "FAILURE", "ERROR":
			i.Checks = "failing"
		default:
			i.Checks = "running"
		}
	}
	return i
}

// stateReasonOf is GitHub's reason for a closed issue in the one model's words (#4365):
// completed, not_planned or duplicate, "" for another (REOPENED) or none.
func stateReasonOf(reason string) string {
	switch reason {
	case "COMPLETED", "NOT_PLANNED", "DUPLICATE":
		return strings.ToLower(reason)
	}
	return ""
}

// SearchQuery is GitHub search's words for repos and f, the last updated first.
func SearchQuery(repos []string, f SearchFilter) string {
	words := []string{"is:issue"}
	if f.PRs {
		words[0] = "is:pr"
	}
	switch f.State {
	case "", "open":
		words = append(words, "is:open")
	case "closed":
		words = append(words, "is:closed")
	}
	for _, r := range repos {
		words = append(words, "repo:"+r)
	}
	if f.Label != "" {
		words = append(words, fmt.Sprintf("label:%q", f.Label))
	}
	if f.Feature != "" {
		words = append(words, fmt.Sprintf("label:%q", "feature:"+f.Feature))
	}
	if f.Assignee != "" {
		words = append(words, "assignee:"+f.Assignee)
	}
	if f.Project != "" {
		words = append(words, "project:"+f.Project)
	}
	if q := strings.TrimSpace(f.Query); q != "" {
		words = append(words, q)
	}
	return strings.Join(append(words, "sort:updated-desc"), " ")
}

// Search is one page of the issues or pull requests of repos, at most first (1 to 100), after
// the cursor after ("" for the first page).
func (g *RealGitHub) Search(ctx context.Context, repos []string, f SearchFilter, after string, first int) (SearchPage, error) {
	if len(repos) == 0 {
		return SearchPage{Items: []Item{}, Cursors: []string{}}, nil
	}
	vars := map[string]any{"q": SearchQuery(repos, f), "first": max(1, min(first, perPage))}
	if after != "" {
		vars["after"] = after
	}
	var data struct {
		Search struct {
			PageInfo struct {
				HasNextPage bool   `json:"hasNextPage"`
				EndCursor   string `json:"endCursor"`
			} `json:"pageInfo"`
			Edges []struct {
				Cursor string  `json:"cursor"`
				Node   gqlItem `json:"node"`
			} `json:"edges"`
		} `json:"search"`
	}
	if err := g.graphql(ctx, searchQuery, vars, &data); err != nil {
		return SearchPage{}, err
	}
	p := SearchPage{Items: []Item{}, Cursors: []string{}}
	for _, e := range data.Search.Edges {
		// A search for issues can find nothing else, but a node it cannot read is empty.
		if n := e.Node; n.Number > 0 && n.Repository.NameWithOwner != "" {
			p.Items = append(p.Items, n.item())
			p.Cursors = append(p.Cursors, e.Cursor)
		}
	}
	if data.Search.PageInfo.HasNextPage {
		p.Next = data.Search.PageInfo.EndCursor
	}
	return p, nil
}

// ItemPage is an issue or a pull request of repo, with its body, the page of its comments before
// the cursor before (the newest page for ""), and a pull request's checks.
func (g *RealGitHub) ItemPage(ctx context.Context, repo string, number int, before string) (ItemDetail, error) {
	owner, name, err := ownerName(repo)
	if err != nil {
		return ItemDetail{}, err
	}
	vars := map[string]any{"owner": owner, "name": name, "number": number}
	if before != "" {
		vars["before"] = before
	}
	var data struct {
		Repository *struct {
			Item *struct {
				gqlItem
				Body     string `json:"body"`
				Comments struct {
					PageInfo struct {
						HasPreviousPage bool   `json:"hasPreviousPage"`
						StartCursor     string `json:"startCursor"`
					} `json:"pageInfo"`
					Nodes []gqlComment `json:"nodes"`
				} `json:"comments"`
				ReviewThreads struct {
					TotalCount int `json:"totalCount"`
				} `json:"reviewThreads"`
				ChangedFiles int       `json:"changedFiles"`
				HeadRefOid   string    `json:"headRefOid"`
				Commits      gqlRollup `json:"commits"`
				Children     struct {
					Nodes []gqlLinked `json:"nodes"`
				} `json:"children"`
				LinkedPulls struct {
					Nodes []gqlLinked `json:"nodes"`
				} `json:"linkedPulls"`
				Events struct {
					Nodes []gqlEvent `json:"nodes"`
				} `json:"events"`
			} `json:"issueOrPullRequest"`
			mergeSettings
		} `json:"repository"`
	}
	if err := g.graphql(ctx, itemQuery, vars, &data); err != nil {
		return ItemDetail{}, err
	}
	if data.Repository == nil || data.Repository.Item == nil {
		return ItemDetail{}, &GitHubError{Kind: NotFound, Message: fmt.Sprintf("no issue or pull request #%d in %s", number, repo)}
	}
	n := data.Repository.Item
	d := ItemDetail{Item: n.item(), Body: n.Body, Thread: []Comment{}}
	if d.Repo == "" {
		d.Repo = repo
	}
	for _, c := range n.Comments.Nodes {
		d.Thread = append(d.Thread, Comment{Author: c.Author.login(), Avatar: c.Author.avatar(), Body: c.Body, At: c.CreatedAt, URL: c.URL, Bot: c.Author.isBot()})
	}
	if n.Comments.PageInfo.HasPreviousPage {
		d.Before = n.Comments.PageInfo.StartCursor
	}
	if !d.PR {
		d.Children, d.LinkedPulls, d.Events = []Linked{}, []Linked{}, []Event{}
		for _, c := range n.Children.Nodes {
			if l, ok := c.linked(false); ok {
				d.Children = append(d.Children, l)
			}
		}
		for _, c := range n.LinkedPulls.Nodes {
			if l, ok := c.linked(true); ok {
				d.LinkedPulls = append(d.LinkedPulls, l)
			}
		}
		for _, e := range n.Events.Nodes {
			if ev, ok := e.event(); ok {
				d.Events = append(d.Events, ev)
			}
		}
	}
	if d.PR {
		d.ReviewThreads, d.FilesChanged, d.Head = n.ReviewThreads.TotalCount, n.ChangedFiles, n.HeadRefOid
		d.MergeMethods = data.Repository.methods()
		d.CheckRuns = []Check{}
		for _, c := range n.Commits.items() {
			name, link := c.Name, c.DetailsURL
			if c.Typename == "StatusContext" {
				name, link = c.Context, c.TargetURL
			}
			d.CheckRuns = append(d.CheckRuns, Check{Name: name, State: c.state(), URL: link})
		}
	}
	return d, nil
}

// Ref is an issue another names, as a blocker: open says it is not closed.
type Ref struct {
	Repo   string
	Number int
	Open   bool
}

// PlanChild is a sub-issue with the issues it is blocked by (#3267).
type PlanChild struct {
	Item
	BlockedBy []Ref
}

// Plan is an issue (an epic) and its sub-issues, in GitHub's order (#3267).
type Plan struct {
	Epic     Item
	Children []PlanChild
}

const planQuery = `query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) { issue(number: $number) { issueState: state ` + itemFields + ` ` + issueFields + `
    subIssues(first: 100) { nodes { issueState: state ` + itemFields + ` ` + issueFields + `
      blockedBy(first: 50) { nodes { number state repository { nameWithOwner } } } } } } } }`

// Plan is the issue number of repo, its sub-issues (at most 100) and each one's blockers (at most
// 50), in one query.
func (g *RealGitHub) Plan(ctx context.Context, repo string, number int) (Plan, error) {
	owner, name, err := ownerName(repo)
	if err != nil {
		return Plan{}, err
	}
	var data struct {
		Repository *struct {
			Issue *struct {
				gqlItem
				SubIssues struct {
					Nodes []struct {
						gqlItem
						BlockedBy gqlBlockers `json:"blockedBy"`
					} `json:"nodes"`
				} `json:"subIssues"`
			} `json:"issue"`
		} `json:"repository"`
	}
	if err := g.graphql(ctx, planQuery, map[string]any{"owner": owner, "name": name, "number": number}, &data); err != nil {
		return Plan{}, err
	}
	if data.Repository == nil || data.Repository.Issue == nil {
		return Plan{}, &GitHubError{Kind: NotFound, Message: fmt.Sprintf("no issue #%d in %s", number, repo)}
	}
	n := data.Repository.Issue
	p := Plan{Epic: n.item(), Children: []PlanChild{}}
	if p.Epic.Repo == "" {
		p.Epic.Repo = repo
	}
	for _, c := range n.SubIssues.Nodes {
		if c.Number < 1 || c.Repository.NameWithOwner == "" {
			continue
		}
		p.Children = append(p.Children, PlanChild{Item: c.item(), BlockedBy: c.BlockedBy.refs()})
	}
	return p, nil
}

// gqlBlockers is an issue's blockedBy, as GraphQL says it.
type gqlBlockers struct {
	Nodes []struct {
		Number     int    `json:"number"`
		State      string `json:"state"`
		Repository struct {
			NameWithOwner string `json:"nameWithOwner"`
		} `json:"repository"`
	} `json:"nodes"`
}

func (b gqlBlockers) refs() []Ref {
	out := []Ref{}
	for _, n := range b.Nodes {
		if n.Number > 0 && n.Repository.NameWithOwner != "" {
			out = append(out, Ref{Repo: n.Repository.NameWithOwner, Number: n.Number, Open: n.State != "CLOSED"})
		}
	}
	return out
}

// BlockersMost bounds the issues one Blockers read asks about.
const BlockersMost = 100

// Blockers are the issues that block each of numbers in repo (at most BlockersMost, each with at
// most 50 blockers), in one query of an aliased issue(number:) each (#4200): a standing epic's
// children come from a search, which does not read blockers. A number that is not an issue has
// none.
func (g *RealGitHub) Blockers(ctx context.Context, repo string, numbers []int) (map[int][]Ref, error) {
	owner, name, err := ownerName(repo)
	if err != nil {
		return nil, err
	}
	out := map[int][]Ref{}
	numbers = numbers[:min(len(numbers), BlockersMost)]
	if len(numbers) == 0 {
		return out, nil
	}
	var q strings.Builder
	q.WriteString("query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) {")
	for _, n := range numbers {
		fmt.Fprintf(&q, " i%d: issue(number: %d) { blockedBy(first: 50) { nodes { number state repository { nameWithOwner } } } }", n, n)
	}
	q.WriteString(" } }")
	var data struct {
		Repository map[string]*struct {
			BlockedBy gqlBlockers `json:"blockedBy"`
		} `json:"repository"`
	}
	if err := g.graphql(ctx, q.String(), map[string]any{"owner": owner, "name": name}, &data); err != nil {
		return nil, err
	}
	for _, n := range numbers {
		if i := data.Repository[fmt.Sprintf("i%d", n)]; i != nil {
			out[n] = i.BlockedBy.refs()
		}
	}
	return out, nil
}

type gqlLinked struct {
	Number     int    `json:"number"`
	Title      string `json:"title"`
	URL        string `json:"url"`
	IssueState string `json:"issueState"`
	PullState  string `json:"pullState"`
	Repository struct {
		NameWithOwner string `json:"nameWithOwner"`
	} `json:"repository"`
}

// linked is n as a sub-issue or a closing pull request; a node the token cannot read is empty.
func (n gqlLinked) linked(pr bool) (Linked, bool) {
	if n.Number < 1 || n.Repository.NameWithOwner == "" {
		return Linked{}, false
	}
	state := strings.ToLower(n.IssueState + n.PullState)
	if state != "closed" && state != "merged" {
		state = "open"
	}
	return Linked{Repo: n.Repository.NameWithOwner, Number: n.Number, PR: pr, Title: n.Title, State: state, URL: n.URL}, true
}

// gqlRefTo is an issue or a pull request that an event names.
type gqlRefTo struct {
	Typename   string `json:"__typename"`
	Number     int    `json:"number"`
	Repository struct {
		NameWithOwner string `json:"nameWithOwner"`
	} `json:"repository"`
}

type gqlEvent struct {
	Typename  string    `json:"__typename"`
	Actor     *gqlActor `json:"actor"`
	CreatedAt string    `json:"createdAt"`
	Label     *label    `json:"label"`
	Assignee  *gqlActor `json:"assignee"`
	Closer    *gqlRefTo `json:"closer"`
	Source    *gqlRefTo `json:"source"`
}

// eventKinds are GitHub's timeline items in the one model's words.
var eventKinds = map[string]string{"LabeledEvent": "labeled", "UnlabeledEvent": "unlabeled", "AssignedEvent": "assigned",
	"UnassignedEvent": "unassigned", "ClosedEvent": "closed", "ReopenedEvent": "reopened", "CrossReferencedEvent": "referenced"}

// event is e in the one model; one of another kind, or a reference from what the token cannot
// read, is left out.
func (e gqlEvent) event() (Event, bool) {
	kind, ok := eventKinds[e.Typename]
	if !ok || e.CreatedAt == "" {
		return Event{}, false
	}
	out := Event{Kind: kind, Actor: e.Actor.login(), At: e.CreatedAt, Assignee: e.Assignee.login()}
	if e.Label != nil {
		names, colors := labelsOf([]label{*e.Label})
		out.Label, out.LabelColor = names[0], colors[names[0]]
	}
	ref := e.Source
	if kind == "closed" {
		ref = e.Closer
	}
	if ref != nil && ref.Number > 0 && ref.Repository.NameWithOwner != "" {
		out.SourceRepo, out.SourceNumber, out.SourcePR = ref.Repository.NameWithOwner, ref.Number, ref.Typename == "PullRequest"
	}
	if kind == "referenced" && out.SourceRepo == "" {
		return Event{}, false
	}
	return out, true
}
