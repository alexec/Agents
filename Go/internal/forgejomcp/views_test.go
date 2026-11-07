package forgejomcp

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// The views (#3838) over the fake Forgejo, through an MCP client: what each tool gives a page,
// who may call what, and the pages themselves.

func viewsClient(t *testing.T, f *fakeForgejo) *mcp.ClientSession {
	t.Helper()
	server := NewServer("test", f.forgejo(nil), true)
	ct, st := mcp.NewInMemoryTransports()
	ctx := context.Background()
	if _, err := server.Connect(ctx, st, nil); err != nil {
		t.Fatal(err)
	}
	c, err := mcp.NewClient(&mcp.Implementation{Name: "test"}, nil).Connect(ctx, ct, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.Close() })
	return c
}

func callTool(t *testing.T, c *mcp.ClientSession, name string, args map[string]any, meta mcp.Meta) map[string]any {
	t.Helper()
	r, err := c.CallTool(context.Background(), &mcp.CallToolParams{Name: name, Arguments: args, Meta: meta})
	if err != nil {
		t.Fatalf("%s: %v", name, err)
	}
	if r.IsError {
		t.Fatalf("%s: %v", name, r.Content[0].(*mcp.TextContent).Text)
	}
	var data map[string]any
	b, _ := json.Marshal(r.StructuredContent)
	_ = json.Unmarshal(b, &data)
	return data
}

func viewsFake(t *testing.T) *fakeForgejo {
	f := newFake(t)
	f.pulls = []obj{
		pull(3, "fix-mean", dev, obj{"title": "Fix the mean", "body": "Divide by the count.", "created_at": at(2), "updated_at": at(5),
			"requested_reviewers": []any{alex}}),
		pull(4, "docs", alex, obj{"title": "WIP: Write the docs", "created_at": at(1), "updated_at": at(6)}),
		pull(6, "theirs", stranger, obj{"created_at": at(0), "updated_at": at(1)}),
	}
	f.statuses["sha3"] = obj{"state": "failure", "sha": "sha3", "statuses": []any{
		obj{"context": "CI / test (pull_request)", "status": "failure", "target_url": "https://forgejo.test/acme/app/actions/runs/12/jobs/0"},
		obj{"context": "CI / lint (pull_request)", "status": "success", "target_url": "https://forgejo.test/acme/app/actions/runs/12/jobs/1"}}}
	f.statuses["sha4"] = obj{"state": "pending", "sha": "sha4", "statuses": []any{
		obj{"context": "woodpecker", "status": "pending", "target_url": "https://ci.test/4"}}}
	f.reviews[3] = []obj{{"id": 40, "user": stranger, "state": "COMMENT", "body": "One question.", "comments_count": 2,
		"submitted_at": at(3), "updated_at": at(3), "html_url": "https://forgejo.test/acme/app/pulls/3#issuecomment-40"}}
	f.lines[40] = []obj{
		{"id": 42, "body": "Then it raises.", "user": dev, "path": "average.py", "position": 3, "created_at": at(4)},
		{"id": 41, "body": "What if xs is empty?", "user": stranger, "path": "average.py", "position": 3, "created_at": at(3)},
	}
	f.reviews[4] = []obj{{"id": 50, "user": dev, "state": "REQUEST_CHANGES", "submitted_at": at(2), "updated_at": at(2)}}
	f.thread[3] = []obj{{"id": 31, "body": "Looks right.", "user": alex, "created_at": at(4), "html_url": "https://forgejo.test/acme/app/pulls/3#issuecomment-31"}}
	f.files[3] = []obj{{"filename": "average.py", "status": "changed", "additions": 2, "deletions": 1},
		{"filename": "logo.png", "status": "added", "additions": 0, "deletions": 0}}
	f.diffs[3] = "diff --git a/average.py b/average.py\nindex 1..2 100644\n--- a/average.py\n+++ b/average.py\n" +
		"@@ -1,2 +1,3 @@\n def mean(xs):\n-    return sum(xs)\n+    n = len(xs)\n+    return sum(xs) / n\n"
	f.issues = []obj{
		issue(5, dev, obj{"title": "The mean is off", "body": "## Work\n\n- **Inspect**", "labels": []any{obj{"name": "bug"}},
			"assignees": []any{alex}, "comments": 2, "created_at": at(3)}),
		issue(7, stranger, obj{"created_at": at(4)}),
		issue(8, alex, obj{"created_at": at(1)}),
	}
	return f
}

func TestEachViewHasAToolThatFeedsItAndAPage(t *testing.T) {
	c := viewsClient(t, viewsFake(t))
	tools, err := c.ListTools(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	visibility := map[string][]any{}
	feeds := map[string]string{}
	for _, tool := range tools.Tools {
		ui, _ := tool.Meta["ui"].(map[string]any)
		visibility[tool.Name], _ = ui["visibility"].([]any)
		if uri, _ := ui["resourceUri"].(string); uri != "" {
			feeds[tool.Name] = uri
			if tool.Annotations == nil || !tool.Annotations.ReadOnlyHint {
				t.Errorf("%s feeds a view but is not read-only, so it can't feed a pin", tool.Name)
			}
		}
	}
	for name, uri := range map[string]string{"show_pull_requests": pullsURI, "show_issues": issuesURI, "show_pull_request": prURI} {
		if feeds[name] != uri {
			t.Errorf("%s feeds %q, not %s", name, feeds[name], uri)
		}
	}
	// A person merges and approves from a page: no agent is offered those.
	for _, name := range []string{"merge_pull_request", "approve_pull_request"} {
		if v := visibility[name]; len(v) != 1 || v[0] != "app" {
			t.Errorf("%s's visibility is %v, not [app]", name, v)
		}
	}
	for _, uri := range []string{pullsURI, issuesURI, prURI} {
		r, err := c.ReadResource(context.Background(), &mcp.ReadResourceParams{URI: uri})
		if err != nil || len(r.Contents) != 1 {
			t.Fatalf("%s: %v", uri, err)
		}
		html := r.Contents[0].Text
		if r.Contents[0].MIMEType != viewMime || !strings.HasPrefix(html, "<!doctype html>") || strings.Contains(html, "/*common.css*/") ||
			strings.Contains(html, "/*bridge.js*/") || strings.Contains(html, "/*lineage.js*/") || !strings.Contains(html, "const bridge") {
			t.Errorf("%s is not a whole page", uri)
		}
		if uri != issuesURI && !strings.Contains(html, "const prPage") {
			t.Errorf("%s has no pull request page in it", uri)
		}
		// Every tool a page calls is one this server has.
		for _, called := range []string{"show_pull_requests", "show_pull_request", "show_pull_request_diff", "failed_log", "retry_pipeline",
			"comment_on_pull_request", "approve_pull_request", "merge_pull_request", "show_issues", "show_issue_details"} {
			if strings.Contains(html, `"`+called+`"`) && visibility[called] == nil {
				t.Errorf("%s calls %s, which is not a tool", uri, called)
			}
		}
		for _, other := range []string{"GitLab", "GitHub", "merge request", "pipeline", "project"} {
			// retry_pipeline is the tool's name, as the gitlab server's.
			if strings.Contains(strings.ReplaceAll(html, `"retry_pipeline"`, ""), other) {
				t.Errorf("%s still speaks of %s", uri, other)
			}
		}
	}
}

// The bridge and the styles are the github server's, word for word: one host draws both.
func TestThePagesShareTheGitHubServersBridge(t *testing.T) {
	for _, name := range []string{"bridge.js", "lineage.js", "common.css", "prpage.css"} {
		ours, err := pageFiles.ReadFile("pages/" + name)
		if err != nil {
			t.Fatal(err)
		}
		theirs, err := os.ReadFile("../githubmcp/pages/" + name)
		if err != nil {
			t.Fatal(err)
		}
		if string(ours) != string(theirs) {
			t.Errorf("pages/%s is not the github server's: copy it again", name)
		}
	}
}

func TestThePullRequestsListSaysEachOnesStateAndSection(t *testing.T) {
	c := viewsClient(t, viewsFake(t))
	data := callTool(t, c, "show_pull_requests", map[string]any{}, nil)
	prs, _ := data["pullRequests"].([]any)
	if data["repo"] != repo || data["viewer"] != "alex" || len(prs) != 3 || data["attention"] != 2.0 {
		t.Fatalf("board: %v", data)
	}
	first, second, third := prs[0].(map[string]any), prs[1].(map[string]any), prs[2].(map[string]any)
	// Newest created first.
	if first["number"] != 3.0 || second["number"] != 4.0 || third["number"] != 6.0 {
		t.Fatalf("order: %v", prs)
	}
	if first["checks"] != "failing" || first["failedRunId"] != 12.0 || first["review"] != "review_required" ||
		first["section"] != "needs_you" || first["author"] != "dev" || first["base"] != "main" || first["branch"] != "fix-mean" {
		t.Errorf("#3: %v", first)
	}
	// The viewer's own, with changes requested: Needs you.
	if second["checks"] != "running" || second["draft"] != true || second["review"] != "changes_requested" || second["section"] != "needs_you" {
		t.Errorf("#4: %v", second)
	}
	if third["checks"] != "none" || third["section"] != "others" {
		t.Errorf("#6: %v", third)
	}
}

func TestTheListsTeamIsTheControlPlanesPeopleWhenTheHostSaysThem(t *testing.T) {
	c := viewsClient(t, viewsFake(t))
	meta := mcp.Meta{"people": []any{map[string]any{"name": "Sam Stranger", "forgejo": "Stranger"}}, "agentOnIssue": map[string]any{"8": "Claude"}}
	prs := callTool(t, c, "show_pull_requests", map[string]any{}, meta)["pullRequests"].([]any)
	if theirs := prs[2].(map[string]any); theirs["section"] != "team" || theirs["authorName"] != "Sam Stranger" {
		t.Errorf("#6: %v", theirs)
	}
	issues := callTool(t, c, "show_issues", map[string]any{}, meta)["issues"].([]any)
	for _, i := range issues {
		i := i.(map[string]any)
		if i["number"] == 8.0 && (i["section"] != "yours" || i["agentOn"] != "Claude") {
			t.Errorf("#8: %v", i)
		}
	}
}

func TestTheIssuesListHasLabelsAssigneesAndSections(t *testing.T) {
	f := viewsFake(t)
	c := viewsClient(t, f)
	data := callTool(t, c, "show_issues", map[string]any{}, nil)
	issues, _ := data["issues"].([]any)
	if data["repo"] != repo || data["viewer"] != "alex" || len(issues) != 3 || data["attention"] != 1.0 {
		t.Fatalf("issues: %v", data)
	}
	sections := map[float64]any{}
	for _, i := range issues {
		i := i.(map[string]any)
		sections[i["number"].(float64)] = i["section"]
	}
	if issues[0].(map[string]any)["number"] != 7.0 || sections[5] != "needs_you" || sections[7] != "others" || sections[8] != "yours" {
		t.Errorf("issues: %v", issues)
	}
	five := issues[1].(map[string]any)
	if five["comments"] != 2.0 || five["labels"].([]any)[0] != "bug" || five["assignees"].([]any)[0] != "alex" {
		t.Errorf("#5: %v", five)
	}
	labelled := callTool(t, c, "show_issues", map[string]any{"label": "bug"}, nil)["issues"].([]any)
	if len(labelled) != 1 {
		t.Errorf("labelled bug: %v", labelled)
	}
	details := callTool(t, c, "show_issue_details", map[string]any{"number": 5}, nil)
	if details["description"] != "## Work\n\n- **Inspect**" || !strings.Contains(details["descriptionHTML"].(string), "<strong>Inspect</strong>") {
		t.Errorf("details: %v", details)
	}
}

func TestAPullRequestsPageHasItsConversationThreadsFilesAndChecks(t *testing.T) {
	c := viewsClient(t, viewsFake(t))
	page := callTool(t, c, "show_pull_request", map[string]any{"number": 3}, nil)
	if page["state"] != "open" || page["headSha"] != "sha3" || page["viewer"] != "alex" || page["squash"] != true ||
		page["additions"] != 2.0 || page["deletions"] != 1.0 || page["failedRunId"] != 12.0 || page["checks"] != "failing" {
		t.Fatalf("page: %v", page)
	}
	comments := page["comments"].([]any)
	if len(comments) != 2 || comments[0].(map[string]any)["body"] != "One question." || comments[1].(map[string]any)["body"] != "Looks right." {
		t.Errorf("conversation, oldest first: %v", comments)
	}
	threads := page["threads"].([]any)
	if len(threads) != 1 {
		t.Fatalf("threads: %v", threads)
	}
	thread := threads[0].(map[string]any)
	in := thread["comments"].([]any)
	if thread["path"] != "average.py" || thread["line"] != 3.0 || len(in) != 2 || in[0].(map[string]any)["body"] != "What if xs is empty?" {
		t.Errorf("thread: %v", thread)
	}
	files := page["files"].([]any)
	if len(files) != 2 || files[1].(map[string]any)["change"] != "added" {
		t.Errorf("files: %v", files)
	}
	runs := page["checkRuns"].([]any)
	if len(runs) != 2 || runs[0].(map[string]any)["state"] != "failing" || runs[0].(map[string]any)["runId"] != 12.0 {
		t.Errorf("checks: %v", runs)
	}
	diff := callTool(t, c, "show_pull_request_diff", map[string]any{"number": 3}, nil)
	if f := diff["files"].([]any); len(f) != 1 || len(f[0].(map[string]any)["hunks"].([]any)) != 1 {
		t.Errorf("diff: %v", diff)
	}
}

func TestOnlyTheHostsCopyMergesAndApproves(t *testing.T) {
	f := viewsFake(t)
	server := NewServer("test", f.forgejo(nil), false)
	ct, st := mcp.NewInMemoryTransports()
	if _, err := server.Connect(context.Background(), st, nil); err != nil {
		t.Fatal(err)
	}
	c, err := mcp.NewClient(&mcp.Implementation{Name: "test"}, nil).Connect(context.Background(), ct, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	tools, err := c.ListTools(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	shows := 0
	for _, tool := range tools.Tools {
		if tool.Name == "merge_pull_request" || tool.Name == "approve_pull_request" {
			t.Errorf("an agent's copy has %s", tool.Name)
		}
		if strings.HasPrefix(tool.Name, "show_") {
			shows++
		}
	}
	// The pages are on every copy: an agent shows them to the person.
	if shows != 5 {
		t.Errorf("%d show_ tools", shows)
	}
}
