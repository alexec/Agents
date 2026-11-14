package bitbucketmcp

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
const Instructions = "This repository's pull requests, their checks, and its issues on Bitbucket Cloud, as events polled as the person whose token this server has: " +
	"checks.failed (a pull request's head commit failed its checks), run.completed (a Pipelines run of any trigger, as main's or a tag's, with what it deployed), pr.opened, pr.merged, pr.closed, pr.conflicted, review.comment (a comment on a line of a pull request's diff), " +
	"issue.opened, issue.labelled (an issue's kind or component), issue.commented, issue.closed. " +
	"list_pull_requests, get_pull_request, get_checks, list_issues and get_issue read them; " +
	"failed_log reads the end of a failed Pipelines run's steps' logs (pipelineId is run.id in checks.failed), retry_pipeline starts it again on the same commit. " +
	"comment_on_pull_request and comment_on_issue comment. " +
	"create_pull_request opens a pull request from a pushed branch; list_pull_request_comments lists its line comments, and " +
	"reply_to_pull_request_comment answers one in its thread. " +
	"show_pull_requests, show_issues and show_pull_request draw this server's pages: Pull requests, Issues and a pull request's page. " +
	"Merging and approving a pull request are a person's: those tools are not for agents."

// HostedEnv is set to "1" in the environment of an MCP server that the host runs for its
// sessions and views (agentsd's hosted copy, githubmcp.HostedEnv). Only that copy has the
// person's tools.
const HostedEnv = "AGENTS_MCP_HOSTED"

// NewServer is the server behind the front: it answers initialize and ping, and has the
// tools; with person, also the tools only a person may call (merge and approve).
func NewServer(version string, f *RealBitbucket, person bool) *mcp.Server {
	server := mcp.NewServer(&mcp.Implementation{Name: "bitbucket-mcp", Title: "Bitbucket", Version: version}, nil)
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
		Name: "bitbucket-mcp", Title: "Bitbucket", Version: f.Version, Instructions: Instructions}
	return front.Serve(ctx, in, out)
}
