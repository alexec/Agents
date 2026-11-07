package azureboardsmcp

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// The azureboards server's tools (#3804), over Azure DevOps's REST API with the same token as
// the events: list the project's work items, read one with its comments, and comment on one.
// What a person decides (a work item's state, who it is assigned to) is not here.

type listArgs struct {
	State string `json:"state,omitempty" jsonschema:"open (when left out), closed or all; closed is a state of the Completed or Removed category"`
	Label string `json:"label,omitempty" jsonschema:"only work items with this tag"`
	Type  string `json:"type,omitempty" jsonschema:"only work items of this type, as Bug or User Story"`
	Area  string `json:"area,omitempty" jsonschema:"only work items in this area path or under it"`
	Mine  bool   `json:"mine,omitempty" jsonschema:"true: only work items assigned to the person whose token this server has"`
}

type idArgs struct {
	ID int `json:"id" jsonschema:"the work item's id, as issue.id in an event"`
}

type commentArgs struct {
	ID   int    `json:"id" jsonschema:"the work item's id, as issue.id in an event"`
	Body string `json:"body" jsonschema:"the comment, in Markdown"`
}

// descriptionChars is the most of a description or of a comment a tool gives.
const descriptionChars = 20000

// commentsRead is the newest comments get_work_item gives.
const commentsRead = 50

// structured is a tool's answer: the data, and the same as JSON text for a client that
// reads only text.
func structured(data map[string]any) *mcp.CallToolResult {
	text, _ := json.Marshal(data)
	return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: string(text)}}, StructuredContent: data}
}

// failed is a tool's answer that it failed, with why.
func failed(err error) *mcp.CallToolResult {
	msg := err.Error()
	if e, ok := err.(*BoardsError); ok && e.Kind == RateLimited {
		msg = fmt.Sprintf("%s; try again in %ds", e.Message, (e.RetryAfterMs+999)/1000)
	}
	return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: msg}}, IsError: true}
}

// tool adds a tool whose answer is f's, or why it failed.
func tool[In any](server *mcp.Server, t *mcp.Tool, f func(context.Context, In) (map[string]any, error)) {
	mcp.AddTool(server, t, func(ctx context.Context, _ *mcp.CallToolRequest, in In) (*mcp.CallToolResult, any, error) {
		r, err := f(ctx, in)
		if err != nil {
			return failed(err), nil, nil
		}
		return structured(r), nil, nil
	})
}

func itemID(id int) error {
	if id <= 0 {
		return fmt.Errorf("id is the work item's id, as 12")
	}
	return nil
}

// AddTools puts the tools on server.
func AddTools(server *mcp.Server, b *RealBoards) {
	tool(server, &mcp.Tool{Name: "list_work_items", Title: "List work items",
		Description: "The project's work items, changed last first, at most 50: open ones when state is left out. " +
			"Each has its id, title, type, state, area, tags (labels), assignee, author and page."},
		func(ctx context.Context, in listArgs) (map[string]any, error) {
			state := strings.ToLower(strings.TrimSpace(in.State))
			switch state {
			case "":
				state = "open"
			case "open", "closed", "all":
			default:
				return nil, fmt.Errorf("state is open, closed or all, not %s", in.State)
			}
			list, truncated, err := b.List(ctx, Filter{State: state, Label: in.Label, Type: in.Type, Area: in.Area, Mine: in.Mine})
			if err != nil {
				return nil, err
			}
			items := make([]any, len(list))
			for i, w := range list {
				items[i] = w.json()
			}
			return map[string]any{"workItems": items, "truncated": truncated}, nil
		})

	tool(server, &mcp.Tool{Name: "get_work_item", Title: "Read a work item",
		Description: "One work item: its fields, its description (HTML, as Azure DevOps keeps it) and its newest 50 comments, newest first."},
		func(ctx context.Context, in idArgs) (map[string]any, error) {
			if err := itemID(in.ID); err != nil {
				return nil, err
			}
			w, description, comments, err := b.Get(ctx, in.ID, commentsRead)
			if err != nil {
				return nil, err
			}
			list := make([]any, len(comments))
			for i, c := range comments {
				list[i] = map[string]any{"id": c.ID, "author": c.Author, "bot": c.AuthorIsBot, "at": c.At, "body": clip(c.Body, descriptionChars)}
			}
			out := w.json()
			out["closed"] = w.Closed
			out["createdAt"] = w.CreatedAt
			out["description"] = clip(description, descriptionChars)
			out["comments"] = list
			return out, nil
		})

	tool(server, &mcp.Tool{Name: "comment_on_work_item", Title: "Comment on a work item",
		Description: "Leaves a comment on a work item, in Markdown, as the person whose token this server has."},
		func(ctx context.Context, in commentArgs) (map[string]any, error) {
			if err := itemID(in.ID); err != nil {
				return nil, err
			}
			if strings.TrimSpace(in.Body) == "" {
				return nil, fmt.Errorf("body is the comment, and it is empty")
			}
			id, url, err := b.AddComment(ctx, in.ID, in.Body)
			if err != nil {
				return nil, err
			}
			return map[string]any{"id": id, "url": url}, nil
		})
}
