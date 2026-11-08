package forgejomcp

import (
	"context"
	"embed"
	"fmt"
	"strings"

	"github.com/alexec/agents/Go/internal/richtext"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// The forgejo server's views (#3838): MCP App pages (SEP-1865) the Agents host draws on the
// Mac, the Remote and the web page, in the gitlab server's shapes (#1631), so no client needs
// code of its own for them. Pull requests (ui://forgejo/pull-requests), Issues
// (ui://forgejo/issues) and a pull request's page (ui://forgejo/pr), each fed by a read-only
// tool a view may call, so each can be pinned. Its diff is drawn by the app (agents/open-diff,
// the Review page's diff, #1472). A person's approve and merge are the tools only a view may
// call (tools.go).

//go:embed pages
var pageFiles embed.FS

// viewMime is an MCP App's HTML.
const viewMime = "text/html;profile=mcp-app"

// The views' addresses.
const (
	pullsURI  = "ui://forgejo/pull-requests"
	issuesURI = "ui://forgejo/issues"
	prURI     = "ui://forgejo/pr"
)

// PullsURI and IssuesURI are the list views' addresses, which agentsd points at a project's
// Forgejo repository (#2669).
const (
	PullsURI  = pullsURI
	IssuesURI = issuesURI
)

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
	Repo string `json:"repo,omitempty" jsonschema:"owner/name; the repository this folder pushes to when left out"`
}

type issuesViewArgs struct {
	Repo  string `json:"repo,omitempty" jsonschema:"owner/name; the repository this folder pushes to when left out"`
	Label string `json:"label,omitempty" jsonschema:"only issues with this label"`
}

// toolMeta adds a tool whose answer is f's, given the call's _meta (the host's people, #2951).
func toolMeta[In any](server *mcp.Server, t *mcp.Tool, f func(context.Context, mcp.Meta, In) (map[string]any, error)) {
	mcp.AddTool(server, t, func(ctx context.Context, req *mcp.CallToolRequest, in In) (*mcp.CallToolResult, any, error) {
		r, err := f(ctx, req.Params.Meta, in)
		if err != nil {
			return failed(err), nil, nil
		}
		return structured(r), nil, nil
	})
}

// addViews puts the views' tools and pages on server.
func addViews(server *mcp.Server, f *RealForgejo, repoOf func(context.Context, string) (string, error)) {
	readOnly := &mcp.ToolAnnotations{ReadOnlyHint: true}

	toolMeta(server, &mcp.Tool{Name: "show_pull_requests", Title: "Show pull requests",
		Description: "The repository's open pull requests, newest created first, at most 50, each with its head's checks " +
			"(passing, failing, running or none), whether it conflicts with its target, its review (approved, changes_requested " +
			"or review_required), and its section for the signed-in login (viewer): needs_you (you are asked to review it, or " +
			"yours with failing checks, a conflict or changes requested), yours, team (the people and bots on this control plane, " +
			"or the repository's collaborators with write access, and bots, with no control plane) or others; attention counts " +
			"needs_you. agentOn says who is on one of the viewer's own. Its view is the Pull requests page, where a person opens " +
			"a pull request's page.",
		Annotations: readOnly, Meta: uiMeta(pullsURI, "model", "app")},
		func(ctx context.Context, meta mcp.Meta, in boardArgs) (map[string]any, error) {
			repo, err := repoOf(ctx, in.Repo)
			if err != nil {
				return nil, err
			}
			return f.Board(ctx, repo, meta)
		})

	toolMeta(server, &mcp.Tool{Name: "show_issues", Title: "Show issues",
		Description: "The repository's open issues, newest created first, at most 50, each with its labels, assignees (logins), " +
			"comment count and section for the signed-in login (viewer): needs_you (assigned to you), yours, team (the people and " +
			"bots on this control plane, or the repository's collaborators with write access, and bots, with no control plane) or " +
			"others; attention counts needs_you. agentOn says who is on one of the viewer's own. " +
			"Its view is the Issues page, where a person expands a row for its Markdown description or chooses Start Agent.",
		Annotations: readOnly, Meta: uiMeta(issuesURI, "model", "app")},
		func(ctx context.Context, meta mcp.Meta, in issuesViewArgs) (map[string]any, error) {
			repo, err := repoOf(ctx, in.Repo)
			if err != nil {
				return nil, err
			}
			return f.OpenIssues(ctx, repo, in.Label, meta)
		})

	tool(server, &mcp.Tool{Name: "show_issue_details", Title: "Show issue details",
		Description: "One issue's description, rendered as rich text for the Issues page.",
		Annotations: readOnly, Meta: uiMeta("", "model", "app")},
		func(ctx context.Context, in numberArgs) (map[string]any, error) {
			repo, err := repoOf(ctx, in.Repo)
			if err != nil {
				return nil, err
			}
			if in.Number < 1 {
				return nil, fmt.Errorf("issue number must be positive")
			}
			var i issueJSON
			if err := f.get(ctx, fmt.Sprintf("%s/issues/%d", repoPath(repo), in.Number), false, &i); err != nil {
				return nil, err
			}
			body := clipDescription(i.Body)
			return map[string]any{"description": body, "descriptionHTML": richtext.Markdown(body)}, nil
		})

	tool(server, &mcp.Tool{Name: "show_pull_request", Title: "Show a pull request",
		Description: "One pull request: its description, its head's checks (a failing Forgejo Actions one with its runId for " +
			"failed_log), files, comments and line comments as threads (path and line), whether it conflicts with its target, and " +
			"the signed-in login (viewer). Its view is the pull request's page.",
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
		{pullsURI, "pull-requests", "Pull requests", "The repository's open pull requests, newest created first, with their checks, conflict " +
			"and review, and Retry on a failed Actions run; a pull request opens its page. Fed by show_pull_requests.", "pulls.html"},
		{issuesURI, "issues", "Issues", "The repository's open issues, newest created first, with their labels and assignees, and Start Agent; " +
			"a label narrows the list. A person expands a row to read its Markdown description. Fed by show_issues.", "issues.html"},
		{prURI, "pr", "Pull request", "One pull request's page: description, comments, line comments, files with the app's diff, " +
			"and its checks with a failed Forgejo Actions run's log and Retry Failed Jobs, with Comment, Approve, Merge, Auto-merge and Ask an Agent. " +
			"Fed by show_pull_request.", "pr.html"},
	} {
		html := page(v.file)
		uri := v.uri
		server.AddResource(&mcp.Resource{URI: uri, Name: v.name, Title: v.title, Description: v.description, MIMEType: viewMime, Meta: meta},
			func(context.Context, *mcp.ReadResourceRequest) (*mcp.ReadResourceResult, error) {
				return &mcp.ReadResourceResult{Contents: []*mcp.ResourceContents{{URI: uri, MIMEType: viewMime, Text: html, Meta: meta}}}, nil
			})
	}
}
