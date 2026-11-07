package bitbucketmcp

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// The views (#3866) over the fake Bitbucket, through an MCP client: what each tool gives a page,
// who may call what, and the pages themselves.

func viewsClient(t *testing.T, f *fakeBitbucket) *mcp.ClientSession {
	t.Helper()
	server := NewServer("test", f.bitbucket(), true)
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

func viewsFake(t *testing.T) *fakeBitbucket {
	f := newFake(t)
	f.pulls = []obj{
		pull(3, "fix-mean", dev, obj{"title": "Fix the mean", "description": "Divide by the count.", "created_on": at(2), "updated_on": at(5),
			"reviewers": []any{alex}}),
		pull(4, "docs", alex, obj{"title": "Write the docs", "draft": true, "created_on": at(1), "updated_on": at(6),
			"participants": []any{obj{"user": dev, "role": "REVIEWER", "state": "changes_requested"}}}),
		pull(6, "theirs", stranger, obj{"created_on": at(0), "updated_on": at(1)}),
	}
	f.statuses["sha3"] = []obj{
		{"key": "test", "name": "Pipeline #12 for fix-mean", "state": "FAILED", "url": "https://bitbucket.org/acme/app/pipelines/results/12"},
		{"key": "lint", "state": "SUCCESSFUL", "url": "https://bitbucket.org/acme/app/pipelines/results/11"}}
	f.statuses["sha4"] = []obj{{"key": "jenkins", "state": "INPROGRESS", "url": "https://ci.test/4"}}
	f.diffstat[3] = []obj{{"status": "modified", "lines_added": 2, "lines_removed": 1, "new": obj{"path": "average.py"}, "old": obj{"path": "average.py"}},
		{"status": "added", "lines_added": 0, "lines_removed": 0, "new": obj{"path": "logo.png"}}}
	f.diffstat[4] = []obj{{"status": "merge conflict", "lines_added": 1, "lines_removed": 1, "new": obj{"path": "README.md"}}}
	line := obj{"path": "average.py", "to": 3}
	f.prComments[3] = []obj{
		comment(31, alex, "Looks right.", at(4), nil),
		comment(41, stranger, "What if xs is empty?", at(3), obj{"inline": line}),
		comment(42, dev, "Then it raises.", at(4), obj{"inline": line, "parent": obj{"id": 41}}),
		comment(43, dev, "Thanks.", at(5), obj{"parent": obj{"id": 31}}),
		comment(44, dev, "", at(5), obj{"deleted": true}),
	}
	f.defaultMerge = "squash"
	f.diffs[3] = "diff --git a/average.py b/average.py\nindex 1..2 100644\n--- a/average.py\n+++ b/average.py\n" +
		"@@ -1,2 +1,3 @@\n def mean(xs):\n-    return sum(xs)\n+    n = len(xs)\n+    return sum(xs) / n\n"
	f.issues = []obj{
		issue(5, dev, obj{"title": "The mean is off", "content": obj{"raw": "## Work\n\n- **Inspect**"}, "assignee": alex,
			"component": obj{"name": "maths"}, "created_on": at(3)}),
		issue(7, stranger, obj{"kind": "task", "created_on": at(4)}),
		issue(8, alex, obj{"kind": "task", "created_on": at(1)}),
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
		for _, other := range []string{"GitLab", "GitHub", "Forgejo", "merge request", "project"} {
			if strings.Contains(html, other) {
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
	if first["checks"] != "failing" || first["failedRunId"] != 12.0 || first["review"] != "review_required" || first["conflicts"] != false ||
		first["section"] != "needs_you" || first["author"] != "dev" || first["base"] != "main" || first["branch"] != "fix-mean" {
		t.Errorf("#3: %v", first)
	}
	// The viewer's own, in conflict and with changes requested: Needs you.
	if second["checks"] != "running" || second["draft"] != true || second["review"] != "changes_requested" || second["conflicts"] != true ||
		second["section"] != "needs_you" {
		t.Errorf("#4: %v", second)
	}
	if third["checks"] != "none" || third["section"] != "others" {
		t.Errorf("#6: %v", third)
	}
}

// A reviewer who approved is not asked any more, and a person with write access is Team.
func TestAnApprovedReviewIsNotNeedsYou(t *testing.T) {
	f := viewsFake(t)
	f.pulls[0]["participants"] = []any{obj{"user": alex, "role": "REVIEWER", "approved": true, "state": "approved"}}
	c := viewsClient(t, f)
	first := callTool(t, c, "show_pull_requests", map[string]any{}, nil)["pullRequests"].([]any)[0].(map[string]any)
	if first["section"] != "team" || first["review"] != "approved" {
		t.Errorf("#3: %v", first)
	}
}

func TestTheListsTeamIsTheControlPlanesPeopleWhenTheHostSaysThem(t *testing.T) {
	c := viewsClient(t, viewsFake(t))
	meta := mcp.Meta{"people": []any{map[string]any{"name": "Sam Stranger", "bitbucket": "Stranger"}}, "agentOnIssue": map[string]any{"8": "Claude"}}
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
	if labels := five["labels"].([]any); len(labels) != 2 || labels[0] != "bug" || labels[1] != "maths" || five["assignees"].([]any)[0] != "alex" {
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
	if page["state"] != "open" || page["headSha"] != "sha3" || page["viewer"] != "alex" || page["squash"] != true || page["conflicts"] != false ||
		page["additions"] != 2.0 || page["deletions"] != 1.0 || page["failedRunId"] != 12.0 || page["checks"] != "failing" {
		t.Fatalf("page: %v", page)
	}
	comments := page["comments"].([]any)
	// The answer to a comment that is not on a line is in the conversation; a deleted one is not.
	if len(comments) != 2 || comments[0].(map[string]any)["body"] != "Looks right." || comments[1].(map[string]any)["body"] != "Thanks." {
		t.Errorf("conversation, oldest first: %v", comments)
	}
	threads := page["threads"].([]any)
	if len(threads) != 1 {
		t.Fatalf("threads: %v", threads)
	}
	thread := threads[0].(map[string]any)
	in := thread["comments"].([]any)
	if thread["path"] != "average.py" || thread["line"] != 3.0 || len(in) != 2 || in[0].(map[string]any)["body"] != "What if xs is empty?" ||
		in[1].(map[string]any)["body"] != "Then it raises." || thread["resolved"] != false {
		t.Errorf("thread: %v", thread)
	}
	files := page["files"].([]any)
	if len(files) != 2 || files[0].(map[string]any)["path"] != "average.py" || files[1].(map[string]any)["change"] != "added" {
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
	server := NewServer("test", f.bitbucket(), false)
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
