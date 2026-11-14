package githubmcp

import (
	"context"
	"io"
	"log/slog"

	"github.com/agentloops-dev/agent-loops/Go/internal/mcpevents"

	ghErrors "github.com/github/github-mcp-server/v2/pkg/errors"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// The front: MCP's stdio transport, one JSON-RPC message a line. It answers events/list and
// events/poll itself, and hands every other message to the official server as it came, and
// that server's messages back as they come. MCP's SDKs have no events (a working-group
// draft), so the front also adds the `events` capability and the events' words to the
// official server's answer to initialize.

// Instructions are the events' words, put before the official server's own.
const Instructions = "This repo's pull requests, their CI, and its issues as events, polled as the person signed in to GitHub in Agent Loops: " +
	"checks.failed, checks.passed, run.completed (a workflow run of any trigger, as a tag's release), deploy.waiting (a run held by an environment's required reviewers), deploy.started, deploy.succeeded and deploy.failed (a GitHub Deployment's state changes), pr.opened, pr.merged, pr.conflicted, pr.closed, issue.opened, issue.labelled, issue.commented, issue.closed, " +
	"and CodeRabbit's review.posted and review.comment. " +
	"coderabbit_review, coderabbit_reply and coderabbit_resolve speak to CodeRabbit on a pull request, as the person. " +
	"show_pull_requests, show_issues and show_pull_request show a page to the person. " +
	"Merging and reviewing a pull request are a person's, from its page: those tools are not for agents."

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
		Name: "github-mcp", Title: "GitHub", Version: f.Version, Instructions: Instructions,
		Context: ghErrors.ContextWithGitHubErrors}
	return front.Serve(ctx, in, out)
}
