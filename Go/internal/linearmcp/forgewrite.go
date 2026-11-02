package linearmcp

import (
	"context"
	"fmt"
	"slices"
	"strings"
)

// The daemon's forge writes on a Linear issue (#3130): a person's own clicks on the Work pages,
// as the signed-in person. Linear has no pull requests, so only a comment, labels and a close.

// issueRef is an issue's own id, its team's and the labels it has, read before a write: Linear's
// mutations take ids, and a page knows an issue by its identifier (ENG-4).
type issueRef struct {
	ID   string
	Team string
	// Labels are the issue's, by name: their ids.
	Labels map[string]string
}

const issueRefQuery = `query($id: String!) { issue(id: $id) { id team { id } labels(first: 100) { nodes { id name } } } }`

func (l *RealLinear) issueRef(ctx context.Context, identifier string) (issueRef, error) {
	var out struct {
		Issue *struct {
			ID   string `json:"id"`
			Team struct {
				ID string `json:"id"`
			} `json:"team"`
			Labels struct {
				Nodes []struct {
					ID   string `json:"id"`
					Name string `json:"name"`
				} `json:"nodes"`
			} `json:"labels"`
		} `json:"issue"`
	}
	if err := l.query(ctx, issueRefQuery, map[string]any{"id": identifier}, &out); err != nil {
		return issueRef{}, err
	}
	if out.Issue == nil {
		return issueRef{}, &LinearError{Kind: NotFound, Message: fmt.Sprintf("Linear issue %s was not found", identifier)}
	}
	r := issueRef{ID: out.Issue.ID, Team: out.Issue.Team.ID, Labels: map[string]string{}}
	for _, n := range out.Issue.Labels.Nodes {
		r.Labels[n.Name] = n.ID
	}
	return r, nil
}

// refused is the error when a mutation says it did not succeed.
func refused(what, identifier string) error {
	return &LinearError{Kind: Failed, Message: fmt.Sprintf("Linear did not %s %s", what, identifier)}
}

// Comment adds a comment, as Markdown, to an issue, and is its URL.
func (l *RealLinear) Comment(ctx context.Context, identifier, body string) (string, error) {
	r, err := l.issueRef(ctx, identifier)
	if err != nil {
		return "", err
	}
	var out struct {
		CommentCreate struct {
			Success bool `json:"success"`
			Comment *struct {
				URL string `json:"url"`
			} `json:"comment"`
		} `json:"commentCreate"`
	}
	const create = `mutation($issue: String!, $body: String!) { commentCreate(input: {issueId: $issue, body: $body}) { success comment { url } } }`
	if err := l.query(ctx, create, map[string]any{"issue": r.ID, "body": body}, &out); err != nil {
		return "", err
	}
	if !out.CommentCreate.Success {
		return "", refused("comment on", identifier)
	}
	if out.CommentCreate.Comment == nil {
		return "", nil
	}
	return out.CommentCreate.Comment.URL, nil
}

const teamLabelsQuery = `query($team: ID!) { issueLabels(first: 100, filter: {or: [{team: {id: {eq: $team}}}, {team: {null: true}}]}) {
  nodes { id name color } } }`

type labelNode struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Color string `json:"color"`
}

func (l *RealLinear) teamLabels(ctx context.Context, team string) ([]labelNode, error) {
	var out struct {
		IssueLabels struct {
			Nodes []labelNode `json:"nodes"`
		} `json:"issueLabels"`
	}
	if err := l.query(ctx, teamLabelsQuery, map[string]any{"team": team}, &out); err != nil {
		return nil, err
	}
	return out.IssueLabels.Nodes, nil
}

// Labels are the labels an issue can have: its team's and the workspace's, at most 100.
func (l *RealLinear) Labels(ctx context.Context, identifier string) ([]string, map[string]string, error) {
	r, err := l.issueRef(ctx, identifier)
	if err != nil {
		return nil, nil, err
	}
	ls, err := l.teamLabels(ctx, r.Team)
	if err != nil {
		return nil, nil, err
	}
	names, colors := []string{}, map[string]string{}
	for _, n := range ls {
		names = append(names, n.Name)
		if n.Color != "" {
			colors[n.Name] = strings.ToLower(n.Color)
		}
	}
	slices.Sort(names)
	return names, colors, nil
}

// SetLabels adds labels to an issue and takes others off it, by name. A label to add must be
// its team's or the workspace's; one to take off that it does not have is not an error.
func (l *RealLinear) SetLabels(ctx context.Context, identifier string, add, remove []string) error {
	r, err := l.issueRef(ctx, identifier)
	if err != nil {
		return err
	}
	var ids map[string]string
	if len(add) > 0 {
		ls, err := l.teamLabels(ctx, r.Team)
		if err != nil {
			return err
		}
		ids = map[string]string{}
		for _, n := range ls {
			ids[n.Name] = n.ID
		}
	}
	change := func(mutation, issue, label string) error {
		var out map[string]struct {
			Success bool `json:"success"`
		}
		q := fmt.Sprintf(`mutation($id: String!, $label: String!) { %s(id: $id, labelId: $label) { success } }`, mutation)
		if err := l.query(ctx, q, map[string]any{"id": issue, "label": label}, &out); err != nil {
			return err
		}
		if !out[mutation].Success {
			return refused("change the labels of", identifier)
		}
		return nil
	}
	for _, name := range add {
		if _, has := r.Labels[name]; has {
			continue
		}
		id, ok := ids[name]
		if !ok {
			return &LinearError{Kind: Failed, Message: fmt.Sprintf("Linear has no label %q for %s's team", name, identifier)}
		}
		if err := change("issueAddLabel", r.ID, id); err != nil {
			return err
		}
	}
	for _, name := range remove {
		if id, has := r.Labels[name]; has {
			if err := change("issueRemoveLabel", r.ID, id); err != nil {
				return err
			}
		}
	}
	return nil
}

const teamStatesQuery = `query($id: String!) { issue(id: $id) { id team { states(first: 100) { nodes { id type position } } } } }`

// SetState closes an issue (its team's first completed state) or opens it again (its first
// unstarted state, else its first backlog state).
func (l *RealLinear) SetState(ctx context.Context, identifier string, closed bool) error {
	var out struct {
		Issue *struct {
			ID   string `json:"id"`
			Team struct {
				States struct {
					Nodes []struct {
						ID       string  `json:"id"`
						Type     string  `json:"type"`
						Position float64 `json:"position"`
					} `json:"nodes"`
				} `json:"states"`
			} `json:"team"`
		} `json:"issue"`
	}
	if err := l.query(ctx, teamStatesQuery, map[string]any{"id": identifier}, &out); err != nil {
		return err
	}
	if out.Issue == nil {
		return &LinearError{Kind: NotFound, Message: fmt.Sprintf("Linear issue %s was not found", identifier)}
	}
	wanted := []string{"unstarted", "backlog"}
	if closed {
		wanted = []string{"completed"}
	}
	state := ""
	for _, kind := range wanted {
		best := -1.0
		for _, s := range out.Issue.Team.States.Nodes {
			if s.Type == kind && (state == "" || s.Position < best) {
				state, best = s.ID, s.Position
			}
		}
		if state != "" {
			break
		}
	}
	if state == "" {
		return &LinearError{Kind: Failed, Message: fmt.Sprintf("%s's team has no %s state", identifier, wanted[0])}
	}
	var done struct {
		IssueUpdate struct {
			Success bool `json:"success"`
		} `json:"issueUpdate"`
	}
	const update = `mutation($id: String!, $state: String!) { issueUpdate(id: $id, input: {stateId: $state}) { success } }`
	if err := l.query(ctx, update, map[string]any{"id": out.Issue.ID, "state": state}, &done); err != nil {
		return err
	}
	if !done.IssueUpdate.Success {
		return refused(map[bool]string{true: "close", false: "reopen"}[closed], identifier)
	}
	return nil
}
