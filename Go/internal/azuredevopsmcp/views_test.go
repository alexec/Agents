package azuredevopsmcp

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// The views (#4098) over the fake Azure DevOps, through an MCP client: what each tool gives a
// page, who may call what, and the pages themselves.

func viewsClient(t *testing.T, f *fakeAzureDevOps) *mcp.ClientSession {
	t.Helper()
	server := NewServer("test", f.azureDevOps(), true)
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

// viewsFake has Dev's pull request with Alex (the token's owner) a reviewer who has not voted,
// Alex's own draft in conflict with a reviewer waiting for its author, and Renovate's.
func viewsFake(t *testing.T) *fakeAzureDevOps {
	f := newFake(t)
	f.pulls = []obj{
		pull(3, "fix-mean", dev, obj{"title": "Fix the mean", "description": "Divide by the count.", "creationDate": at(2),
			"reviewers": []any{obj{"id": "a1", "displayName": "Alex", "uniqueName": "alex@acme.test", "vote": 0}}}),
		pull(4, "docs", alex, obj{"title": "Write the docs", "isDraft": true, "creationDate": at(3), "mergeStatus": "conflicts",
			"autoCompleteSetBy": alex, "reviewers": []any{obj{"id": "d2", "displayName": "Dev", "uniqueName": "dev@acme.test", "vote": -5}}}),
		pull(6, "bump", renovate, obj{"creationDate": at(1)}),
		pull(7, "done", dev, obj{"status": "completed", "creationDate": at(4)}),
	}
	f.builds = []obj{build(70, 3, "sha3", "ci", "failed", 4), build(71, 6, "sha6", "ci", "succeeded", 2)}
	f.statuses[3] = []obj{prStatus(1, "scan", "secrets", "succeeded", 2, 0)}
	f.threads[3] = []obj{
		{"id": 1, "comments": []any{obj{"id": 1, "author": alex, "content": "Looks right.", "publishedDate": at(5), "commentType": "text"},
			obj{"id": 2, "author": dev, "content": "Thanks.", "publishedDate": at(6), "commentType": "text"}}},
		{"id": 2, "comments": []any{obj{"id": 1, "author": builder, "content": "Policy set", "publishedDate": at(1), "commentType": "system"}}},
		{"id": 3, "status": "active", "threadContext": obj{"filePath": "/average.py", "rightFileStart": obj{"line": 3}},
			"comments": []any{obj{"id": 1, "author": renovate, "content": "What if xs is empty?", "publishedDate": at(3)},
				obj{"id": 2, "author": dev, "content": "Then it raises.", "publishedDate": at(4)}}},
		{"id": 4, "isDeleted": true, "comments": []any{obj{"id": 1, "author": dev, "content": "Gone", "publishedDate": at(4)}}},
	}
	f.iterations[3] = []obj{{"id": 1, "sourceRefCommit": obj{"commitId": "sha3"}}}
	f.changes[3] = []obj{{"changeType": "edit", "item": obj{"path": "/average.py"}}, {"changeType": "add", "item": obj{"path": "/logo.png"}},
		{"changeType": "add", "item": obj{"path": "/dir", "isFolder": true}}}
	f.policies = []obj{{"isEnabled": true, "settings": obj{"allowSquash": true, "allowNoFastForward": false}}}
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
	same(t, feeds, map[string]string{"show_pull_requests": pullsURI, "show_pull_request": prURI})
	// A person merges and approves from a page: no agent is offered those.
	for _, name := range []string{"merge_pull_request", "approve_pull_request"} {
		if v := visibility[name]; len(v) != 1 || v[0] != "app" {
			t.Errorf("%s's visibility is %v, not [app]", name, v)
		}
	}
	for _, uri := range []string{pullsURI, prURI} {
		r, err := c.ReadResource(context.Background(), &mcp.ReadResourceParams{URI: uri})
		if err != nil || len(r.Contents) != 1 {
			t.Fatalf("%s: %v", uri, err)
		}
		html := r.Contents[0].Text
		if r.Contents[0].MIMEType != viewMime || !strings.HasPrefix(html, "<!doctype html>") || strings.Contains(html, "/*common.css*/") ||
			strings.Contains(html, "/*bridge.js*/") || strings.Contains(html, "/*lineage.js*/") || strings.Contains(html, "/*prpage.js*/") ||
			!strings.Contains(html, "const bridge") || !strings.Contains(html, "const prPage") {
			t.Errorf("%s is not a whole page", uri)
		}
		// A page names no other forge, and calls only this server's tools.
		for _, other := range []string{"Forgejo", "Bitbucket", "failed_log", "retry_pipeline"} {
			if strings.Contains(html, other) {
				t.Errorf("%s says %s", uri, other)
			}
		}
	}
}

// The shared script and styles are the github server's, word for word, as on the other
// servers' pages: a change there is made in each copy.
func TestThePagesShareTheGitHubServersBridge(t *testing.T) {
	for _, name := range []string{"bridge.js", "common.css", "lineage.js", "prpage.css"} {
		ours, err := pageFiles.ReadFile("pages/" + name)
		if err != nil {
			t.Fatal(err)
		}
		theirs, err := os.ReadFile("../githubmcp/pages/" + name)
		if err != nil {
			t.Fatal(err)
		}
		if string(ours) != string(theirs) {
			t.Errorf("pages/%s is not the github server's", name)
		}
	}
}

func TestThePullRequestsListSaysEachOnesStateAndSection(t *testing.T) {
	c := viewsClient(t, viewsFake(t))
	out := callTool(t, c, "show_pull_requests", map[string]any{}, nil)
	same(t, []any{out["repo"], out["viewer"], out["count"], out["attention"]}, []any{repo, "Alex", float64(3), float64(2)})
	prs := out["pullRequests"].([]any)
	// Newest created first; a completed one is not listed.
	docs, mean, bump := prs[0].(map[string]any), prs[1].(map[string]any), prs[2].(map[string]any)
	same(t, []any{docs["number"], mean["number"], bump["number"]}, []any{float64(4), float64(3), float64(6)})
	// Alex is a reviewer who has not voted: Needs you, with its failed build.
	same(t, []any{mean["section"], mean["checks"], mean["failedRunId"], mean["review"], mean["mine"], mean["author"], mean["branch"], mean["base"]},
		[]any{"needs_you", "failing", float64(70), "review_required", false, "dev@acme.test", "fix-mean", "main"})
	// Alex's own, in conflict and waiting for its author: Needs you, with auto-complete on.
	same(t, []any{docs["section"], docs["conflicts"], docs["draft"], docs["review"], docs["autoMerge"], docs["mine"], docs["checks"]},
		[]any{"needs_you", true, true, "changes_requested", true, true, "none"})
	// With no control plane, the organization's other people and bots are Team.
	same(t, []any{bump["section"], bump["authorBot"], bump["checks"], bump["failedRunId"]}, []any{"team", true, "passing", nil})
	if !strings.HasSuffix(mean["url"].(string), web+"/pullrequest/3") {
		t.Fatalf("url %v", mean["url"])
	}
}

// With the control plane's people (#2951), Team is those people by their Azure DevOps login
// (#3853): a sign-in email or a display name. The rest are Others, and an agent on one of the
// viewer's own says so.
func TestTheListsTeamIsTheControlPlanesPeopleWhenTheHostSaysThem(t *testing.T) {
	f := viewsFake(t)
	f.pulls = append(f.pulls, pull(8, "theirs", obj{"id": "s5", "displayName": "Sam", "uniqueName": "sam@else.test"}, obj{"creationDate": at(0)}))
	c := viewsClient(t, f)
	meta := mcp.Meta{"people": []any{map[string]any{"name": "Dev Person", "azuredevops": "DEV@acme.test"},
		map[string]any{"name": "Renovate", "azuredevops": "renovate-bot", "bot": true}},
		"agentOnPR": map[string]any{"4": "Claude"}}
	out := callTool(t, c, "show_pull_requests", map[string]any{}, meta)
	by := map[float64]map[string]any{}
	for _, p := range out["pullRequests"].([]any) {
		by[p.(map[string]any)["number"].(float64)] = p.(map[string]any)
	}
	same(t, []any{by[3]["authorName"], by[6]["section"], by[6]["authorName"], by[8]["section"], by[4]["agentOn"], by[3]["agentOn"]},
		[]any{"Dev Person", "team", "Renovate", "others", "Claude", nil})
}

func TestAPullRequestsPageHasItsConversationThreadsFilesAndChecks(t *testing.T) {
	c := viewsClient(t, viewsFake(t))
	pr := callTool(t, c, "show_pull_request", map[string]any{"number": 3}, nil)
	same(t, []any{pr["number"], pr["state"], pr["body"], pr["checks"], pr["failedRunId"], pr["conflicts"], pr["squash"], pr["headSha"],
		pr["viewer"], pr["mine"], pr["autoMerge"], pr["filesTotal"], pr["filesCut"], pr["createdAt"]},
		[]any{float64(3), "open", "Divide by the count.", "failing", float64(70), false, true, "sha3", "Alex", false, false, float64(2), false,
			"2026-11-06T12:02:00.000Z"})
	// Its comments not on a line, oldest first, without Azure DevOps's own.
	comments := pr["comments"].([]any)
	if len(comments) != 2 || comments[0].(map[string]any)["body"] != "Looks right." || comments[1].(map[string]any)["author"] != "dev@acme.test" ||
		!strings.HasSuffix(comments[0].(map[string]any)["url"].(string), "/pullrequest/3?discussionId=1") {
		t.Fatalf("comments %+v", comments)
	}
	threads := pr["threads"].([]any)
	if len(threads) != 1 {
		t.Fatalf("threads %+v", threads)
	}
	th := threads[0].(map[string]any)
	same(t, []any{th["path"], th["line"], th["resolved"], len(th["comments"].([]any)), th["comments"].([]any)[0].(map[string]any)["bot"]},
		[]any{"average.py", float64(3), false, 2, true})
	// Its files, with no folder and no counts of lines: Azure DevOps says only how each changed.
	same(t, pr["files"], []any{map[string]any{"path": "average.py", "change": "modified"}, map[string]any{"path": "logo.png", "change": "added"}})
	runs := pr["checkRuns"].([]any)
	same(t, runs[0], map[string]any{"name": "ci", "state": "failing", "url": "https://ado.test/acme/Web%20App/_build/results?buildId=70", "runId": float64(70)})
	same(t, runs[1], map[string]any{"name": "scan/secrets", "state": "passing", "url": "https://scan.test/1"})

	merged := callTool(t, c, "show_pull_request", map[string]any{"number": 7}, nil)
	if merged["state"] != "merged" || merged["conflicts"] != nil {
		t.Fatalf("a completed one: %+v", merged)
	}
}

// Retry Failed Jobs runs the build's failed jobs again, in the same build.
func TestRetryBuildRunsTheFailedJobsAgain(t *testing.T) {
	f := viewsFake(t)
	c := viewsClient(t, f)
	out := callTool(t, c, "retry_build", map[string]any{"buildId": 70}, nil)
	if out["buildId"] != float64(70) || out["url"] != "https://ado.test/build" {
		t.Fatalf("retry %+v", out)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	last := f.posted[len(f.posted)-1]
	if last["_method"] != "PATCH" || last["_path"] != "/acme/Web App/_apis/build/builds/70" {
		t.Fatalf("posted %+v", last)
	}
}
