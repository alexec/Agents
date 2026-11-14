package gitlabmcp

import (
	"context"
	"io"
	"log/slog"

	"github.com/agentloops-dev/agent-loops/Go/internal/mcpevents"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// The front, as the github server's (Go/internal/githubmcp/front.go): MCP's stdio transport,
// one JSON-RPC message a line. It answers events/list and events/poll itself, and hands every
// other message to a go-sdk server with this server's tools, and that server's messages back
// as they come. MCP's SDKs have no events (a working-group draft), so the front also adds the
// `events` capability and the events' words to its answer to initialize.

// Instructions are the server's words.
const Instructions = "This project's merge requests, their pipelines, and its issues on GitLab, as events polled as the person who connected GitLab: " +
	"checks.failed (a failed pipeline), run.completed (a pipeline of any trigger, as main's or a tag's, with what it deployed), deploy.waiting (a deploy held for a protected environment's approval), pr.opened, pr.merged, pr.closed, pr.conflicted, review.comment (a comment on a line of a merge request's diff), " +
	"issue.opened, issue.labelled, issue.commented, issue.closed. A merge request is a pr in their names and data, and its number is its iid (!12). " +
	"list_merge_requests, get_merge_request, list_pipelines, get_pipeline, list_issues and get_issue read them; " +
	"comment_on_merge_request and comment_on_issue comment; failed_log reads a failed pipeline's jobs' logs, retry_pipeline runs them again. " +
	"create_merge_request opens a merge request from a pushed branch; list_merge_request_comments lists its open line threads, and " +
	"reply_to_merge_request_comment answers one in its thread. " +
	"show_merge_requests, show_issues and show_merge_request show a page to the person. " +
	"Merging and approving a merge request are a person's, from its page: those tools are not for agents."

// HostedEnv is set to "1" in the environment of an MCP server that the host runs for its
// sessions and views (agentsd's hosted copy, githubmcp.HostedEnv). Only that copy has the
// person's tools.
const HostedEnv = "AGENTS_MCP_HOSTED"

// NewServer is the server behind the front: it answers initialize and ping, and has the
// tools; with person, also the tools only a view may call (merge and approve).
func NewServer(version string, g *RealGitLab, person bool) *mcp.Server {
	server := mcp.NewServer(&mcp.Implementation{Name: "gitlab-mcp", Title: "GitLab", Version: version}, nil)
	AddTools(server, g, person)
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
		Name: "gitlab-mcp", Title: "GitLab", Version: f.Version, Instructions: Instructions}
	return front.Serve(ctx, in, out)
}
