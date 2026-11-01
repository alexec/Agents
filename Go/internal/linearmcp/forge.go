package linearmcp

import (
	"context"
	"fmt"
	"slices"
	"strings"
)

// The daemon's forge reads (#3209, after GitHub's in #3129): the issues of many teams in one
// query, the last updated first, and one issue with its description and a page of its comments.
// The daemon puts them in the one model the Work pages draw for every forge (wire.ForgeItem).
// Linear has issues only: no pull requests.

// SearchFilter is what a list lists: issues in state open, closed or all (open when ""),
// narrowed by a label, an assignee's display name and words in the title or description.
type SearchFilter struct {
	State                  string
	Label, Assignee, Query string
}

// Item is an issue as the forge reads list it, by its identifier (ENG-4).
type Item struct {
	Identifier, Team string
	// State is open or closed.
	State, Title, URL, Author, Milestone, UpdatedAt string
	Labels                                          []string
	LabelColors                                     map[string]string
	Assignees                                       []string
	// Comments is how many, at most 50: Linear does not count them.
	Comments int
}

// SearchPage is a page of a list, the last updated first. Cursors[i] goes on after Items[i],
// so a caller that keeps only some of the page goes on from the last it kept; Next is the
// cursor after the page, "" at the end.
type SearchPage struct {
	Items   []Item
	Cursors []string
	Next    string
}

// Comment is a comment on an issue, as Markdown.
type Comment struct {
	Author, Body, At, URL string
	Bot                   bool
}

// ItemDetail is an issue with its description and a page of its comments (Thread), oldest
// first in the page. Before is the cursor of the page before it, "" at the first comment.
type ItemDetail struct {
	Item
	Body   string
	Thread []Comment
	Before string
}

// forgeComments is a page of an issue's comments.
const forgeComments = 50

const forgeFields = `identifier title url updatedAt team { key } state { type } projectMilestone { name }
  labels { nodes { name color } } assignee { displayName } creator { displayName } botActor { name }
  commentCount: comments(first: 50) { nodes { id } }`

const forgeSearch = `query ForgeIssues($filter: IssueFilter, $first: Int, $after: String) {
  issues(filter: $filter, first: $first, after: $after, orderBy: updatedAt) {
    edges { cursor node { ` + forgeFields + ` } } pageInfo { hasNextPage endCursor } } }`

// Linear's pages go newest first, so the page before a comment is the one after it.
const forgeItem = `query ForgeIssue($id: String!, $comments: Int, $before: String) { issue(id: $id) { ` + forgeFields + ` description
  comments(first: $comments, after: $before) { pageInfo { hasNextPage endCursor }
    nodes { body createdAt url user { displayName } botActor { name } } } } }`

type forgeNode struct {
	Identifier string `json:"identifier"`
	Title      string `json:"title"`
	URL        string `json:"url"`
	UpdatedAt  string `json:"updatedAt"`
	Team       *struct {
		Key string `json:"key"`
	} `json:"team"`
	State *struct {
		Type string `json:"type"`
	} `json:"state"`
	ProjectMilestone *struct {
		Name string `json:"name"`
	} `json:"projectMilestone"`
	Labels struct {
		Nodes []struct {
			Name  string `json:"name"`
			Color string `json:"color"`
		} `json:"nodes"`
	} `json:"labels"`
	Assignee *struct {
		DisplayName string `json:"displayName"`
	} `json:"assignee"`
	Creator *struct {
		DisplayName string `json:"displayName"`
	} `json:"creator"`
	BotActor     *gqlBot `json:"botActor"`
	CommentCount struct {
		Nodes []struct{} `json:"nodes"`
	} `json:"commentCount"`
}

func (n forgeNode) item() Item {
	i := Item{Identifier: n.Identifier, Title: n.Title, URL: n.URL, UpdatedAt: n.UpdatedAt, State: "open",
		Labels: []string{}, LabelColors: map[string]string{}, Assignees: []string{}, Comments: len(n.CommentCount.Nodes)}
	if n.Team != nil {
		i.Team = n.Team.Key
	}
	if n.State != nil && isClosed(n.State.Type) {
		i.State = "closed"
	}
	if n.ProjectMilestone != nil {
		i.Milestone = n.ProjectMilestone.Name
	}
	for _, l := range n.Labels.Nodes {
		i.Labels = append(i.Labels, l.Name)
		if l.Color != "" {
			i.LabelColors[l.Name] = strings.ToLower(l.Color)
		}
	}
	if n.Assignee != nil && n.Assignee.DisplayName != "" {
		i.Assignees = append(i.Assignees, n.Assignee.DisplayName)
	}
	switch {
	case n.Creator != nil:
		i.Author = n.Creator.DisplayName
	case n.BotActor != nil:
		i.Author = n.BotActor.Name
	}
	return i
}

// SearchFilterOf is Linear's IssueFilter for teams (by key) and f.
func SearchFilterOf(teams []string, f SearchFilter) map[string]any {
	filter := map[string]any{"team": map[string]any{"key": map[string]any{"in": teams}}}
	switch f.State {
	case "", "open":
		filter["state"] = map[string]any{"type": map[string]any{"nin": []string{"completed", "canceled"}}}
	case "closed":
		filter["state"] = map[string]any{"type": map[string]any{"in": []string{"completed", "canceled"}}}
	}
	if f.Label != "" {
		filter["labels"] = map[string]any{"name": map[string]any{"eq": f.Label}}
	}
	if f.Assignee != "" {
		filter["assignee"] = map[string]any{"displayName": map[string]any{"eqIgnoreCase": f.Assignee}}
	}
	if q := strings.TrimSpace(f.Query); q != "" {
		filter["or"] = []any{map[string]any{"title": map[string]any{"containsIgnoreCase": q}},
			map[string]any{"description": map[string]any{"containsIgnoreCase": q}}}
	}
	return filter
}

// Search is one page of the issues of teams, at most first (1 to 100), after the cursor after
// ("" for the first page), in one query.
func (l *RealLinear) Search(ctx context.Context, teams []string, f SearchFilter, after string, first int) (SearchPage, error) {
	page := SearchPage{Items: []Item{}, Cursors: []string{}}
	if len(teams) == 0 {
		return page, nil
	}
	vars := map[string]any{"filter": SearchFilterOf(teams, f), "first": max(1, min(first, perPage))}
	if after != "" {
		vars["after"] = after
	}
	var out struct {
		Issues struct {
			Edges []struct {
				Cursor string    `json:"cursor"`
				Node   forgeNode `json:"node"`
			} `json:"edges"`
			PageInfo struct {
				HasNextPage bool   `json:"hasNextPage"`
				EndCursor   string `json:"endCursor"`
			} `json:"pageInfo"`
		} `json:"issues"`
	}
	if err := l.query(ctx, forgeSearch, vars, &out); err != nil {
		return SearchPage{}, err
	}
	for _, e := range out.Issues.Edges {
		if e.Node.Identifier != "" {
			page.Items = append(page.Items, e.Node.item())
			page.Cursors = append(page.Cursors, e.Cursor)
		}
	}
	if out.Issues.PageInfo.HasNextPage {
		page.Next = out.Issues.PageInfo.EndCursor
	}
	return page, nil
}

// ItemPage is the issue identifier names, with its description and the page of its comments
// before the cursor before (the newest page for "").
func (l *RealLinear) ItemPage(ctx context.Context, identifier, before string) (ItemDetail, error) {
	vars := map[string]any{"id": identifier, "comments": forgeComments}
	if before != "" {
		vars["before"] = before
	}
	var out struct {
		Issue *struct {
			forgeNode
			Description string `json:"description"`
			Comments    struct {
				PageInfo struct {
					HasNextPage bool   `json:"hasNextPage"`
					EndCursor   string `json:"endCursor"`
				} `json:"pageInfo"`
				Nodes []struct {
					Body      string `json:"body"`
					CreatedAt string `json:"createdAt"`
					URL       string `json:"url"`
					User      *struct {
						DisplayName string `json:"displayName"`
					} `json:"user"`
					BotActor *gqlBot `json:"botActor"`
				} `json:"nodes"`
			} `json:"comments"`
		} `json:"issue"`
	}
	if err := l.query(ctx, forgeItem, vars, &out); err != nil {
		return ItemDetail{}, err
	}
	if out.Issue == nil {
		return ItemDetail{}, &LinearError{Kind: NotFound, Message: fmt.Sprintf("Linear issue %s was not found", identifier)}
	}
	d := ItemDetail{Item: out.Issue.item(), Body: out.Issue.Description, Thread: []Comment{}}
	for _, c := range slices.Backward(out.Issue.Comments.Nodes) {
		comment := Comment{Body: c.Body, At: c.CreatedAt, URL: c.URL}
		switch {
		case c.User != nil:
			comment.Author = c.User.DisplayName
		case c.BotActor != nil:
			comment.Author, comment.Bot = c.BotActor.Name, true
		}
		d.Thread = append(d.Thread, comment)
	}
	if out.Issue.Comments.PageInfo.HasNextPage {
		d.Before = out.Issue.Comments.PageInfo.EndCursor
	}
	return d, nil
}
