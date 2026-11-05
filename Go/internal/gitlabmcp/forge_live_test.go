//go:build live

package gitlabmcp

import (
	"context"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"slices"
	"strings"
	"testing"
	"time"
)

// The forge's reads, writes and plans on a real GitLab (#3412), run by hand, never by CI:
//
//	AGENTS_LIVE_GITLAB_TOKEN=$(cat ~/.agents/secrets/gitlab-token) go test -tags live -run Live -v ./internal/gitlabmcp/
//
// AGENTS_LIVE_GITLAB_PROJECT is a test project (agentstest-group/agents-walk when empty) and
// AGENTS_LIVE_GITLAB_URL its GitLab (gitlab.com when empty). The test opens an epic with a task
// under it (GitLab Free's hierarchy), a branch and a merge request, merges it, and closes every
// issue it opened. The merged merge request's number is in the log, for the cost comment's live
// test (agentsd).

func liveGitLab(t *testing.T) (*RealGitLab, string) {
	t.Helper()
	token := os.Getenv("AGENTS_LIVE_GITLAB_TOKEN")
	if token == "" {
		t.Skip("AGENTS_LIVE_GITLAB_TOKEN is not set")
	}
	project := os.Getenv("AGENTS_LIVE_GITLAB_PROJECT")
	if project == "" {
		project = "agentstest-group/agents-walk"
	}
	g := NewRealGitLab(os.Getenv("AGENTS_LIVE_GITLAB_URL"), func() string { return token },
		func(context.Context) (string, error) { return project, nil })
	return g, project
}

func TestLiveGitLabForge(t *testing.T) {
	g, project := liveGitLab(t)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	stamp := time.Now().UTC().Format("2006-01-02 15:04")
	var opened []int
	t.Cleanup(func() {
		for _, n := range opened {
			if err := g.SetState(context.Background(), project, n, false, true); err != nil {
				t.Errorf("close #%d: %v", n, err)
			}
		}
	})

	// The plan (#3265): an epic and a task under it, made with GitLab's own GraphQL (Agents
	// refuses to change a GitLab plan).
	var epic struct {
		ID  int `json:"id"`
		IID int `json:"iid"`
	}
	if err := g.send(ctx, http.MethodPost, fmt.Sprintf("projects/%s/issues", pid(project)),
		map[string]any{"title": "Live #3412: an epic (" + stamp + ")", "labels": "epic"}, &epic); err != nil {
		t.Fatalf("create the epic: %v", err)
	}
	opened = append(opened, epic.IID)
	var types struct {
		Project struct {
			WorkItemTypes struct {
				Nodes []struct{ ID, Name string }
			} `json:"workItemTypes"`
		}
	}
	if err := g.graphql(ctx, `query($path: ID!) { project(fullPath: $path) { workItemTypes { nodes { id name } } } }`,
		map[string]any{"path": project}, &types); err != nil {
		t.Fatalf("the work item types: %v", err)
	}
	task := ""
	for _, n := range types.Project.WorkItemTypes.Nodes {
		if n.Name == "Task" {
			task = n.ID
		}
	}
	var made struct {
		WorkItemCreate struct {
			WorkItem *struct{ IID string } `json:"workItem"`
			Errors   []string
		} `json:"workItemCreate"`
	}
	if err := g.graphql(ctx, `mutation($in: WorkItemCreateInput!) { workItemCreate(input: $in) { workItem { iid } errors } }`,
		map[string]any{"in": map[string]any{"namespacePath": project, "title": "Live #3412: a task (" + stamp + ")",
			"workItemTypeId": task, "hierarchyWidget": map[string]any{"parentId": fmt.Sprintf("gid://gitlab/WorkItem/%d", epic.ID)}}},
		&made); err != nil || made.WorkItemCreate.WorkItem == nil {
		t.Fatalf("create the task: %v %v", err, made.WorkItemCreate.Errors)
	}
	var child int
	fmt.Sscan(made.WorkItemCreate.WorkItem.IID, &child)
	opened = append(opened, child)
	plan, err := g.Plan(ctx, project, epic.IID)
	if err != nil {
		t.Fatalf("plan: %v", err)
	}
	if len(plan.Children) != 1 || plan.Children[0].Number != child || plan.Children[0].Title == "" || plan.Epic.SubTotal != 1 {
		t.Fatalf("the plan = %+v, want the task #%d with its title", plan, child)
	}

	// The writes (#3130) on the epic: a comment, labels, close and reopen.
	if err := g.Comment(ctx, project, epic.IID, false, "<!-- agent -->\nA comment from the forge's live test (#3412)."); err != nil {
		t.Fatalf("comment: %v", err)
	}
	if err := g.SetLabels(ctx, project, epic.IID, false, []string{"live-3412"}, []string{"epic"}); err != nil {
		t.Fatalf("labels: %v", err)
	}
	if err := g.SetState(ctx, project, epic.IID, false, true); err != nil {
		t.Fatalf("close: %v", err)
	}
	if err := g.SetState(ctx, project, epic.IID, false, false); err != nil {
		t.Fatalf("reopen: %v", err)
	}
	if labels, _, err := g.ProjectLabels(ctx, project); err != nil || !slices.Contains(labels, "live-3412") {
		t.Fatalf("the project's labels = %v, %v; want live-3412", labels, err)
	}

	// The reads (#3129): the epic in a list, and its own page with the comment and the task.
	page, err := g.Search(ctx, []string{project}, SearchFilter{Label: "live-3412"}, "", 10)
	if err != nil {
		t.Fatalf("search: %v", err)
	}
	if !slices.ContainsFunc(page.Items, func(i Item) bool { return i.Number == epic.IID }) {
		t.Fatalf("the list found %+v, not #%d", page.Items, epic.IID)
	}
	item, err := g.ItemPage(ctx, project, epic.IID, false, "")
	if err != nil {
		t.Fatalf("the epic's page: %v", err)
	}
	if item.State != "open" || !slices.Contains(item.Labels, "live-3412") || item.SubTotal != 1 ||
		!slices.ContainsFunc(item.Thread, func(c Comment) bool { return strings.Contains(c.Body, "live test (#3412)") }) {
		t.Fatalf("the epic's page = %+v", item)
	}

	// A merge request: a branch with one file, opened, read, its diff, and merged by the
	// project's squash option.
	var sink map[string]any
	branch := "live-3412/" + time.Now().UTC().Format("20060102-150405")
	if err := g.send(ctx, http.MethodPost, fmt.Sprintf("projects/%s/repository/branches?branch=%s&ref=main", pid(project), url.QueryEscape(branch)), map[string]any{}, &sink); err != nil {
		t.Fatalf("the branch: %v", err)
	}
	file := url.PathEscape("live/3412-" + strings.TrimPrefix(branch, "live-3412/") + ".md")
	if err := g.send(ctx, http.MethodPost, fmt.Sprintf("projects/%s/repository/files/%s", pid(project), file), map[string]any{
		"branch": branch, "commit_message": "Live #3412: a file to merge",
		"content": "Written by the forge's live test (#3412) at " + stamp + ".\n"}, &sink); err != nil {
		t.Fatalf("the file: %v", err)
	}
	var mr struct {
		IID int `json:"iid"`
	}
	if err := g.send(ctx, http.MethodPost, fmt.Sprintf("projects/%s/merge_requests", pid(project)), map[string]any{
		"source_branch": branch, "target_branch": "main", "title": "Live #3412: a merge request to merge (" + stamp + ")",
		"description": "Opened and merged by the forge's live test (#3412).", "remove_source_branch": true}, &mr); err != nil {
		t.Fatalf("the merge request: %v", err)
	}
	t.Logf("merge request !%d", mr.IID)
	var detail ItemDetail
	for range 15 {
		if detail, err = g.ItemPage(ctx, project, mr.IID, true, ""); err == nil && detail.Head != "" && detail.Mergeable == "mergeable" {
			break
		}
		time.Sleep(2 * time.Second)
	}
	if err != nil || !detail.MR || detail.Head == "" {
		t.Fatalf("the merge request's page = %+v, %v", detail, err)
	}
	if _, err := g.MRDiff(ctx, project, mr.IID); err != nil {
		t.Fatalf("diff: %v", err)
	}
	methods, err := g.MergeMethods(ctx, project)
	if err != nil || len(methods) == 0 {
		t.Fatalf("merge methods: %v, %v", methods, err)
	}
	if err := g.Merge(ctx, project, mr.IID, detail.Head, methods[0] == "squash", false); err != nil {
		t.Fatalf("merge (the page said %q, checks %q): %v", detail.Mergeable, detail.Checks, err)
	}
	merged, err := g.ItemPage(ctx, project, mr.IID, true, "")
	if err != nil || merged.State != "merged" {
		t.Fatalf("after the merge: %+v, %v", merged.Item, err)
	}
	t.Logf("merged merge request !%d: AGENTS_LIVE_GITLAB_MR=%d", mr.IID, mr.IID)
}

// TestLiveGitLabFailedLog reads the failed jobs' log of the newest failed pipeline, as the Work
// pages' log and Fix failed checks do. gitlab.com runs no job for an account whose identity is
// not verified, so its pipelines fail with no job: the test then says so and skips.
func TestLiveGitLabFailedLog(t *testing.T) {
	g, project := liveGitLab(t)
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	var pipelines []struct {
		ID     int    `json:"id"`
		WebURL string `json:"web_url"`
	}
	if err := g.get(ctx, fmt.Sprintf("projects/%s/pipelines?status=failed&per_page=1", pid(project)), false, &pipelines); err != nil {
		t.Fatalf("the failed pipelines: %v", err)
	}
	if len(pipelines) == 0 {
		t.Skip("the test project has no failed pipeline")
	}
	p := pipelines[0]
	text, err := g.FailedLog(ctx, project, p.ID, "")
	if err != nil {
		t.Fatalf("the log of %s: %v", p.WebURL, err)
	}
	if strings.HasPrefix(text, "No failed jobs") {
		t.Skipf("%s failed with no job (an account whose identity is not verified runs none): %s", p.WebURL, text)
	}
	t.Logf("%s: %d bytes of log", p.WebURL, len(text))
}
