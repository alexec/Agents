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
// (open when ""), narrowed by a label, an assignee's login and words.
type SearchFilter struct {
	PRs                    bool
	State                  string
	Label, Assignee, Query string
}

// Item is an issue or a pull request as the forge reads list it.
type Item struct {
	Repo   string
	Number int
	PR     bool
	// State is open, closed or merged.
	State, Title, URL, Author, Milestone, UpdatedAt string
	Labels                                          []string
	LabelColors                                     map[string]string
	Assignees                                       []string
	Comments                                        int
	// A pull request's: Checks is passing, failing, running or none; Review is approved,
	// changes_requested, review_required or ""; Mergeable is mergeable, conflicting or unknown.
	Draft, AutoMerge          bool
	Checks, Review, Mergeable string
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
	Author, Body, At, URL string
	Bot                   bool
}

// Check is one of a pull request's checks: State is passing, failing, running or skipped.
type Check struct{ Name, State, URL string }

// ItemDetail is an item with its body and a page of its comments (Thread), oldest first in the
// page. Before is the cursor of the page before it, "" at the first comment. CheckRuns are a pull
// request's checks, each one.
type ItemDetail struct {
	Item
	Body          string
	Thread        []Comment
	Before        string
	CheckRuns     []Check
	ReviewThreads int
	FilesChanged  int
}

// itemFields are what an issue and a pull request both say, in a search and on their own. Their
// states are of two types, so each has its own name: issueState and pullState.
const itemFields = `number title url updatedAt author { login __typename } repository { nameWithOwner }
  ` + labelFields + ` assignees(first: 20) { nodes { login } } milestone { title } commentCount: comments { totalCount }`

// pullFields are a pull request's own, for a list: its checks in one word, not each of them.
const pullFields = `isDraft mergeable reviewDecision autoMergeRequest { enabledAt }
  checkState: commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }`

const searchQuery = `query($q: String!, $first: Int!, $after: String) {
  search(query: $q, type: ISSUE, first: $first, after: $after) { pageInfo { hasNextPage endCursor } edges { cursor node {
    __typename ... on Issue { issueState: state ` + itemFields + ` }
    ... on PullRequest { pullState: state ` + itemFields + ` ` + pullFields + ` } } } } }`

// commentFields are the newest page of an item's comments, before $before.
const commentFields = `comments(last: 50, before: $before) { pageInfo { hasPreviousPage startCursor }
  nodes { author { login __typename } body createdAt url } }`

const itemQuery = `query($owner: String!, $name: String!, $number: Int!, $before: String) {
  repository(owner: $owner, name: $name) { issueOrPullRequest(number: $number) {
    __typename ... on Issue { issueState: state ` + itemFields + ` body ` + commentFields + ` }
    ... on PullRequest { pullState: state ` + itemFields + ` ` + pullFields + ` body ` + commentFields + `
      reviewThreads { totalCount } changedFiles ` + rollupFields + ` } } } }`

type gqlItem struct {
	Typename   string    `json:"__typename"`
	Number     int       `json:"number"`
	Title      string    `json:"title"`
	URL        string    `json:"url"`
	IssueState string    `json:"issueState"`
	PullState  string    `json:"pullState"`
	UpdatedAt  string    `json:"updatedAt"`
	Author     *gqlActor `json:"author"`
	Repository struct {
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
}

func (n gqlItem) item() Item {
	i := Item{Repo: n.Repository.NameWithOwner, Number: n.Number, PR: n.Typename == "PullRequest",
		State: strings.ToLower(n.IssueState + n.PullState), Title: n.Title, URL: n.URL, Author: n.Author.login(), UpdatedAt: n.UpdatedAt,
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
	if !i.PR {
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
	if f.Assignee != "" {
		words = append(words, "assignee:"+f.Assignee)
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
				Commits      gqlRollup `json:"commits"`
			} `json:"issueOrPullRequest"`
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
		d.Thread = append(d.Thread, Comment{Author: c.Author.login(), Body: c.Body, At: c.CreatedAt, URL: c.URL, Bot: c.Author.isBot()})
	}
	if n.Comments.PageInfo.HasPreviousPage {
		d.Before = n.Comments.PageInfo.StartCursor
	}
	if d.PR {
		d.ReviewThreads, d.FilesChanged = n.ReviewThreads.TotalCount, n.ChangedFiles
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
