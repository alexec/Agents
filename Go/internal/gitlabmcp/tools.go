package gitlabmcp

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// The gitlab server's tools (#1629), over GitLab's REST API v4 with the same token as the
// events: list and read merge requests, pipelines and issues, and comment on a merge request
// or an issue. Merging is a person's, as on GitHub (#837): merge_merge_request is for a view
// only (#1631), never offered to an agent.

const projectWords = "group/name or a project id; the project this folder pushes to when left out"

type listMRArgs struct {
	Project string `json:"project,omitempty" jsonschema:"group/name or a project id; the project this folder pushes to when left out"`
	State   string `json:"state,omitempty" jsonschema:"opened (when left out), merged, closed or all"`
	Branch  string `json:"branch,omitempty" jsonschema:"only the merge requests from this branch"`
	Label   string `json:"label,omitempty" jsonschema:"only merge requests with this label"`
}

type numberArgs struct {
	Project string `json:"project,omitempty" jsonschema:"group/name or a project id; the project this folder pushes to when left out"`
	Number  int    `json:"number" jsonschema:"the merge request's or issue's number (its iid, as !12 or #12)"`
}

type listPipelinesArgs struct {
	Project string `json:"project,omitempty" jsonschema:"group/name or a project id; the project this folder pushes to when left out"`
	Ref     string `json:"ref,omitempty" jsonschema:"only pipelines of this branch or tag"`
	Status  string `json:"status,omitempty" jsonschema:"only pipelines in this status: running, pending, success, failed, canceled, skipped or manual"`
}

type pipelineArgs struct {
	Project string `json:"project,omitempty" jsonschema:"group/name or a project id; the project this folder pushes to when left out"`
	ID      int    `json:"id" jsonschema:"the pipeline's id (run.id in a checks.failed event)"`
}

type listIssuesArgs struct {
	Project string `json:"project,omitempty" jsonschema:"group/name or a project id; the project this folder pushes to when left out"`
	State   string `json:"state,omitempty" jsonschema:"opened (when left out), closed or all"`
	Label   string `json:"label,omitempty" jsonschema:"only issues with this label"`
}

type commentArgs struct {
	Project string `json:"project,omitempty" jsonschema:"group/name or a project id; the project this folder pushes to when left out"`
	Number  int    `json:"number" jsonschema:"the merge request's or issue's number (its iid)"`
	Body    string `json:"body" jsonschema:"the comment, in Markdown"`
}

type mergeArgs struct {
	Project string `json:"project,omitempty" jsonschema:"group/name or a project id; the project this folder pushes to when left out"`
	Number  int    `json:"number" jsonschema:"the merge request's number (its iid)"`
	Squash  bool   `json:"squash,omitempty" jsonschema:"true: squash its commits into one"`
	Auto    bool   `json:"auto,omitempty" jsonschema:"true: merge once its pipeline succeeds"`
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
	if e, ok := err.(*GitLabError); ok && e.Kind == RateLimited {
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

// AddTools puts the tools on server.
func AddTools(server *mcp.Server, g *RealGitLab) {
	projectOf := func(ctx context.Context, project string) (string, error) {
		if project != "" {
			if !projectPattern.MatchString(project) {
				return "", fmt.Errorf("project is %s", projectWords)
			}
			return project, nil
		}
		return g.DefaultProject(ctx)
	}
	readOnly := &mcp.ToolAnnotations{ReadOnlyHint: true}
	agentsAndViews := visibility("model", "app")

	tool(server, &mcp.Tool{Name: "list_merge_requests", Title: "List merge requests",
		Description: "The project's merge requests, newest updated first, at most 100: number, title, branch, target, author, draft, " +
			"state, whether each conflicts with its target, and its address.",
		Annotations: readOnly, Meta: agentsAndViews},
		func(ctx context.Context, in listMRArgs) (map[string]any, error) {
			project, err := projectOf(ctx, in.Project)
			if err != nil {
				return nil, err
			}
			st := in.State
			switch st {
			case "":
				st = "opened"
			case "opened", "merged", "closed", "all":
			default:
				return nil, fmt.Errorf("state is opened, merged, closed or all")
			}
			path := fmt.Sprintf("projects/%s/merge_requests?state=%s&order_by=updated_at&sort=desc&per_page=100", pid(project), st)
			if in.Branch != "" {
				path += "&source_branch=" + url.QueryEscape(in.Branch)
			}
			if in.Label != "" {
				path += "&labels=" + url.QueryEscape(in.Label)
			}
			var list []mergeRequest
			if err := g.get(ctx, path, false, &list); err != nil {
				return nil, err
			}
			out := make([]any, len(list))
			for i, m := range list {
				out[i] = mrSummary(m)
			}
			return map[string]any{"project": project, "mergeRequests": out}, nil
		})

	tool(server, &mcp.Tool{Name: "get_merge_request", Title: "Read a merge request",
		Description: "One merge request: its description, labels, head commit, its latest pipeline's status, " +
			"and whether it can merge (GitLab's merge status).",
		Annotations: readOnly, Meta: agentsAndViews},
		func(ctx context.Context, in numberArgs) (map[string]any, error) {
			project, err := projectOf(ctx, in.Project)
			if err != nil {
				return nil, err
			}
			var m mergeRequest
			if err := g.get(ctx, fmt.Sprintf("projects/%s/merge_requests/%d", pid(project), in.Number), false, &m); err != nil {
				return nil, err
			}
			r := mrSummary(m)
			labels := m.Labels
			if labels == nil {
				labels = []string{}
			}
			r["description"], r["labels"], r["headSha"], r["mergeStatus"] = clipDescription(m.Description), labels, m.SHA, m.DetailedMergeStatus
			if p := m.HeadPipeline; p != nil {
				r["pipeline"] = map[string]any{"id": p.ID, "status": p.Status, "url": p.WebURL}
			}
			return map[string]any{"project": project, "mergeRequest": r}, nil
		})

	tool(server, &mcp.Tool{Name: "list_pipelines", Title: "List pipelines",
		Description: "The project's pipelines, newest first, at most 50: id, status, ref, commit, what started it, and its address.",
		Annotations: readOnly, Meta: agentsAndViews},
		func(ctx context.Context, in listPipelinesArgs) (map[string]any, error) {
			project, err := projectOf(ctx, in.Project)
			if err != nil {
				return nil, err
			}
			path := fmt.Sprintf("projects/%s/pipelines?order_by=id&sort=desc&per_page=50", pid(project))
			if in.Ref != "" {
				path += "&ref=" + url.QueryEscape(in.Ref)
			}
			if in.Status != "" {
				path += "&status=" + url.QueryEscape(in.Status)
			}
			var list []pipelineJSON
			if err := g.get(ctx, path, false, &list); err != nil {
				return nil, err
			}
			out := make([]any, len(list))
			for i, p := range list {
				out[i] = pipelineSummary(p)
			}
			return map[string]any{"project": project, "pipelines": out}, nil
		})

	tool(server, &mcp.Tool{Name: "get_pipeline", Title: "Read a pipeline",
		Description: "One pipeline and its jobs: each job's name, stage, status, whether it may fail, and its address, where its log is.",
		Annotations: readOnly, Meta: agentsAndViews},
		func(ctx context.Context, in pipelineArgs) (map[string]any, error) {
			project, err := projectOf(ctx, in.Project)
			if err != nil {
				return nil, err
			}
			var p pipelineJSON
			if err := g.get(ctx, fmt.Sprintf("projects/%s/pipelines/%d", pid(project), in.ID), false, &p); err != nil {
				return nil, err
			}
			var jobs []jobJSON
			if err := g.get(ctx, fmt.Sprintf("projects/%s/pipelines/%d/jobs?per_page=100", pid(project), in.ID), false, &jobs); err != nil {
				return nil, err
			}
			r := pipelineSummary(p)
			list := make([]any, len(jobs))
			for i, j := range jobs {
				list[i] = map[string]any{"id": j.ID, "name": j.Name, "stage": j.Stage, "status": j.Status, "allowFailure": j.AllowFailure, "url": j.WebURL}
			}
			r["jobs"] = list
			return map[string]any{"project": project, "pipeline": r}, nil
		})

	tool(server, &mcp.Tool{Name: "list_issues", Title: "List issues",
		Description: "The project's issues, newest updated first, at most 100: number, title, author, labels, assignees, state and address.",
		Annotations: readOnly, Meta: agentsAndViews},
		func(ctx context.Context, in listIssuesArgs) (map[string]any, error) {
			project, err := projectOf(ctx, in.Project)
			if err != nil {
				return nil, err
			}
			st := in.State
			switch st {
			case "":
				st = "opened"
			case "opened", "closed", "all":
			default:
				return nil, fmt.Errorf("state is opened, closed or all")
			}
			path := fmt.Sprintf("projects/%s/issues?state=%s&order_by=updated_at&sort=desc&per_page=100", pid(project), st)
			if in.Label != "" {
				path += "&labels=" + url.QueryEscape(in.Label)
			}
			var list []issueJSON
			if err := g.get(ctx, path, false, &list); err != nil {
				return nil, err
			}
			out := make([]any, len(list))
			for i, is := range list {
				out[i] = issueSummary(is)
			}
			return map[string]any{"project": project, "issues": out}, nil
		})

	tool(server, &mcp.Tool{Name: "get_issue", Title: "Read an issue",
		Description: "One issue, with its description.", Annotations: readOnly, Meta: agentsAndViews},
		func(ctx context.Context, in numberArgs) (map[string]any, error) {
			project, err := projectOf(ctx, in.Project)
			if err != nil {
				return nil, err
			}
			var i issueJSON
			if err := g.get(ctx, fmt.Sprintf("projects/%s/issues/%d", pid(project), in.Number), false, &i); err != nil {
				return nil, err
			}
			r := issueSummary(i)
			r["description"] = clipDescription(i.Description)
			return map[string]any{"project": project, "issue": r}, nil
		})

	comment := func(kind string) func(context.Context, commentArgs) (map[string]any, error) {
		return func(ctx context.Context, in commentArgs) (map[string]any, error) {
			project, err := projectOf(ctx, in.Project)
			if err != nil {
				return nil, err
			}
			if strings.TrimSpace(in.Body) == "" {
				return nil, fmt.Errorf("write the comment first")
			}
			if in.Number <= 0 {
				return nil, fmt.Errorf("number is a positive integer: the iid, as !12 or #12")
			}
			var note noteJSON
			path := fmt.Sprintf("projects/%s/%s/%d/notes", pid(project), kind, in.Number)
			if err := g.send(ctx, http.MethodPost, path, map[string]any{"body": in.Body}, &note); err != nil {
				return nil, err
			}
			return map[string]any{"project": project, "number": in.Number, "commentId": note.ID}, nil
		}
	}
	tool(server, &mcp.Tool{Name: "comment_on_merge_request", Title: "Comment on a merge request",
		Description: "Adds a comment to a merge request, as the person whose token it is.", Meta: agentsAndViews},
		comment("merge_requests"))
	tool(server, &mcp.Tool{Name: "comment_on_issue", Title: "Comment on an issue",
		Description: "Adds a comment to an issue, as the person whose token it is.", Meta: agentsAndViews},
		comment("issues"))

	tool(server, &mcp.Tool{Name: "merge_merge_request", Title: "Merge a merge request",
		Description: "Merges a merge request and deletes its branch on GitLab, as the person whose token it is; squash squashes its " +
			"commits, auto merges once its pipeline succeeds. Only a view may call it: a person merges.",
		Meta: visibility("app")},
		func(ctx context.Context, in mergeArgs) (map[string]any, error) {
			project, err := projectOf(ctx, in.Project)
			if err != nil {
				return nil, err
			}
			body := map[string]any{"squash": in.Squash, "should_remove_source_branch": true}
			if in.Auto {
				// auto_merge since GitLab 17.11; merge_when_pipeline_succeeds before it.
				body["auto_merge"], body["merge_when_pipeline_succeeds"] = true, true
			}
			var m mergeRequest
			path := fmt.Sprintf("projects/%s/merge_requests/%d/merge", pid(project), in.Number)
			if err := g.send(ctx, http.MethodPut, path, body, &m); err != nil {
				return nil, err
			}
			return map[string]any{"project": project, "number": in.Number, "state": m.State, "mergeSha": m.mergeSHA(), "auto": in.Auto}, nil
		})
}

func mrSummary(m mergeRequest) map[string]any {
	r := map[string]any{"number": m.IID, "title": m.Title, "branch": m.SourceBranch, "target": m.TargetBranch,
		"author": m.Author.Username, "draft": m.draft(), "state": m.State, "url": m.WebURL, "updatedAt": m.UpdatedAt,
		"fromFork": m.SourceProjectID != m.TargetProjectID}
	if c := m.conflicts(); c != nil {
		r["conflicts"] = *c
	}
	return r
}

func pipelineSummary(p pipelineJSON) map[string]any {
	return map[string]any{"id": p.ID, "status": p.Status, "ref": p.Ref, "sha": p.SHA, "source": p.Source, "url": p.WebURL,
		"updatedAt": p.UpdatedAt}
}

func issueSummary(i issueJSON) map[string]any {
	r := i.issue().json()
	r["state"], r["updatedAt"] = i.State, i.UpdatedAt
	return r
}
