package gitlabmcp

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"reflect"
	"runtime"
	"strings"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// The views (#1631) over the fake GitLab, through an MCP client: what each tool gives a page,
// who may call what, and the pages themselves.

func viewsClient(t *testing.T, f *fakeGitLab) *mcp.ClientSession {
	t.Helper()
	server := NewServer("test", f.gitlab(), true)
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

func callTool(t *testing.T, c *mcp.ClientSession, name string, args map[string]any) (*mcp.CallToolResult, map[string]any) {
	t.Helper()
	r, err := c.CallTool(context.Background(), &mcp.CallToolParams{Name: name, Arguments: args})
	if err != nil {
		t.Fatalf("%s: %v", name, err)
	}
	if r.IsError {
		t.Fatalf("%s: %v", name, r.Content[0].(*mcp.TextContent).Text)
	}
	var data map[string]any
	if r.StructuredContent != nil {
		b, _ := json.Marshal(r.StructuredContent)
		_ = json.Unmarshal(b, &data)
	}
	return r, data
}

func TestTheListsAskForNewestCreatedFirst(t *testing.T) {
	f := viewsFake(t)
	c := viewsClient(t, f)
	callTool(t, c, "show_merge_requests", map[string]any{})
	callTool(t, c, "show_issues", map[string]any{})

	mergeRequests, issues := "", ""
	for _, request := range f.asked() {
		if strings.Contains(request, "/merge_requests?") {
			mergeRequests = request
		}
		if strings.Contains(request, "/issues?") {
			issues = request
		}
	}
	for label, request := range map[string]string{"merge requests": mergeRequests, "issues": issues} {
		if !strings.Contains(request, "order_by=created_at") || !strings.Contains(request, "sort=desc") || strings.Contains(request, "order_by=updated_at") {
			t.Errorf("%s request: %s", label, request)
		}
	}

	tools, err := c.ListTools(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"show_merge_requests", "show_issues"} {
		found := false
		for _, tool := range tools.Tools {
			if tool.Name == name {
				found = true
				if !strings.Contains(tool.Description, "newest created first") {
					t.Errorf("%s description: %s", name, tool.Description)
				}
			}
		}
		if !found {
			t.Errorf("missing tool %s", name)
		}
	}
	resources, err := c.ListResources(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	for _, title := range []string{"Merge requests", "Issues"} {
		found := false
		for _, resource := range resources.Resources {
			if resource.Title == title {
				found = true
				if !strings.Contains(resource.Description, "newest created first") {
					t.Errorf("%s resource description: %s", title, resource.Description)
				}
			}
		}
		if !found {
			t.Errorf("missing resource %s", title)
		}
	}
}

func viewsFake(t *testing.T) *fakeGitLab {
	f := newFake(t)
	f.addMembers()
	f.mrs = []obj{
		mrJSON(3, "fix-mean", dev, obj{"title": "Fix the mean", "description": "Divide by the count.", "sha": "s3",
			"detailed_merge_status": "not_approved", "head_pipeline": obj{"id": 100, "status": "failed", "web_url": "https://gitlab.test/p/100"},
			"updated_at": at(2)}),
		mrJSON(4, "docs", alex, obj{"draft": true, "sha": "s4", "merge_when_pipeline_succeeds": true, "updated_at": at(1)}),
	}
	f.pipes = []obj{
		{"id": 101, "status": "running", "ref": "docs", "sha": "s4", "web_url": "https://gitlab.test/p/101", "updated_at": at(1)},
		{"id": 100, "status": "failed", "ref": "fix-mean", "sha": "s3", "web_url": "https://gitlab.test/p/100", "updated_at": at(1)},
		{"id": 90, "status": "success", "ref": "fix-mean", "sha": "s3", "web_url": "https://gitlab.test/p/90", "updated_at": at(-10)},
	}
	f.jobs[100] = []obj{{"id": 7, "name": "test", "stage": "test", "status": "failed", "web_url": "https://gitlab.test/j/7"},
		{"id": 8, "name": "lint", "stage": "test", "status": "failed", "allow_failure": true, "web_url": "https://gitlab.test/j/8"},
		{"id": 9, "name": "build", "stage": "build", "status": "success", "web_url": "https://gitlab.test/j/9"}}
	f.traces[7] = "\x1b[0Ksection_start:1700000000:step_script\r\x1b[0K\x1b[31mline one\x1b[0m\nFAIL: mean\n"
	f.diffs[3] = []obj{
		{"old_path": "average.py", "new_path": "average.py", "diff": "@@ -1,3 +1,4 @@\n def mean(xs):\n-    return sum(xs)\n+    n = len(xs)\n+    return sum(xs) / n\n"},
		{"old_path": "logo.png", "new_path": "logo.png", "new_file": true, "diff": ""},
	}
	f.discuss[3] = []obj{
		{"id": "d1", "notes": []obj{{"id": 31, "body": "Looks right.", "author": alex, "created_at": at(1)}}},
		{"id": "d2", "notes": []obj{{"id": 32, "type": "DiffNote", "body": "What if xs is empty?", "author": alex, "created_at": at(2),
			"resolved": false, "position": obj{"new_path": "average.py", "new_line": 3}},
			{"id": 33, "type": "DiffNote", "body": "Then it raises.", "author": dev, "created_at": at(3)}}},
		{"id": "d3", "notes": []obj{{"id": 34, "body": "added 1 commit", "system": true, "author": dev, "created_at": at(0)}}},
	}
	f.issues = []obj{issueObj(5, dev, obj{"description": "## Work\n\n- **Inspect**", "labels": []string{"bug"}, "assignees": []obj{alex}, "user_notes_count": 2})}
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
	for name, uri := range map[string]string{"show_merge_requests": mrsURI, "show_issues": issuesURI, "show_merge_request": mrURI} {
		if feeds[name] != uri {
			t.Errorf("%s feeds %q, not %s", name, feeds[name], uri)
		}
	}
	// A person merges and approves from a page: no agent is offered those.
	for _, name := range []string{"merge_merge_request", "approve_merge_request"} {
		if v := visibility[name]; len(v) != 1 || v[0] != "app" {
			t.Errorf("%s's visibility is %v, not [app]", name, v)
		}
	}
	for _, uri := range []string{mrsURI, issuesURI, mrURI} {
		r, err := c.ReadResource(context.Background(), &mcp.ReadResourceParams{URI: uri})
		if err != nil || len(r.Contents) != 1 {
			t.Fatalf("%s: %v", uri, err)
		}
		html := r.Contents[0].Text
		if r.Contents[0].MIMEType != viewMime || !strings.HasPrefix(html, "<!doctype html>") ||
			strings.Contains(html, "/*common.css*/") || strings.Contains(html, "/*bridge.js*/") || strings.Contains(html, "/*lineage.js*/") || !strings.Contains(html, "const bridge") {
			t.Errorf("%s is not a whole page", uri)
		}
		if uri != issuesURI && !strings.Contains(html, "const mrPage") {
			t.Errorf("%s has no merge request page in it", uri)
		}
		if uri == issuesURI {
			for _, want := range []string{"Add a label filter", "label-tags", "removeLabel", "Promise.all"} {
				if !strings.Contains(html, want) {
					t.Errorf("issues page is missing %q", want)
				}
			}
		}
		// Every tool a page calls is one this server has.
		for _, called := range []string{"show_merge_requests", "show_merge_request", "show_merge_request_diff", "failed_log",
			"retry_pipeline", "comment_on_merge_request", "approve_merge_request", "merge_merge_request", "show_issues", "show_issue_details"} {
			if strings.Contains(html, `"`+called+`"`) && visibility[called] == nil {
				t.Errorf("%s calls %s, which is not a tool", uri, called)
			}
		}
		if strings.Contains(html, "GitHub") || strings.Contains(html, "gh pr") || strings.Contains(html, "CodeRabbit") {
			t.Errorf("%s still speaks of GitHub", uri)
		}
		if uri == issuesURI && (!strings.Contains(html, "aria-expanded") || strings.Contains(html, "Show details")) {
			t.Error("issues page does not expand issue rows without a details button")
		}
	}
}

// The bridge and the styles are the github server's, word for word: one host draws both.
func TestThePagesShareTheGitHubServersBridge(t *testing.T) {
	for _, pair := range [][2]string{{"bridge.js", "bridge.js"}, {"lineage.js", "lineage.js"}, {"common.css", "common.css"}, {"mrpage.css", "prpage.css"}} {
		ours, err := pageFiles.ReadFile("pages/" + pair[0])
		if err != nil {
			t.Fatal(err)
		}
		theirs, err := os.ReadFile("../githubmcp/pages/" + pair[1])
		if err != nil {
			t.Fatal(err)
		}
		if string(ours) != string(theirs) {
			t.Errorf("pages/%s is not the github server's %s: copy it again", pair[0], pair[1])
		}
	}
}

func TestTheMergeRequestsListSaysEachOnesState(t *testing.T) {
	c := viewsClient(t, viewsFake(t))
	_, data := callTool(t, c, "show_merge_requests", map[string]any{})
	mrs, _ := data["mergeRequests"].([]any)
	if data["project"] != project || data["viewer"] != "alex" || len(mrs) != 2 {
		t.Fatalf("board: %v", data)
	}
	first, second := mrs[0].(map[string]any), mrs[1].(map[string]any)
	if first["checks"] != "failing" || first["failedPipelineId"] != 100.0 || first["review"] != "review_required" ||
		first["autoMerge"] != false || first["author"] != "dev" || first["base"] != "main" {
		t.Errorf("!3: %v", first)
	}
	if second["checks"] != "running" || second["draft"] != true || second["autoMerge"] != true || second["review"] != nil {
		t.Errorf("!4: %v", second)
	}
}

// #2952: each merge request is in a section for the viewer; attention counts Needs you, and
// the authors' access is one call, kept for the next list.
func TestTheMergeRequestsListPutsEachInASection(t *testing.T) {
	f := viewsFake(t)
	f.mrs = append(f.mrs,
		mrJSON(6, "outside", stranger, obj{"reviewers": []obj{{"id": 1, "username": "Alex"}}}),
		mrJSON(7, "deps", tokenBot, nil),
		mrJSON(8, "guest", guest, nil),
		mrJSON(9, "mine", alex, obj{"detailed_merge_status": "requested_changes"}))
	c := viewsClient(t, f)
	_, data := callTool(t, c, "show_merge_requests", map[string]any{})
	sections := map[float64]any{}
	for _, m := range data["mergeRequests"].([]any) {
		m := m.(map[string]any)
		sections[m["number"].(float64)] = m["section"]
		if m["number"] == 7.0 && m["authorBot"] != true {
			t.Errorf("!7 is a bot's: %v", m)
		}
		if m["number"] == 9.0 && m["review"] != "changes_requested" {
			t.Errorf("!9's review: %v", m["review"])
		}
	}
	want := map[float64]any{3: sectionTeam, 4: sectionYours, 6: sectionNeedsYou, 7: sectionTeam, 8: sectionOthers, 9: sectionNeedsYou}
	if !reflect.DeepEqual(sections, want) || data["attention"] != 2.0 {
		t.Errorf("sections %v, attention %v", sections, data["attention"])
	}
	callTool(t, c, "show_merge_requests", map[string]any{})
	if f.memberLists != 1 {
		t.Errorf("member listings: %d", f.memberLists)
	}
}

func TestTheIssuesListHasLabelsAndAssignees(t *testing.T) {
	f := viewsFake(t)
	c := viewsClient(t, f)
	_, data := callTool(t, c, "show_issues", map[string]any{"label": "bug"})
	issue := data["issues"].([]any)[0].(map[string]any)
	if issue["number"] != 5.0 || issue["comments"] != 2.0 || issue["assignees"].([]any)[0] != "alex" {
		t.Fatalf("issue %v", issue)
	}
	listed := ""
	for _, request := range f.asked() {
		if strings.Contains(request, "/issues?") {
			listed = request
		}
	}
	if !strings.Contains(listed, "state=opened") || !strings.Contains(listed, "labels=bug") {
		t.Fatalf("asked %s", listed)
	}
}

// #2952: an issue assigned to the viewer needs them; the viewer's own is theirs; a Reporter's
// is the others'.
func TestTheIssuesListPutsEachInASection(t *testing.T) {
	f := viewsFake(t)
	f.issues = append(f.issues, issueObj(6, guest, nil), issueObj(7, alex, nil), issueObj(8, tokenBot, nil), issueObj(9, dev, nil))
	c := viewsClient(t, f)
	_, data := callTool(t, c, "show_issues", map[string]any{})
	sections := map[float64]any{}
	for _, i := range data["issues"].([]any) {
		i := i.(map[string]any)
		sections[i["number"].(float64)] = i["section"]
	}
	want := map[float64]any{5: sectionNeedsYou, 6: sectionOthers, 7: sectionYours, 8: sectionTeam, 9: sectionTeam}
	if !reflect.DeepEqual(sections, want) || data["viewer"] != "alex" || data["attention"] != 1.0 {
		t.Errorf("sections %v, viewer %v, attention %v", sections, data["viewer"], data["attention"])
	}
}

func TestIssueDetailsRenderMarkdownForTheView(t *testing.T) {
	c := viewsClient(t, viewsFake(t))
	_, details := callTool(t, c, "show_issue_details", map[string]any{"number": 5})
	if details["description"] != "## Work\n\n- **Inspect**" || !strings.Contains(details["descriptionHTML"].(string), "<strong>Inspect</strong>") {
		t.Fatalf("issue details: %v", details)
	}
}

func TestAMergeRequestsPageHasItsConversationDiscussionsAndPipeline(t *testing.T) {
	c := viewsClient(t, viewsFake(t))
	_, page := callTool(t, c, "show_merge_request", map[string]any{"number": 3})
	if page["title"] != "Fix the mean" || page["checks"] != "failing" || page["failedPipelineId"] != 100.0 || page["viewer"] != "alex" ||
		page["additions"] != 2.0 || page["deletions"] != 1.0 || page["filesTotal"] != 2.0 || page["state"] != "open" {
		t.Fatalf("page %v", page)
	}
	comments := page["comments"].([]any)
	if len(comments) != 1 || comments[0].(map[string]any)["body"] != "Looks right." {
		t.Fatalf("conversation %v", comments)
	}
	threads := page["threads"].([]any)
	thread := threads[0].(map[string]any)
	if len(threads) != 1 || thread["path"] != "average.py" || thread["line"] != 3.0 || len(thread["comments"].([]any)) != 2 {
		t.Fatalf("threads %v", threads)
	}
	runs := page["checkRuns"].([]any)
	states := []string{}
	for _, r := range runs {
		states = append(states, r.(map[string]any)["state"].(string))
	}
	same(t, states, []string{"failing", "skipped", "passing"})
	files := page["files"].([]any)
	if f := files[1].(map[string]any); f["change"] != "added" {
		t.Fatalf("files %v", files)
	}
}

func TestADiffIsEachFilesHunks(t *testing.T) {
	c := viewsClient(t, viewsFake(t))
	_, diff := callTool(t, c, "show_merge_request_diff", map[string]any{"number": 3})
	files := diff["files"].([]any)
	first := files[0].(map[string]any)
	hunk := first["hunks"].([]any)[0].(map[string]any)
	lines := hunk["lines"].([]any)
	if diff["url"] != "https://gitlab.test/group/app/-/merge_requests/3/diffs" || hunk["oldStart"] != 1.0 || hunk["newStart"] != 1.0 ||
		len(lines) != 4 || lines[1].(map[string]any)["kind"] != "removed" || lines[2].(map[string]any)["kind"] != "added" {
		t.Fatalf("diff %v", diff)
	}
	if second := files[1].(map[string]any); len(second["hunks"].([]any)) != 0 || second["note"] == nil {
		t.Fatalf("a file with no lines: %v", second)
	}
}

func TestAFailedLogIsItsFailedJobsEndInPlainText(t *testing.T) {
	c := viewsClient(t, viewsFake(t))
	r, _ := callTool(t, c, "failed_log", map[string]any{"pipelineId": 100})
	text := r.Content[0].(*mcp.TextContent).Text
	if !strings.Contains(text, "== test (https://gitlab.test/j/7)") || !strings.Contains(text, "line one\nFAIL: mean") ||
		strings.Contains(text, "\x1b") || strings.Contains(text, "section_start") || strings.Contains(text, "lint") {
		t.Fatalf("log %q", text)
	}
}

func TestAPersonsActionsFromThePage(t *testing.T) {
	f := viewsFake(t)
	c := viewsClient(t, f)
	callTool(t, c, "retry_pipeline", map[string]any{"pipelineId": 100})
	_, page := callTool(t, c, "show_merge_request", map[string]any{"number": 3})
	equal(t, page["headSha"], "s3", "the page's head")
	callTool(t, c, "approve_merge_request", map[string]any{"number": 3, "sha": page["headSha"]})
	f.set(func() {
		equal(t, f.posted[0]["path"], "pipelines/100/retry", "retry")
		equal(t, f.posted[1], obj{"path": "merge_requests/3/approve", "sha": "s3"}, "approve")
	})
}

// Approve and Merge act on the commit the page shows: with another head GitLab does nothing,
// and the server says to open the page again; with none, nothing is sent.
func TestApproveAndMergeOnlyAtTheHeadShown(t *testing.T) {
	f := viewsFake(t)
	c := viewsClient(t, f)
	for _, name := range []string{"approve_merge_request", "merge_merge_request"} {
		for _, sha := range []any{"older", nil} {
			args := map[string]any{"number": 3}
			if sha != nil {
				args["sha"] = sha
			}
			r, err := c.CallTool(context.Background(), &mcp.CallToolParams{Name: name, Arguments: args})
			if err != nil {
				t.Fatal(err)
			}
			// With no sha the tool's schema refuses it; with another, GitLab does.
			if !r.IsError || sha != nil && !strings.Contains(r.Content[0].(*mcp.TextContent).Text, "page again") {
				t.Errorf("%s at %v: %v", name, sha, r.Content)
			}
		}
	}
	f.set(func() {
		for _, sent := range f.posted {
			if sent["sha"] != "older" {
				t.Errorf("sent with no sha: %v", sent)
			}
		}
	})
}

// P20261020-3: a merge request's page reads its diff once at a head. Refresh, a comment and
// Show Diff use the parsed diff again; a new head reads it again.
func TestAMergeRequestsDiffIsReadOnceAtAHead(t *testing.T) {
	f := viewsFake(t)
	for i := 0; i < 300; i++ {
		f.diffs[3] = append(f.diffs[3], obj{"old_path": fmt.Sprintf("f%d.go", i), "new_path": fmt.Sprintf("f%d.go", i),
			"diff": "@@ -1,2 +1,2 @@\n-" + strings.Repeat("old ", 200) + "\n+" + strings.Repeat("new ", 200) + "\n"})
	}
	c := viewsClient(t, f)
	diffReads := func() int {
		n := 0
		for _, r := range f.asked() {
			if strings.Contains(r, "/merge_requests/3/diffs") {
				n++
			}
		}
		return n
	}
	callTool(t, c, "show_merge_request", map[string]any{"number": 3})
	first, sent := diffReads(), f.sent
	for range 3 { // Refresh, and after a comment and an approval
		callTool(t, c, "show_merge_request", map[string]any{"number": 3})
	}
	_, diff := callTool(t, c, "show_merge_request_diff", map[string]any{"number": 3})
	if first != 4 || diffReads() != first {
		t.Fatalf("diff pages read: %d at first, %d after Refresh and Show Diff; want 4 and 4", first, diffReads())
	}
	t.Logf("300 files: %d bytes at first, %d after three Refreshes and Show Diff", sent, f.sent-sent)
	if files := diff["files"].([]any); len(files) != 302 || files[2].(map[string]any)["additions"] != 1.0 {
		t.Fatalf("diff %d files", len(files))
	}
	f.set(func() { f.mrs[0]["sha"] = "s3-new" })
	callTool(t, c, "show_merge_request", map[string]any{"number": 3})
	if diffReads() != first+4 {
		t.Fatalf("a new head read %d diff pages, want 4", diffReads()-first)
	}
}

// A copy a session runs itself (not the host's, so not person) has no merge or approve at
// all: no tools/list filter stands between it and the agent.
func TestOnlyTheHostsCopyMergesAndApproves(t *testing.T) {
	f := newFake(t)
	for _, person := range []bool{true, false} {
		server := NewServer("test", f.gitlab(), person)
		ct, st := mcp.NewInMemoryTransports()
		ctx := context.Background()
		if _, err := server.Connect(ctx, st, nil); err != nil {
			t.Fatal(err)
		}
		c, err := mcp.NewClient(&mcp.Implementation{Name: "test"}, nil).Connect(ctx, ct, nil)
		if err != nil {
			t.Fatal(err)
		}
		list, err := c.ListTools(ctx, nil)
		_ = c.Close()
		if err != nil {
			t.Fatal(err)
		}
		has := map[string]bool{}
		for _, tool := range list.Tools {
			has[tool.Name] = true
		}
		for _, name := range []string{"merge_merge_request", "approve_merge_request"} {
			if has[name] != person {
				t.Errorf("person %v: %s listed %v", person, name, has[name])
			}
		}
		if !has["comment_on_merge_request"] {
			t.Errorf("person %v: an agent's tool is missing", person)
		}
	}
}

// P20261020-4: failed_log reads a job's log as it comes and keeps only its end, so a 50 MB
// log is never held whole: the tool gives its last lines.
func TestAFailedLogKeepsOnlyTheEndOfALongLog(t *testing.T) {
	f := viewsFake(t)
	var b strings.Builder
	for i := 0; b.Len() < 50<<20; i++ {
		fmt.Fprintf(&b, "\x1b[32mstep %d of the build, with some words to make it long\x1b[0m\n", i)
	}
	b.WriteString("FAIL: mean\nsection_end:1700000001:step_script\r\x1b[0K\n\n")
	log := b.String()
	f.traces[7] = log
	c := viewsClient(t, f)
	r, _ := callTool(t, c, "failed_log", map[string]any{"pipelineId": 100})
	text := r.Content[0].(*mcp.TextContent).Text
	lines := strings.Split(text[strings.Index(text, "==\n")+3:], "\n")
	if len(lines) != logLines || lines[len(lines)-1] != "FAIL: mean" || strings.Contains(text, "\x1b") ||
		!strings.HasPrefix(lines[0], "step ") {
		t.Fatalf("%d lines, the last %q, the first %q", len(lines), lines[len(lines)-1], lines[0])
	}

	// The read itself, without the HTTP and MCP layers' own, is well under the log's size: the
	// old way allocated 630 MB; this, 0.3 MB (19 MB under -race, the race runtime's own).
	runtime.GC()
	var before, after runtime.MemStats
	runtime.ReadMemStats(&before)
	end, err := traceTail(strings.NewReader(log), logLines)
	runtime.ReadMemStats(&after)
	allocated := after.TotalAlloc - before.TotalAlloc
	t.Logf("a 50 MB log: %d KB allocated", allocated>>10)
	if err != nil || !strings.HasSuffix(end, "FAIL: mean") || allocated > 32<<20 {
		t.Fatalf("a 50 MB log allocated %d KB (err %v)", allocated>>10, err)
	}
}

func TestATraceTailIsTheEndOfTheCleanedLog(t *testing.T) {
	for _, log := range []string{"", "\n", "one", "one\ntwo\n", "one\r\n\x1b[0Ktwo\n\n\n", "a\n\x1b[31m\x1b[0m\nb\n" + strings.Repeat("x\n", 500)} {
		got, err := traceTail(strings.NewReader(log), 3)
		lines := strings.Split(strings.TrimRight(plain(log), "\n"), "\n")
		want := strings.Join(lines[max(0, len(lines)-3):], "\n")
		if err != nil || got != want {
			t.Fatalf("%q: got %q, want %q", log, got, want)
		}
	}
}
