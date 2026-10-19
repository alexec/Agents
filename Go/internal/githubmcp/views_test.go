package githubmcp

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// The views (#1341) against a fake of GitHub's API, through an MCP client: what each tool
// gives a page, who may call what, and the pages themselves.

const boardAnswer = `{"data":{"viewer":{"login":"alexec"},"repository":{"pullRequests":{"nodes":[
 {"number":7,"title":"Fix the mean","url":"https://github.com/o/r/pull/7","headRefName":"fix-mean","baseRefName":"main",
  "isDraft":false,"updatedAt":"2026-10-18T10:00:00Z","mergeable":"CONFLICTING","reviewDecision":"CHANGES_REQUESTED",
  "author":{"login":"sam","__typename":"User"},"autoMergeRequest":null,
  "commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"nodes":[
   {"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"https://github.com/o/r/actions/runs/99/job/1"},
   {"__typename":"StatusContext","context":"CodeRabbit","state":"SUCCESS","targetUrl":""}]}}}}]}},
 {"number":8,"title":"Docs","url":"https://github.com/o/r/pull/8","headRefName":"docs","baseRefName":"main",
  "isDraft":true,"updatedAt":"2026-10-18T09:00:00Z","mergeable":"MERGEABLE","reviewDecision":null,
  "author":{"login":"alexec","__typename":"User"},"autoMergeRequest":{"enabledAt":"2026-10-18T09:00:00Z"},
  "commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"nodes":[
   {"__typename":"CheckRun","name":"test","status":"IN_PROGRESS","conclusion":null,"detailsUrl":""}]}}}}]}}]}}}}`

const pageAnswer = `{"data":{"viewer":{"login":"alexec"},"repository":{"pullRequest":{
 "number":7,"title":"Fix the mean","url":"https://github.com/o/r/pull/7","headRefName":"fix-mean","baseRefName":"main",
 "state":"OPEN","isDraft":false,"body":"Divide by the count.","createdAt":"2026-10-18T08:00:00Z","additions":3,"deletions":1,
 "mergeable":"MERGEABLE","reviewDecision":"REVIEW_REQUIRED","author":{"login":"sam","__typename":"User"},"autoMergeRequest":null,
 "files":{"totalCount":1,"nodes":[{"path":"average.py","additions":3,"deletions":1,"changeType":"MODIFIED"}]},
 "comments":{"nodes":[{"author":{"login":"coderabbitai","__typename":"Bot"},"body":"<!-- This is an auto-generated comment: summarize by coderabbit.ai -->\n## Walkthrough","createdAt":"2026-10-18T08:05:00Z","url":"u1"}]},
 "reviews":{"nodes":[
  {"author":{"login":"coderabbitai","__typename":"Bot"},"body":"Actionable comments posted: 1","state":"COMMENTED","submittedAt":"2026-10-18T08:06:00Z","url":"u2"},
  {"author":{"login":"kim","__typename":"User"},"body":"","state":"COMMENTED","submittedAt":"2026-10-18T08:07:00Z","url":"u3"}]},
 "reviewThreads":{"nodes":[{"isResolved":false,"isOutdated":false,"path":"average.py","line":6,"originalLine":6,
  "comments":{"nodes":[{"author":{"login":"coderabbitai","__typename":"Bot"},"body":"Return the mean.","createdAt":"2026-10-18T08:06:00Z","url":"u4","databaseId":44}]}}]},
 "commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"nodes":[
  {"__typename":"StatusContext","context":"CodeRabbit","state":"SUCCESS","targetUrl":""}]}}}}]}}}}}`

type viewsAPI struct {
	mu    sync.Mutex
	calls []string
	// posted is each comment posted: its path and words.
	posted []string
}

func (a *viewsAPI) serve(t *testing.T) *httptest.Server {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		a.mu.Lock()
		a.calls = append(a.calls, r.Method+" "+r.URL.Path)
		a.mu.Unlock()
		switch {
		case r.URL.Path == "/graphql" && strings.Contains(string(body), "pullRequests(states: OPEN"):
			io.WriteString(w, boardAnswer)
		case r.URL.Path == "/graphql" && strings.Contains(string(body), "pullRequest(number"):
			io.WriteString(w, pageAnswer)
		case r.URL.Path == "/repos/o/r/issues":
			io.WriteString(w, `[{"number":3,"title":"Mean is off by one","html_url":"https://github.com/o/r/issues/3","user":{"login":"kim"},
			  "labels":[{"name":"bug"}],"assignees":[{"login":"sam"}],"comments":2,"updated_at":"2026-10-18T07:00:00Z"},
			 {"number":7,"title":"a PR","pull_request":{"url":"x"}}]`)
		case r.URL.Path == "/repos/o/r/pulls/7" && r.Method == http.MethodGet:
			io.WriteString(w, `{"node_id":"PR_7","head":{"ref":"fix-mean","repo":{"full_name":"o/r"}}}`)
		case r.URL.Path == "/repos/o/r/pulls/7/merge" && r.Method == http.MethodPut:
			if !strings.Contains(string(body), `"squash"`) {
				t.Errorf("merge: %s", body)
			}
			io.WriteString(w, `{"merged":true}`)
		case r.URL.Path == "/repos/o/r/git/refs/heads/fix-mean" && r.Method == http.MethodDelete:
			w.WriteHeader(http.StatusNoContent)
		case r.Method == http.MethodPost && (r.URL.Path == "/repos/o/r/issues/7/comments" || r.URL.Path == "/repos/o/r/pulls/7/comments/44/replies"):
			var c struct {
				Body string `json:"body"`
			}
			_ = json.Unmarshal(body, &c)
			a.mu.Lock()
			a.posted = append(a.posted, r.URL.Path+" "+c.Body)
			a.mu.Unlock()
			io.WriteString(w, `{"html_url":"https://github.com/o/r/pull/7#c"}`)
		case r.URL.Path == "/repos/o/r/pulls/7/reviews":
			io.WriteString(w, `{"id":1}`)
		case r.URL.Path == "/repos/o/r/pulls/7/files":
			io.WriteString(w, `[{"filename":"average.py","status":"modified","additions":1,"deletions":1,
			  "patch":"@@ -4,3 +4,3 @@ def average(xs):\n     total = sum(xs)\n-    return total / len(xs) - 1\n+    return total / len(xs)\n \n\\ No newline at end of file"},
			 {"filename":"logo.png","status":"added","additions":0,"deletions":0}]`)
		case r.URL.Path == "/repos/o/r/actions/runs/99/jobs":
			io.WriteString(w, `{"jobs":[{"id":5,"name":"test","html_url":"j","conclusion":"failure"},{"id":6,"name":"lint","conclusion":"success"}]}`)
		case r.URL.Path == "/repos/o/r/actions/jobs/5/logs":
			io.WriteString(w, "\x1b[31mline one\x1b[0m\nFAIL: mean\n")
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(s.Close)
	return s
}

func viewsClient(t *testing.T) (*mcp.ClientSession, *viewsAPI) {
	t.Helper()
	api := &viewsAPI{}
	s := api.serve(t)
	gh := NewRealGitHub(s.URL, func() string { return "token" }, func(context.Context) (string, error) { return "o/r", nil })
	server := mcp.NewServer(&mcp.Implementation{Name: "github-mcp", Version: "test"}, nil)
	AddViews(server, gh)
	ct, st := mcp.NewInMemoryTransports()
	ctx := context.Background()
	if _, err := server.Connect(ctx, st, nil); err != nil {
		t.Fatal(err)
	}
	c, err := mcp.NewClient(&mcp.Implementation{Name: "test"}, nil).Connect(ctx, ct, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	return c, api
}

func callTool(t *testing.T, c *mcp.ClientSession, name string, args map[string]any) (*mcp.CallToolResult, map[string]any) {
	t.Helper()
	r, err := c.CallTool(context.Background(), &mcp.CallToolParams{Name: name, Arguments: args})
	if err != nil {
		t.Fatalf("%s: %v", name, err)
	}
	var data map[string]any
	if r.StructuredContent != nil {
		b, _ := json.Marshal(r.StructuredContent)
		json.Unmarshal(b, &data)
	}
	return r, data
}

func TestEachViewHasAToolThatFeedsItAndAPage(t *testing.T) {
	c, _ := viewsClient(t)
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
	want := map[string]string{"show_pull_requests": pullsURI, "show_issues": issuesURI, "show_pull_request": prURI}
	for name, uri := range want {
		if feeds[name] != uri {
			t.Errorf("%s feeds %q, not %s", name, feeds[name], uri)
		}
	}
	// A person merges, reviews and comments from a page: no agent is offered those.
	for _, name := range []string{"merge_pr", "review_pr", "comment_on_pr"} {
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
		if r.Contents[0].MIMEType != viewMime || !strings.HasPrefix(html, "<!doctype html>") ||
			strings.Contains(html, "/*common.css*/") || strings.Contains(html, "/*bridge.js*/") || !strings.Contains(html, "const bridge") {
			t.Errorf("%s is not a whole page", uri)
		}
		if uri != issuesURI && !strings.Contains(html, "const prPage") {
			t.Errorf("%s has no pull request page in it", uri)
		}
	}
}

func TestThePullRequestsListSaysEachOnesState(t *testing.T) {
	c, _ := viewsClient(t)
	_, data := callTool(t, c, "show_pull_requests", map[string]any{})
	prs, _ := data["prs"].([]any)
	if data["repo"] != "o/r" || data["viewer"] != "alexec" || len(prs) != 2 {
		t.Fatalf("board: %v", data)
	}
	first, second := prs[0].(map[string]any), prs[1].(map[string]any)
	if first["checks"] != "failing" || first["failedRunId"] != 99.0 || first["conflicts"] != true ||
		first["review"] != "changes_requested" || first["autoMerge"] != false || first["author"] != "sam" {
		t.Errorf("#7: %v", first)
	}
	if second["checks"] != "running" || second["conflicts"] != false || second["draft"] != true || second["autoMerge"] != true ||
		second["review"] != nil {
		t.Errorf("#8: %v", second)
	}
}

func TestTheIssuesListLeavesOutPullRequests(t *testing.T) {
	c, _ := viewsClient(t)
	_, data := callTool(t, c, "show_issues", map[string]any{"repo": "o/r"})
	issues, _ := data["issues"].([]any)
	if len(issues) != 1 {
		t.Fatalf("issues: %v", data)
	}
	i := issues[0].(map[string]any)
	if i["number"] != 3.0 || i["comments"] != 2.0 || i["assignees"].([]any)[0] != "sam" || i["labels"].([]any)[0] != "bug" {
		t.Errorf("#3: %v", i)
	}
	if r, _ := callTool(t, c, "show_issues", map[string]any{"repo": "not a repo"}); !r.IsError {
		t.Error("a repo that is not owner/name was read")
	}
}

func TestAPullRequestsPageHasItsConversationReviewAndChecks(t *testing.T) {
	c, _ := viewsClient(t)
	_, p := callTool(t, c, "show_pull_request", map[string]any{"number": 7})
	if p["number"] != 7.0 || p["state"] != "open" || p["checks"] != "passing" || p["conflicts"] != false || p["review"] != "review_required" ||
		p["viewer"] != "alexec" || p["filesTotal"] != 1.0 {
		t.Fatalf("page: %v", p)
	}
	// CodeRabbit's review is marked as an app's (its summary is its own block); a review with no words is in its threads.
	comments := p["comments"].([]any)
	if len(comments) != 1 || comments[0].(map[string]any)["bot"] != true || comments[0].(map[string]any)["review"] != "commented" {
		t.Errorf("conversation: %v", comments)
	}
	threads := p["threads"].([]any)
	thread := threads[0].(map[string]any)
	if len(threads) != 1 || thread["path"] != "average.py" || thread["line"] != 6.0 || thread["resolved"] != false {
		t.Errorf("threads: %v", threads)
	}
}

func TestAFailedLogIsItsFailedJobsEndInPlainText(t *testing.T) {
	c, _ := viewsClient(t)
	r, _ := callTool(t, c, "failed_log", map[string]any{"runId": 99})
	text := r.Content[0].(*mcp.TextContent).Text
	if r.IsError || !strings.Contains(text, "== test (j), last 300 lines ==\nline one\nFAIL: mean") || strings.Contains(text, "\x1b") ||
		strings.Contains(text, "lint") {
		t.Errorf("log: %q", text)
	}
}

func TestAPersonsMergeSquashesAndDeletesTheBranch(t *testing.T) {
	c, api := viewsClient(t)
	_, r := callTool(t, c, "merge_pr", map[string]any{"number": 7})
	if r["merged"] != true {
		t.Fatalf("merge: %v", r)
	}
	api.mu.Lock()
	calls := strings.Join(api.calls, "\n")
	api.mu.Unlock()
	if !strings.Contains(calls, "PUT /repos/o/r/pulls/7/merge") || !strings.Contains(calls, "DELETE /repos/o/r/git/refs/heads/fix-mean") {
		t.Errorf("calls: %s", calls)
	}
	if res, _ := callTool(t, c, "review_pr", map[string]any{"number": 7, "event": "request_changes"}); !res.IsError {
		t.Error("changes were requested without saying what")
	}
	if _, rv := callTool(t, c, "review_pr", map[string]any{"number": 7, "event": "approve"}); rv["event"] != "approve" {
		t.Errorf("approve: %v", rv)
	}
}

func TestADiffIsEachFilesHunks(t *testing.T) {
	c, _ := viewsClient(t)
	_, d := callTool(t, c, "show_pull_request_diff", map[string]any{"number": 7})
	files, _ := d["files"].([]any)
	if len(files) != 2 || d["cut"] != false {
		t.Fatalf("diff: %v", d)
	}
	first := files[0].(map[string]any)
	hunks := first["hunks"].([]any)
	h := hunks[0].(map[string]any)
	lines := h["lines"].([]any)
	if len(hunks) != 1 || h["oldStart"] != 4.0 || h["newStart"] != 4.0 || len(lines) != 4 {
		t.Fatalf("hunk: %v", h)
	}
	kinds := []string{}
	for _, l := range lines {
		kinds = append(kinds, l.(map[string]any)["kind"].(string))
	}
	if strings.Join(kinds, " ") != "context removed added context" || lines[2].(map[string]any)["text"] != "    return total / len(xs)" {
		t.Errorf("lines: %v", lines)
	}
	if png := files[1].(map[string]any); len(png["hunks"].([]any)) != 0 || png["note"] == nil {
		t.Errorf("a file with no patch: %v", png)
	}
}
