package agentsd

import (
	"encoding/json"
	"strconv"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
	sdk "github.com/coder/acp-go-sdk"
)

// #2941: a page's address is its issue or pull request, as lineage refs name it.
func TestNodeOfURL(t *testing.T) {
	for raw, want := range map[string]string{
		"https://github.com/alexec/Agents/issues/7":                  "issue github:alexec/agents#7",
		"https://github.com/alexec/Agents/pull/9/files":              "pr github:alexec/agents#9",
		"https://gitlab.com/group/sub/project/-/issues/3":            "issue gitlab:group/sub/project#3",
		"https://gitlab.example.com/group/project/-/merge_requests/4": "pr gitlab:group/project!4",
		"https://linear.app/acme/issue/eng-4/fix-the-walk":           "issue linear:ENG-4",
		"https://github.com/alexec/Agents/-/issues/7":                "",
		"https://example.com/a/b/issues/7":                           "",
		"javascript:alert(1)":                                        "",
		"":                                                           "",
	} {
		n, _, ok := nodeOfURL(raw)
		got := ""
		if ok {
			got = n.Kind + " " + n.Ref
		}
		if got != want {
			t.Errorf("%q: %q, want %q", raw, got, want)
		}
	}
}

// #2941: an issue's section names the sessions on it and on its PRs, the helpers they
// started, and each PR's end and cost.
func TestAnIssuesLineageSection(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	folder := t.TempDir()
	d.repos = map[string]forgeRepo{folder: {"github", "alexec/agents"}}
	branch := "agents/7-fix"
	a := seeded(t, d, folder, func(a *wire.Agent) {
		title := "Fix the walk"
		a.Title = &title
		a.Worktree = &wire.AgentWorktree{Name: "7-fix", Branch: &branch, Folder: store.FolderURL(folder)}
		a.Labels = []wire.SessionLabel{{Value: "#7", Owner: wire.SessionLabelOwnerPerson}}
	})
	d.noteLineage(nil, a)
	helper := seeded(t, d, folder, func(h *wire.Agent) { h.StartedByAgent = &a.ID })
	d.noteLineage(nil, helper)
	d.bankSessionCost(a.ID, wire.Cost{Amount: 1, Currency: "USD"})
	event := func(name string, n int) wire.Event {
		return wire.Event{Name: name, Details: map[string]string{"payload": `{"pr":{"number":` + strconv.Itoa(n) + `,"branch":"agents/7-fix",` +
			`"title":"Fix it","url":"https://github.com/alexec/Agents/pull/` + strconv.Itoa(n) + `","fixes":["#7"]}}`}}
	}
	d.lineageEvent(event("pr.opened", 9))
	d.bankSessionCost(a.ID, wire.Cost{Amount: 3, Currency: "USD"})
	d.lineageEvent(event("pr.closed", 9))
	d.lineageEvent(event("pr.opened", 10))
	d.bankSessionCost(a.ID, wire.Cost{Amount: 7, Currency: "USD"})
	d.lineageEvent(event("pr.merged", 10))

	node, base, _ := nodeOfURL("https://github.com/alexec/Agents/issues/7")
	v := d.lineageViewOf(node, base)
	if v.Summary != "2 sessions · 2 pull requests (1 merged, 1 waste)" {
		t.Errorf("summary %q", v.Summary)
	}
	if !strings.HasPrefix(v.Total, "$7.00 · ") || !strings.HasPrefix(v.Waste, "Waste: $1.00 · ") {
		t.Errorf("total %q, waste %q", v.Total, v.Waste)
	}
	prs := map[string]lineageViewNode{}
	for _, p := range v.PRs {
		prs[p.Name] = p
	}
	if p := prs["#9"]; p.Outcome != "closed" || !p.Waste || p.URL != "https://github.com/alexec/agents/pull/9" || !strings.HasPrefix(p.Words, "$1.00") {
		t.Errorf("#9 %+v", p)
	}
	if p := prs["#10"]; p.Outcome != "merged" || p.Waste || !strings.HasPrefix(p.Words, "$2.00") {
		t.Errorf("#10 %+v", p)
	}
	if len(v.Sessions) != 2 || v.Sessions[0].Title != "Fix the walk" || v.Sessions[1].How != "a helper of “Fix the walk”" {
		t.Fatalf("sessions %+v", v.Sessions)
	}
	if !strings.Contains(v.Sessions[0].Words, "$7.00") {
		t.Errorf("session words %q", v.Sessions[0].Words)
	}

	// The PR's page: its sessions, and the issue it fixes.
	node, base, _ = nodeOfURL("https://github.com/alexec/Agents/pull/10")
	v = d.lineageViewOf(node, base)
	if v.Summary != "2 sessions" || len(v.Issues) != 1 || v.Issues[0].Name != "#7" || v.Sessions[0].How != "opened it" {
		t.Errorf("pr %+v", v)
	}

	// Nothing on it.
	node, base, _ = nodeOfURL("https://github.com/alexec/Agents/issues/99")
	if v := d.lineageViewOf(node, base); v.Summary != "No session has worked on it yet." || v.Total != "" {
		t.Errorf("empty %+v", v)
	}
}

// #2941: only the github, gitlab and linear servers' views may ask; the answer is a tool result.
func TestOnlyOurServersViewsAskForLineage(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	server := func(command string) viewServer {
		return viewServer{name: "x", filled: sdk.McpServer{Stdio: &sdk.McpServerStdio{Name: "x", Command: command}}}
	}
	args := json.RawMessage(`{"url":"https://github.com/alexec/Agents/issues/7"}`)
	if _, err := d.lineageViewResult(server("/opt/their-mcp"), args); err == nil {
		t.Fatal("a server not ours was answered")
	}
	raw, err := d.lineageViewResult(server("github-mcp"), args)
	if err != nil {
		t.Fatal(err)
	}
	var r struct {
		StructuredContent lineageView `json:"structuredContent"`
		IsError           bool        `json:"isError"`
	}
	if json.Unmarshal(raw, &r) != nil || r.IsError || r.StructuredContent.Ref != "github:alexec/agents#7" {
		t.Fatalf("%s", raw)
	}
	raw, _ = d.lineageViewResult(server("linear-mcp"), json.RawMessage(`{"url":"https://example.com"}`))
	if json.Unmarshal(raw, &r) != nil || !r.IsError {
		t.Fatalf("%s", raw)
	}
}
