package azuredevopsmcp

import (
	"context"
	"io"
	"log/slog"

	"github.com/agentloops-dev/agents/Go/internal/mcpevents"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// The front, as the gitlab server's (Go/internal/gitlabmcp/front.go): MCP's stdio transport,
// one JSON-RPC message a line. It answers events/list and events/poll itself, and hands every
// other message to a go-sdk server with this server's tools, and that server's messages back
// as they come. MCP's SDKs have no events (a working-group draft), so the front also adds the
// `events` capability and the events' words to its answer to initialize.

// Instructions are the server's words.
const Instructions = "This repository's pull requests and their Azure Pipelines builds on Azure DevOps, as events polled as the person whose token this server has: " +
	"checks.failed (a build of a pull request's head commit failed), checks.passed, run.completed (a build of any trigger, as main's or a tag's, with what it deployed), deploy.waiting (a build held by an environment's approvals), pr.opened, pr.merged, pr.closed (abandoned), pr.conflicted, review.requested, " +
	"review.comment (a comment on a line of a pull request's diff). " +
	"list_pull_requests, get_pull_request and get_checks read them, and get_build_log reads a failed build's failed steps; " +
	"comment_on_pull_request comments. " +
	"create_pull_request opens a pull request from a pushed branch; list_pull_request_comments lists its line comments, and " +
	"reply_to_pull_request_comment answers one in its thread. retry_build runs a build's failed jobs again. " +
	"show_pull_requests and show_pull_request draw this server's pages: Pull requests and a pull request's page. " +
	"Work items are not here: use the tracker's tools. " +
	"Merging and approving a pull request are a person's: those tools are not for agents."

// HostedEnv is set to "1" in the environment of an MCP server that the host runs for its
// sessions and views (agentsd's hosted copy, githubmcp.HostedEnv). Only that copy has the
// person's tools.
const HostedEnv = "AGENTS_MCP_HOSTED"

// NewServer is the server behind the front: it answers initialize and ping, and has the
// tools; with person, also the tools only a person may call (merge and approve).
func NewServer(version string, f *RealAzureDevOps, person bool) *mcp.Server {
	server := mcp.NewServer(&mcp.Implementation{Name: "azuredevops-mcp", Title: "Azure DevOps", Version: version}, nil)
	AddTools(server, f, person)
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
		Name: "azuredevops-mcp", Title: "Azure DevOps", Version: f.Version, Instructions: Instructions}
	return front.Serve(ctx, in, out)
}
