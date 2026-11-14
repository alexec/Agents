package linearmcp

import (
	"context"
	"io"
	"log/slog"

	"github.com/agentloops-dev/agents/Go/internal/mcpevents"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// The front, as the github server's (Go/internal/githubmcp/front.go): MCP's stdio transport,
// one JSON-RPC message a line. It answers events/list and events/poll itself, and hands every
// other message (initialize, ping, the empty lists) to a go-sdk server with no tools, and that
// server's messages back as they come. MCP's SDKs have no events (a working-group draft), so
// the front also adds the `events` capability and the events' words to its answer to
// initialize. Its one tool and page are AddViews' (views.go); Linear's own MCP server (mcp.linear.app) changes issues.

// Instructions are the server's words.
const Instructions = "The Linear workspace's issues, read with the person's Linear connection (or the LINEAR_API_KEY " +
	"personal API key): show_issues lists the open ones, with a page that has Start Agent, and the events issue.opened, " +
	"issue.labelled, issue.commented and issue.closed. Linear's own MCP server (mcp.linear.app) changes issues."

// NewServer is the server behind the front: it answers initialize and ping. AddViews puts show_issues and its page on it.
func NewServer(version string) *mcp.Server {
	return mcp.NewServer(&mcp.Implementation{Name: "linear-mcp", Title: "Linear events", Version: version}, nil)
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
		Name: "linear-mcp", Title: "Linear", Version: f.Version, Instructions: Instructions}
	return front.Serve(ctx, in, out)
}
