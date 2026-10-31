package linearmcp

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// RealLinear reads Linear's GraphQL API with a personal API key (Linear ▸ Settings ▸ Security
// & access ▸ Personal API keys). Answers are shared for sharedFor (#932): every wait polls on
// its own, and the same query asked twice in one poll costs Linear's rate limit once.
type RealLinear struct {
	// API is the GraphQL endpoint: https://api.linear.app/graphql.
	API    string
	Key    func() string
	Client *http.Client

	mu      sync.Mutex
	recent  map[string]sharedBody
	sharing time.Duration
}

type sharedBody struct {
	at   time.Time
	body json.RawMessage
}

const (
	perPage   = 100
	sharedFor = 25 * time.Second
	// historyPerIssue is how many of an updated issue's latest changes are read for labels and closes.
	historyPerIssue = 50
)

// NewRealLinear reads api (Linear's own when empty) with key's answer.
func NewRealLinear(api string, key func() string) *RealLinear {
	if api == "" {
		api = "https://api.linear.app/graphql"
	}
	return &RealLinear{API: api, Key: key, Client: &http.Client{Timeout: 30 * time.Second},
		recent: map[string]sharedBody{}, sharing: sharedFor}
}

// MARK: GraphQL

type gqlError struct {
	Message    string `json:"message"`
	Extensions struct {
		Code            string `json:"code"`
		UserPresentable string `json:"userPresentableMessage"`
	} `json:"extensions"`
}

// query asks Linear query with variables and reads its data into out.
func (l *RealLinear) query(ctx context.Context, query string, variables map[string]any, out any) error {
	key := l.Key()
	if key == "" {
		return &LinearError{Kind: NotSignedIn, Message: "Linear is not signed in: connect Linear in Connectors, or set LINEAR_API_KEY to a personal API key"}
	}
	body, err := json.Marshal(map[string]any{"query": query, "variables": variables})
	if err != nil {
		return &LinearError{Kind: Failed, Message: "Linear: " + err.Error()}
	}
	l.mu.Lock()
	shared, have := l.recent[string(body)]
	l.mu.Unlock()
	var data json.RawMessage
	if have && time.Since(shared.at) < l.sharing {
		data = shared.body
	} else {
		if data, err = l.post(ctx, key, body); err != nil {
			return err
		}
		l.mu.Lock()
		for k, v := range l.recent {
			if time.Since(v.at) >= l.sharing {
				delete(l.recent, k)
			}
		}
		l.recent[string(body)] = sharedBody{at: time.Now(), body: data}
		l.mu.Unlock()
	}
	if err := json.Unmarshal(data, out); err != nil {
		return &LinearError{Kind: Failed, Message: "Linear: " + err.Error()}
	}
	return nil
}

func (l *RealLinear) post(ctx context.Context, key string, body []byte) (json.RawMessage, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, l.API, bytes.NewReader(body))
	if err != nil {
		return nil, &LinearError{Kind: Failed, Message: "Linear: " + err.Error()}
	}
	req.Header.Set("Content-Type", "application/json")
	// A personal API key goes as it is; an OAuth token says Bearer (the key func adds it).
	req.Header.Set("Authorization", key)
	req.Header.Set("User-Agent", "agents-linear-mcp")
	res, err := l.Client.Do(req)
	if err != nil {
		return nil, &LinearError{Kind: Failed, Message: "Linear: " + err.Error()}
	}
	defer res.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(res.Body, 32<<20))
	if err != nil {
		return nil, &LinearError{Kind: Failed, Message: "Linear: " + err.Error()}
	}
	var reply struct {
		Data   json.RawMessage `json:"data"`
		Errors []gqlError      `json:"errors"`
	}
	_ = json.Unmarshal(raw, &reply)
	if len(reply.Errors) == 0 && res.StatusCode >= 200 && res.StatusCode < 300 && len(reply.Data) > 0 {
		return reply.Data, nil
	}
	return nil, linearError(res, reply.Errors)
}

// linearError is a failed answer as a LinearError.
func linearError(res *http.Response, errs []gqlError) *LinearError {
	message := fmt.Sprintf("Linear answered %d", res.StatusCode)
	code := ""
	if len(errs) > 0 {
		code = strings.ToUpper(errs[0].Extensions.Code)
		message = "Linear: " + errs[0].Message
		if errs[0].Extensions.UserPresentable != "" {
			message = "Linear: " + errs[0].Extensions.UserPresentable
		}
	}
	switch {
	case code == "RATELIMITED" || res.StatusCode == http.StatusTooManyRequests:
		retry := 60000
		if reset, err := strconv.ParseInt(res.Header.Get("X-RateLimit-Requests-Reset"), 10, 64); err == nil {
			if ms := reset - time.Now().UnixMilli(); ms > 0 {
				retry = int(ms)
			}
		}
		return &LinearError{Kind: RateLimited, Message: "Linear's rate limit is reached", RetryAfterMs: retry}
	case code == "AUTHENTICATION_ERROR" || res.StatusCode == http.StatusUnauthorized:
		return &LinearError{Kind: NotSignedIn, Message: "Linear refused the key: connect Linear again, or make a new personal API key"}
	case code == "FORBIDDEN" || res.StatusCode == http.StatusForbidden:
		return &LinearError{Kind: NotSignedIn, Message: message}
	case strings.Contains(strings.ToLower(message), "not found"):
		return &LinearError{Kind: NotFound, Message: message}
	}
	return &LinearError{Kind: Failed, Message: message}
}

// MARK: What is read

const fragments = `
fragment P on User { id displayName app guest }
fragment I on Issue {
  id identifier title url createdAt
  team { key } state { name type } labels { nodes { name } } assignee { id displayName }
  creator { ...P } botActor { name }
}`

type gqlPerson struct {
	ID          string `json:"id"`
	DisplayName string `json:"displayName"`
	App         bool   `json:"app"`
	Guest       bool   `json:"guest"`
}

type gqlBot struct {
	Name string `json:"name"`
}

// person is who did something: the user, else the app (bot) that did it, else nobody.
func person(user *gqlPerson, bot *gqlBot) *Person {
	if user != nil {
		return &Person{ID: user.ID, Name: user.DisplayName, App: user.App, Guest: user.Guest}
	}
	if bot != nil {
		name := bot.Name
		if name == "" {
			name = "app"
		}
		return &Person{Name: name, App: true}
	}
	return nil
}

type gqlIssue struct {
	ID         string `json:"id"`
	Identifier string `json:"identifier"`
	Title      string `json:"title"`
	URL        string `json:"url"`
	CreatedAt  string `json:"createdAt"`
	Team       *struct {
		Key string `json:"key"`
	} `json:"team"`
	State *struct {
		Name string `json:"name"`
		Type string `json:"type"`
	} `json:"state"`
	Labels struct {
		Nodes []struct {
			Name string `json:"name"`
		} `json:"nodes"`
	} `json:"labels"`
	Assignee *struct {
		ID          string `json:"id"`
		DisplayName string `json:"displayName"`
	} `json:"assignee"`
	Creator  *gqlPerson `json:"creator"`
	BotActor *gqlBot    `json:"botActor"`
}

func (g gqlIssue) issue() Issue {
	i := Issue{ID: g.ID, Identifier: g.Identifier, Title: g.Title, URL: g.URL, CreatedAt: g.CreatedAt,
		Creator: person(g.Creator, g.BotActor), Labels: []string{}}
	if g.Team != nil {
		i.Team = g.Team.Key
	}
	if g.State != nil {
		i.State, i.StateType = g.State.Name, g.State.Type
	}
	for _, l := range g.Labels.Nodes {
		i.Labels = append(i.Labels, l.Name)
	}
	sort.Strings(i.Labels)
	if g.Assignee != nil {
		i.Assignee, i.AssigneeID = g.Assignee.DisplayName, g.Assignee.ID
	}
	return i
}

type pageInfo struct {
	HasNextPage bool `json:"hasNextPage"`
}

func teamFilter(team string) map[string]any {
	return map[string]any{"key": map[string]any{"eq": team}}
}

// isClosed says whether a state type is a closed one.
func isClosed(stateType string) bool { return stateType == "completed" || stateType == "canceled" }

// Activity reads what happened since, of one kind: issues created, comments created, or the
// history of issues updated (labels added, moves into a closed state).
func (l *RealLinear) Activity(ctx context.Context, kind Kind, team, since string) ([]Activity, bool, error) {
	switch kind {
	case Opened:
		return l.opened(ctx, team, since)
	case Commented:
		return l.commented(ctx, team, since)
	}
	return l.changed(ctx, kind, team, since)
}

func (l *RealLinear) opened(ctx context.Context, team, since string) ([]Activity, bool, error) {
	filter := map[string]any{"createdAt": map[string]any{"gte": since}}
	if team != "" {
		filter["team"] = teamFilter(team)
	}
	var out struct {
		Issues struct {
			Nodes    []gqlIssue `json:"nodes"`
			PageInfo pageInfo   `json:"pageInfo"`
		} `json:"issues"`
	}
	q := `query Opened($filter: IssueFilter, $first: Int) {
  issues(filter: $filter, first: $first, orderBy: createdAt) { nodes { ...I } pageInfo { hasNextPage } }
}` + fragments
	if err := l.query(ctx, q, map[string]any{"filter": filter, "first": perPage}, &out); err != nil {
		return nil, false, err
	}
	var items []Activity
	for _, n := range out.Issues.Nodes {
		i := n.issue()
		items = append(items, Activity{ID: i.ID, At: i.CreatedAt, Issue: i, Kind: Opened, By: i.Creator})
	}
	return items, out.Issues.PageInfo.HasNextPage, nil
}

func (l *RealLinear) commented(ctx context.Context, team, since string) ([]Activity, bool, error) {
	filter := map[string]any{"createdAt": map[string]any{"gte": since}}
	if team != "" {
		filter["issue"] = map[string]any{"team": teamFilter(team)}
	}
	var out struct {
		Comments struct {
			Nodes []struct {
				ID        string     `json:"id"`
				Body      string     `json:"body"`
				URL       string     `json:"url"`
				CreatedAt string     `json:"createdAt"`
				User      *gqlPerson `json:"user"`
				BotActor  *gqlBot    `json:"botActor"`
				Issue     *gqlIssue  `json:"issue"`
			} `json:"nodes"`
			PageInfo pageInfo `json:"pageInfo"`
		} `json:"comments"`
	}
	q := `query Commented($filter: CommentFilter, $first: Int) {
  comments(filter: $filter, first: $first, orderBy: createdAt) {
    nodes { id body url createdAt user { ...P } botActor { name } issue { ...I } }
    pageInfo { hasNextPage }
  }
}` + fragments
	if err := l.query(ctx, q, map[string]any{"filter": filter, "first": perPage}, &out); err != nil {
		return nil, false, err
	}
	var items []Activity
	for _, c := range out.Comments.Nodes {
		if c.Issue == nil { // a comment on a folder update, not an issue
			continue
		}
		items = append(items, Activity{ID: c.ID, At: c.CreatedAt, Issue: c.Issue.issue(), Kind: Commented,
			By: person(c.User, c.BotActor), CommentURL: c.URL, CommentBody: clip(c.Body)})
	}
	return items, out.Comments.PageInfo.HasNextPage, nil
}

type gqlHistory struct {
	ID          string     `json:"id"`
	CreatedAt   string     `json:"createdAt"`
	Actor       *gqlPerson `json:"actor"`
	BotActor    *gqlBot    `json:"botActor"`
	AddedLabels []struct {
		Name string `json:"name"`
	} `json:"addedLabels"`
	FromState *struct {
		Type string `json:"type"`
	} `json:"fromState"`
	ToState *struct {
		Type string `json:"type"`
	} `json:"toState"`
	// ToAssignee is who it was assigned to, for issue.assigned (#2034).
	ToAssignee *struct {
		ID string `json:"id"`
	} `json:"toAssignee"`
}

// changed reads the latest history of the issues updated since: a label added is labelled, a
// move from an open state into a closed one is closed. Labels and closes share the one query,
// so a poll of both costs one. history(first:) is the newest first.
func (l *RealLinear) changed(ctx context.Context, kind Kind, team, since string) ([]Activity, bool, error) {
	filter := map[string]any{"updatedAt": map[string]any{"gte": since}}
	if team != "" {
		filter["team"] = teamFilter(team)
	}
	var out struct {
		Viewer struct {
			ID string `json:"id"`
		} `json:"viewer"`
		Issues struct {
			Nodes []struct {
				gqlIssue
				History struct {
					Nodes []gqlHistory `json:"nodes"`
				} `json:"history"`
			} `json:"nodes"`
			PageInfo pageInfo `json:"pageInfo"`
		} `json:"issues"`
	}
	q := `query Changed($filter: IssueFilter, $first: Int, $history: Int) {
  viewer { id }
  issues(filter: $filter, first: $first, orderBy: updatedAt) {
    nodes {
      ...I
      history(first: $history) {
        nodes { id createdAt actor { ...P } botActor { name } addedLabels { name } fromState { type } toState { type } toAssignee { id } }
      }
    }
    pageInfo { hasNextPage }
  }
}` + fragments
	if err := l.query(ctx, q, map[string]any{"filter": filter, "first": perPage, "history": historyPerIssue}, &out); err != nil {
		return nil, false, err
	}
	var items []Activity
	for _, n := range out.Issues.Nodes {
		i := n.gqlIssue.issue()
		for _, h := range n.History.Nodes {
			if !before(h.CreatedAt, since) {
				by := person(h.Actor, h.BotActor)
				switch kind {
				case Labelled:
					for _, label := range h.AddedLabels {
						items = append(items, Activity{ID: h.ID + ":" + label.Name, At: h.CreatedAt, Issue: i, Kind: Labelled,
							By: by, Label: label.Name})
					}
				case Closed:
					if h.ToState != nil && isClosed(h.ToState.Type) && (h.FromState == nil || !isClosed(h.FromState.Type)) {
						items = append(items, Activity{ID: h.ID, At: h.CreatedAt, Issue: i, Kind: Closed, By: by, Reason: h.ToState.Type})
					}
				// To the connection's owner (#2034), by anyone.
				case Assigned:
					if h.ToAssignee != nil && h.ToAssignee.ID != "" && h.ToAssignee.ID == out.Viewer.ID {
						items = append(items, Activity{ID: h.ID, At: h.CreatedAt, Issue: i, Kind: Assigned, By: by})
					}
				}
			}
		}
	}
	return items, out.Issues.PageInfo.HasNextPage, nil
}

// before says whether a is earlier than b; a time that is not one is earliest of all.
func before(a, b string) bool {
	ta, oka := parseTime(a)
	tb, okb := parseTime(b)
	switch {
	case !oka:
		return okb
	case !okb:
		return false
	}
	return ta.Before(tb)
}
