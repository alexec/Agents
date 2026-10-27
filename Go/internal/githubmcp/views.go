package githubmcp

import (
	"context"
	"embed"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/alexec/agents/Go/internal/richtext"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// The github server's views (#1341): MCP App pages (SEP-1865) the Agents host draws on the
// Mac, the Remote and the web page, as the ci server's were (#383, #837). Pull requests
// (ui://github/pulls), Issues (ui://github/issues) and a pull request's page
// (ui://github/pr), each fed by a read-only tool a view may call, so each can be pinned. A
// person's actions on the page (merge, approve, comment) are tools only a view may call: the
// host never offers them to an agent.

//go:embed pages
var pageFiles embed.FS

// viewMime is an MCP App's HTML.
const viewMime = "text/html;profile=mcp-app"

// The views' addresses.
const (
	pullsURI  = "ui://github/pulls"
	issuesURI = "ui://github/issues"
	prURI     = "ui://github/pr"
)

// PullsURI and IssuesURI are the list views' addresses, which agentsd points at a
// project's repository (#2669).
const (
	PullsURI  = pullsURI
	IssuesURI = issuesURI
)

// page is a view's HTML: its file, with the PR page's script and styles put in.
func page(name string) string {
	read := func(n string) string {
		b, err := pageFiles.ReadFile("pages/" + n)
		if err != nil {
			panic(err)
		}
		return string(b)
	}
	return strings.NewReplacer("/*common.css*/", read("common.css"), "/*prpage.css*/", read("prpage.css"),
		"/*bridge.js*/", read("bridge.js"), "/*prpage.js*/", read("prpage.js")).Replace(read(name))
}

func uiMeta(uri string, visibility ...string) mcp.Meta {
	ui := map[string]any{"visibility": visibility}
	if uri != "" {
		ui["resourceUri"] = uri
		return mcp.Meta{"ui": ui, "ui/resourceUri": uri}
	}
	return mcp.Meta{"ui": ui}
}

type repoArgs struct {
	Repo string `json:"repo,omitempty" jsonschema:"owner/name; the repo this folder pushes to when left out"`
}

type issuesArgs struct {
	Repo  string `json:"repo,omitempty" jsonschema:"owner/name; the repo this folder pushes to when left out"`
	Label string `json:"label,omitempty" jsonschema:"only issues with this label"`
}

type issueDetailsArgs struct {
	Repo   string `json:"repo,omitempty" jsonschema:"owner/name; the repo this folder pushes to when left out"`
	Number int    `json:"number" jsonschema:"the issue's number"`
}

type prArgs struct {
	Repo   string `json:"repo,omitempty" jsonschema:"owner/name; the repo this folder pushes to when left out"`
	Number int    `json:"number" jsonschema:"the pull request's number"`
}

type diffArgs struct {
	Repo   string `json:"repo,omitempty" jsonschema:"owner/name; the repo this folder pushes to when left out"`
	Number int    `json:"number" jsonschema:"the pull request's number"`
	Sha    string `json:"sha,omitempty" jsonschema:"the head commit that the page shows (headSha); refused when the head is another"`
}

type runArgs struct {
	Repo  string `json:"repo,omitempty" jsonschema:"owner/name; the repo this folder pushes to when left out"`
	RunID int    `json:"runId" jsonschema:"the Actions run's id"`
	Job   string `json:"job,omitempty" jsonschema:"only the failed job with this name"`
}

type mergeArgs struct {
	Repo   string `json:"repo,omitempty" jsonschema:"owner/name; the repo this folder pushes to when left out"`
	Number int    `json:"number" jsonschema:"the pull request's number"`
	Sha    string `json:"sha" jsonschema:"the head commit that the page shows (headSha); refused when the head is another"`
	Auto   bool   `json:"auto,omitempty" jsonschema:"true: merge once its checks pass"`
}

type reviewArgs struct {
	Repo   string `json:"repo,omitempty" jsonschema:"owner/name; the repo this folder pushes to when left out"`
	Number int    `json:"number" jsonschema:"the pull request's number"`
	Sha    string `json:"sha" jsonschema:"the head commit that the page shows (headSha); the review is of that commit"`
	Event  string `json:"event" jsonschema:"approve or request_changes"`
	Body   string `json:"body,omitempty" jsonschema:"the review's words, in Markdown; needed to request changes"`
}

type commentArgs struct {
	Repo   string `json:"repo,omitempty" jsonschema:"owner/name; the repo this folder pushes to when left out"`
	Number int    `json:"number" jsonschema:"the pull request's number"`
	Body   string `json:"body" jsonschema:"the comment, in Markdown"`
}

// structured is a tool's answer: the data, and the same as JSON text for a client that
// reads only text.
func structured(data map[string]any) *mcp.CallToolResult {
	text, _ := json.Marshal(data)
	return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: string(text)}}, StructuredContent: data}
}

// failed is a tool's answer that it failed, with why.
func failed(err error) *mcp.CallToolResult {
	msg := err.Error()
	if e, ok := err.(*GitHubError); ok && e.Kind == RateLimited {
		msg = fmt.Sprintf("%s; try again in %ds", e.Message, (e.RetryAfterMs+999)/1000)
	}
	return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: msg}}, IsError: true}
}

// HostedEnv is set to "1" in the environment of an MCP server that the host runs for its
// sessions and views (agentsd's hosted copy). Only that copy has the person's tools.
const HostedEnv = "AGENTS_MCP_HOSTED"

// AddViews puts the views' tools and pages on server; with person, also the tools that
// only a view may call (merge_pr, review_pr, comment_on_pr).
func AddViews(server *mcp.Server, gh Views, person bool) {
	repoOf := func(ctx context.Context, repo string) (string, error) {
		if repo != "" {
			if _, _, err := ownerName(repo); err != nil {
				return "", err
			}
			return repo, nil
		}
		return gh.DefaultRepo(ctx)
	}
	readOnly := &mcp.ToolAnnotations{ReadOnlyHint: true}
	addCodeRabbitTools(server, gh, repoOf)

	mcp.AddTool(server, &mcp.Tool{Name: "show_pull_requests", Title: "Show pull requests",
		Description: "The repo's open pull requests, newest created first, each with its checks (passing, failing, running or none), " +
			"its review (approved, changes_requested or review_required), whether it conflicts with its base, and whether auto-merge is on. " +
			"Its view is the Pull requests page, where a person opens a pull request's page.",
		Annotations: readOnly, Meta: uiMeta(pullsURI, "model", "app")},
		func(ctx context.Context, _ *mcp.CallToolRequest, in repoArgs) (*mcp.CallToolResult, any, error) {
			repo, err := repoOf(ctx, in.Repo)
			if err != nil {
				return failed(err), nil, nil
			}
			b, err := gh.BoardPRs(ctx, repo)
			if err != nil {
				return failed(err), nil, nil
			}
			prs := make([]any, len(b.PRs))
			// The count on the sidebar's row (#2033), and the signed-in person's PRs whose checks fail.
			failing := 0
			for i, p := range b.PRs {
				prs[i] = p.json()
				if p.Checks == "failing" && p.Author != "" && p.Author == b.Viewer {
					failing++
				}
			}
			return structured(map[string]any{"repo": repo, "viewer": b.Viewer, "prs": prs,
				"count": len(prs), "attention": failing}), nil, nil
		})

	mcp.AddTool(server, &mcp.Tool{Name: "show_issues", Title: "Show issues",
		Description: "The repo's open issues (not pull requests), newest created first, at most 100, each with its labels, " +
			"assignees (logins), milestone and comment count. Its view is the Issues page, where a person expands a row to read its rich-text description and linked pull requests.",
		Annotations: readOnly, Meta: uiMeta(issuesURI, "model", "app")},
		func(ctx context.Context, _ *mcp.CallToolRequest, in issuesArgs) (*mcp.CallToolResult, any, error) {
			repo, err := repoOf(ctx, in.Repo)
			if err != nil {
				return failed(err), nil, nil
			}
			list, err := gh.OpenIssues(ctx, repo, in.Label)
			if err != nil {
				return failed(err), nil, nil
			}
			issues := make([]any, len(list))
			for i, l := range list {
				issues[i] = l.json()
			}
			return structured(map[string]any{"repo": repo, "issues": issues, "count": len(issues)}), nil, nil
		})

	mcp.AddTool(server, &mcp.Tool{Name: "show_issue_details", Title: "Show issue details",
		Description: "One issue's description and the pull requests GitHub's issue_read tool links to it by closing keywords.",
		Annotations: readOnly, Meta: uiMeta("", "model", "app")},
		func(ctx context.Context, _ *mcp.CallToolRequest, in issueDetailsArgs) (*mcp.CallToolResult, any, error) {
			repo, err := repoOf(ctx, in.Repo)
			if err != nil {
				return failed(err), nil, nil
			}
			if in.Number < 1 {
				return failed(fmt.Errorf("issue number must be positive")), nil, nil
			}
			details, err := gh.IssueDetails(ctx, repo, in.Number)
			if err != nil {
				return failed(err), nil, nil
			}
			body, _ := details["body"].(string)
			details["bodyHTML"] = richtext.Markdown(body)
			return structured(details), nil, nil
		})

	mcp.AddTool(server, &mcp.Tool{Name: "show_pull_request", Title: "Show a pull request",
		Description: "One pull request: its description, checks (a failing one with its run's id for failed_log), files, comments, " +
			"reviews and review threads (path and line), whether it conflicts with its base, its review decision, and the signed-in login (viewer). " +
			"An app's words say which app (app: CodeRabbit); codeRabbit is CodeRabbit's summary, its review status and its last review's state. " +
			"Its view is the pull request's page.",
		Annotations: readOnly, Meta: uiMeta(prURI, "model", "app")},
		func(ctx context.Context, _ *mcp.CallToolRequest, in prArgs) (*mcp.CallToolResult, any, error) {
			repo, err := repoOf(ctx, in.Repo)
			if err != nil {
				return failed(err), nil, nil
			}
			p, err := gh.PRPage(ctx, repo, in.Number)
			if err != nil {
				return failed(err), nil, nil
			}
			return structured(p), nil, nil
		})

	mcp.AddTool(server, &mcp.Tool{Name: "show_pull_request_diff", Title: "Show a pull request's diff",
		Description: fmt.Sprintf("A pull request's changed files, each with its hunks of context, added and removed lines, at most %d lines "+
			"in all, and the head commit it is of (headSha). The pull request's page opens it in the app's own diff.", diffLines),
		Annotations: readOnly, Meta: uiMeta("", "model", "app")},
		func(ctx context.Context, _ *mcp.CallToolRequest, in diffArgs) (*mcp.CallToolResult, any, error) {
			repo, err := repoOf(ctx, in.Repo)
			if err != nil {
				return failed(err), nil, nil
			}
			d, err := gh.PRDiff(ctx, repo, in.Number, in.Sha)
			if err != nil {
				return failed(err), nil, nil
			}
			return structured(d), nil, nil
		})

	mcp.AddTool(server, &mcp.Tool{Name: "failed_log", Title: "Read a failed run's log",
		Description: fmt.Sprintf("The last %d lines of each failed job's log in an Actions run, or of one job by name.", logLines),
		Annotations: readOnly, Meta: uiMeta("", "model", "app")},
		func(ctx context.Context, _ *mcp.CallToolRequest, in runArgs) (*mcp.CallToolResult, any, error) {
			repo, err := repoOf(ctx, in.Repo)
			if err != nil {
				return failed(err), nil, nil
			}
			text, err := gh.FailedLog(ctx, repo, in.RunID, in.Job)
			if err != nil {
				return failed(err), nil, nil
			}
			return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: text}}}, nil, nil
		})

	mcp.AddTool(server, &mcp.Tool{Name: "rerun_failed", Title: "Rerun failed jobs",
		Description: "Reruns an Actions run's failed jobs. Use it for a failure that is known to be flaky, not to hide a real one.",
		Meta:        uiMeta("", "model", "app")},
		func(ctx context.Context, _ *mcp.CallToolRequest, in runArgs) (*mcp.CallToolResult, any, error) {
			repo, err := repoOf(ctx, in.Repo)
			if err != nil {
				return failed(err), nil, nil
			}
			r, err := gh.RerunFailed(ctx, repo, in.RunID)
			if err != nil {
				return failed(err), nil, nil
			}
			return structured(r), nil, nil
		})

	// Merge, review and comment are the person's, from a view. They are only on the copy the
	// host runs (person), whose tools/list the host filters for an agent; a copy that a
	// session runs itself has none of them.
	if person {
		mcp.AddTool(server, &mcp.Tool{Name: "merge_pr", Title: "Merge a pull request",
			Description: "Squash-merges a pull request and deletes its branch on GitHub, as the signed-in person; auto: true turns on " +
				"auto-merge, so it merges once its checks pass. Only a view may call it: a person merges.",
			Meta: uiMeta("", "app")},
			func(ctx context.Context, _ *mcp.CallToolRequest, in mergeArgs) (*mcp.CallToolResult, any, error) {
				repo, err := repoOf(ctx, in.Repo)
				if err != nil {
					return failed(err), nil, nil
				}
				r, err := gh.MergePR(ctx, repo, in.Number, in.Sha, in.Auto)
				if err != nil {
					return failed(err), nil, nil
				}
				return structured(r), nil, nil
			})

		mcp.AddTool(server, &mcp.Tool{Name: "review_pr", Title: "Review a pull request",
			Description: "Approves a pull request, or requests changes with a body that says what, as the signed-in person. " +
				"GitHub refuses either on the person's own pull request. Only a view may call it: a person reviews.",
			Meta: uiMeta("", "app")},
			func(ctx context.Context, _ *mcp.CallToolRequest, in reviewArgs) (*mcp.CallToolResult, any, error) {
				repo, err := repoOf(ctx, in.Repo)
				if err != nil {
					return failed(err), nil, nil
				}
				body := strings.TrimSpace(in.Body)
				switch {
				case in.Event != "approve" && in.Event != "request_changes":
					return failed(fmt.Errorf("event is approve or request_changes")), nil, nil
				case in.Event == "request_changes" && body == "":
					return failed(fmt.Errorf("say what is to change: body is needed to request changes")), nil, nil
				}
				r, err := gh.ReviewPR(ctx, repo, in.Number, in.Sha, in.Event == "approve", body)
				if err != nil {
					return failed(err), nil, nil
				}
				return structured(r), nil, nil
			})

		mcp.AddTool(server, &mcp.Tool{Name: "comment_on_pr", Title: "Comment on a pull request",
			Description: "Adds a comment to a pull request, as the signed-in person, from its page. Only a view may call it; " +
				"an agent comments with add_issue_comment.",
			Meta: uiMeta("", "app")},
			func(ctx context.Context, _ *mcp.CallToolRequest, in commentArgs) (*mcp.CallToolResult, any, error) {
				repo, err := repoOf(ctx, in.Repo)
				if err != nil {
					return failed(err), nil, nil
				}
				if strings.TrimSpace(in.Body) == "" {
					return failed(fmt.Errorf("write the comment first")), nil, nil
				}
				r, err := gh.CommentOnPR(ctx, repo, in.Number, in.Body)
				if err != nil {
					return failed(err), nil, nil
				}
				return structured(r), nil, nil
			})
	}

	// No network at all: an empty csp, so the host draws them under its strictest policy.
	meta := mcp.Meta{"ui": map[string]any{"csp": map[string]any{}, "prefersBorder": true}}
	for _, v := range []struct{ uri, name, title, description, file string }{
		{pullsURI, "pulls", "Pull requests", "The repo's open pull requests, newest created first, with their checks, review, conflict and auto-merge; " +
			"a pull request opens its page. Fed by show_pull_requests.", "pulls.html"},
		{issuesURI, "issues", "Issues", "The repo's open issues, newest created first, with their labels and assignees, and Start Agent; a label narrows " +
			"the list. A person expands a row to read its rich-text description and linked pull requests. Fed by show_issues.", "issues.html"},
		{prURI, "pr", "Pull request", "One pull request's page: description, checks with a failed run's log, files, comments and " +
			"review threads, CodeRabbit's summary and review, with Comment, Approve, Merge, Auto-merge, Start Agent and Ask CodeRabbit Again. Fed by show_pull_request.", "pr.html"},
	} {
		html := page(v.file)
		uri := v.uri
		server.AddResource(&mcp.Resource{URI: uri, Name: v.name, Title: v.title, Description: v.description, MIMEType: viewMime, Meta: meta},
			func(context.Context, *mcp.ReadResourceRequest) (*mcp.ReadResourceResult, error) {
				return &mcp.ReadResourceResult{Contents: []*mcp.ResourceContents{{URI: uri, MIMEType: viewMime, Text: html, Meta: meta}}}, nil
			})
	}
}
