package linearmcp

import (
	"context"
	"embed"
	"encoding/json"
	"fmt"
	"sort"
	"strings"

	"github.com/alexec/agents/Go/internal/richtext"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// The linear server's view (#1343): Issues (ui://linear/issues), an MCP App page (SEP-1865)
// the Agents host draws on the Mac, the Remote and the web page, in the github server's
// shape (Go/internal/githubmcp/views.go). It is fed by show_issues, a read-only tool, so it
// can be pinned. It only reads: Linear's own MCP server (mcp.linear.app) changes issues.

// pages/bridge.js, pages/lineage.js and pages/common.css are the github server's, copied: a page has no
// network, so it carries its own.
//
//go:embed pages
var pageFiles embed.FS

const (
	viewMime  = "text/html;profile=mcp-app"
	issuesURI = "ui://linear/issues"
)

func page(name string) string {
	read := func(n string) string {
		b, err := pageFiles.ReadFile("pages/" + n)
		if err != nil {
			panic(err)
		}
		return string(b)
	}
	return strings.NewReplacer("/*common.css*/", read("common.css"), "/*bridge.js*/", read("bridge.js"), "/*lineage.js*/", read("lineage.js")).Replace(read(name))
}

func uiMeta(uri string, visibility ...string) mcp.Meta {
	return mcp.Meta{"ui": map[string]any{"visibility": visibility, "resourceUri": uri}, "ui/resourceUri": uri}
}

// Views is what the view asks of Linear.
type Views interface {
	// OpenIssues is the workspace's issues not completed or canceled, newest updated first,
	// at most 100, narrowed to a team key, a state type and a label when they are not empty,
	// and the viewer, the user of the API key, for the page's sections (#2453).
	OpenIssues(ctx context.Context, team, stateType, label string) ([]ListedIssue, *Person, error)
	// IssueDetails reads one issue's Markdown description.
	IssueDetails(ctx context.Context, identifier string) (map[string]any, error)
	// Teams is the workspace's teams, for the page's team choice.
	Teams(ctx context.Context) ([]Team, error)
}

// ListedIssue is an issue on the page.
type ListedIssue struct {
	Issue
	Priority  string // Urgent, High, Medium, Low, or "" for none
	UpdatedAt string
	Comments  int
}

func (l ListedIssue) json() map[string]any {
	d := l.Issue.json()
	d["stateType"], d["priority"], d["updatedAt"], d["comments"] = l.StateType, l.Priority, l.UpdatedAt, l.Comments
	if l.Creator != nil && l.Creator.App {
		d["authorBot"] = true
	}
	return d
}

// Team is a Linear team: its key (ENG) and its name.
type Team struct {
	Key, Name string
}

// openStateTypes are the state types a page lists, in the order it shows them.
var openStateTypes = []string{"triage", "backlog", "unstarted", "started"}

type issuesArgs struct {
	Team  string `json:"team,omitempty" jsonschema:"a team's key, such as ENG; every team when left out"`
	State string `json:"state,omitempty" jsonschema:"only issues in this state type: triage, backlog, unstarted or started"`
	Label string `json:"label,omitempty" jsonschema:"only issues with this label"`
}

type issueDetailsArgs struct {
	Identifier string `json:"identifier" jsonschema:"the issue identifier, such as ENG-12"`
}

func structured(data map[string]any) *mcp.CallToolResult {
	text, _ := json.Marshal(data)
	return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: string(text)}}, StructuredContent: data}
}

func failed(err error) *mcp.CallToolResult {
	msg := err.Error()
	if e, ok := err.(*LinearError); ok && e.Kind == RateLimited {
		msg = fmt.Sprintf("%s; try again in %ds", e.Message, (e.RetryAfterMs+999)/1000)
	}
	return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: msg}}, IsError: true}
}

// AddViews puts the view's tool and page on server.
func AddViews(server *mcp.Server, linear Views) {
	mcp.AddTool(server, &mcp.Tool{Name: "show_issues", Title: "Show Linear issues",
		Description: "The Linear workspace's open issues (not completed or canceled), newest updated first, at most 100, each with " +
			"its identifier (ENG-12), team, state, priority, labels, assignee, comment count and section for the API key's user (viewer): " +
			"needs_you (assigned to you), yours, team (the people and bots on this control plane, or the workspace's members and " +
			"apps, with no control plane) or others (guests); attention counts needs_you. A row the control plane knows has " +
			"authorName; agentOn says who is on one of the viewer's own. " +
			"It also gives the workspace's teams. " +
			"A team key, a state type (triage, backlog, unstarted, started) or a label narrows it. " +
			"Its view is the Linear issues page, where a person expands a row for its Markdown description or chooses Start Agent.",
		Annotations: &mcp.ToolAnnotations{ReadOnlyHint: true}, Meta: uiMeta(issuesURI, "model", "app")},
		func(ctx context.Context, req *mcp.CallToolRequest, in issuesArgs) (*mcp.CallToolResult, any, error) {
			if in.State != "" && !contains(openStateTypes, in.State) {
				return failed(fmt.Errorf("state must be one of %s", strings.Join(openStateTypes, ", "))), nil, nil
			}
			list, viewer, err := linear.OpenIssues(ctx, in.Team, in.State, in.Label)
			if err != nil {
				return failed(err), nil, nil
			}
			teams, err := linear.Teams(ctx)
			if err != nil {
				return failed(err), nil, nil
			}
			// The control plane's people (#2951): names a row, tells Team from Others.
			people := teamMetaOf(req.Params.Meta, "linear")
			issues := make([]any, len(list))
			// The count on the sidebar's row (#2033): the issues that need the viewer (#2453).
			needsYou := 0
			for i, l := range list {
				j := l.json()
				section := issueSection(l.Issue, viewer, people)
				j["section"] = section
				if l.Creator != nil {
					if tp, on := people[strings.ToLower(l.Creator.Email)]; on {
						j["authorName"] = tp.Name
						if tp.Bot {
							j["authorBot"] = true
						}
					}
				}
				if section == sectionNeedsYou {
					needsYou++
				}
				if section == sectionNeedsYou || section == sectionYours {
					if who := agentOnOf(req.Params.Meta, l.Identifier); who != "" {
						j["agentOn"] = who
					}
				}
				issues[i] = j
			}
			names := make([]any, len(teams))
			for i, t := range teams {
				names[i] = map[string]any{"key": t.Key, "name": t.Name}
			}
			return structured(map[string]any{"team": in.Team, "state": in.State, "label": in.Label, "viewer": viewer.name(),
				"teams": names, "states": openStateTypes, "issues": issues, "count": len(issues), "attention": needsYou}), nil, nil
		})

	mcp.AddTool(server, &mcp.Tool{Name: "show_issue_details", Title: "Show issue details",
		Description: "One issue's description, rendered as rich text for the Issues page.",
		Annotations: &mcp.ToolAnnotations{ReadOnlyHint: true}, Meta: uiMeta("", "model", "app")},
		func(ctx context.Context, _ *mcp.CallToolRequest, in issueDetailsArgs) (*mcp.CallToolResult, any, error) {
			if strings.TrimSpace(in.Identifier) == "" {
				return failed(fmt.Errorf("issue identifier is required")), nil, nil
			}
			details, err := linear.IssueDetails(ctx, in.Identifier)
			if err != nil {
				return failed(err), nil, nil
			}
			return structured(details), nil, nil
		})

	// No network at all: an empty csp, so the host draws it under its strictest policy.
	meta := mcp.Meta{"ui": map[string]any{"csp": map[string]any{}, "prefersBorder": true}}
	html := page("issues.html")
	server.AddResource(&mcp.Resource{URI: issuesURI, Name: "issues", Title: "Linear issues",
		Description: "The workspace's open Linear issues, with their team, state, priority, labels and assignee, and Start Agent; " +
			"a team, a state or a label narrows the list. A person expands a row to read its Markdown description. Fed by show_issues.", MIMEType: viewMime, Meta: meta},
		func(context.Context, *mcp.ReadResourceRequest) (*mcp.ReadResourceResult, error) {
			return &mcp.ReadResourceResult{Contents: []*mcp.ResourceContents{{URI: issuesURI, MIMEType: viewMime, Text: html, Meta: meta}}}, nil
		})
}

// IssueDetails reads and renders one issue's Markdown description.
func (l *RealLinear) IssueDetails(ctx context.Context, identifier string) (map[string]any, error) {
	var out struct {
		Issue *struct {
			Identifier  string `json:"identifier"`
			Description string `json:"description"`
		} `json:"issue"`
	}
	q := `query IssueDetails($id: String!) { issue(id: $id) { identifier description } }`
	if err := l.query(ctx, q, map[string]any{"id": identifier}, &out); err != nil {
		return nil, err
	}
	if out.Issue == nil {
		return nil, fmt.Errorf("Linear issue %s was not found", identifier)
	}
	return map[string]any{"identifier": out.Issue.Identifier, "description": out.Issue.Description,
		"descriptionHTML": richtext.Markdown(out.Issue.Description)}, nil
}

// MARK: Read from Linear

// priorityName is Linear's priority number in words.
func priorityName(p int) string {
	return map[int]string{1: "Urgent", 2: "High", 3: "Medium", 4: "Low"}[p]
}

// OpenIssues reads the open issues, newest updated first, and the viewer, in one query.
func (l *RealLinear) OpenIssues(ctx context.Context, team, stateType, label string) ([]ListedIssue, *Person, error) {
	state := map[string]any{"type": map[string]any{"nin": []string{"completed", "canceled"}}}
	if stateType != "" {
		state = map[string]any{"type": map[string]any{"eq": stateType}}
	}
	filter := map[string]any{"state": state}
	if team != "" {
		filter["team"] = teamFilter(team)
	}
	if label != "" {
		filter["labels"] = map[string]any{"name": map[string]any{"eq": label}}
	}
	var out struct {
		Viewer *gqlPerson `json:"viewer"`
		Issues struct {
			Nodes []struct {
				gqlIssue
				Priority  int    `json:"priority"`
				UpdatedAt string `json:"updatedAt"`
				Comments  struct {
					Nodes []struct {
						ID string `json:"id"`
					} `json:"nodes"`
				} `json:"comments"`
			} `json:"nodes"`
		} `json:"issues"`
	}
	q := `query OpenIssues($filter: IssueFilter, $first: Int) {
  viewer { ...P }
  issues(filter: $filter, first: $first, orderBy: updatedAt) { nodes { ...I priority updatedAt comments(first: 50) { nodes { id } } } }
}` + fragments
	if err := l.query(ctx, q, map[string]any{"filter": filter, "first": 100}, &out); err != nil {
		return nil, nil, err
	}
	list := make([]ListedIssue, 0, len(out.Issues.Nodes))
	for _, n := range out.Issues.Nodes {
		list = append(list, ListedIssue{Issue: n.issue(), Priority: priorityName(n.Priority), UpdatedAt: n.UpdatedAt,
			Comments: len(n.Comments.Nodes)})
	}
	// orderBy updatedAt is newest first on Linear; sort anyway, so a page never jumps.
	sort.SliceStable(list, func(i, j int) bool { return list[i].UpdatedAt > list[j].UpdatedAt })
	return list, person(out.Viewer, nil), nil
}

// Teams reads the workspace's teams, by key.
func (l *RealLinear) Teams(ctx context.Context) ([]Team, error) {
	var out struct {
		Teams struct {
			Nodes []struct {
				Key  string `json:"key"`
				Name string `json:"name"`
			} `json:"nodes"`
		} `json:"teams"`
	}
	if err := l.query(ctx, `query Teams { teams(first: 100) { nodes { key name } } }`, nil, &out); err != nil {
		return nil, err
	}
	teams := make([]Team, 0, len(out.Teams.Nodes))
	for _, t := range out.Teams.Nodes {
		teams = append(teams, Team{Key: t.Key, Name: t.Name})
	}
	sort.Slice(teams, func(i, j int) bool { return teams[i].Key < teams[j].Key })
	return teams, nil
}
