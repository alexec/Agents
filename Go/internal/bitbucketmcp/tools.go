package bitbucketmcp

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// The bitbucket server's tools (#2828), over Bitbucket Cloud's REST API 2.0 with the same
// token as the events, in the gitlab server's shape (Go/internal/gitlabmcp/tools.go) and with
// its names, so the ready-made workflows (#1633) work here too: list and read pull requests,
// their checks and issues, and comment on a pull request or an issue; open a pull request,
// list its line comments, and answer one in its thread. Merging and approving are a person's,
// as on GitHub (#837): they are only on the host's copy, never offered to an agent.

const repoWords = "workspace/name; the repository this folder pushes to when left out"

type listPRArgs struct {
	Repo   string `json:"repo,omitempty" jsonschema:"workspace/name; the repository this folder pushes to when left out"`
	State  string `json:"state,omitempty" jsonschema:"open (when left out), merged, declined, closed (merged or declined) or all"`
	Branch string `json:"branch,omitempty" jsonschema:"only the pull requests from this branch"`
}

type numberArgs struct {
	Repo   string `json:"repo,omitempty" jsonschema:"workspace/name; the repository this folder pushes to when left out"`
	Number int    `json:"number" jsonschema:"the pull request's or issue's number"`
}

type checksArgs struct {
	Repo string `json:"repo,omitempty" jsonschema:"workspace/name; the repository this folder pushes to when left out"`
	Ref  string `json:"ref,omitempty" jsonschema:"a commit, or a branch; left out, the head of the pull request number names"`
	PR   int    `json:"number,omitempty" jsonschema:"a pull request's number: its head's checks"`
}

type listIssuesArgs struct {
	Repo  string `json:"repo,omitempty" jsonschema:"workspace/name; the repository this folder pushes to when left out"`
	State string `json:"state,omitempty" jsonschema:"open (new, open or on hold; when left out), closed or all"`
	Label string `json:"label,omitempty" jsonschema:"only issues of this kind (bug, enhancement, proposal, task) or component"`
}

type commentArgs struct {
	Repo   string `json:"repo,omitempty" jsonschema:"workspace/name; the repository this folder pushes to when left out"`
	Number int    `json:"number" jsonschema:"the pull request's or issue's number"`
	Body   string `json:"body" jsonschema:"the comment, in Markdown"`
}

type createPRArgs struct {
	Repo        string `json:"repo,omitempty" jsonschema:"workspace/name; the repository this folder pushes to when left out"`
	Branch      string `json:"branch" jsonschema:"the branch to merge, already pushed"`
	Target      string `json:"target,omitempty" jsonschema:"the branch to merge into; the repository's main branch when left out"`
	Title       string `json:"title" jsonschema:"the pull request's title"`
	Description string `json:"description,omitempty" jsonschema:"its description, in Markdown; Closes #12 closes that issue when it merges"`
	Draft       bool   `json:"draft,omitempty" jsonschema:"true: open it as a draft"`
}

type replyArgs struct {
	Repo      string `json:"repo,omitempty" jsonschema:"workspace/name; the repository this folder pushes to when left out"`
	Number    int    `json:"number" jsonschema:"the pull request's number"`
	CommentID int    `json:"commentId" jsonschema:"the comment to answer: comment.id in a review.comment event, or an id from list_pull_request_comments"`
	Body      string `json:"body" jsonschema:"the answer, in Markdown"`
}

type mergeArgs struct {
	Repo   string `json:"repo,omitempty" jsonschema:"workspace/name; the repository this folder pushes to when left out"`
	Number int    `json:"number" jsonschema:"the pull request's number"`
	Squash bool   `json:"squash,omitempty" jsonschema:"true: squash its commits into one"`
	Sha    string `json:"sha" jsonschema:"the head commit the person saw (headSha); refused when the pull request has a newer one"`
}

type approveArgs struct {
	Repo   string `json:"repo,omitempty" jsonschema:"workspace/name; the repository this folder pushes to when left out"`
	Number int    `json:"number" jsonschema:"the pull request's number"`
	Sha    string `json:"sha" jsonschema:"the head commit the person saw (headSha); refused when the pull request has a newer one"`
}

// sameCommit says whether two hashes name one commit: Bitbucket gives a pull request's head
// as 12 characters, a person may give all 40.
func sameCommit(a, b string) bool {
	a, b = strings.ToLower(strings.TrimSpace(a)), strings.ToLower(strings.TrimSpace(b))
	if len(a) < 7 || len(b) < 7 {
		return false
	}
	return strings.HasPrefix(a, b) || strings.HasPrefix(b, a)
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
	if e, ok := err.(*BitbucketError); ok && e.Kind == RateLimited {
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

// prStates are a listing's states as Bitbucket's: open, merged, declined, closed or all.
func prStates(state string) (string, error) {
	switch state {
	case "", "open":
		return "state=OPEN", nil
	case "merged":
		return "state=MERGED", nil
	case "declined":
		return "state=DECLINED", nil
	case "closed":
		return "state=MERGED&state=DECLINED", nil
	case "all":
		return "state=OPEN&state=MERGED&state=DECLINED&state=SUPERSEDED", nil
	}
	return "", fmt.Errorf("state is open, merged, declined, closed or all")
}

// AddTools puts the tools on server; with person, also the tools only a person may call.
func AddTools(server *mcp.Server, b *RealBitbucket, person bool) {
	repoOf := func(ctx context.Context, repo string) (string, error) {
		if repo != "" {
			if !repoPattern.MatchString(repo) {
				return "", fmt.Errorf("repo is %s", repoWords)
			}
			return repo, nil
		}
		return b.DefaultRepo(ctx)
	}
	pull := func(ctx context.Context, repo string, number int) (pullJSON, error) {
		var p pullJSON
		err := b.get(ctx, fmt.Sprintf("%s/pullrequests/%d", repoPath(repo), number), false, &p)
		return p, err
	}
	readOnly := &mcp.ToolAnnotations{ReadOnlyHint: true}
	agents := visibility("model", "app")

	tool(server, &mcp.Tool{Name: "list_pull_requests", Title: "List pull requests",
		Description: "The repository's pull requests, newest updated first, at most 50: number, title, branch, target, author, draft, " +
			"state, whether it is from a fork, and its address.",
		Annotations: readOnly, Meta: agents},
		func(ctx context.Context, in listPRArgs) (map[string]any, error) {
			repo, err := repoOf(ctx, in.Repo)
			if err != nil {
				return nil, err
			}
			states, err := prStates(in.State)
			if err != nil {
				return nil, err
			}
			path := fmt.Sprintf("%s/pullrequests?%s&sort=-updated_on&pagelen=%d", repoPath(repo), states, perPage)
			if in.Branch != "" {
				path += "&" + bbql(fmt.Sprintf("source.branch.name=%q", in.Branch))
			}
			var list paged[pullJSON]
			if err := b.get(ctx, path, false, &list); err != nil {
				return nil, err
			}
			out := []any{}
			for _, p := range list.Values {
				if in.Branch == "" || p.Source.Branch.Name == in.Branch {
					out = append(out, prSummary(p))
				}
			}
			return map[string]any{"repo": repo, "pullRequests": out}, nil
		})

	tool(server, &mcp.Tool{Name: "get_pull_request", Title: "Read a pull request",
		Description: "One pull request: its description (the first 20000 characters), branch, target, author, reviewers, draft, " +
			"state, its head commit and its checks' combined state (pending, success or failure).",
		Annotations: readOnly, Meta: agents},
		func(ctx context.Context, in numberArgs) (map[string]any, error) {
			repo, err := repoOf(ctx, in.Repo)
			if err != nil {
				return nil, err
			}
			p, err := pull(ctx, repo, in.Number)
			if err != nil {
				return nil, err
			}
			out := prSummary(p)
			out["description"] = clipDescription(p.Description)
			reviewers := []string{}
			for _, r := range p.Reviewers {
				reviewers = append(reviewers, r.name())
			}
			out["reviewers"] = reviewers
			out["headSha"] = p.Source.hash()
			out["fixes"] = closingRefs(p.Description)
			if sha := p.Source.hash(); sha != "" {
				if s, err := b.statuses(ctx, repo, sha, false); err == nil {
					out["checks"] = combined(s)
				}
			}
			return out, nil
		})

	tool(server, &mcp.Tool{Name: "get_checks", Title: "Read a commit's checks",
		Description: "The checks of a commit or branch, or of a pull request's head: the combined state (pending, success or failure) " +
			"and each check's status, its name, state (SUCCESSFUL, FAILED, INPROGRESS or STOPPED), description and address (a " +
			"Pipelines run's page, or another CI's).",
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
				p, err := pull(ctx, repo, in.PR)
				if err != nil {
					return nil, err
				}
				ref = p.Source.hash()
			}
			statuses, err := b.statuses(ctx, repo, ref, false)
			if err != nil {
				return nil, err
			}
			checks := []any{}
			for _, s := range statuses {
				checks = append(checks, map[string]any{"name": s.title(), "key": s.Key, "state": s.State, "description": s.Description,
					"url": s.URL, "updatedAt": s.UpdatedOn})
			}
			return map[string]any{"repo": repo, "sha": ref, "state": combined(statuses), "checks": checks}, nil
		})

	tool(server, &mcp.Tool{Name: "list_issues", Title: "List issues",
		Description: "The repository's issues, newest updated first, at most 50: number, title, state, kind, priority, component, " +
			"author, assignee and address. Bitbucket's issues have no labels: their kind and component are their labels. A " +
			"repository whose issue tracker is off has none.",
		Annotations: readOnly, Meta: agents},
		func(ctx context.Context, in listIssuesArgs) (map[string]any, error) {
			repo, err := repoOf(ctx, in.Repo)
			if err != nil {
				return nil, err
			}
			var q []string
			switch in.State {
			case "", "open":
				q = append(q, openIssues)
			case "closed":
				q = append(q, closedIssues)
			case "all":
			default:
				return nil, fmt.Errorf("state is open, closed or all")
			}
			if in.Label != "" {
				q = append(q, fmt.Sprintf("(kind=%q OR component.name=%q)", in.Label, in.Label))
			}
			path := fmt.Sprintf("%s/issues?sort=-updated_on&pagelen=%d", repoPath(repo), perPage)
			if len(q) > 0 {
				path += "&" + bbql(strings.Join(q, " AND "))
			}
			var list paged[issueJSON]
			if err := b.get(ctx, path, false, &list); err != nil {
				if noTracker(err) {
					return nil, fmt.Errorf("%w: %s may have no issue tracker", err, repo)
				}
				return nil, err
			}
			out := []any{}
			for _, i := range list.Values {
				out = append(out, issueSummary(i))
			}
			return map[string]any{"repo": repo, "issues": out}, nil
		})

	tool(server, &mcp.Tool{Name: "get_issue", Title: "Read an issue",
		Description: "One issue: its description (the first 20000 characters), state, kind, priority, component, author, assignee, " +
			"and its first 50 comments, each with its author, time and body.",
		Annotations: readOnly, Meta: agents},
		func(ctx context.Context, in numberArgs) (map[string]any, error) {
			repo, err := repoOf(ctx, in.Repo)
			if err != nil {
				return nil, err
			}
			var i issueJSON
			if err := b.get(ctx, fmt.Sprintf("%s/issues/%d", repoPath(repo), in.Number), false, &i); err != nil {
				return nil, err
			}
			var comments paged[commentJSON]
			if err := b.get(ctx, fmt.Sprintf("%s/issues/%d/comments?sort=created_on&pagelen=%d", repoPath(repo), in.Number, perPage), false, &comments); err != nil {
				return nil, err
			}
			out := issueSummary(i)
			out["description"] = clipDescription(i.Content.Raw)
			list := []any{}
			for _, c := range comments.Values {
				if strings.TrimSpace(c.Content.Raw) == "" {
					continue
				}
				list = append(list, map[string]any{"id": c.ID, "author": c.User.name(), "createdAt": c.CreatedOn,
					"body": clipDescription(c.Content.Raw), "url": c.Links.HTML.Href})
			}
			out["comments"] = list
			return out, nil
		})

	comment := func(kind string) func(ctx context.Context, in commentArgs) (map[string]any, error) {
		return func(ctx context.Context, in commentArgs) (map[string]any, error) {
			repo, err := repoOf(ctx, in.Repo)
			if err != nil {
				return nil, err
			}
			if strings.TrimSpace(in.Body) == "" {
				return nil, fmt.Errorf("body is empty")
			}
			var c commentJSON
			if err := b.send(ctx, http.MethodPost, fmt.Sprintf("%s/%s/%d/comments", repoPath(repo), kind, in.Number),
				map[string]any{"content": map[string]any{"raw": in.Body}}, &c); err != nil {
				return nil, err
			}
			return map[string]any{"id": c.ID, "url": c.Links.HTML.Href}, nil
		}
	}
	tool(server, &mcp.Tool{Name: "comment_on_pull_request", Title: "Comment on a pull request",
		Description: "Adds a comment to a pull request, as the person whose token it is.", Meta: agents}, comment("pullrequests"))
	tool(server, &mcp.Tool{Name: "comment_on_issue", Title: "Comment on an issue",
		Description: "Adds a comment to an issue, as the person whose token it is.", Meta: agents}, comment("issues"))

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
			body := map[string]any{"title": in.Title, "description": in.Description, "draft": in.Draft,
				"source": map[string]any{"branch": map[string]any{"name": in.Branch}}}
			// Left out, Bitbucket takes the repository's main branch.
			if in.Target != "" {
				body["destination"] = map[string]any{"branch": map[string]any{"name": in.Target}}
			}
			var p pullJSON
			if err := b.send(ctx, http.MethodPost, repoPath(repo)+"/pullrequests", body, &p); err != nil {
				return nil, err
			}
			return prSummary(p), nil
		})

	tool(server, &mcp.Tool{Name: "list_pull_request_comments", Title: "List a pull request's line comments",
		Description: "The comments on lines of a pull request's diff, and the answers in their threads, oldest first: each one's id " +
			"(to answer with reply_to_pull_request_comment), author, file, line, body, whether it is resolved, and address.",
		Annotations: readOnly, Meta: agents},
		func(ctx context.Context, in numberArgs) (map[string]any, error) {
			repo, err := repoOf(ctx, in.Repo)
			if err != nil {
				return nil, err
			}
			p, err := pull(ctx, repo, in.Number)
			if err != nil {
				return nil, err
			}
			comments, err := b.inlineComments(ctx, repo, p, "")
			if err != nil {
				return nil, err
			}
			list := []any{}
			for i := len(comments) - 1; i >= 0; i-- {
				c := comments[i]
				list = append(list, map[string]any{"id": c.ID, "author": c.User.name(), "path": c.Inline.Path, "line": c.line(),
					"body": clipDescription(c.Content.Raw), "resolved": c.Resolution != nil, "createdAt": c.CreatedOn, "url": c.Links.HTML.Href})
			}
			return map[string]any{"repo": repo, "number": in.Number, "comments": list}, nil
		})

	tool(server, &mcp.Tool{Name: "reply_to_pull_request_comment", Title: "Answer a pull request's comment",
		Description: "Answers a comment on a line of a pull request's diff in its own thread, as the person whose token it is.",
		Meta:        agents},
		func(ctx context.Context, in replyArgs) (map[string]any, error) {
			repo, err := repoOf(ctx, in.Repo)
			if err != nil {
				return nil, err
			}
			if strings.TrimSpace(in.Body) == "" {
				return nil, fmt.Errorf("body is empty")
			}
			var to commentJSON
			if err := b.get(ctx, fmt.Sprintf("%s/pullrequests/%d/comments/%d", repoPath(repo), in.Number, in.CommentID), false, &to); err != nil {
				if noTracker(err) {
					return nil, fmt.Errorf("pull request %d has no comment %d", in.Number, in.CommentID)
				}
				return nil, err
			}
			if to.Inline == nil {
				return nil, fmt.Errorf("comment %d is not on a line of pull request %d's diff: use comment_on_pull_request", in.CommentID, in.Number)
			}
			var c commentJSON
			if err := b.send(ctx, http.MethodPost, fmt.Sprintf("%s/pullrequests/%d/comments", repoPath(repo), in.Number),
				map[string]any{"content": map[string]any{"raw": in.Body}, "parent": map[string]any{"id": in.CommentID}}, &c); err != nil {
				return nil, err
			}
			return map[string]any{"id": c.ID, "url": c.Links.HTML.Href}, nil
		})

	// Merge and approve are the person's. They are only on the copy the host runs (person),
	// whose callers are the person's own windows and devices.
	if person {
		person := visibility("app")
		// atHead is the pull request when its head is still the commit the person saw.
		atHead := func(ctx context.Context, repo string, number int, sha string) error {
			if strings.TrimSpace(sha) == "" {
				return fmt.Errorf("sha is the head commit the person saw: read the pull request again")
			}
			p, err := pull(ctx, repo, number)
			if err != nil {
				return err
			}
			if !sameCommit(p.Source.hash(), sha) {
				return fmt.Errorf("the pull request has a newer commit (%s) than the person saw: read it again", p.Source.hash())
			}
			return nil
		}
		tool(server, &mcp.Tool{Name: "merge_pull_request", Title: "Merge a pull request",
			Description: "Merges a pull request and deletes its branch, as the person whose token it is; squash squashes its " +
				"commits. Only a person may call it.",
			Meta: person},
			func(ctx context.Context, in mergeArgs) (map[string]any, error) {
				repo, err := repoOf(ctx, in.Repo)
				if err != nil {
					return nil, err
				}
				if err := atHead(ctx, repo, in.Number, in.Sha); err != nil {
					return nil, err
				}
				strategy := "merge_commit"
				if in.Squash {
					strategy = "squash"
				}
				if err := b.send(ctx, http.MethodPost, fmt.Sprintf("%s/pullrequests/%d/merge", repoPath(repo), in.Number),
					map[string]any{"merge_strategy": strategy, "close_source_branch": true}, nil); err != nil {
					return nil, err
				}
				return map[string]any{"merged": true, "number": in.Number}, nil
			})
		tool(server, &mcp.Tool{Name: "approve_pull_request", Title: "Approve a pull request",
			Description: "Approves a pull request at the head commit the person saw, as the person whose token it is. Only a person may call it.",
			Meta:        person},
			func(ctx context.Context, in approveArgs) (map[string]any, error) {
				repo, err := repoOf(ctx, in.Repo)
				if err != nil {
					return nil, err
				}
				if err := atHead(ctx, repo, in.Number, in.Sha); err != nil {
					return nil, err
				}
				if err := b.send(ctx, http.MethodPost, fmt.Sprintf("%s/pullrequests/%d/approve", repoPath(repo), in.Number), nil, nil); err != nil {
					return nil, err
				}
				return map[string]any{"approved": true, "number": in.Number}, nil
			})
	}
}

func prSummary(p pullJSON) map[string]any {
	return map[string]any{"number": p.ID, "title": p.Title, "branch": p.Source.Branch.Name, "target": p.Destination.Branch.Name,
		"author": p.Author.name(), "draft": p.Draft, "state": strings.ToLower(p.State), "fork": p.fork(), "url": p.Links.HTML.Href,
		"updatedAt": p.UpdatedOn}
}

func issueSummary(i issueJSON) map[string]any {
	component := ""
	if i.Component != nil {
		component = i.Component.Name
	}
	return map[string]any{"number": i.ID, "title": i.Title, "state": i.State, "kind": i.Kind, "priority": i.Priority,
		"component": component, "labels": i.labels(), "author": i.Reporter.name(), "assignees": i.issue().Assignees,
		"url": i.Links.HTML.Href, "createdAt": i.CreatedOn, "updatedAt": i.UpdatedOn}
}
