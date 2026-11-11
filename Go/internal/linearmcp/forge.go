package linearmcp

import (
	"cmp"
	"context"
	"fmt"
	"regexp"
	"slices"
	"strconv"
	"strings"
)

// The daemon's forge reads (#3209, after GitHub's in #3129): the issues of many teams, or of
// the whole workspace (#3311), in one query, the last updated first, and one issue with its
// description and a page of its comments. The daemon puts them in the one model the Work
// pages draw for every forge (wire.ForgeItem). Linear has issues only: no pull requests.

// SearchFilter is what a list lists: issues in state open, closed or all (open when ""),
// narrowed by a label, an assignee's display name, words in the title or description, and a
// feature: the name of a feature:<name> label (#3267).
type SearchFilter struct {
	State                           string
	Label, Assignee, Query, Feature string
}

// Item is an issue as the forge reads list it, by its identifier (ENG-4).
type Item struct {
	Identifier, Team string
	// State is open or closed.
	State, Title, URL, Author, Milestone, UpdatedAt string
	// CreatedAt is when it was made; ClosedAt when it was completed or canceled, "" while open
	// (#4373).
	CreatedAt, ClosedAt string
	// AuthorAvatar is the author's picture, on Linear's public upload host; "" for none (#4363).
	AuthorAvatar string
	// StateReason is why a closed issue closed: completed, not_planned or duplicate; "" while
	// it is open (#4365).
	StateReason string
	Labels      []string
	LabelColors map[string]string
	Assignees   []string
	// Comments is how many, at most 50: Linear does not count them.
	Comments int
	// Parent is the issue it is a child of, by identifier (#3267). SubTotal and SubDone are its
	// children and the closed ones, read on an issue's own read and in a plan only: a list
	// would cost Linear's query budget a page of children for each issue.
	Parent            string
	SubTotal, SubDone int
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
	Author, Avatar, Body, At, URL string
	Bot                           bool
}

// ItemDetail is an issue with its description and a page of its comments (Thread), oldest
// first in the page. Before is the cursor of the page before it, "" at the first comment.
type ItemDetail struct {
	Item
	Body   string
	Thread []Comment
	Before string
	// Children are its sub-issues, at most 50, in Linear's order (#4373).
	Children []Child
	// LinkedPulls are the GitHub pull requests and GitLab merge requests attached to it, and
	// Events what its latest 50 changes did, oldest first (#4626).
	LinkedPulls []LinkedPull
	Events      []Event
}

// LinkedPull is a pull request (Forge github) or a merge request (Forge gitlab) that an
// attachment names: Repo is owner/repo or group/project, State open, closed or merged.
type LinkedPull struct {
	Forge, Repo, Title, URL, State string
	Number                         int
}

// Event is one thing a change did (#4626): Kind is labeled, unlabeled, assigned, unassigned,
// closed or reopened. Label and LabelColor name a label; Assignee a person.
type Event struct {
	Kind, Actor, At, Label, LabelColor, Assignee string
}

// Child is a sub-issue on an issue's read: State is open or closed.
type Child struct {
	Identifier, Title, URL, State string
}

// forgeComments is a page of an issue's comments.
const forgeComments = 50

const forgeFields = `identifier title url createdAt completedAt canceledAt updatedAt team { key } state { type name } projectMilestone { name }
  labels { nodes { name color } } assignee { displayName } creator { displayName avatarUrl } botActor { name avatarUrl }
  commentCount: comments(first: 50) { nodes { id } } parent { identifier }`

// forgeChildren are an issue's children's states, to count them (#3267).
const forgeChildren = `children(first: 100) { nodes { state { type } } }`

const forgeSearch = `query ForgeIssues($filter: IssueFilter, $first: Int, $after: String) {
  issues(filter: $filter, first: $first, after: $after, orderBy: updatedAt) {
    edges { cursor node { ` + forgeFields + ` } } pageInfo { hasNextPage endCursor } } }`

// Linear's pages go newest first, so the page before a comment is the one after it.
const forgeItem = `query ForgeIssue($id: String!, $comments: Int, $before: String) { issue(id: $id) { ` + forgeFields + ` ` + forgeChildren + ` description
  subIssues: children(first: 50) { nodes { identifier title url state { type } } }
  attachments(first: 50) { nodes { url title sourceType metadata } }
  history(first: 50) { nodes { createdAt actor { displayName } botActor { name } addedLabels { name color } removedLabels { name color }
    fromAssignee { displayName } toAssignee { displayName } fromState { type } toState { type } } }
  comments(first: $comments, after: $before) { pageInfo { hasNextPage endCursor }
    nodes { body createdAt url user { displayName avatarUrl } botActor { name avatarUrl } } } } }`

// forgePerson is an issue's creator or a comment's writer.
type forgePerson struct {
	DisplayName string `json:"displayName"`
	AvatarURL   string `json:"avatarUrl"`
}

type forgeNode struct {
	Identifier string `json:"identifier"`
	Title      string `json:"title"`
	URL        string `json:"url"`
	UpdatedAt  string `json:"updatedAt"`
	CreatedAt  string `json:"createdAt"`
	// CompletedAt and CanceledAt are when it moved to a completed or a canceled state.
	CompletedAt string `json:"completedAt"`
	CanceledAt  string `json:"canceledAt"`
	Team        *struct {
		Key string `json:"key"`
	} `json:"team"`
	State *struct {
		Type string `json:"type"`
		Name string `json:"name"`
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
	Creator      *forgePerson `json:"creator"`
	BotActor     *gqlBot      `json:"botActor"`
	CommentCount struct {
		Nodes []struct{} `json:"nodes"`
	} `json:"commentCount"`
	Parent *struct {
		Identifier string `json:"identifier"`
	} `json:"parent"`
	Children *struct {
		Nodes []struct {
			State *struct {
				Type string `json:"type"`
			} `json:"state"`
		} `json:"nodes"`
	} `json:"children"`
}

func (n forgeNode) item() Item {
	i := Item{Identifier: n.Identifier, Title: n.Title, URL: n.URL, UpdatedAt: n.UpdatedAt, CreatedAt: n.CreatedAt, State: "open",
		Labels: []string{}, LabelColors: map[string]string{}, Assignees: []string{}, Comments: len(n.CommentCount.Nodes)}
	if n.Team != nil {
		i.Team = n.Team.Key
	}
	if n.State != nil && isClosed(n.State.Type) {
		i.State, i.StateReason = "closed", stateReasonOf(n.State.Type, n.State.Name)
		i.ClosedAt = cmp.Or(n.CompletedAt, n.CanceledAt)
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
		i.Author, i.AuthorAvatar = n.Creator.DisplayName, n.Creator.AvatarURL
	case n.BotActor != nil:
		i.Author, i.AuthorAvatar = n.BotActor.Name, n.BotActor.AvatarURL
	}
	if n.Parent != nil {
		i.Parent = n.Parent.Identifier
	}
	if n.Children != nil {
		for _, c := range n.Children.Nodes {
			i.SubTotal++
			if c.State != nil && isClosed(c.State.Type) {
				i.SubDone++
			}
		}
	}
	return i
}

// stateReasonOf is why an issue in a closed state of stateType and name closed (#4365): a
// completed state is completed; a canceled one is not_planned, or duplicate when it is the
// team's Duplicate state, where Linear's "Mark as duplicate" moves an issue (Linear's Issue has
// no field that says it is a duplicate, only a relation).
func stateReasonOf(stateType, name string) string {
	switch {
	case stateType == "completed":
		return "completed"
	case strings.EqualFold(strings.TrimSpace(name), "duplicate"):
		return "duplicate"
	}
	return "not_planned"
}

// SearchFilterOf is Linear's IssueFilter for teams (by key) and f; no teams is the whole
// workspace (#3311).
func SearchFilterOf(teams []string, f SearchFilter) map[string]any {
	filter := map[string]any{}
	if len(teams) > 0 {
		filter["team"] = map[string]any{"key": map[string]any{"in": teams}}
	}
	switch f.State {
	case "", "open":
		filter["state"] = map[string]any{"type": map[string]any{"nin": []string{"completed", "canceled"}}}
	case "closed":
		filter["state"] = map[string]any{"type": map[string]any{"in": []string{"completed", "canceled"}}}
	}
	// Each label is a filter of its own: an issue has them all.
	var labels []any
	for _, name := range []string{f.Label, featureLabel(f.Feature)} {
		if name != "" {
			labels = append(labels, map[string]any{"labels": map[string]any{"name": map[string]any{"eq": name}}})
		}
	}
	switch len(labels) {
	case 1:
		filter["labels"] = labels[0].(map[string]any)["labels"]
	case 2:
		filter["and"] = labels
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

// Search is one page of the issues of teams (of the whole workspace for none, #3311), at most
// first (1 to 100), after the cursor after ("" for the first page), in one query.
func (l *RealLinear) Search(ctx context.Context, teams []string, f SearchFilter, after string, first int) (SearchPage, error) {
	page := SearchPage{Items: []Item{}, Cursors: []string{}}
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
					Body      string       `json:"body"`
					CreatedAt string       `json:"createdAt"`
					URL       string       `json:"url"`
					User      *forgePerson `json:"user"`
					BotActor  *gqlBot      `json:"botActor"`
				} `json:"nodes"`
			} `json:"comments"`
			SubIssues struct {
				Nodes []struct {
					Identifier string `json:"identifier"`
					Title      string `json:"title"`
					URL        string `json:"url"`
					State      *struct {
						Type string `json:"type"`
					} `json:"state"`
				} `json:"nodes"`
			} `json:"subIssues"`
			Attachments struct {
				Nodes []forgeAttachment `json:"nodes"`
			} `json:"attachments"`
			History struct {
				Nodes []forgeHistory `json:"nodes"`
			} `json:"history"`
		} `json:"issue"`
	}
	if err := l.query(ctx, forgeItem, vars, &out); err != nil {
		return ItemDetail{}, err
	}
	if out.Issue == nil {
		return ItemDetail{}, &LinearError{Kind: NotFound, Message: fmt.Sprintf("Linear issue %s was not found", identifier)}
	}
	d := ItemDetail{Item: out.Issue.item(), Body: out.Issue.Description, Thread: []Comment{}, Children: []Child{}}
	for _, c := range out.Issue.SubIssues.Nodes {
		state := "open"
		if c.State != nil && isClosed(c.State.Type) {
			state = "closed"
		}
		d.Children = append(d.Children, Child{Identifier: c.Identifier, Title: c.Title, URL: c.URL, State: state})
	}
	d.LinkedPulls = []LinkedPull{}
	for _, a := range out.Issue.Attachments.Nodes {
		if p, ok := a.pull(); ok {
			d.LinkedPulls = append(d.LinkedPulls, p)
		}
	}
	d.Events = eventsOf(out.Issue.History.Nodes)
	for _, c := range slices.Backward(out.Issue.Comments.Nodes) {
		comment := Comment{Body: c.Body, At: c.CreatedAt, URL: c.URL}
		switch {
		case c.User != nil:
			comment.Author, comment.Avatar = c.User.DisplayName, c.User.AvatarURL
		case c.BotActor != nil:
			comment.Author, comment.Avatar, comment.Bot = c.BotActor.Name, c.BotActor.AvatarURL, true
		}
		d.Thread = append(d.Thread, comment)
	}
	if out.Issue.Comments.PageInfo.HasNextPage {
		d.Before = out.Issue.Comments.PageInfo.EndCursor
	}
	return d, nil
}

func featureLabel(name string) string {
	if name == "" {
		return ""
	}
	return "feature:" + name
}

// Ref is an issue another names, as a blocker, by identifier: open says it is not closed.
type Ref struct {
	Identifier string
	Open       bool
}

// PlanChild is a child issue with the issues that block it (#3267).
type PlanChild struct {
	Item
	BlockedBy []Ref
}

// Plan is an issue (an epic) and its children, in Linear's order (#3267).
type Plan struct {
	Epic     Item
	Children []PlanChild
}

// A "blocks" relation is said on the issue that blocks: on the blocked one, it is an inverse
// relation, whose issue is the blocker.
const forgePlan = `query ForgePlan($id: String!) { issue(id: $id) { ` + forgeFields + ` ` + forgeChildren + `
  plan: children(first: 50) { nodes { ` + forgeFields + ` ` + forgeChildren + `
    inverseRelations(first: 20) { nodes { type issue { identifier state { type } } } } } } } }`

// linearRelations is an issue's inverse relations: a "blocks" one's issue blocks it.
type linearRelations struct {
	InverseRelations struct {
		Nodes []struct {
			Type  string `json:"type"`
			Issue *struct {
				Identifier string `json:"identifier"`
				State      *struct {
					Type string `json:"type"`
				} `json:"state"`
			} `json:"issue"`
		} `json:"nodes"`
	} `json:"inverseRelations"`
}

func (r linearRelations) blockers() []Ref {
	out := []Ref{}
	for _, n := range r.InverseRelations.Nodes {
		if n.Type == "blocks" && n.Issue != nil && n.Issue.Identifier != "" {
			out = append(out, Ref{Identifier: n.Issue.Identifier, Open: n.Issue.State == nil || !isClosed(n.Issue.State.Type)})
		}
	}
	return out
}

// Plan is the issue identifier names, its children (at most 50) and each one's blockers (at most
// 20), in one query.
func (l *RealLinear) Plan(ctx context.Context, identifier string) (Plan, error) {
	var out struct {
		Issue *struct {
			forgeNode
			Plan struct {
				Nodes []struct {
					forgeNode
					linearRelations
				} `json:"nodes"`
			} `json:"plan"`
		} `json:"issue"`
	}
	if err := l.query(ctx, forgePlan, map[string]any{"id": identifier}, &out); err != nil {
		return Plan{}, err
	}
	if out.Issue == nil {
		return Plan{}, &LinearError{Kind: NotFound, Message: fmt.Sprintf("Linear issue %s was not found", identifier)}
	}
	p := Plan{Epic: out.Issue.item(), Children: []PlanChild{}}
	for _, c := range out.Issue.Plan.Nodes {
		if c.Identifier == "" {
			continue
		}
		p.Children = append(p.Children, PlanChild{Item: c.item(), BlockedBy: c.blockers()})
	}
	return p, nil
}

// BlockersMost bounds the issues one Blockers read asks about.
const BlockersMost = 100

// Blockers are the issues that block each of identifiers (at most BlockersMost, each with at
// most 20 blockers), in one query of an aliased issue(id:) each (#4242): a standing epic's
// children come from a list, which does not read relations. An identifier Linear does not have
// has none.
func (l *RealLinear) Blockers(ctx context.Context, identifiers []string) (map[string][]Ref, error) {
	out := map[string][]Ref{}
	identifiers = identifiers[:min(len(identifiers), BlockersMost)]
	if len(identifiers) == 0 {
		return out, nil
	}
	var q strings.Builder
	q.WriteString("query(")
	vars := map[string]any{}
	for n, id := range identifiers {
		if n > 0 {
			q.WriteString(", ")
		}
		fmt.Fprintf(&q, "$i%d: String!", n)
		vars[fmt.Sprintf("i%d", n)] = id
	}
	q.WriteString(") {")
	for n := range identifiers {
		fmt.Fprintf(&q, " i%d: issue(id: $i%d) { inverseRelations(first: 20) { nodes { type issue { identifier state { type } } } } }", n, n)
	}
	q.WriteString(" }")
	var data map[string]*linearRelations
	if err := l.query(ctx, q.String(), vars, &data); err != nil {
		return nil, err
	}
	for n, id := range identifiers {
		if r := data[fmt.Sprintf("i%d", n)]; r != nil {
			out[id] = r.blockers()
		}
	}
	return out, nil
}

// forgeAttachment is a link on an issue: an integration's (sourceType github, gitlab) has the
// pull request's status in its metadata.
type forgeAttachment struct {
	URL        string `json:"url"`
	Title      string `json:"title"`
	SourceType string `json:"sourceType"`
	Metadata   struct {
		Status string `json:"status"`
		State  string `json:"state"`
	} `json:"metadata"`
}

var (
	githubPull  = regexp.MustCompile(`^https://github\.com/([^/]+/[^/]+)/pull/(\d+)(?:[/?#].*)?$`)
	gitlabMerge = regexp.MustCompile(`^https://[^/]+/(.+?)/-/merge_requests/(\d+)(?:[/?#].*)?$`)
)

// pull is the pull request or merge request the attachment links to, if it is one.
func (a forgeAttachment) pull() (LinkedPull, bool) {
	forge, m := "", []string(nil)
	switch strings.ToLower(a.SourceType) {
	case "github":
		forge, m = "github", githubPull.FindStringSubmatch(a.URL)
	case "gitlab":
		forge, m = "gitlab", gitlabMerge.FindStringSubmatch(a.URL)
	}
	if m == nil {
		return LinkedPull{}, false
	}
	n, err := strconv.Atoi(m[2])
	if err != nil || n < 1 {
		return LinkedPull{}, false
	}
	state := "open"
	switch s := strings.ToLower(cmp.Or(a.Metadata.Status, a.Metadata.State)); s {
	case "merged", "closed":
		state = s
	}
	return LinkedPull{Forge: forge, Repo: m[1], Number: n, Title: cmp.Or(a.Title, a.URL), URL: a.URL, State: state}, true
}

// forgeHistory is one change to an issue, as an issue's read asks for it.
type forgeHistory struct {
	CreatedAt string       `json:"createdAt"`
	Actor     *forgePerson `json:"actor"`
	BotActor  *gqlBot      `json:"botActor"`
	Added     []struct {
		Name  string `json:"name"`
		Color string `json:"color"`
	} `json:"addedLabels"`
	Removed []struct {
		Name  string `json:"name"`
		Color string `json:"color"`
	} `json:"removedLabels"`
	FromAssignee *forgePerson `json:"fromAssignee"`
	ToAssignee   *forgePerson `json:"toAssignee"`
	FromState    *struct {
		Type string `json:"type"`
	} `json:"fromState"`
	ToState *struct {
		Type string `json:"type"`
	} `json:"toState"`
}

// eventsOf are what the changes did, oldest first: one change can add and remove labels,
// change the assignee and move the state at once.
func eventsOf(history []forgeHistory) []Event {
	out := []Event{}
	for _, h := range history {
		actor := ""
		switch {
		case h.Actor != nil:
			actor = h.Actor.DisplayName
		case h.BotActor != nil:
			actor = h.BotActor.Name
		}
		at := func(kind string) Event { return Event{Kind: kind, Actor: actor, At: h.CreatedAt} }
		for _, l := range h.Added {
			e := at("labeled")
			e.Label, e.LabelColor = l.Name, l.Color
			out = append(out, e)
		}
		for _, l := range h.Removed {
			e := at("unlabeled")
			e.Label, e.LabelColor = l.Name, l.Color
			out = append(out, e)
		}
		if h.FromAssignee != nil && (h.ToAssignee == nil || h.ToAssignee.DisplayName != h.FromAssignee.DisplayName) {
			e := at("unassigned")
			e.Assignee = h.FromAssignee.DisplayName
			out = append(out, e)
		}
		if h.ToAssignee != nil && (h.FromAssignee == nil || h.ToAssignee.DisplayName != h.FromAssignee.DisplayName) {
			e := at("assigned")
			e.Assignee = h.ToAssignee.DisplayName
			out = append(out, e)
		}
		if h.FromState != nil && h.ToState != nil {
			switch from, to := isClosed(h.FromState.Type), isClosed(h.ToState.Type); {
			case !from && to:
				out = append(out, at("closed"))
			case from && !to:
				out = append(out, at("reopened"))
			}
		}
	}
	// history(first:) is the newest first; a stable sort keeps one change's events in order.
	slices.SortStableFunc(out, func(a, b Event) int { return cmp.Compare(a.At, b.At) })
	return out
}
