package azuredevopsmcp

import (
	"context"
	"embed"
	"fmt"
	"strings"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// The azuredevops server's views (#4098): MCP App pages (SEP-1865) the Agents host draws on the
// Mac, the Remote and the web page, in the forgejo server's shapes (#3838), so no client needs
// code of its own for them. Pull requests (ui://azuredevops/pull-requests) and a pull request's
// page (ui://azuredevops/pr), each fed by a read-only tool a view may call, so each can be
// pinned. Its diff is drawn by the app (agents/open-diff, the Review page's diff, #1472). A
// person's approve and merge are the tools only a view may call (tools.go). Work items are
// Azure Boards', whose server has the Issues page (#3826).

//go:embed pages
var pageFiles embed.FS

// viewMime is an MCP App's HTML.
const viewMime = "text/html;profile=mcp-app"

// The views' addresses.
const (
	pullsURI = "ui://azuredevops/pull-requests"
	prURI    = "ui://azuredevops/pr"
)

// PullsURI is the list view's address.
const PullsURI = pullsURI

// page is a view's HTML: its file, with the shared script and styles put in.
func page(name string) string {
	read := func(n string) string {
		b, err := pageFiles.ReadFile("pages/" + n)
		if err != nil {
			panic(err)
		}
		return string(b)
	}
	return strings.NewReplacer("/*common.css*/", read("common.css"), "/*prpage.css*/", read("prpage.css"),
		"/*bridge.js*/", read("bridge.js"), "/*lineage.js*/", read("lineage.js"), "/*prpage.js*/", read("prpage.js")).Replace(read(name))
}

func uiMeta(uri string, v ...string) mcp.Meta {
	m := visibility(v...)
	if uri != "" {
		m["ui"].(map[string]any)["resourceUri"] = uri
		m["ui/resourceUri"] = uri
	}
	return m
}

type boardArgs struct {
	Repo string `json:"repo,omitempty" jsonschema:"organization/project/name; the repository this folder pushes to when left out"`
}

// addViews puts the views' tools and pages on server.
func addViews(server *mcp.Server, f *RealAzureDevOps, repoOf func(context.Context, string) (string, error)) {
	readOnly := &mcp.ToolAnnotations{ReadOnlyHint: true}

	mcp.AddTool(server, &mcp.Tool{Name: "show_pull_requests", Title: "Show pull requests",
		Description: "The repository's active pull requests, newest created first, at most 50, each with its checks (passing, " +
			"failing, running or none: its Azure Pipelines builds and other services' statuses; a failed build's id as " +
			"failedRunId), whether it conflicts with its target, its review (approved, changes_requested or review_required), " +
			"auto-complete, and its section for the token's owner (viewer; mine is theirs): needs_you (you are a reviewer who " +
			"has not voted, or yours with failing checks, a conflict or changes requested), yours, team (the people and bots on " +
			"this control plane by their Azure DevOps login, or with no control plane everyone else) or others; attention counts " +
			"needs_you. agentOn says who is on one of the viewer's own. Its view is the Pull requests page, where a person opens " +
			"a pull request's page.",
		Annotations: readOnly, Meta: uiMeta(pullsURI, "model", "app")},
		func(ctx context.Context, req *mcp.CallToolRequest, in boardArgs) (*mcp.CallToolResult, any, error) {
			repo, err := repoOf(ctx, in.Repo)
			if err != nil {
				return failed(err), nil, nil
			}
			r, err := f.Board(ctx, repo, req.Params.Meta)
			if err != nil {
				return failed(err), nil, nil
			}
			return structured(r), nil, nil
		})

	tool(server, &mcp.Tool{Name: "show_pull_request", Title: "Show a pull request",
		Description: "One pull request: its description, its checks (an Azure Pipelines build with its id as runId, for " +
			"get_build_log's and retry_build's buildId), files, comments and the threads on its lines (path and line), whether " +
			"it conflicts with its target, auto-complete, and the token's owner (viewer; mine is theirs). Its view is the pull " +
			"request's page.",
		Annotations: readOnly, Meta: uiMeta(prURI, "model", "app")},
		func(ctx context.Context, in numberArgs) (map[string]any, error) {
			repo, err := repoOf(ctx, in.Repo)
			if err != nil {
				return nil, err
			}
			return f.PRPage(ctx, repo, in.Number)
		})

	tool(server, &mcp.Tool{Name: "show_pull_request_diff", Title: "Show a pull request's diff",
		Description: fmt.Sprintf("A pull request's changed files, each with its hunks of context, added and removed lines, at most %d lines "+
			"in all. The pull request's page opens it in the app's own diff.", diffLines),
		Annotations: readOnly, Meta: uiMeta("", "model", "app")},
		func(ctx context.Context, in numberArgs) (map[string]any, error) {
			repo, err := repoOf(ctx, in.Repo)
			if err != nil {
				return nil, err
			}
			return f.PRDiff(ctx, repo, in.Number)
		})

	// No network at all: an empty csp, so the host draws them under its strictest policy.
	meta := mcp.Meta{"ui": map[string]any{"csp": map[string]any{}, "prefersBorder": true}}
	for _, v := range []struct{ uri, name, title, description, file string }{
		{pullsURI, "pull-requests", "Pull requests", "The repository's active pull requests, newest created first, with their checks, " +
			"conflict and review; a pull request opens its page. Fed by show_pull_requests.", "pulls.html"},
		{prURI, "pr", "Pull request", "One pull request's page: description, comments, line comments, files with the app's diff, " +
			"and its checks with a failed build's log and Retry Failed Jobs, with Comment, Approve, Merge, Auto-merge (auto-complete) " +
			"and Ask an Agent. Fed by show_pull_request.", "pr.html"},
	} {
		html := page(v.file)
		uri := v.uri
		server.AddResource(&mcp.Resource{URI: uri, Name: v.name, Title: v.title, Description: v.description, MIMEType: viewMime, Meta: meta},
			func(context.Context, *mcp.ReadResourceRequest) (*mcp.ReadResourceResult, error) {
				return &mcp.ReadResourceResult{Contents: []*mcp.ResourceContents{{URI: uri, MIMEType: viewMime, Text: html, Meta: meta}}}, nil
			})
	}
}
