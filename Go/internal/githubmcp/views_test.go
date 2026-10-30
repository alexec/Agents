package githubmcp

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
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
 "number":7,"title":"Fix the mean","url":"https://github.com/o/r/pull/7","headRefName":"fix-mean","headRefOid":"c0ffee","baseRefName":"main",
 "state":"OPEN","isDraft":false,"body":"Divide by the count.","createdAt":"2026-10-18T08:00:00Z","additions":3,"deletions":1,
 "mergeable":"MERGEABLE","reviewDecision":"REVIEW_REQUIRED","author":{"login":"sam","__typename":"User"},"autoMergeRequest":null,
 "files":{"totalCount":1,"nodes":[{"path":"average.py","additions":3,"deletions":1,"changeType":"MODIFIED"}]},
 "comments":{"nodes":[{"author":{"login":"coderabbitai","__typename":"Bot"},"body":"<!-- This is an auto-generated comment: summarize by coderabbit.ai -->\n## Walkthrough","createdAt":"2026-10-18T08:05:00Z","url":"u1"}]},
 "reviews":{"nodes":[
  {"author":{"login":"coderabbitai","__typename":"Bot"},"body":"Actionable comments posted: 1","state":"COMMENTED","submittedAt":"2026-10-18T08:06:00Z","url":"u2"},
  {"author":{"login":"kim","__typename":"User"},"body":"","state":"COMMENTED","submittedAt":"2026-10-18T08:07:00Z","url":"u3"},
  {"author":{"login":"coderabbitai","__typename":"Bot"},"body":"","state":"COMMENTED","submittedAt":"2026-10-18T08:09:00Z","url":"u5"}]},
 "reviewThreads":{"nodes":[{"isResolved":false,"isOutdated":false,"path":"average.py","line":6,"originalLine":6,
  "comments":{"nodes":[{"author":{"login":"coderabbitai","__typename":"Bot"},"body":"Return the mean.","createdAt":"2026-10-18T08:06:00Z","url":"u4","databaseId":44}]}}]},
 "commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"nodes":[
  {"__typename":"StatusContext","context":"CodeRabbit","state":"SUCCESS","targetUrl":""}]}}}}]}}}}}`

type viewsAPI struct {
	mu    sync.Mutex
	calls []string
	// posted is each comment posted: its path and words.
	posted []string
	// sent is each write's method, path and body.
	sent []string
	// queries records each GET's raw query and each GraphQL request body.
	queries []string
}

func (a *viewsAPI) sentText() string {
	a.mu.Lock()
	defer a.mu.Unlock()
	return strings.Join(a.sent, "\n")
}

func (a *viewsAPI) serve(t *testing.T) *httptest.Server {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		a.mu.Lock()
		a.calls = append(a.calls, r.Method+" "+r.URL.Path)
		if r.Method == http.MethodGet {
			a.queries = append(a.queries, r.URL.RawQuery)
		} else if r.URL.Path == "/graphql" {
			a.queries = append(a.queries, string(body))
		}
		if r.Method != http.MethodGet && !strings.HasPrefix(string(body), `{"query":"query`) {
			a.sent = append(a.sent, r.Method+" "+r.URL.Path+" "+string(body))
		}
		a.mu.Unlock()
		switch {
		case r.URL.Path == "/graphql" && strings.Contains(string(body), "pullRequests(states: OPEN"):
			io.WriteString(w, boardAnswer)
		case r.URL.Path == "/graphql" && strings.Contains(string(body), "enablePullRequestAutoMerge"):
			io.WriteString(w, `{"data":{"enablePullRequestAutoMerge":{"pullRequest":{"number":7}}}}`)
		case r.URL.Path == "/graphql" && strings.Contains(string(body), "pullRequest(number"):
			io.WriteString(w, pageAnswer)
		case r.URL.Path == "/repos/o/r/issues":
			io.WriteString(w, `[{"number":3,"title":"Mean is off by one","html_url":"https://github.com/o/r/issues/3","user":{"login":"kim"},
			  "labels":[{"name":"bug","color":"D73A4A"},{"name":"odd","color":"red"}],"assignees":[{"login":"sam"}],"comments":2,"updated_at":"2026-10-18T07:00:00Z",
			  "milestone":{"title":"0.13 Lineage and value"}},
			 {"number":4,"title":"No milestone yet","html_url":"https://github.com/o/r/issues/4","user":{"login":"kim"},
			  "labels":[],"assignees":[],"comments":0,"updated_at":"2026-10-18T07:00:00Z"},
			 {"number":7,"title":"a PR","pull_request":{"url":"x"}}]`)
		case r.URL.Path == "/search/issues":
			io.WriteString(w, `{"total_count":2,"items":[{"number":9,"title":"Old mean bug","html_url":"https://github.com/o/r/issues/9",
			  "user":{"login":"kim"},"labels":[{"name":"bug","color":"d73a4a"}],"assignees":[]},
			 {"number":3,"title":"Mean is off by one","html_url":"https://github.com/o/r/issues/3","user":{"login":"kim"},"labels":[]}]}`)
		case r.URL.Path == "/repos/o/r/issues/3":
			io.WriteString(w, `{"number":3,"title":"Mean is off by one","state":"open","html_url":"https://github.com/o/r/issues/3",
			  "user":{"login":"kim"},"labels":[{"name":"bug","color":"d73a4a"}]}`)
		case r.URL.Path == "/repos/o/r/issues/7":
			io.WriteString(w, `{"number":7,"title":"a PR","state":"open","pull_request":{"url":"x"}}`)
		case r.URL.Path == "/repos/o/r/pulls/7" && r.Method == http.MethodGet:
			io.WriteString(w, `{"node_id":"PR_7","head":{"ref":"fix-mean","sha":"c0ffee","repo":{"full_name":"o/r"}}}`)
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

func TestTheListsAskForNewestCreatedFirst(t *testing.T) {
	c, api := viewsClient(t)
	callTool(t, c, "show_pull_requests", map[string]any{})
	callTool(t, c, "show_issues", map[string]any{"repo": "o/r"})

	api.mu.Lock()
	queries := append([]string(nil), api.queries...)
	api.mu.Unlock()
	board, issues := "", ""
	for _, q := range queries {
		if strings.Contains(q, `"query":"query`) && strings.Contains(q, "pullRequests(states: OPEN") {
			board = q
		}
		if strings.Contains(q, "sort=created") {
			issues = q
		}
	}
	if !strings.Contains(board, "orderBy: {field: CREATED_AT, direction: DESC}") || strings.Contains(board, "UPDATED_AT") {
		t.Errorf("board query: %s", board)
	}
	if !strings.Contains(issues, "sort=created") || !strings.Contains(issues, "direction=desc") || strings.Contains(issues, "sort=updated") {
		t.Errorf("issues query: %s", issues)
	}

	tools, err := c.ListTools(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"show_pull_requests", "show_issues"} {
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
	for _, title := range []string{"Pull requests", "Issues"} {
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

func viewsClient(t *testing.T) (*mcp.ClientSession, *viewsAPI) {
	return viewsClientAs(t, true)
}

// viewsClientAs is a client of a server with the person's tools (the host's copy) or not.
func viewsClientAs(t *testing.T, person bool) (*mcp.ClientSession, *viewsAPI) {
	t.Helper()
	api := &viewsAPI{}
	s := api.serve(t)
	gh := NewRealGitHub(s.URL, func() string { return "token" }, func(context.Context) (string, error) { return "o/r", nil },
		func(_ context.Context, owner, repo string, number int) (map[string]any, error) {
			if owner != "o" || repo != "r" || number != 3 {
				return nil, fmt.Errorf("unexpected issue lookup: %s/%s#%d", owner, repo, number)
			}
			return map[string]any{"number": 3, "body": "A description", "closed_by_pull_requests": map[string]any{
				"total_count": 1, "references": []any{map[string]any{"number": 7, "title": "Fix the mean", "state": "MERGED",
					"url": "https://github.com/o/r/pull/7", "repository": "o/r"}},
			}}, nil
		})
	server := mcp.NewServer(&mcp.Implementation{Name: "github-mcp", Version: "test"}, nil)
	AddViews(server, gh, person)
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

// A copy that the host does not run (a session's own) has no merge, review or comment.
func TestOnlyTheHostsCopyHasThePersonsTools(t *testing.T) {
	for _, person := range []bool{true, false} {
		c, _ := viewsClientAs(t, person)
		tools, err := c.ListTools(context.Background(), nil)
		if err != nil {
			t.Fatal(err)
		}
		names := map[string]bool{}
		for _, tool := range tools.Tools {
			names[tool.Name] = true
		}
		for _, name := range []string{"merge_pr", "review_pr", "comment_on_pr"} {
			if names[name] != person {
				t.Errorf("person %v: %s listed %v", person, name, names[name])
			}
		}
		if !names["show_pull_request"] {
			t.Errorf("person %v: no show_pull_request", person)
		}
	}
}

func TestEachViewHasAToolThatFeedsItAndAPage(t *testing.T) {
	c, _ := viewsClient(t)
	tools, err := c.ListTools(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	visibility := map[string][]any{}
	feeds := map[string]string{}
	detailsReadOnly := false
	for _, tool := range tools.Tools {
		ui, _ := tool.Meta["ui"].(map[string]any)
		visibility[tool.Name], _ = ui["visibility"].([]any)
		if uri, _ := ui["resourceUri"].(string); uri != "" {
			feeds[tool.Name] = uri
			if tool.Annotations == nil || !tool.Annotations.ReadOnlyHint {
				t.Errorf("%s feeds a view but is not read-only, so it can't feed a pin", tool.Name)
			}
		}
		if tool.Name == "show_issue_details" {
			detailsReadOnly = tool.Annotations != nil && tool.Annotations.ReadOnlyHint
		}
	}
	want := map[string]string{"show_pull_requests": pullsURI, "show_issues": issuesURI, "show_pull_request": prURI}
	for name, uri := range want {
		if feeds[name] != uri {
			t.Errorf("%s feeds %q, not %s", name, feeds[name], uri)
		}
	}
	if v := visibility["show_issue_details"]; !detailsReadOnly || len(v) != 2 || v[0] != "model" || v[1] != "app" {
		t.Errorf("show_issue_details must be read-only and visible to the issue view and agent; visibility=%v", v)
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
			strings.Contains(html, "/*common.css*/") || strings.Contains(html, "/*bridge.js*/") || strings.Contains(html, "/*lineage.js*/") || !strings.Contains(html, "const bridge") {
			t.Errorf("%s is not a whole page", uri)
		}
		if uri != issuesURI && !strings.Contains(html, "const prPage") {
			t.Errorf("%s has no pull request page in it", uri)
		}
		if uri == issuesURI {
			for _, want := range []string{"show_issue_details", "closed_by_pull_requests", "milestone", "aria-expanded", "issue-row",
				"Add a label filter", "label-tags", "removeLabel", "Search issues", "labelColors", "query", "No open issues match"} {
				if !strings.Contains(html, want) {
					t.Errorf("issues page is missing %q", want)
				}
			}
			if strings.Contains(html, "Show details") || strings.Contains(html, "Hide details") {
				t.Error("issues page still has a details button")
			}
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
	if len(issues) != 2 {
		t.Fatalf("issues: %v", data)
	}
	i := issues[0].(map[string]any)
	if i["number"] != 3.0 || i["comments"] != 2.0 || i["assignees"].([]any)[0] != "sam" || i["labels"].([]any)[0] != "bug" ||
		i["milestone"] != "0.13 Lineage and value" {
		t.Errorf("#3: %v", i)
	}
	if second := issues[1].(map[string]any); second["number"] != 4.0 {
		t.Errorf("#4: %v", second)
	} else if _, ok := second["milestone"]; ok {
		t.Errorf("#4 should have no milestone: %v", second)
	}
	if r, _ := callTool(t, c, "show_issues", map[string]any{"repo": "not a repo"}); !r.IsError {
		t.Error("a repo that is not owner/name was read")
	}
	// Each label's colour (#2686), and none for a colour that is not 6-digit hex.
	if colors, _ := data["labelColors"].(map[string]any); colors["bug"] != "#d73a4a" || colors["odd"] != nil {
		t.Errorf("labelColors: %v", data["labelColors"])
	}
}

func TestTheIssuesListTakesAllItsLabelsInOneCall(t *testing.T) {
	c, api := viewsClient(t)
	callTool(t, c, "show_issues", map[string]any{"repo": "o/r", "label": "bug", "labels": []string{"ui", "bug"}})
	api.mu.Lock()
	defer api.mu.Unlock()
	if len(api.queries) != 1 || !strings.Contains(api.queries[0], "labels="+url.QueryEscape("ui,bug")+"&") {
		t.Errorf("queries: %v", api.queries)
	}
}

func TestTheIssuesSearchIsOneGitHubSearch(t *testing.T) {
	c, api := viewsClient(t)
	_, data := callTool(t, c, "show_issues", map[string]any{"repo": "o/r", "query": " mean ", "labels": []string{"bug", "good first"}})
	issues, _ := data["issues"].([]any)
	if len(issues) != 2 || issues[0].(map[string]any)["number"] != 9.0 {
		t.Fatalf("issues: %v", data)
	}
	if colors, _ := data["labelColors"].(map[string]any); colors["bug"] != "#d73a4a" {
		t.Errorf("labelColors: %v", data["labelColors"])
	}
	api.mu.Lock()
	q, _ := url.ParseQuery(api.queries[0])
	api.mu.Unlock()
	if q.Get("q") != `repo:o/r is:issue is:open mean label:"bug" label:"good first"` || q.Get("sort") != "created" || q.Get("order") != "desc" {
		t.Errorf("search: %v", q)
	}
}

func TestTheIssuesSearchFindsANumber(t *testing.T) {
	c, _ := viewsClient(t)
	_, data := callTool(t, c, "show_issues", map[string]any{"repo": "o/r", "query": "#3"})
	issues, _ := data["issues"].([]any)
	// #3 first, from its own read, and not twice; then the search's other one.
	if len(issues) != 2 || issues[0].(map[string]any)["number"] != 3.0 || issues[1].(map[string]any)["number"] != 9.0 {
		t.Fatalf("issues: %v", issues)
	}
	// A pull request's number is not an issue.
	_, data = callTool(t, c, "show_issues", map[string]any{"repo": "o/r", "query": "7"})
	if issues, _ := data["issues"].([]any); len(issues) != 2 || issues[0].(map[string]any)["number"] != 9.0 {
		t.Fatalf("issues for 7: %v", issues)
	}
	// With a label it does not have, the number finds nothing of its own.
	_, data = callTool(t, c, "show_issues", map[string]any{"repo": "o/r", "query": "3", "labels": []string{"ui"}})
	if issues, _ := data["issues"].([]any); len(issues) != 2 || issues[0].(map[string]any)["number"] != 9.0 {
		t.Fatalf("issues for 3 with ui: %v", issues)
	}
}

func TestIssueDetailsUseIssueReadAndShowClosingPullRequests(t *testing.T) {
	c, _ := viewsClient(t)
	r, data := callTool(t, c, "show_issue_details", map[string]any{"repo": "o/r", "number": 3})
	if r.IsError || data["body"] != "A description" || !strings.Contains(data["bodyHTML"].(string), "A description") {
		t.Fatalf("issue details: %v", data)
	}
	closing, ok := data["closed_by_pull_requests"].(map[string]any)
	if !ok || closing["total_count"] != 1.0 {
		t.Fatalf("closing pull requests: %v", data["closed_by_pull_requests"])
	}
	refs, ok := closing["references"].([]any)
	if !ok || len(refs) != 1 || refs[0].(map[string]any)["url"] != "https://github.com/o/r/pull/7" {
		t.Fatalf("linked pull requests: %v", closing["references"])
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
	_, r := callTool(t, c, "merge_pr", map[string]any{"number": 7, "sha": "c0ffee"})
	if r["merged"] != true {
		t.Fatalf("merge: %v", r)
	}
	api.mu.Lock()
	calls := strings.Join(api.calls, "\n")
	api.mu.Unlock()
	if !strings.Contains(calls, "PUT /repos/o/r/pulls/7/merge") || !strings.Contains(calls, "DELETE /repos/o/r/git/refs/heads/fix-mean") {
		t.Errorf("calls: %s", calls)
	}
	if res, _ := callTool(t, c, "review_pr", map[string]any{"number": 7, "event": "request_changes", "sha": "c0ffee"}); !res.IsError {
		t.Error("changes were requested without saying what")
	}
	if _, rv := callTool(t, c, "review_pr", map[string]any{"number": 7, "event": "approve", "sha": "c0ffee"}); rv["event"] != "approve" {
		t.Errorf("approve: %v", rv)
	}
	sent := api.sentText()
	if !strings.Contains(sent, `"sha":"c0ffee"`) || !strings.Contains(sent, `"commit_id":"c0ffee"`) {
		t.Errorf("sent: %s", sent)
	}
}

// A person's merge, auto-merge, review and diff are of the head commit the page showed: with
// none, or when the pull request has a newer one, GitHub is asked nothing.
func TestAPersonActsOnTheCommitThePageShows(t *testing.T) {
	c, api := viewsClient(t)
	if _, p := callTool(t, c, "show_pull_request", map[string]any{"number": 7}); p["headSha"] != "c0ffee" {
		t.Fatalf("page: %v", p)
	}
	for _, sha := range []string{"", "newer"} {
		for _, call := range []struct {
			tool string
			args map[string]any
		}{
			{"merge_pr", map[string]any{"number": 7}},
			{"merge_pr", map[string]any{"number": 7, "auto": true}},
			{"review_pr", map[string]any{"number": 7, "event": "approve"}},
		} {
			if sha != "" {
				call.args["sha"] = sha
			}
			if r, _ := callTool(t, c, call.tool, call.args); !r.IsError {
				t.Errorf("%s %v with sha %q was not refused", call.tool, call.args, sha)
			}
		}
	}
	if sent := api.sentText(); sent != "" {
		t.Fatalf("GitHub was asked: %s", sent)
	}
	if r, _ := callTool(t, c, "show_pull_request_diff", map[string]any{"number": 7, "sha": "newer"}); !r.IsError {
		t.Error("a diff of another commit was shown")
	}
	if _, d := callTool(t, c, "show_pull_request_diff", map[string]any{"number": 7, "sha": "c0ffee"}); d["headSha"] != "c0ffee" {
		t.Errorf("diff: %v", d)
	}
	if _, r := callTool(t, c, "merge_pr", map[string]any{"number": 7, "auto": true, "sha": "c0ffee"}); r["auto"] != true {
		t.Fatalf("auto: %v", r)
	}
	if sent := api.sentText(); !strings.Contains(sent, "expectedHeadOid") || !strings.Contains(sent, `"sha":"c0ffee"`) {
		t.Errorf("auto-merge: %s", sent)
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
