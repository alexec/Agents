package jiramcp

import (
	"context"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/mcpevents"
)

// What the events and the view read from Jira (#3247). RealJira reads it over Jira's REST API
// (rest.go), Jira Cloud's with an email and an API token, or Jira Data Center's with a
// personal access token; tests use a fake, or a fake site over HTTP.

// Person is who did something: a user of the site, or an app.
type Person struct {
	// ID is the user's account id on Jira Cloud, their user name on Jira Data Center.
	ID    string
	Name  string
	Email string
	// App says it is an app (a bot), not a person: Jira Cloud's accountType "app".
	App bool
	// Customer says it is a Jira Service Management customer, not one of the site's users:
	// accountType "customer". It is the Linear server's guest.
	Customer bool
	// Avatar is the person's picture: on Atlassian's avatar host or Gravatar (Jira Cloud), or on
	// the site (Data Center's /secure/useravatar); "" for none (#4363).
	Avatar string
}

// trusted says whether p is one of the site's own (#728): a user, never a customer or an app.
func (p *Person) trusted() bool { return p != nil && !p.App && !p.Customer }

func (p *Person) name() string {
	if p == nil {
		return ""
	}
	return p.Name
}

func (p *Person) avatar() string {
	if p == nil {
		return ""
	}
	return p.Avatar
}

// Issue is an issue as the events name it.
type Issue struct {
	ID      string
	Key     string // PROJ-12
	Title   string
	Project string // its key, as PROJ
	Status  string // its name, as In Progress
	// StatusCategory is new (To Do), indeterminate (In Progress) or done.
	StatusCategory string
	Labels         []string
	Assignee       string
	AssigneeID     string // the assignee's ID, for the Issues page's Needs you (#2453)
	URL            string
	CreatedAt      string
	Creator        *Person
}

// Created is when the issue was made, when Jira said it as a time.
func (i Issue) Created() (time.Time, bool) { return parseTime(i.CreatedAt) }

func (i Issue) json() map[string]any {
	labels := i.Labels
	if labels == nil {
		labels = []string{}
	}
	return map[string]any{"id": i.ID, "key": i.Key, "title": i.Title, "project": i.Project, "status": i.Status,
		"labels": labels, "assignee": i.Assignee, "author": i.Creator.name(), "url": i.URL}
}

// Kind is what happened to an issue.
type Kind string

const (
	Opened    Kind = "opened"
	Labelled  Kind = "labelled"
	Commented Kind = "commented"
	// Assigned is to the connection's owner (#2034).
	Assigned Kind = "assigned"
)

// Activity is one thing that happened to an issue.
type Activity struct {
	// ID is the thing's own: the issue's for opened, the comment's, or the changelog entry's.
	ID    string
	At    string
	Issue Issue
	Kind  Kind
	// By is who did it.
	By *Person
	// Label for a label added.
	Label string
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
	case Assigned:
		d["by"], d["assignedAt"] = a.By.name(), a.At
	}
	return d
}

// trusted says whether the thing was the site's own doing (#728): its author's for an issue
// opened, whoever did it for the rest.
func (a Activity) trusted() bool {
	if a.Kind == Opened {
		return a.Issue.Creator.trusted()
	}
	return a.By.trusted()
}

// Jira is what the events ask of Jira.
type Jira interface {
	// Activity is what happened to the site's issues at or after since, of one kind, in
	// project when it is not empty.
	Activity(ctx context.Context, kind Kind, project, since string) (items []Activity, truncated bool, err error)
}

// ErrorKind is why a Jira call failed.
type ErrorKind int

const (
	NotSignedIn ErrorKind = iota
	RateLimited
	NotFound
	Failed
)

// JiraError is a failed Jira call.
type JiraError struct {
	Kind         ErrorKind
	Message      string
	RetryAfterMs int
}

func (e *JiraError) Error() string { return e.Message }

// notSignedIn is what is said when there is no site or token.
const notSignedIn = "Jira is not signed in: connect Jira in Connectors, or set JIRA_URL to the site, and JIRA_EMAIL " +
	"and JIRA_API_TOKEN (Jira Cloud), or JIRA_API_TOKEN to a personal access token (Jira Data Center)"

// commentChars is the most of a comment's body an event gives.
const commentChars = 4000

func clip(body string) string {
	r := []rune(body)
	if len(r) > commentChars {
		return string(r[:commentChars]) + "…"
	}
	return body
}

// jiraTime is how Jira's REST API writes a time: 2026-11-02T09:15:00.000+0000, with no colon
// in the offset.
const jiraTime = "2006-01-02T15:04:05.000-0700"

func parseTime(text string) (time.Time, bool) {
	if t, err := time.Parse(time.RFC3339Nano, text); err == nil {
		return t, true
	}
	t, err := time.Parse(jiraTime, text)
	return t, err == nil
}

// normalized is text in mcpevents.TimeLayout, or "" when it is not a time.
func normalized(text string) string {
	t, ok := parseTime(text)
	if !ok {
		return ""
	}
	return mcpevents.TimeString(t)
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
