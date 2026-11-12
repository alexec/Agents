package azureboardsmcp

import (
	"context"
	"regexp"
	"strings"
	"time"
)

// What the events and the tools read from Azure Boards (#3804). RealBoards reads it over Azure
// DevOps's REST API (rest.go) with a personal access token; tests use a fake Azure DevOps over
// HTTP. A work item is the tracker's issue: its tags are the issue's labels.

// Person is who did something: a member of the organization, or a bot.
type Person struct {
	ID   string
	Name string
	// DisplayName is the identity's display name, also when Name is its sign-in name: an Azure
	// DevOps login is either (#3853).
	DisplayName string
	// Bot says it is not a person: a build service, a service or a group (#728).
	Bot bool
	// Avatar is the identity's picture, on the organization; "" for none (#4363).
	Avatar string
}

// trusted says whether p is a person of the organization, never a bot.
func (p *Person) trusted() bool { return p != nil && !p.Bot }

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

// WorkItem is a work item as the events and the tools name it.
type WorkItem struct {
	ID    int
	Title string
	Type  string // Bug, User Story, Task, …
	State string // its process's name, as Active
	// Closed says its state is in the Completed or Removed category.
	Closed     bool
	Area       string // its area path, as Web App\Team
	Tags       []string
	Assignee   string
	AssigneeID string
	URL        string
	CreatedAt  string
	Creator    *Person
	// Category is its state's category: Proposed, InProgress, Resolved, Completed or Removed.
	Category string
	// UpdatedAt is when it changed last.
	UpdatedAt string
}

func (w WorkItem) json() map[string]any {
	tags := w.Tags
	if tags == nil {
		tags = []string{}
	}
	return map[string]any{"id": w.ID, "key": itoa(w.ID), "title": w.Title, "type": w.Type, "status": w.State,
		"area": w.Area, "labels": tags, "assignee": w.Assignee, "author": w.Creator.name(), "url": w.URL}
}

// Kind is what happened to a work item.
type Kind string

const (
	Opened    Kind = "opened"
	Labelled  Kind = "labelled"
	Commented Kind = "commented"
	Closed    Kind = "closed"
	// Assigned is to the token's owner (#2034).
	Assigned Kind = "assigned"
)

// Activity is one thing that happened to a work item.
type Activity struct {
	// ID is the thing's own: the work item's for opened, the comment's, or the update's.
	ID       string
	At       string
	WorkItem WorkItem
	Kind     Kind
	// By is who did it.
	By *Person
	// Label for a tag added; State for a state it closed in.
	Label, State string
	// CommentURL and CommentBody (clipped) for a comment.
	CommentURL, CommentBody string
	// Project is the project it is in, organization/project: its ref's topic (#4728).
	Project string
}

func (a Activity) data() map[string]any {
	d := map[string]any{"issue": a.WorkItem.json()}
	at := normalized(a.At)
	switch a.Kind {
	case Opened:
		d["openedAt"] = at
	case Labelled:
		d["label"], d["by"], d["labelledAt"] = a.Label, a.By.name(), at
	case Commented:
		d["comment"] = map[string]any{"author": a.By.name(), "url": a.CommentURL, "body": a.CommentBody}
		d["commentedAt"] = at
	case Closed:
		d["state"], d["by"], d["closedAt"] = a.State, a.By.name(), at
	case Assigned:
		d["by"], d["assignedAt"] = a.By.name(), at
	}
	return d
}

// trusted says whether the thing was a person's doing (#728): its author's for a work item
// opened, whoever did it for the rest.
func (a Activity) trusted() bool {
	if a.Kind == Opened {
		return a.WorkItem.Creator.trusted()
	}
	return a.By.trusted()
}

// Boards is what the events ask of Azure Boards.
type Boards interface {
	// Activity is what happened to the project's work items at or after since, of one kind.
	Activity(ctx context.Context, kind Kind, since string) (items []Activity, truncated bool, err error)
}

// ErrorKind is why an Azure DevOps call failed.
type ErrorKind int

const (
	NotSignedIn ErrorKind = iota
	RateLimited
	NotFound
	Failed
)

// BoardsError is a failed Azure DevOps call.
type BoardsError struct {
	Kind         ErrorKind
	Message      string
	RetryAfterMs int
}

func (e *BoardsError) Error() string { return e.Message }

// commentChars is the most of a comment's body an event gives.
const commentChars = 4000

func clip(body string, chars int) string {
	r := []rune(body)
	if len(r) > chars {
		return string(r[:chars]) + "…"
	}
	return body
}

// botName is a bot's name: a build service's ("Project Collection Build Service (acme)"), and
// others named as a bot, as the azuredevops server's.
var botName = regexp.MustCompile(`build service|[-_ ]bot$|\[bot\]$`)

// isBot says whether an identity is a bot: one named as one, a build service's (Build\…), or
// a service or a group, whose descriptors start svc., s2s. or vssgp..
func isBot(i identity) bool {
	unique, descriptor := strings.ToLower(i.UniqueName), strings.ToLower(i.Descriptor)
	return i.IsContainer || strings.HasPrefix(unique, `build\`) || strings.HasPrefix(descriptor, "svc.") ||
		strings.HasPrefix(descriptor, "s2s.") || strings.HasPrefix(descriptor, "vssgp.") ||
		botName.MatchString(strings.ToLower(i.DisplayName))
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
