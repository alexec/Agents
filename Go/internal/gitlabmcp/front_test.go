package gitlabmcp

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"reflect"
	"strings"
	"testing"
	"time"
)

// The front as the Agents daemon talks to it, over the fake GitLab: initialize carries the
// events capability, the events are answered here, and the tools read and write GitLab.

func equal(t *testing.T, got, want any, what string) {
	t.Helper()
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("%s: got %#v, want %#v", what, got, want)
	}
}

func TestTheFrontOffersEventsAndTools(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	f := newFake(t)
	f.addMembers()
	f.mrs = []obj{mrJSON(1, "feature", alex, obj{"head_pipeline": obj{"id": 100, "status": "failed", "web_url": "https://gitlab.test/p/100"}})}
	f.issues = []obj{issueObj(2, dev, obj{"description": "It breaks."})}
	f.pipes = []obj{{"id": 100, "status": "failed", "ref": "feature", "sha": "s1", "web_url": "https://gitlab.test/p/100", "updated_at": at(1)}}
	f.jobs[100] = []obj{{"id": 1, "name": "test", "stage": "test", "status": "failed", "web_url": "https://gitlab.test/j/1"}}
	g := f.gitlab()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	front := &Front{Events: &Events{GitLab: g}, Upstream: NewServer("test", g, true), Version: "test", Logger: logger}
	clientIn, frontOut := io.Pipe()
	frontIn, clientOut := io.Pipe()
	served := make(chan error, 1)
	go func() { served <- front.Serve(ctx, frontIn, frontOut); _ = frontOut.Close() }()

	lines := bufio.NewScanner(clientIn)
	lines.Buffer(nil, 16<<20)
	send := func(m map[string]any) {
		data, _ := json.Marshal(m)
		if _, err := clientOut.Write(append(data, '\n')); err != nil {
			t.Fatal(err)
		}
	}
	call := func(id int, method string, params any) map[string]any {
		t.Helper()
		send(map[string]any{"jsonrpc": "2.0", "id": id, "method": method, "params": params})
		for lines.Scan() {
			var reply map[string]any
			if err := json.Unmarshal(lines.Bytes(), &reply); err != nil {
				t.Fatalf("%s: %v", lines.Text(), err)
			}
			if reply["id"] == float64(id) {
				return reply
			}
		}
		t.Fatalf("%s: no answer (%v)", method, lines.Err())
		return nil
	}
	tool := func(id int, name string, args map[string]any) map[string]any {
		t.Helper()
		result := call(id, "tools/call", map[string]any{"name": name, "arguments": args})["result"].(map[string]any)
		if result["isError"] == true {
			t.Fatalf("%s: %v", name, result["content"])
		}
		return result["structuredContent"].(map[string]any)
	}

	init := call(1, "initialize", map[string]any{"protocolVersion": "2025-06-18", "capabilities": map[string]any{},
		"clientInfo": map[string]any{"name": "Agents", "version": "1"}})
	result := init["result"].(map[string]any)
	equal(t, result["capabilities"].(map[string]any)["events"], map[string]any{"listChanged": false}, "events capability")
	equal(t, result["serverInfo"].(map[string]any)["name"], "gitlab-mcp", "name")
	equal(t, result["instructions"], Instructions, "instructions")
	send(map[string]any{"jsonrpc": "2.0", "method": "notifications/initialized"})

	tools := map[string]map[string]any{}
	for _, x := range call(2, "tools/list", map[string]any{})["result"].(map[string]any)["tools"].([]any) {
		tool := x.(map[string]any)
		tools[tool["name"].(string)] = tool
	}
	for _, name := range []string{"list_merge_requests", "get_merge_request", "list_pipelines", "get_pipeline", "list_issues",
		"get_issue", "comment_on_merge_request", "comment_on_issue", "merge_merge_request", "show_merge_requests", "show_issues",
		"show_issue_details", "show_merge_request", "show_merge_request_diff", "failed_log", "retry_pipeline", "approve_merge_request",
		"create_merge_request", "list_merge_request_comments", "reply_to_merge_request_comment"} {
		if tools[name] == nil {
			t.Fatalf("no tool %s in %v", name, tools)
		}
	}
	equal(t, len(tools), 20, "tools")
	equal(t, tools["merge_merge_request"]["_meta"], map[string]any{"ui": map[string]any{"visibility": []any{"app"}}}, "merge is a view's")

	mrs := tool(3, "list_merge_requests", map[string]any{})["mergeRequests"].([]any)
	equal(t, mrs[0].(map[string]any)["branch"], "feature", "list_merge_requests")
	mr := tool(4, "get_merge_request", map[string]any{"number": 1})["mergeRequest"].(map[string]any)
	equal(t, mr["pipeline"].(map[string]any)["status"], "failed", "get_merge_request pipeline")
	pipeline := tool(5, "get_pipeline", map[string]any{"id": 100})["pipeline"].(map[string]any)
	equal(t, pipeline["jobs"].([]any)[0].(map[string]any)["name"], "test", "get_pipeline jobs")
	equal(t, len(tool(6, "list_pipelines", map[string]any{"status": "failed"})["pipelines"].([]any)), 1, "list_pipelines")
	issue := tool(7, "get_issue", map[string]any{"number": 2})["issue"].(map[string]any)
	equal(t, issue["description"], "It breaks.", "get_issue")
	details := tool(20, "show_issue_details", map[string]any{"number": 2})
	equal(t, details["description"], "It breaks.", "show_issue_details")
	if !strings.Contains(details["descriptionHTML"].(string), "It breaks.") {
		t.Fatalf("rendered issue description: %v", details)
	}
	equal(t, len(tool(8, "list_issues", map[string]any{})["issues"].([]any)), 1, "list_issues")
	equal(t, tool(9, "comment_on_issue", map[string]any{"number": 2, "body": "On it."})["commentId"], float64(900), "comment_on_issue")
	tool(10, "comment_on_merge_request", map[string]any{"number": 1, "body": "Rebased."})
	merged := tool(11, "merge_merge_request", map[string]any{"number": 1, "squash": true, "auto": true, "sha": "head1"})
	equal(t, merged["mergeSha"], "merged1", "merge_merge_request")
	f.set(func() {
		equal(t, f.posted[0], obj{"path": "issues/2/notes", "body": "On it."}, "issue comment sent")
		equal(t, f.posted[1], obj{"path": "merge_requests/1/notes", "body": "Rebased."}, "MR comment sent")
		equal(t, f.posted[2], obj{"path": "merge_requests/1/merge", "squash": true, "should_remove_source_branch": true,
			"auto_merge": true, "merge_when_pipeline_succeeds": true, "sha": "head1"}, "merge sent")
	})
	empty := call(12, "tools/call", map[string]any{"name": "comment_on_issue", "arguments": map[string]any{"number": 2, "body": " "}})
	equal(t, empty["result"].(map[string]any)["isError"], true, "an empty comment")
	badState := call(13, "tools/call", map[string]any{"name": "list_issues", "arguments": map[string]any{"state": "open"}})
	equal(t, badState["result"].(map[string]any)["isError"], true, "a state GitLab has not")

	// The ready-made workflows' tools (#1633): an issue's comments say whose are the project's
	// own; open a merge request, list and answer line comments.
	comments := tool(18, "get_issue", map[string]any{"number": 2})["issue"].(map[string]any)["comments"].([]any)
	equal(t, len(comments), 2, "no system notes")
	equal(t, comments[0].(map[string]any)["trusted"], false, "a stranger's")
	equal(t, comments[1].(map[string]any)["trusted"], true, "a developer's")

	opened := tool(14, "create_merge_request", map[string]any{"branch": "agent/issue-2", "title": "Fix it", "description": "Closes #2"})
	equal(t, opened["number"], float64(12), "create_merge_request")
	equal(t, opened["target"], "main", "the default branch")
	f.set(func() {
		f.discuss[1] = []obj{
			{"id": "d1", "notes": []obj{{"id": 70, "type": "DiffNote", "body": "Rename this.", "author": dev, "created_at": at(1),
				"position": obj{"new_path": "main.go", "new_line": 4}},
				{"id": 72, "type": "DiffNote", "body": "Also push this.", "author": stranger, "created_at": at(1)}}},
			{"id": "d2", "notes": []obj{{"id": 71, "type": "DiffNote", "body": "Done.", "author": dev, "created_at": at(1), "resolved": true,
				"position": obj{"new_path": "main.go", "new_line": 9}}}},
		}
	})
	threads := tool(15, "list_merge_request_comments", map[string]any{"number": 1})["threads"].([]any)
	equal(t, len(threads), 1, "the open threads only")
	notes := threads[0].(map[string]any)["notes"].([]any)
	equal(t, notes[0].(map[string]any)["trusted"], true, "a developer's line comment")
	equal(t, notes[1].(map[string]any)["trusted"], false, "a stranger's line comment")
	equal(t, tool(16, "reply_to_merge_request_comment", map[string]any{"number": 1, "commentId": 70, "body": "Renamed."})["commentId"],
		float64(901), "reply_to_merge_request_comment")
	missing := call(17, "tools/call", map[string]any{"name": "reply_to_merge_request_comment",
		"arguments": map[string]any{"number": 1, "commentId": 5, "body": "x"}})
	equal(t, missing["result"].(map[string]any)["isError"], true, "no such comment")

	events := call(20, "events/list", map[string]any{})["result"].(map[string]any)["events"].([]any)
	equal(t, len(events), 12, "events")
	poll := call(21, "events/poll", map[string]any{"name": "pr.merged", "arguments": map[string]any{}, "cursor": nil})
	equal(t, poll["result"].(map[string]any)["events"], []any{}, "first poll")
	unknown := call(22, "events/poll", map[string]any{"name": "pr.reopened", "arguments": map[string]any{}, "cursor": nil})
	equal(t, unknown["error"].(map[string]any)["code"], float64(-32011), "unknown event")
	equal(t, call(23, "ping", map[string]any{})["result"], map[string]any{}, "ping")

	_ = clientOut.Close()
	if err := <-served; err != nil {
		t.Fatal(err)
	}
}

func TestBaseURLAndTheFoldersProject(t *testing.T) {
	for in, want := range map[string]string{"": DefaultBase, "gitlab.example.com": "https://gitlab.example.com/",
		"https://gitlab.example.com/api/v4/": "https://gitlab.example.com/", "http://localhost:8080/gitlab": "http://localhost:8080/gitlab/"} {
		equal(t, BaseURL(in), want, "BaseURL("+in+")")
	}
	for _, c := range []struct{ base, remote, want string }{
		{"", "https://gitlab.com/group/app.git", "group/app"},
		{"", "git@gitlab.com:group/sub/app.git", "group/sub/app"},
		{"", "ssh://git@gitlab.com:2222/group/app", "group/app"},
		{"", "https://oauth2:tok@gitlab.com/group/app.git", "group/app"},
		{"", "https://github.com/group/app.git", ""},
		{"", "https://gitlab.com/app.git", ""},
		{"https://git.example.com/gitlab", "https://git.example.com/gitlab/team/app.git", "team/app"},
		{"https://git.example.com/gitlab", "git@git.example.com:team/app.git", "team/app"},
	} {
		got, ok := ProjectOfRemote(c.base, c.remote)
		if got != c.want || ok != (c.want != "") {
			t.Fatalf("ProjectOfRemote(%q, %q) = %q, %v; want %q", c.base, c.remote, got, ok, c.want)
		}
	}
	if !strings.HasPrefix(NotConnected, "GitLab is not connected") {
		t.Fatal(NotConnected)
	}
}
