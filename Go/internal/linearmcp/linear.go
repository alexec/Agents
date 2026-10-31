package linearmcp

import (
	"context"
	"time"
)

// What the events read from Linear (#839). RealLinear reads it over Linear's GraphQL API with
// a personal API key; tests use a fake, or recorded answers.

// Person is who did something: a workspace user, or an app or integration.
type Person struct {
	// ID is the user's Linear id; an app with no user has none.
	ID   string
	Name string
	// App says it is an app or integration (a bot), not a person.
	App bool
	// Guest says it is a guest of the workspace, not one of its members.
	Guest bool
}

// trusted says whether p is one of the workspace's own (#728): a member, not a guest, never
// an app.
func (p *Person) trusted() bool { return p != nil && !p.App && !p.Guest }

func (p *Person) name() string {
	if p == nil {
		return ""
	}
	return p.Name
}

// Issue is an issue as the events name it.
type Issue struct {
	ID         string
	Identifier string
	Title      string
	Team       string // its key, as ENG
	State      string // its name, as In Progress
	StateType  string // triage, backlog, unstarted, started, completed or canceled
	Labels     []string
	Assignee   string
	AssigneeID string // the assignee's user id, for the Issues page's Needs you (#2453)
	URL        string
	CreatedAt  string
	Creator    *Person
}

func (i Issue) json() map[string]any {
	labels := i.Labels
	if labels == nil {
		labels = []string{}
	}
	return map[string]any{"id": i.ID, "identifier": i.Identifier, "title": i.Title, "team": i.Team, "state": i.State,
		"labels": labels, "assignee": i.Assignee, "author": i.Creator.name(), "url": i.URL}
}

// Kind is what happened to an issue.
type Kind string

const (
	Opened    Kind = "opened"
	Labelled  Kind = "labelled"
	Commented Kind = "commented"
	Closed    Kind = "closed"
	// Assigned is to the connection's owner (#2034).
	Assigned Kind = "assigned"
)

// Activity is one thing that happened to an issue.
type Activity struct {
	// ID is the thing's own: the issue's for opened, the comment's, or the history entry's.
	ID    string
	At    string
	Issue Issue
	Kind  Kind
	// By is who did it.
	By *Person
	// Label for a label; Reason (completed or canceled) for a close.
	Label, Reason string
	// CommentURL and CommentBody (clipped) for a comment.
	CommentURL, CommentBody string
}

func (a Activity) data() map[string]any {
	d := map[string]any{"issue": a.Issue.json()}
	switch a.Kind {
	case Opened:
		d["openedAt"] = a.At
	case Labelled:
		d["label"], d["by"], d["labelledAt"] = a.Label, a.By.name(), a.At
	case Commented:
		d["comment"] = map[string]any{"author": a.By.name(), "url": a.CommentURL, "body": a.CommentBody}
		d["commentedAt"] = a.At
	case Closed:
		d["reason"], d["by"], d["closedAt"] = a.Reason, a.By.name(), a.At
	case Assigned:
		d["by"], d["assignedAt"] = a.By.name(), a.At
	}
	return d
}

// trusted says whether the thing was the workspace's own doing (#728): its author's for an
// issue opened, whoever did it for the rest.
func (a Activity) trusted() bool {
	if a.Kind == Opened {
		return a.Issue.Creator.trusted()
	}
	return a.By.trusted()
}

// Linear is what the events ask of Linear.
type Linear interface {
	// Activity is what happened to the workspace's issues at or after since, of one kind, in
	// team when it is not empty.
	Activity(ctx context.Context, kind Kind, team, since string) (items []Activity, truncated bool, err error)
}

// ErrorKind is why a Linear call failed.
type ErrorKind int

const (
	NotSignedIn ErrorKind = iota
	RateLimited
	NotFound
	Failed
)

// LinearError is a failed Linear call.
type LinearError struct {
	Kind         ErrorKind
	Message      string
	RetryAfterMs int
}

func (e *LinearError) Error() string { return e.Message }

// commentChars is the most of a comment's body an event gives.
const commentChars = 4000

func clip(body string) string {
	r := []rune(body)
	if len(r) > commentChars {
		return string(r[:commentChars]) + "…"
	}
	return body
}

// timeLayout is how the events draft carries a time: ISO 8601 in UTC with milliseconds, which
// sorts as text in time order.
const timeLayout = "2006-01-02T15:04:05.000Z"

func timeString(t time.Time) string { return t.UTC().Format(timeLayout) }

func parseTime(text string) (time.Time, bool) {
	t, err := time.Parse(time.RFC3339Nano, text)
	return t, err == nil
}

// normalized is text in timeLayout, or "" when it is not a time.
func normalized(text string) string {
	t, ok := parseTime(text)
	if !ok {
		return ""
	}
	return timeString(t)
}
