package forgejomcp

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// The forgejo server's tools (#1753), over Forgejo's REST API v1 with the same token as the
// events, in the gitlab server's shape (Go/internal/gitlabmcp/tools.go): list and read pull
// requests, their checks and issues, and comment on a pull request or an issue. For the
// ready-made workflows (#1633): open a pull request, list its line comments, and answer one
// in its thread. Merging and approving are a person's, as on GitHub (#837): they are only on
// the host's copy, never offered to an agent.

const repoWords = "owner/name; the repository this folder pushes to when left out"

type listPRArgs struct {
	Repo   string `json:"repo,omitempty" jsonschema:"owner/name; the repository this folder pushes to when left out"`
	State  string `json:"state,omitempty" jsonschema:"open (when left out), closed or all"`
	Branch string `json:"branch,omitempty" jsonschema:"only the pull requests from this branch"`
	Label  string `json:"label,omitempty" jsonschema:"only pull requests with this label"`
}

type numberArgs struct {
	Repo   string `json:"repo,omitempty" jsonschema:"owner/name; the repository this folder pushes to when left out"`
	Number int    `json:"number" jsonschema:"the pull request's or issue's number"`
}

type checksArgs struct {
	Repo string `json:"repo,omitempty" jsonschema:"owner/name; the repository this folder pushes to when left out"`
	Ref  string `json:"ref,omitempty" jsonschema:"a branch, tag or commit; left out, the head of the pull request number names"`
	PR   int    `json:"number,omitempty" jsonschema:"a pull request's number: its head's checks"`
}

type listIssuesArgs struct {
	Repo  string `json:"repo,omitempty" jsonschema:"owner/name; the repository this folder pushes to when left out"`
	State string `json:"state,omitempty" jsonschema:"open (when left out), closed or all"`
	Label string `json:"label,omitempty" jsonschema:"only issues with this label"`
}

type commentArgs struct {
	Repo   string `json:"repo,omitempty" jsonschema:"owner/name; the repository this folder pushes to when left out"`
	Number int    `json:"number" jsonschema:"the pull request's or issue's number"`
	Body   string `json:"body" jsonschema:"the comment, in Markdown"`
}

type createPRArgs struct {
	Repo        string `json:"repo,omitempty" jsonschema:"owner/name; the repository this folder pushes to when left out"`
	Branch      string `json:"branch" jsonschema:"the branch to merge, already pushed"`
	Target      string `json:"target,omitempty" jsonschema:"the branch to merge into; the repository's default branch when left out"`
	Title       string `json:"title" jsonschema:"the pull request's title"`
	Description string `json:"description,omitempty" jsonschema:"its description, in Markdown; Closes #12 closes that issue when it merges"`
	Draft       bool   `json:"draft,omitempty" jsonschema:"true: open it as a draft (its title starts WIP:)"`
}

type replyArgs struct {
	Repo      string `json:"repo,omitempty" jsonschema:"owner/name; the repository this folder pushes to when left out"`
	Number    int    `json:"number" jsonschema:"the pull request's number"`
	CommentID int    `json:"commentId" jsonschema:"the comment to answer: comment.id in a review.comment event, or an id from list_pull_request_comments"`
	Body      string `json:"body" jsonschema:"the answer, in Markdown"`
}

type mergeArgs struct {
	Repo   string `json:"repo,omitempty" jsonschema:"owner/name; the repository this folder pushes to when left out"`
	Number int    `json:"number" jsonschema:"the pull request's number"`
	Squash bool   `json:"squash,omitempty" jsonschema:"true: squash its commits into one"`
	Auto   bool   `json:"auto,omitempty" jsonschema:"true: merge once its checks succeed"`
	Sha    string `json:"sha" jsonschema:"the head commit the person saw (headSha); Forgejo refuses when the pull request has a newer one"`
}

type logArgs struct {
	Repo  string `json:"repo,omitempty" jsonschema:"owner/name; the repository this folder pushes to when left out"`
	RunID int    `json:"runId" jsonschema:"the Forgejo Actions run's number: run.id in a checks.failed event, or the number after /actions/runs/ in a check's url"`
	Job   string `json:"job,omitempty" jsonschema:"only the failed job with this name"`
}

type approveArgs struct {
	Repo   string `json:"repo,omitempty" jsonschema:"owner/name; the repository this folder pushes to when left out"`
	Number int    `json:"number" jsonschema:"the pull request's number"`
	Sha    string `json:"sha" jsonschema:"the head commit the person saw (headSha)"`
}

// headSha is a merge or an approval's sha: the commit the person saw.
func headSha(sha string) (string, error) {
	sha = strings.TrimSpace(sha)
	if sha == "" {
		return "", fmt.Errorf("sha is the head commit the person saw: read the pull request again")
	}
	return sha, nil
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
	if e, ok := err.(*ForgejoError); ok && e.Kind == RateLimited {
		msg = fmt.Sprintf("%s; try again in %ds", e.Message, (e.RetryAfterMs+999)/1000)
	}
	return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: msg}}, IsError: true}
}

func visibility(v ...string) mcp.Meta { return mcp.Meta{"ui": map[string]any{"visibility": v}} }

// descriptionChars is the most of a description a tool gives.
const descriptionChars = 20000

func clipDescription(text string) string {
	r := []rune(text)
	if len(r) > descriptionChars {
		return string(r[:descriptionChars]) + "…"
	}
	return text
}

// tool adds a tool whose answer is f's, or why it failed.
func tool[In any](server *mcp.Server, t *mcp.Tool, f func(context.Context, In) (map[string]any, error)) {
	mcp.AddTool(server, t, func(ctx context.Context, _ *mcp.CallToolRequest, in In) (*mcp.CallToolResult, any, error) {
		r, err := f(ctx, in)
		if err != nil {
			return failed(err), nil, nil
		}
		return structured(r), nil, nil
	})
}

// AddTools puts the tools and the views (views.go) on server; with person, also the tools only
// a person may call.
func AddTools(server *mcp.Server, f *RealForgejo, person bool) {
	repoOf := func(ctx context.Context, repo string) (string, error) {
		if repo != "" {
			if !repoPattern.MatchString(repo) {
				return "", fmt.Errorf("repo is %s", repoWords)
			}
			return repo, nil
		}
		return f.DefaultRepo(ctx)
	}
	readOnly := &mcp.ToolAnnotations{ReadOnlyHint: true}
	agents := visibility("model", "app")
	addViews(server, f, repoOf)

	tool(server, &mcp.Tool{Name: "list_pull_requests", Title: "List pull requests",
		Description: "The repository's pull requests, newest updated first, at most 50: number, title, branch, target, author, draft, " +
			"state, whether each can merge, and its address.",
		Annotations: readOnly, Meta: agents},
		func(ctx context.Context, in listPRArgs) (map[string]any, error) {
			repo, err := repoOf(ctx, in.Repo)
			if err != nil {
				return nil, err
			}
			st := in.State
			switch st {
			case "":
				st = "open"
			case "open", "closed", "all":
			default:
				return nil, fmt.Errorf("state is open, closed or all")
			}
			path := fmt.Sprintf("%s/pulls?state=%s&sort=recentupdate&limit=%d", repoPath(repo), st, perPage)
			if in.Label != "" {
				id, err := f.labelID(ctx, repo, in.Label)
				if err != nil {
					return nil, err
				}
				path += fmt.Sprintf("&labels=%d", id)
			}
			var list []pullJSON
			if err := f.get(ctx, path, false, &list); err != nil {
				return nil, err
			}
			out := []any{}
			for _, p := range list {
				if in.Branch == "" || p.Head.Ref == in.Branch {
					out = append(out, prSummary(p))
				}
			}
			return map[string]any{"repo": repo, "pullRequests": out}, nil
		})

	tool(server, &mcp.Tool{Name: "get_pull_request", Title: "Read a pull request",
		Description: "One pull request: its description (the first 20000 characters), branch, target, author, labels, draft, state, " +
			"whether it can merge, its head commit and its checks' combined state.",
		Annotations: readOnly, Meta: agents},
		func(ctx context.Context, in numberArgs) (map[string]any, error) {
			repo, err := repoOf(ctx, in.Repo)
			if err != nil {
				return nil, err
			}
			var p pullJSON
			if err := f.get(ctx, fmt.Sprintf("%s/pulls/%d", repoPath(repo), in.Number), false, &p); err != nil {
				return nil, err
			}
			out := prSummary(p)
			out["description"] = clipDescription(p.Body)
			out["labels"] = labelNames(p.Labels)
			out["headSha"] = p.Head.SHA
			out["fixes"] = closingRefs(p.Body)
			if p.Head.SHA != "" {
				if c, err := f.status(ctx, repo, p.Head.SHA); err == nil {
					out["checks"] = c.State
				}
			}
			return out, nil
		})

	tool(server, &mcp.Tool{Name: "get_checks", Title: "Read a commit's checks",
		Description: "The checks of a branch, tag or commit, or of a pull request's head: the combined state (pending, success, error " +
			"or failure) and each check's newest status, its name, state, description and address (a Forgejo Actions run's page, or " +
			"another CI's).",
		Annotations: readOnly, Meta: agents},
		func(ctx context.Context, in checksArgs) (map[string]any, error) {
			repo, err := repoOf(ctx, in.Repo)
			if err != nil {
				return nil, err
			}
			ref := in.Ref
			if ref == "" {
				if in.PR == 0 {
					return nil, fmt.Errorf("ref or number is needed")
				}
				var p pullJSON
				if err := f.get(ctx, fmt.Sprintf("%s/pulls/%d", repoPath(repo), in.PR), false, &p); err != nil {
					return nil, err
				}
				ref = p.Head.SHA
			}
			var c combinedJSON
			if err := f.get(ctx, fmt.Sprintf("%s/commits/%s/status", repoPath(repo), url.PathEscape(ref)), false, &c); err != nil {
				return nil, err
			}
			checks := []any{}
			for _, s := range c.Statuses {
				checks = append(checks, map[string]any{"name": s.Context, "state": s.State, "description": s.Description,
					"url": s.TargetURL, "updatedAt": s.UpdatedAt})
			}
			return map[string]any{"repo": repo, "sha": c.SHA, "state": c.State, "checks": checks}, nil
		})

	mcp.AddTool(server, &mcp.Tool{Name: "failed_log", Title: "Read a failed run's log",
		Description: fmt.Sprintf("The last %d lines of each failed job's log in a Forgejo Actions run, or of one job by name; on "+
			"Forgejo 17 or later, of the step that failed. It needs Forgejo 16 or Gitea 1.25 or later, and says so on an older "+
			"server. Another CI's logs are on its own pages (get_checks gives their addresses).", logLines),
		Annotations: readOnly, Meta: agents},
		func(ctx context.Context, _ *mcp.CallToolRequest, in logArgs) (*mcp.CallToolResult, any, error) {
			repo, err := repoOf(ctx, in.Repo)
			if err != nil {
				return failed(err), nil, nil
			}
			if in.RunID <= 0 {
				return failed(fmt.Errorf("runId is a Forgejo Actions run's number")), nil, nil
			}
			text, err := f.FailedLog(ctx, repo, in.RunID, in.Job)
			if err != nil {
				return failed(err), nil, nil
			}
			return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: text}}}, nil, nil
		})

	tool(server, &mcp.Tool{Name: "list_issues", Title: "List issues",
		Description: "The repository's issues (not its pull requests), newest first, at most 50: number, title, state, author, " +
			"labels, assignees, comments and address.",
		Annotations: readOnly, Meta: agents},
		func(ctx context.Context, in listIssuesArgs) (map[string]any, error) {
			repo, err := repoOf(ctx, in.Repo)
			if err != nil {
				return nil, err
			}
			st := in.State
			switch st {
			case "":
				st = "open"
			case "open", "closed", "all":
			default:
				return nil, fmt.Errorf("state is open, closed or all")
			}
			path := fmt.Sprintf("%s/issues?type=issues&state=%s&limit=%d", repoPath(repo), st, perPage)
			if in.Label != "" {
				path += "&labels=" + url.QueryEscape(in.Label)
			}
			var list []issueJSON
			if err := f.get(ctx, path, false, &list); err != nil {
				return nil, err
			}
			out := []any{}
			for _, i := range list {
				out = append(out, issueSummary(i))
			}
			return map[string]any{"repo": repo, "issues": out}, nil
		})

	tool(server, &mcp.Tool{Name: "get_issue", Title: "Read an issue",
		Description: "One issue: its description (the first 20000 characters), state, author, labels, assignees, and its first 50 " +
			"comments, each with its author, time and body.",
		Annotations: readOnly, Meta: agents},
		func(ctx context.Context, in numberArgs) (map[string]any, error) {
			repo, err := repoOf(ctx, in.Repo)
			if err != nil {
				return nil, err
			}
			var i issueJSON
			if err := f.get(ctx, fmt.Sprintf("%s/issues/%d", repoPath(repo), in.Number), false, &i); err != nil {
				return nil, err
			}
			var comments []commentJSON
			if err := f.get(ctx, fmt.Sprintf("%s/issues/%d/comments?limit=%d", repoPath(repo), in.Number, perPage), false, &comments); err != nil {
				return nil, err
			}
			out := issueSummary(i)
			out["description"] = clipDescription(i.Body)
			list := []any{}
			for _, c := range comments {
				list = append(list, map[string]any{"id": c.ID, "author": c.User.Login, "createdAt": c.CreatedAt,
					"body": clipDescription(c.Body), "url": c.HTMLURL})
			}
			out["comments"] = list
			return out, nil
		})

	comment := func(ctx context.Context, in commentArgs) (map[string]any, error) {
		repo, err := repoOf(ctx, in.Repo)
		if err != nil {
			return nil, err
		}
		if strings.TrimSpace(in.Body) == "" {
			return nil, fmt.Errorf("body is empty")
		}
		var c commentJSON
		if err := f.send(ctx, http.MethodPost, fmt.Sprintf("%s/issues/%d/comments", repoPath(repo), in.Number),
			map[string]any{"body": in.Body}, &c); err != nil {
			return nil, err
		}
		return map[string]any{"id": c.ID, "url": c.HTMLURL}, nil
	}
	tool(server, &mcp.Tool{Name: "comment_on_pull_request", Title: "Comment on a pull request",
		Description: "Adds a comment to a pull request, as the person whose token it is.", Meta: agents}, comment)
	tool(server, &mcp.Tool{Name: "comment_on_issue", Title: "Comment on an issue",
		Description: "Adds a comment to an issue, as the person whose token it is.", Meta: agents}, comment)

	tool(server, &mcp.Tool{Name: "create_pull_request", Title: "Open a pull request",
		Description: "Opens a pull request from a branch already pushed, as the person whose token it is. Never merges it.",
		Meta:        agents},
		func(ctx context.Context, in createPRArgs) (map[string]any, error) {
			repo, err := repoOf(ctx, in.Repo)
			if err != nil {
				return nil, err
			}
			if strings.TrimSpace(in.Branch) == "" || strings.TrimSpace(in.Title) == "" {
				return nil, fmt.Errorf("branch and title are needed")
			}
			target := in.Target
			if target == "" {
				var r struct {
					DefaultBranch string `json:"default_branch"`
				}
				if err := f.get(ctx, repoPath(repo), false, &r); err != nil {
					return nil, err
				}
				target = r.DefaultBranch
			}
			title := in.Title
			if in.Draft && !(pullJSON{Title: title}).draft() {
				title = "WIP: " + title
			}
			var p pullJSON
			if err := f.send(ctx, http.MethodPost, repoPath(repo)+"/pulls",
				map[string]any{"head": in.Branch, "base": target, "title": title, "body": in.Description}, &p); err != nil {
				return nil, err
			}
			return prSummary(p), nil
		})

	tool(server, &mcp.Tool{Name: "list_pull_request_comments", Title: "List a pull request's line comments",
		Description: "The comments on lines of a pull request's diff, in every review, oldest first: each one's id (to answer with " +
			"reply_to_pull_request_comment), author, file, line, body, whether it is resolved, and address.",
		Annotations: readOnly, Meta: agents},
		func(ctx context.Context, in numberArgs) (map[string]any, error) {
			repo, err := repoOf(ctx, in.Repo)
			if err != nil {
				return nil, err
			}
			var p pullJSON
			if err := f.get(ctx, fmt.Sprintf("%s/pulls/%d", repoPath(repo), in.Number), false, &p); err != nil {
				return nil, err
			}
			comments, err := f.reviewComments(ctx, repo, p, "")
			if err != nil {
				return nil, err
			}
			list := []any{}
			for _, c := range comments {
				author := ""
				if c.User != nil {
					author = c.User.Login
				}
				list = append(list, map[string]any{"id": c.ID, "author": author, "path": c.Path, "line": c.line(),
					"body": clipDescription(c.Body), "resolved": c.Resolver != nil, "createdAt": c.CreatedAt, "url": c.HTMLURL})
			}
			return map[string]any{"repo": repo, "number": in.Number, "comments": list}, nil
		})

	tool(server, &mcp.Tool{Name: "reply_to_pull_request_comment", Title: "Answer a pull request's comment",
		Description: "Answers a comment on a line of a pull request's diff in its own thread, as the person whose token it is: " +
			"a review comment on the same file and line.",
		Meta: agents},
		func(ctx context.Context, in replyArgs) (map[string]any, error) {
			repo, err := repoOf(ctx, in.Repo)
			if err != nil {
				return nil, err
			}
			if strings.TrimSpace(in.Body) == "" {
				return nil, fmt.Errorf("body is empty")
			}
			var p pullJSON
			if err := f.get(ctx, fmt.Sprintf("%s/pulls/%d", repoPath(repo), in.Number), false, &p); err != nil {
				return nil, err
			}
			comments, err := f.reviewComments(ctx, repo, p, "")
			if err != nil {
				return nil, err
			}
			var to *reviewCommentJSON
			for i := range comments {
				if comments[i].ID == in.CommentID {
					to = &comments[i]
				}
			}
			if to == nil {
				return nil, fmt.Errorf("pull request %d has no line comment %d", in.Number, in.CommentID)
			}
			// Forgejo keeps a thread by its file, line and commit, so a comment there is in it.
			line := map[string]any{"path": to.Path, "body": in.Body}
			if to.Position > 0 {
				line["new_position"] = to.Position
			} else {
				line["old_position"] = to.OriginalPosition
			}
			commit := to.CommitID
			if commit == "" {
				commit = p.Head.SHA
			}
			var r reviewJSON
			if err := f.send(ctx, http.MethodPost, fmt.Sprintf("%s/pulls/%d/reviews", repoPath(repo), in.Number),
				map[string]any{"event": "COMMENT", "commit_id": commit, "comments": []any{line}}, &r); err != nil {
				return nil, err
			}
			return map[string]any{"review": r.ID, "url": r.HTMLURL}, nil
		})

	// Merge and approve are the person's. They are only on the copy the host runs (person),
	// whose callers are the person's own windows and devices.
	if person {
		person := visibility("app")
		tool(server, &mcp.Tool{Name: "merge_pull_request", Title: "Merge a pull request",
			Description: "Merges a pull request and deletes its branch, as the person whose token it is; squash squashes its " +
				"commits, auto merges once its checks succeed. Only a person may call it.",
			Meta: person},
			func(ctx context.Context, in mergeArgs) (map[string]any, error) {
				repo, err := repoOf(ctx, in.Repo)
				if err != nil {
					return nil, err
				}
				sha, err := headSha(in.Sha)
				if err != nil {
					return nil, err
				}
				do := "merge"
				if in.Squash {
					do = "squash"
				}
				body := map[string]any{"Do": do, "head_commit_id": sha, "delete_branch_after_merge": true,
					"merge_when_checks_succeed": in.Auto}
				if err := f.send(ctx, http.MethodPost, fmt.Sprintf("%s/pulls/%d/merge", repoPath(repo), in.Number), body, nil); err != nil {
					var fe *ForgejoError
					if errors.As(err, &fe) && strings.Contains(strings.ToLower(fe.Message), "head") {
						return nil, fmt.Errorf("the pull request has a newer commit than the person saw: read it again (%w)", err)
					}
					return nil, err
				}
				return map[string]any{"merged": !in.Auto, "auto": in.Auto, "number": in.Number}, nil
			})
		tool(server, &mcp.Tool{Name: "approve_pull_request", Title: "Approve a pull request",
			Description: "Approves a pull request at the head commit the person saw, as the person whose token it is. Only a person may call it.",
			Meta:        person},
			func(ctx context.Context, in approveArgs) (map[string]any, error) {
				repo, err := repoOf(ctx, in.Repo)
				if err != nil {
					return nil, err
				}
				sha, err := headSha(in.Sha)
				if err != nil {
					return nil, err
				}
				var r reviewJSON
				if err := f.send(ctx, http.MethodPost, fmt.Sprintf("%s/pulls/%d/reviews", repoPath(repo), in.Number),
					map[string]any{"event": "APPROVED", "commit_id": sha}, &r); err != nil {
					return nil, err
				}
				return map[string]any{"approved": true, "number": in.Number, "review": r.ID}, nil
			})
	}
}

// labelID is a label's id by its name: Forgejo filters pull requests by label id.
func (f *RealForgejo) labelID(ctx context.Context, repo, name string) (int, error) {
	labels, _, err := all[struct {
		ID   int    `json:"id"`
		Name string `json:"name"`
	}](ctx, f, repoPath(repo)+"/labels")
	if err != nil {
		return 0, err
	}
	for _, l := range labels {
		if strings.EqualFold(l.Name, name) {
			return l.ID, nil
		}
	}
	return 0, fmt.Errorf("%s has no label %q", repo, name)
}

func prSummary(p pullJSON) map[string]any {
	state := p.State
	if p.Merged {
		state = "merged"
	}
	return map[string]any{"number": p.Number, "title": p.Title, "branch": p.Head.Ref, "target": p.Base.Ref, "author": p.User.Login,
		"draft": p.draft(), "state": state, "mergeable": p.Mergeable, "fork": p.fork(), "url": p.HTMLURL, "updatedAt": p.UpdatedAt}
}

func issueSummary(i issueJSON) map[string]any {
	return map[string]any{"number": i.Number, "title": i.Title, "state": i.State, "author": i.User.Login,
		"labels": labelNames(i.Labels), "assignees": i.issue().Assignees, "comments": i.Comments, "url": i.HTMLURL,
		"createdAt": i.CreatedAt, "updatedAt": i.UpdatedAt}
}
