package agentsd

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// #3582: a session that files an epic and its children opens each of them, and once the
// children are the epic's sub-issues, asked again filedRecheck later, a walk from the
// session reaches the epic and its children.
func TestLineageSessionOpensTheIssuesItFiles(t *testing.T) {
	was := filedRecheck
	filedRecheck = 50 * time.Millisecond
	defer func() { filedRecheck = was }()
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	folder := t.TempDir()
	repo := forgeRepo{"github", "alexec/agents"}
	d.repos = map[string]forgeRepo{folder: repo}
	forge := &fakeMilestones{of: map[string]int{repo.issue(1).Ref: 0, repo.issue(2).Ref: 0, repo.issue(3).Ref: 0}, asked: map[string]int{}}
	d.issueLookup = forge.lookup
	a := seeded(t, d, folder, func(*wire.Agent) {})
	l := &live{d: d, id: a.ID}

	call := func(id, title, input, output string) wire.ToolCall {
		c := wire.ToolCall{ToolCallID: &id, Title: title, RawInput: json.RawMessage(input)}
		if output != "" {
			done := "completed"
			text := output
			c.Status = &done
			c.Content = []wire.ToolCallContent{{Type: "content", Content: &wire.ContentBlock{Type: "text", Text: &text}}}
		}
		return c
	}
	// gh issue create in a shell: its address comes in the update.
	d.noteIssueFiled(l, call("c1", "Create the epic", `{"command":"gh issue create --title Epic --body-file /tmp/b"}`, ""))
	d.noteIssueFiled(l, wire.ToolCall{ToolCallID: ptr("c1"), Title: "Tool call", Status: ptr("completed"),
		Content: []wire.ToolCallContent{{Type: "content", Content: &wire.ContentBlock{Type: "text", Text: ptr("https://github.com/alexec/Agents/issues/1\n")}}}})
	// GitHub's own server, in one call.
	d.noteIssueFiled(l, call("c2", "mcp__github__issue_write", `{"method":"create","title":"Child"}`,
		`{"url":"https://github.com/alexec/Agents/issues/2"}`))
	d.noteIssueFiled(l, call("c3", "gh issue create --title Child", `{}`, "Creating issue in alexec/Agents\n\nhttps://github.com/alexec/Agents/issues/3"))
	// Not a filing: viewing an issue, or a create that names other issues in its input only.
	d.noteIssueFiled(l, call("c4", "gh issue view 9", `{"command":"gh issue view 9"}`, "https://github.com/alexec/Agents/issues/9"))
	d.noteIssueFiled(l, call("c5", "mcp__github__issue_write", `{"method":"update","issue_number":8}`, `{"url":"https://github.com/alexec/Agents/issues/8"}`))

	settleMilestones(t, d)
	s := sessionNode(a.ID)
	wantLinks(t, active(d, s),
		s.Ref+" opens "+repo.issue(1).Ref+" (agent)",
		s.Ref+" opens "+repo.issue(2).Ref+" (agent)",
		s.Ref+" opens "+repo.issue(3).Ref+" (agent)")

	// The children are made the epic's sub-issues; the second ask links them.
	forge.setParent(repo.issue(2).Ref, repo.issue(1).Ref)
	forge.setParent(repo.issue(3).Ref, repo.issue(1).Ref)
	for deadline := time.Now().Add(5 * time.Second); ; {
		if forge.times(repo.issue(2).Ref) >= 2 && forge.times(repo.issue(3).Ref) >= 2 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the filed issues were not asked again")
		}
		time.Sleep(10 * time.Millisecond)
	}
	settleMilestones(t, d)
	wantLinks(t, active(d, repo.issue(1)),
		s.Ref+" opens "+repo.issue(1).Ref+" (agent)",
		repo.issue(2).Ref+" part-of "+repo.issue(1).Ref+" (forge)",
		repo.issue(3).Ref+" part-of "+repo.issue(1).Ref+" (forge)")
	g := d.lineage().Walk(s, 2)
	reached := map[string]bool{}
	for _, n := range g.Nodes {
		reached[n.Ref] = true
	}
	for _, n := range []int{1, 2, 3} {
		if !reached[repo.issue(n).Ref] {
			t.Errorf("the walk from the session did not reach #%d: %v", n, g.Nodes)
		}
	}
}

func TestFilesIssue(t *testing.T) {
	name := func(s string) *string { return &s }
	for _, c := range []struct {
		call wire.ToolCall
		want bool
	}{
		{wire.ToolCall{Title: "Bash", RawInput: json.RawMessage(`{"command":"cd x && gh issue create -t T -b B"}`)}, true},
		{wire.ToolCall{Title: "glab issue create --title T"}, true},
		{wire.ToolCall{Title: "mcp__github__create_issue"}, true},
		{wire.ToolCall{Title: "Tool call", Name: name("linear.createIssue")}, true},
		{wire.ToolCall{Title: "create_issue (github MCP Server)"}, true},
		{wire.ToolCall{Title: "issue_write", RawInput: json.RawMessage(`{"method": "create"}`)}, true},
		{wire.ToolCall{Title: "issue_write", RawInput: json.RawMessage(`{"method":"update"}`)}, false},
		{wire.ToolCall{Title: "gh issue list"}, false},
		// Gitea's tea and Forgejo's fj (#3850), with flags before the command.
		{wire.ToolCall{Title: "Bash", RawInput: json.RawMessage(`{"command":"tea issues create --title T --repo o/r"}`)}, true},
		{wire.ToolCall{Title: "tea issue create -t T"}, true},
		{wire.ToolCall{Title: "fj issue create T --body B"}, true},
		{wire.ToolCall{Title: "fj --host https://git.example.com issue create T"}, true},
		{wire.ToolCall{Title: "fj -H git.example.com issue create T"}, true},
		{wire.ToolCall{Title: "tea issues list"}, false},
		{wire.ToolCall{Title: "fj issue view 3"}, false},
		{wire.ToolCall{Title: "Read", RawInput: json.RawMessage(`{"file_path":"/x/recreate_issues.md"}`)}, false},
	} {
		if got := filesIssue(c.call); got != c.want {
			t.Errorf("%+v: got %v, want %v", c.call, got, c.want)
		}
	}
}
