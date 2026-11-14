package azureboardsmcp

import (
	"context"
	"io"
	"log/slog"

	"github.com/agentloops-dev/agents/Go/internal/mcpevents"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// The front, as the jira server's (Go/internal/jiramcp/front.go): MCP's stdio transport, one
// JSON-RPC message a line. It answers events/list and events/poll itself, and hands every
// other message to a go-sdk server with this server's tools, and that server's messages back
// as they come. MCP's SDKs have no events (a working-group draft), so the front also adds the
// `events` capability and the events' words to its answer to initialize.

// Instructions are the server's words.
const Instructions = "This Azure DevOps project's work items (Azure Boards), as the person whose token this server has; a work item is an issue, and its tags are its labels. " +
	"Events, polled: issue.opened, issue.labelled (a tag added), issue.commented, issue.closed (moved to a Completed or Removed state) and issue.assigned (to the person). " +
	"list_work_items and get_work_item read them, and comment_on_work_item comments; show_issues feeds the Azure Boards page. " +
	"Pull requests and builds are the azuredevops server's."

// NewServer is the server behind the front: it answers initialize and ping, and has the tools and the page (views.go).
func NewServer(version string, b *RealBoards) *mcp.Server {
	server := mcp.NewServer(&mcp.Implementation{Name: "azureboards-mcp", Title: "Azure Boards", Version: version}, nil)
	AddTools(server, b)
	AddViews(server, b)
	return server
}

// Front serves one client over stdio (mcpevents.Front).
type Front struct {
	Events   *Events
	Upstream *mcp.Server
	Version  string
	Logger   *slog.Logger
}

// Serve reads in until it ends and writes to out, then stops the server behind it.
func (f *Front) Serve(ctx context.Context, in io.Reader, out io.Writer) error {
	front := mcpevents.Front{Events: f.Events, List: eventsList, Upstream: f.Upstream,
		Name: "azureboards-mcp", Title: "Azure Boards", Version: f.Version, Instructions: Instructions}
	return front.Serve(ctx, in, out)
}
