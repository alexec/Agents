package azuredevopsmcp

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// The azuredevops server's tools (#2829), over Azure DevOps's REST API with the same token as
// the events, in the gitlab server's shape (Go/internal/gitlabmcp/tools.go): list and read
// pull requests and their builds, read a failed build's log, and comment on a pull request.
// For the ready-made workflows (#1633): open a pull request, list its line comments, and
// answer one in its thread. Merging and approving are a person's, as on GitHub (#837): they
// are only on the host's copy, never offered to an agent. Work items are the tracker's.

const repoWords = "organization/project/name; the repository this folder pushes to when left out"

type listPRArgs struct {
	Repo   string `json:"repo,omitempty" jsonschema:"organization/project/name; the repository this folder pushes to when left out"`
	State  string `json:"state,omitempty" jsonschema:"open (when left out), merged, abandoned or all"`
	Branch string `json:"branch,omitempty" jsonschema:"only the pull requests from this branch"`
	Label  string `json:"label,omitempty" jsonschema:"only pull requests with this tag"`
}

type numberArgs struct {
	Repo   string `json:"repo,omitempty" jsonschema:"organization/project/name; the repository this folder pushes to when left out"`
	Number int    `json:"number" jsonschema:"the pull request's number"`
}

type checksArgs struct {
	Repo   string `json:"repo,omitempty" jsonschema:"organization/project/name; the repository this folder pushes to when left out"`
	Branch string `json:"branch,omitempty" jsonschema:"a branch: its builds; left out, the builds of the pull request number names"`
	PR     int    `json:"number,omitempty" jsonschema:"a pull request's number: its builds and statuses"`
}

type buildLogArgs struct {
	Repo  string `json:"repo,omitempty" jsonschema:"organization/project/name; the repository this folder pushes to when left out"`
	Build int    `json:"buildId" jsonschema:"the build's id: run.id in a checks.failed event, or an id from get_checks"`
}

type commentArgs struct {
	Repo   string `json:"repo,omitempty" jsonschema:"organization/project/name; the repository this folder pushes to when left out"`
	Number int    `json:"number" jsonschema:"the pull request's number"`
	Body   string `json:"body" jsonschema:"the comment, in Markdown"`
}

type createPRArgs struct {
	Repo        string `json:"repo,omitempty" jsonschema:"organization/project/name; the repository this folder pushes to when left out"`
	Branch      string `json:"branch" jsonschema:"the branch to merge, already pushed"`
	Target      string `json:"target,omitempty" jsonschema:"the branch to merge into; the repository's default branch when left out"`
	Title       string `json:"title" jsonschema:"the pull request's title"`
	Description string `json:"description,omitempty" jsonschema:"its description, in Markdown; Fixes #12 links work item 12"`
	Draft       bool   `json:"draft,omitempty" jsonschema:"true: open it as a draft"`
}

type replyArgs struct {
	Repo     string `json:"repo,omitempty" jsonschema:"organization/project/name; the repository this folder pushes to when left out"`
	Number   int    `json:"number" jsonschema:"the pull request's number"`
	ThreadID int    `json:"threadId" jsonschema:"the thread to answer in: comment.threadId in a review.comment event, or a threadId from list_pull_request_comments"`
	Body     string `json:"body" jsonschema:"the answer, in Markdown"`
}

type mergeArgs struct {
	Repo   string `json:"repo,omitempty" jsonschema:"organization/project/name; the repository this folder pushes to when left out"`
	Number int    `json:"number" jsonschema:"the pull request's number"`
	Squash bool   `json:"squash,omitempty" jsonschema:"true: squash its commits into one"`
	Auto   bool   `json:"auto,omitempty" jsonschema:"true: complete it once its policies pass (auto-complete)"`
	Sha    string `json:"sha" jsonschema:"the head commit the person saw (headSha); Azure DevOps refuses when the pull request has a newer one"`
}

type approveArgs struct {
	Repo   string `json:"repo,omitempty" jsonschema:"organization/project/name; the repository this folder pushes to when left out"`
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
	if e, ok := err.(*AzureDevOpsError); ok && e.Kind == RateLimited {
		msg = fmt.Sprintf("%s; try again in %ds", e.Message, (e.RetryAfterMs+999)/1000)
	}
	return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: msg}}, IsError: true}
}

func visibility(v ...string) mcp.Meta { return mcp.Meta{"ui": map[string]any{"visibility": v}} }

// descriptionChars is the most of a description, or of a log's end, a tool gives.
const descriptionChars = 20000

func clipDescription(text string) string {
	r := []rune(text)
	if len(r) > descriptionChars {
		return string(r[:descriptionChars]) + "…"
	}
	return text
}

// logEnd is the end of a log, where a failure is: its last descriptionChars.
func logEnd(text string) string {
	r := []rune(text)
	if len(r) > descriptionChars {
		return "…" + string(r[len(r)-descriptionChars:])
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

// AddTools puts the tools on server; with person, also the tools only a person may call.
func AddTools(server *mcp.Server, f *RealAzureDevOps, person bool) {
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
	pull := func(ctx context.Context, repo string, number int) (pullJSON, error) {
		var p pullJSON
		err := f.get(ctx, api(fmt.Sprintf("%s/pullrequests/%d", repoPath(repo), number), nil), false, &p)
		return p, err
	}

	tool(server, &mcp.Tool{Name: "list_pull_requests", Title: "List pull requests",
		Description: "The repository's pull requests, newest first, at most 100: number, title, branch, target, author, draft, " +
			"state (open, merged or abandoned), whether it can merge, and its address.",
		Annotations: readOnly, Meta: agents},
		func(ctx context.Context, in listPRArgs) (map[string]any, error) {
			repo, err := repoOf(ctx, in.Repo)
			if err != nil {
				return nil, err
			}
			st, ok := map[string]string{"": "active", "open": "active", "merged": "completed", "abandoned": "abandoned", "all": "all"}[in.State]
			if !ok {
				return nil, fmt.Errorf("state is open, merged, abandoned or all")
			}
			q := url.Values{"searchCriteria.status": {st}, "$top": {strconv.Itoa(perPage)}}
			if in.Branch != "" {
				q.Set("searchCriteria.sourceRefName", "refs/heads/"+in.Branch)
			}
			var list struct {
				Value []pullJSON `json:"value"`
			}
			if err := f.get(ctx, api(repoPath(repo)+"/pullrequests", q), false, &list); err != nil {
				return nil, err
			}
			out := []any{}
			for _, p := range list.Value {
				if in.Label == "" || hasLabel(p, in.Label) {
					out = append(out, f.prSummary(repo, p))
				}
			}
			return map[string]any{"repo": repo, "pullRequests": out}, nil
		})

	tool(server, &mcp.Tool{Name: "get_pull_request", Title: "Read a pull request",
		Description: "One pull request: its description (the first 20000 characters), branch, target, author, tags, draft, state, " +
			"whether it can merge, its head commit, its reviewers and their votes, and its builds' combined state.",
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
			out := f.prSummary(repo, p)
			out["description"] = clipDescription(p.Description)
			out["labels"] = p.labels()
			out["headSha"] = p.head()
			out["fixes"] = closingRefs(p.Description)
			reviewers := []any{}
			for _, r := range p.Reviewers {
				reviewers = append(reviewers, map[string]any{"name": r.name(), "vote": voteWords(r.Vote), "required": r.IsRequired})
			}
			out["reviewers"] = reviewers
			if builds, err := f.newestBuilds(ctx, repo, fmt.Sprintf("refs/pull/%d/merge", p.ID)); err == nil {
				out["checks"] = combined(builds)
			}
			return out, nil
		})

	tool(server, &mcp.Tool{Name: "get_checks", Title: "Read the checks",
		Description: "The Azure Pipelines builds of a branch, or of a pull request (its build validation), the newest of each " +
			"pipeline: the combined state (pending, succeeded or failed) and each build's id (for get_build_log), pipeline, state, " +
			"result, commit and address; for a pull request, also the statuses other services set on it.",
		Annotations: readOnly, Meta: agents},
		func(ctx context.Context, in checksArgs) (map[string]any, error) {
			repo, err := repoOf(ctx, in.Repo)
			if err != nil {
				return nil, err
			}
			ref := "refs/heads/" + in.Branch
			if in.Branch == "" {
				if in.PR == 0 {
					return nil, fmt.Errorf("branch or number is needed")
				}
				ref = fmt.Sprintf("refs/pull/%d/merge", in.PR)
			}
			builds, err := f.newestBuilds(ctx, repo, ref)
			if err != nil {
				return nil, err
			}
			checks := []any{}
			for _, b := range builds {
				checks = append(checks, map[string]any{"id": b.ID, "name": b.Definition.Name, "number": b.BuildNumber, "state": b.Status,
					"result": b.Result, "sha": b.sha(), "url": b.Links.Web.Href, "finishedAt": b.FinishTime})
			}
			out := map[string]any{"repo": repo, "ref": ref, "state": combined(builds), "checks": checks}
			if in.Branch == "" {
				var statuses struct {
					Value []struct {
						State       string `json:"state"`
						Description string `json:"description"`
						TargetURL   string `json:"targetUrl"`
						Context     struct {
							Name  string `json:"name"`
							Genre string `json:"genre"`
						} `json:"context"`
					} `json:"value"`
				}
				if err := f.get(ctx, api(fmt.Sprintf("%s/pullRequests/%d/statuses", repoPath(repo), in.PR), nil), false, &statuses); err != nil {
					return nil, err
				}
				list := []any{}
				for _, s := range statuses.Value {
					name := s.Context.Name
					if s.Context.Genre != "" {
						name = s.Context.Genre + "/" + name
					}
					list = append(list, map[string]any{"name": name, "state": s.State, "description": s.Description, "url": s.TargetURL})
				}
				out["statuses"] = list
			}
			return out, nil
		})

	tool(server, &mcp.Tool{Name: "get_build_log", Title: "Read a failed build's log",
		Description: "An Azure Pipelines build's failed steps: each one's name, its job's, its errors, and the end of its log " +
			"(the last 20000 characters), where the failure is.",
		Annotations: readOnly, Meta: agents},
		func(ctx context.Context, in buildLogArgs) (map[string]any, error) {
			repo, err := repoOf(ctx, in.Repo)
			if err != nil {
				return nil, err
			}
			if in.Build <= 0 {
				return nil, fmt.Errorf("buildId is needed")
			}
			return f.buildLog(ctx, repo, in.Build)
		})

	tool(server, &mcp.Tool{Name: "comment_on_pull_request", Title: "Comment on a pull request",
		Description: "Adds a comment to a pull request, in a thread of its own, as the person whose token it is.", Meta: agents},
		func(ctx context.Context, in commentArgs) (map[string]any, error) {
			repo, err := repoOf(ctx, in.Repo)
			if err != nil {
				return nil, err
			}
			if strings.TrimSpace(in.Body) == "" {
				return nil, fmt.Errorf("body is empty")
			}
			var t threadJSON
			if err := f.send(ctx, http.MethodPost, api(fmt.Sprintf("%s/pullRequests/%d/threads", repoPath(repo), in.Number), nil),
				map[string]any{"status": "active", "comments": []any{map[string]any{"parentCommentId": 0, "content": in.Body, "commentType": "text"}}},
				&t); err != nil {
				return nil, err
			}
			return map[string]any{"threadId": t.ID, "url": fmt.Sprintf("%s?discussionId=%d", f.prURL(repo, in.Number), t.ID)}, nil
		})

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
			target := "refs/heads/" + in.Target
			if in.Target == "" {
				r, err := f.repository(ctx, repo)
				if err != nil {
					return nil, err
				}
				target = r.DefaultBranch
			}
			var p pullJSON
			if err := f.send(ctx, http.MethodPost, api(repoPath(repo)+"/pullrequests", nil),
				map[string]any{"sourceRefName": "refs/heads/" + in.Branch, "targetRefName": target, "title": in.Title,
					"description": in.Description, "isDraft": in.Draft}, &p); err != nil {
				return nil, err
			}
			return f.prSummary(repo, p), nil
		})

	tool(server, &mcp.Tool{Name: "list_pull_request_comments", Title: "List a pull request's line comments",
		Description: "The comments on lines of a pull request's diff, thread by thread, oldest first: each one's threadId (to answer " +
			"with reply_to_pull_request_comment), id, author, file, line, body, whether its thread is resolved, and address.",
		Annotations: readOnly, Meta: agents},
		func(ctx context.Context, in numberArgs) (map[string]any, error) {
			repo, err := repoOf(ctx, in.Repo)
			if err != nil {
				return nil, err
			}
			threads, err := f.threads(ctx, repo, in.Number, false)
			if err != nil {
				return nil, err
			}
			list := []any{}
			for _, t := range threads {
				if !t.onALine() {
					continue
				}
				for _, c := range t.Comments {
					if c.IsDeleted || c.CommentType == "system" {
						continue
					}
					list = append(list, map[string]any{"threadId": t.ID, "id": c.ID, "author": c.Author.name(), "path": t.path(),
						"line": t.line(), "body": clipDescription(c.Content), "resolved": t.resolved(), "createdAt": c.PublishedDate,
						"url": fmt.Sprintf("%s?discussionId=%d", f.prURL(repo, in.Number), t.ID)})
				}
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
			threads, err := f.threads(ctx, repo, in.Number, false)
			if err != nil {
				return nil, err
			}
			var to *threadJSON
			for i := range threads {
				if threads[i].ID == in.ThreadID && threads[i].onALine() {
					to = &threads[i]
				}
			}
			if to == nil || len(to.Comments) == 0 {
				return nil, fmt.Errorf("pull request %d has no line comment thread %d", in.Number, in.ThreadID)
			}
			var c threadCommentJSON
			if err := f.send(ctx, http.MethodPost, api(fmt.Sprintf("%s/pullRequests/%d/threads/%d/comments", repoPath(repo), in.Number, to.ID), nil),
				map[string]any{"parentCommentId": to.Comments[0].ID, "content": in.Body, "commentType": "text"}, &c); err != nil {
				return nil, err
			}
			return map[string]any{"threadId": to.ID, "id": c.ID, "url": fmt.Sprintf("%s?discussionId=%d", f.prURL(repo, in.Number), to.ID)}, nil
		})

	// Merge and approve are the person's. They are only on the copy the host runs (person),
	// whose callers are the person's own windows and devices.
	if person {
		person := visibility("app")
		tool(server, &mcp.Tool{Name: "merge_pull_request", Title: "Merge a pull request",
			Description: "Completes a pull request and deletes its branch, as the person whose token it is; squash squashes its " +
				"commits, auto completes it once its policies pass. Only a person may call it.",
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
				strategy := "noFastForward"
				if in.Squash {
					strategy = "squash"
				}
				body := map[string]any{"completionOptions": map[string]any{"mergeStrategy": strategy, "deleteSourceBranch": true}}
				if in.Auto {
					id, err := f.me(ctx, repo)
					if err != nil {
						return nil, err
					}
					p, err := pull(ctx, repo, in.Number)
					if err != nil {
						return nil, err
					}
					if !strings.EqualFold(p.head(), sha) {
						return nil, fmt.Errorf("the pull request has a newer commit than the person saw: read it again")
					}
					body["autoCompleteSetBy"] = map[string]any{"id": id}
				} else {
					// Azure DevOps refuses when the head is not this commit.
					body["status"] = "completed"
					body["lastMergeSourceCommit"] = map[string]any{"commitId": sha}
				}
				if err := f.send(ctx, http.MethodPatch, api(fmt.Sprintf("%s/pullrequests/%d", repoPath(repo), in.Number), nil), body, nil); err != nil {
					return nil, err
				}
				return map[string]any{"merged": !in.Auto, "auto": in.Auto, "number": in.Number}, nil
			})
		tool(server, &mcp.Tool{Name: "approve_pull_request", Title: "Approve a pull request",
			Description: "Approves a pull request at the head commit the person saw, as the person whose token it is: a vote of " +
				"approved. Only a person may call it.",
			Meta: person},
			func(ctx context.Context, in approveArgs) (map[string]any, error) {
				repo, err := repoOf(ctx, in.Repo)
				if err != nil {
					return nil, err
				}
				sha, err := headSha(in.Sha)
				if err != nil {
					return nil, err
				}
				p, err := pull(ctx, repo, in.Number)
				if err != nil {
					return nil, err
				}
				if !strings.EqualFold(p.head(), sha) {
					return nil, fmt.Errorf("the pull request has a newer commit than the person saw: read it again")
				}
				id, err := f.me(ctx, repo)
				if err != nil {
					return nil, err
				}
				if err := f.send(ctx, http.MethodPut, api(fmt.Sprintf("%s/pullrequests/%d/reviewers/%s", repoPath(repo), in.Number, url.PathEscape(id)), nil),
					map[string]any{"vote": 10}, nil); err != nil {
					return nil, err
				}
				return map[string]any{"approved": true, "number": in.Number}, nil
			})
	}
}

func hasLabel(p pullJSON, name string) bool {
	for _, l := range p.labels() {
		if strings.EqualFold(l, name) {
			return true
		}
	}
	return false
}

// voteWords is a reviewer's vote as words.
func voteWords(vote int) string {
	switch {
	case vote >= 10:
		return "approved"
	case vote > 0:
		return "approved with suggestions"
	case vote <= -10:
		return "rejected"
	case vote < 0:
		return "waiting for author"
	}
	return "no vote"
}

func (b buildJSON) sha() string {
	if sha := b.TriggerInfo["pr.sourceSha"]; sha != "" {
		return sha
	}
	return b.SourceVer
}

// newestBuilds are a ref's builds, the newest of each pipeline, by pipeline name.
func (f *RealAzureDevOps) newestBuilds(ctx context.Context, repo, ref string) ([]buildJSON, error) {
	r, err := f.repository(ctx, repo)
	if err != nil {
		return nil, err
	}
	q := url.Values{"repositoryId": {r.ID}, "repositoryType": {"TfsGit"}, "branchName": {ref}, "queryOrder": {"queueTimeDescending"},
		"$top": {strconv.Itoa(perPage)}}
	var list struct {
		Value []buildJSON `json:"value"`
	}
	if err := f.get(ctx, api(projectPath(repo)+"build/builds", q), false, &list); err != nil {
		return nil, err
	}
	seen := map[int]bool{}
	var out []buildJSON
	for _, b := range list.Value {
		if !seen[b.Definition.ID] {
			seen[b.Definition.ID] = true
			out = append(out, b)
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Definition.Name < out[j].Definition.Name })
	return out, nil
}

// combined is builds' state: failed when one failed, pending while one runs, else succeeded;
// "" for none.
func combined(builds []buildJSON) string {
	state := ""
	for _, b := range builds {
		switch {
		case b.Status != "completed":
			if state != "failed" {
				state = "pending"
			}
		case b.Result == "failed" || b.Result == "canceled":
			state = "failed"
		case state == "":
			state = "succeeded"
		}
	}
	return state
}

// buildLog is a build's failed steps and the end of each one's log.
func (f *RealAzureDevOps) buildLog(ctx context.Context, repo string, build int) (map[string]any, error) {
	var timeline struct {
		Records []struct {
			ID       string `json:"id"`
			ParentID string `json:"parentId"`
			Type     string `json:"type"`
			Name     string `json:"name"`
			Result   string `json:"result"`
			Log      *struct {
				ID int `json:"id"`
			} `json:"log"`
			Issues []struct {
				Type    string `json:"type"`
				Message string `json:"message"`
			} `json:"issues"`
		} `json:"records"`
	}
	if err := f.get(ctx, api(fmt.Sprintf("%sbuild/builds/%d/timeline", projectPath(repo), build), nil), false, &timeline); err != nil {
		return nil, err
	}
	names := map[string]string{}
	for _, r := range timeline.Records {
		names[r.ID] = r.Name
	}
	steps := []any{}
	for _, r := range timeline.Records {
		if r.Type != "Task" || r.Result != "failed" {
			continue
		}
		errs := []string{}
		for _, i := range r.Issues {
			if i.Type == "error" {
				errs = append(errs, i.Message)
			}
		}
		step := map[string]any{"name": r.Name, "job": names[r.ParentID], "errors": errs}
		if r.Log != nil {
			text, err := f.do(ctx, http.MethodGet, api(fmt.Sprintf("%sbuild/builds/%d/logs/%d", projectPath(repo), build, r.Log.ID), nil), nil)
			if err != nil {
				return nil, err
			}
			step["log"] = logEnd(logText(text))
		}
		steps = append(steps, step)
	}
	return map[string]any{"repo": repo, "buildId": build, "failedSteps": steps}, nil
}

// logText is a log as text: asked for JSON, Azure DevOps gives its lines as a list.
func logText(body []byte) string {
	var lines struct {
		Value []string `json:"value"`
	}
	if json.Unmarshal(body, &lines) == nil && lines.Value != nil {
		return strings.Join(lines.Value, "\n")
	}
	return string(body)
}

func (f *RealAzureDevOps) prSummary(repo string, p pullJSON) map[string]any {
	state := map[string]string{"active": "open", "completed": "merged", "abandoned": "abandoned"}[p.Status]
	if state == "" {
		state = p.Status
	}
	mergeable := p.MergeStatus == "succeeded"
	return map[string]any{"number": p.ID, "title": p.Title, "branch": branch(p.SourceRefName), "target": branch(p.TargetRefName),
		"author": p.CreatedBy.name(), "draft": p.IsDraft, "state": state, "mergeable": mergeable, "fork": p.fork(),
		"url": f.prURL(repo, p.ID), "createdAt": p.CreationDate}
}
