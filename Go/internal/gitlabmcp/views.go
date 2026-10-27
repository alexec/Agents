package gitlabmcp

import (
	"context"
	"embed"
	"fmt"
	"strings"

	"github.com/alexec/agents/Go/internal/richtext"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// The gitlab server's views (#1631): MCP App pages (SEP-1865) the Agents host draws on the
// Mac, the Remote and the web page, in the github server's shapes (#1341), so no client needs
// code of its own for them. Merge requests (ui://gitlab/merge-requests), Issues
// (ui://gitlab/issues) and a merge request's page (ui://gitlab/mr), each fed by a read-only
// tool a view may call, so each can be pinned. Its diff is drawn by the app (agents/open-diff,
// the Review page's diff, #1472). A person's approve and merge are tools only a view may call.

//go:embed pages
var pageFiles embed.FS

// viewMime is an MCP App's HTML.
const viewMime = "text/html;profile=mcp-app"

// The views' addresses.
const (
	mrsURI    = "ui://gitlab/merge-requests"
	issuesURI = "ui://gitlab/issues"
	mrURI     = "ui://gitlab/mr"
)

// MergeRequestsURI and IssuesURI are the list views' addresses, which agentsd points at a
// project's GitLab project (#2669).
const (
	MergeRequestsURI = mrsURI
	IssuesURI        = issuesURI
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
	return strings.NewReplacer("/*common.css*/", read("common.css"), "/*mrpage.css*/", read("mrpage.css"),
		"/*bridge.js*/", read("bridge.js"), "/*mrpage.js*/", read("mrpage.js")).Replace(read(name))
}

func uiMeta(uri string, visibility ...string) mcp.Meta {
	ui := map[string]any{"visibility": visibility}
	if uri != "" {
		ui["resourceUri"] = uri
		return mcp.Meta{"ui": ui, "ui/resourceUri": uri}
	}
	return mcp.Meta{"ui": ui}
}

type boardArgs struct {
	Project string `json:"project,omitempty" jsonschema:"group/name or a project id; the project this folder pushes to when left out"`
}

type issuesViewArgs struct {
	Project string `json:"project,omitempty" jsonschema:"group/name or a project id; the project this folder pushes to when left out"`
	Label   string `json:"label,omitempty" jsonschema:"only issues with this label"`
}

type logArgs struct {
	Project    string `json:"project,omitempty" jsonschema:"group/name or a project id; the project this folder pushes to when left out"`
	PipelineID int    `json:"pipelineId" jsonschema:"the pipeline's id (run.id in a checks.failed event)"`
	Job        string `json:"job,omitempty" jsonschema:"only the failed job with this name"`
}

type retryArgs struct {
	Project    string `json:"project,omitempty" jsonschema:"group/name or a project id; the project this folder pushes to when left out"`
	PipelineID int    `json:"pipelineId" jsonschema:"the pipeline's id (run.id in a checks.failed event)"`
}

// addViews puts the views' tools and pages on server.
func addViews(server *mcp.Server, g *RealGitLab, projectOf func(context.Context, string) (string, error), person bool) {
	readOnly := &mcp.ToolAnnotations{ReadOnlyHint: true}

	tool(server, &mcp.Tool{Name: "show_merge_requests", Title: "Show merge requests",
		Description: "The project's open merge requests, newest created first, at most 100, each with its head commit's pipeline " +
			"(passing, failing, running or none), whether it conflicts with its target, whether approvals are missing, and whether " +
			"auto-merge is on. Its view is the Merge requests page, where a person opens a merge request's page.",
		Annotations: readOnly, Meta: uiMeta(mrsURI, "model", "app")},
		func(ctx context.Context, in boardArgs) (map[string]any, error) {
			project, err := projectOf(ctx, in.Project)
			if err != nil {
				return nil, err
			}
			return g.Board(ctx, project)
		})

	tool(server, &mcp.Tool{Name: "show_issues", Title: "Show issues",
		Description: "The project's open issues, newest created first, at most 100, each with its labels, assignees (usernames) " +
			"and comment count. Its view is the Issues page, where a person expands a row for its Markdown description or chooses Start Agent.",
		Annotations: readOnly, Meta: uiMeta(issuesURI, "model", "app")},
		func(ctx context.Context, in issuesViewArgs) (map[string]any, error) {
			project, err := projectOf(ctx, in.Project)
			if err != nil {
				return nil, err
			}
			return g.OpenIssues(ctx, project, in.Label)
		})

	tool(server, &mcp.Tool{Name: "show_issue_details", Title: "Show issue details",
		Description: "One issue's description, rendered as rich text for the Issues page.",
		Annotations: readOnly, Meta: uiMeta("", "model", "app")},
		func(ctx context.Context, in numberArgs) (map[string]any, error) {
			project, err := projectOf(ctx, in.Project)
			if err != nil {
				return nil, err
			}
			if in.Number < 1 {
				return nil, fmt.Errorf("issue number must be positive")
			}
			var issue issueJSON
			if err := g.get(ctx, fmt.Sprintf("projects/%s/issues/%d", pid(project), in.Number), false, &issue); err != nil {
				return nil, err
			}
			return map[string]any{"description": issue.Description, "descriptionHTML": richtext.Markdown(issue.Description)}, nil
		})

	tool(server, &mcp.Tool{Name: "show_merge_request", Title: "Show a merge request",
		Description: "One merge request: its description, its pipeline's jobs (a failing one with its pipeline's id for failed_log), " +
			"files, comments and discussions on lines (path and line), whether it conflicts with its target, and the signed-in " +
			"username (viewer). Its view is the merge request's page.",
		Annotations: readOnly, Meta: uiMeta(mrURI, "model", "app")},
		func(ctx context.Context, in numberArgs) (map[string]any, error) {
			project, err := projectOf(ctx, in.Project)
			if err != nil {
				return nil, err
			}
			return g.MRPage(ctx, project, in.Number)
		})

	tool(server, &mcp.Tool{Name: "show_merge_request_diff", Title: "Show a merge request's diff",
		Description: fmt.Sprintf("A merge request's changed files, each with its hunks of context, added and removed lines, at most %d lines "+
			"in all. The merge request's page opens it in the app's own diff.", diffLines),
		Annotations: readOnly, Meta: uiMeta("", "model", "app")},
		func(ctx context.Context, in numberArgs) (map[string]any, error) {
			project, err := projectOf(ctx, in.Project)
			if err != nil {
				return nil, err
			}
			return g.MRDiff(ctx, project, in.Number)
		})

	mcp.AddTool(server, &mcp.Tool{Name: "failed_log", Title: "Read a failed pipeline's log",
		Description: fmt.Sprintf("The last %d lines of each failed job's log in a pipeline, or of one job by name.", logLines),
		Annotations: readOnly, Meta: uiMeta("", "model", "app")},
		func(ctx context.Context, _ *mcp.CallToolRequest, in logArgs) (*mcp.CallToolResult, any, error) {
			project, err := projectOf(ctx, in.Project)
			if err != nil {
				return failed(err), nil, nil
			}
			text, err := g.FailedLog(ctx, project, in.PipelineID, in.Job)
			if err != nil {
				return failed(err), nil, nil
			}
			return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: text}}}, nil, nil
		})

	tool(server, &mcp.Tool{Name: "retry_pipeline", Title: "Retry a pipeline's failed jobs",
		Description: "Runs a pipeline's failed and canceled jobs again. Use it for a failure that is known to be flaky, not to hide a real one.",
		Meta:        uiMeta("", "model", "app")},
		func(ctx context.Context, in retryArgs) (map[string]any, error) {
			project, err := projectOf(ctx, in.Project)
			if err != nil {
				return nil, err
			}
			return g.RetryPipeline(ctx, project, in.PipelineID)
		})

	// Approve is the person's, from a view, and only on the host's copy (AddTools).
	if person {
		tool(server, &mcp.Tool{Name: "approve_merge_request", Title: "Approve a merge request",
			Description: "Approves a merge request as the person whose token it is. Only a view may call it: a person approves.",
			Meta:        uiMeta("", "app")},
			func(ctx context.Context, in approveArgs) (map[string]any, error) {
				project, err := projectOf(ctx, in.Project)
				if err != nil {
					return nil, err
				}
				sha, err := headSha(in.Sha)
				if err != nil {
					return nil, err
				}
				r, err := g.Approve(ctx, project, in.Number, sha)
				return r, staleHead(err)
			})
	}

	// No network at all: an empty csp, so the host draws them under its strictest policy.
	meta := mcp.Meta{"ui": map[string]any{"csp": map[string]any{}, "prefersBorder": true}}
	for _, v := range []struct{ uri, name, title, description, file string }{
		{mrsURI, "merge-requests", "Merge requests", "The project's open merge requests, newest created first, with their pipeline, conflict, approvals " +
			"and auto-merge; a merge request opens its page. Fed by show_merge_requests.", "mrs.html"},
		{issuesURI, "issues", "Issues", "The project's open issues, newest created first, with their labels and assignees, and Start Agent; a label narrows " +
			"the list. A person expands a row to read its Markdown description. Fed by show_issues.", "issues.html"},
		{mrURI, "mr", "Merge request", "One merge request's page: description, comments, discussions on lines, files with the app's " +
			"diff, and its pipeline with a failed job's log, with Comment, Approve, Merge, Auto-merge and Ask an Agent. Fed by show_merge_request.", "mr.html"},
	} {
		html := page(v.file)
		uri := v.uri
		server.AddResource(&mcp.Resource{URI: uri, Name: v.name, Title: v.title, Description: v.description, MIMEType: viewMime, Meta: meta},
			func(context.Context, *mcp.ReadResourceRequest) (*mcp.ReadResourceResult, error) {
				return &mcp.ReadResourceResult{Contents: []*mcp.ResourceContents{{URI: uri, MIMEType: viewMime, Text: html, Meta: meta}}}, nil
			})
	}
}
