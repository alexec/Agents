package jiramcp

import (
	"context"
	"io"
	"log/slog"

	"github.com/agentloops-dev/agents/Go/internal/mcpevents"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// The front, as the linear server's (Go/internal/linearmcp/front.go): MCP's stdio transport,
// one JSON-RPC message a line. It answers events/list and events/poll itself, and hands every
// other message (initialize, ping, the empty lists) to a go-sdk server with no tools, and that
// server's messages back as they come. MCP's SDKs have no events (a working-group draft), so
// the front also adds the `events` capability and the events' words to its answer to
// initialize. Its tools and page are AddViews' (views.go); Atlassian's own MCP server changes issues.

// Instructions are the server's words.
const Instructions = "The Jira site's issues, read with the person's Atlassian connection (Connect Jira), or with " +
	"JIRA_URL and an API token (JIRA_EMAIL and JIRA_API_TOKEN on Jira Cloud, a personal access token in JIRA_API_TOKEN " +
	"on Jira Data Center): show_issues lists the open ones, with a " +
	"page that has Start Agent, and the events issue.opened, issue.labelled, issue.commented and issue.assigned. " +
	"Atlassian's own MCP server (mcp.atlassian.com) changes issues."

// NewServer is the server behind the front: it answers initialize and ping. AddViews puts show_issues and its page on it.
func NewServer(version string) *mcp.Server {
	return mcp.NewServer(&mcp.Implementation{Name: "jira-mcp", Title: "Jira events", Version: version}, nil)
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
		Name: "jira-mcp", Title: "Jira", Version: f.Version, Instructions: Instructions}
	return front.Serve(ctx, in, out)
}
