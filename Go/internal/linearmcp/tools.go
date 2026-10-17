package linearmcp

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// The tools (#839): read-only, so an agent finds and reads issues; changing them is the
// person's, or an agent's through Linear's own MCP server.

// ListIssuesInput is list_issues' arguments.
type ListIssuesInput struct {
	Team          string `json:"team,omitempty" jsonschema:"only this team's issues, by its key, as ENG"`
	State         string `json:"state,omitempty" jsonschema:"only issues in this state, by its name (In Progress) or type (triage, backlog, unstarted, started, completed, canceled)"`
	Label         string `json:"label,omitempty" jsonschema:"only issues with this label"`
	Assignee      string `json:"assignee,omitempty" jsonschema:"only issues assigned to this person (name or email), me for the key's own user, none for unassigned"`
	Query         string `json:"query,omitempty" jsonschema:"only issues whose title contains this text"`
	IncludeClosed bool   `json:"include_closed,omitempty" jsonschema:"also closed (completed and canceled) issues; left out, open ones only unless state is given"`
	Limit         int    `json:"limit,omitempty" jsonschema:"at most this many, 1 to 100; 25 when left out"`
}

// GetIssueInput is get_issue's arguments.
type GetIssueInput struct {
	Issue string `json:"issue" jsonschema:"the issue's identifier, as ENG-12, or its id"`
}

func issueRow(i Issue) map[string]any {
	row := i.json()
	row["priority"] = i.Priority
	row["createdAt"] = i.CreatedAt
	return row
}

// NewServer is the MCP server of the tools, with l behind them.
func NewServer(l Linear, version string) *mcp.Server {
	s := mcp.NewServer(&mcp.Implementation{Name: "linear-mcp", Title: "Linear", Version: version}, nil)
	readOnly := &mcp.ToolAnnotations{ReadOnlyHint: true}
	mcp.AddTool(s, &mcp.Tool{Name: "list_issues", Title: "List issues", Annotations: readOnly,
		Description: "List the Linear workspace's issues, the latest updated first, filtered by team, state, label, assignee or title. Open issues only unless state or include_closed says otherwise."},
		func(ctx context.Context, _ *mcp.CallToolRequest, in ListIssuesInput) (*mcp.CallToolResult, any, error) {
			issues, more, err := l.Issues(ctx, IssueQuery{Team: in.Team, State: in.State, Label: in.Label, Assignee: in.Assignee,
				Text: in.Query, IncludeClosed: in.IncludeClosed, Limit: in.Limit})
			if err != nil {
				return toolError(err), nil, nil
			}
			rows := make([]any, len(issues))
			for i, issue := range issues {
				rows[i] = issueRow(issue)
			}
			return toolResult(map[string]any{"issues": rows, "hasMore": more}), nil, nil
		})
	mcp.AddTool(s, &mcp.Tool{Name: "get_issue", Title: "Get an issue", Annotations: readOnly,
		Description: "One Linear issue with its description and its first 50 comments, oldest first."},
		func(ctx context.Context, _ *mcp.CallToolRequest, in GetIssueInput) (*mcp.CallToolResult, any, error) {
			if in.Issue == "" {
				return toolError(errors.New("issue is needed, as ENG-12")), nil, nil
			}
			d, err := l.IssueDetail(ctx, in.Issue)
			if err != nil {
				return toolError(err), nil, nil
			}
			comments := make([]any, len(d.Comments))
			for i, c := range d.Comments {
				comments[i] = map[string]any{"author": c.Author, "body": c.Body, "url": c.URL, "createdAt": c.CreatedAt}
			}
			row := issueRow(d.Issue)
			row["description"], row["comments"] = d.Description, comments
			return toolResult(row), nil, nil
		})
	mcp.AddTool(s, &mcp.Tool{Name: "list_teams", Title: "List teams", Annotations: readOnly,
		Description: "The Linear workspace's teams: each one's key (as in ENG-12) and name."},
		func(ctx context.Context, _ *mcp.CallToolRequest, _ struct{}) (*mcp.CallToolResult, any, error) {
			teams, err := l.Teams(ctx)
			if err != nil {
				return toolError(err), nil, nil
			}
			rows := make([]any, len(teams))
			for i, t := range teams {
				rows[i] = map[string]any{"key": t.Key, "name": t.Name}
			}
			return toolResult(map[string]any{"teams": rows}), nil, nil
		})
	return s
}

func toolResult(v any) *mcp.CallToolResult {
	data, _ := json.MarshalIndent(v, "", "  ")
	return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: string(data)}}}
}

func toolError(err error) *mcp.CallToolResult {
	return &mcp.CallToolResult{IsError: true, Content: []mcp.Content{&mcp.TextContent{Text: err.Error()}}}
}
