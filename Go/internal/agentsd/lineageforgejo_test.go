package agentsd

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/forgejomcp"
	"github.com/alexec/agents/Go/wire"
	sdk "github.com/coder/acp-go-sdk"
)

func (f *fakeForgeForgejo) Node(_ context.Context, repo string, number int) (forgejomcp.Node, error) {
	f.note(&f.asked, fmt.Sprintf("node %s#%d", repo, number))
	if number == 8 {
		return forgejomcp.Node{Title: "Add a", State: "merged"}, nil
	}
	return forgejomcp.Node{Title: "Lineage asks Forgejo", State: "open", Labels: []string{"bug"}}, nil
}

func (f *fakeForgeForgejo) CommitTime(_ context.Context, repo, ref string) (time.Time, error) {
	f.note(&f.asked, "time "+repo+" "+ref)
	return time.Date(2026, 11, 7, 13, 17, 47, 0, time.UTC), nil
}

func (f *fakeForgeForgejo) Compare(_ context.Context, repo, base, head string) ([]forgejomcp.Commit, error) {
	f.note(&f.asked, "compare "+repo+" "+base+"..."+head)
	return []forgejomcp.Commit{{SHA: "aaa", Message: "Add a (#8)\n"}, {SHA: "bbb", Message: "Merge branch 'b'"}}, nil
}

func (f *fakeForgeForgejo) CommitPR(_ context.Context, repo, sha string) (int, error) {
	f.note(&f.asked, "pull of "+repo+" "+sha)
	return 9, nil
}

func (f *fakeForgeForgejo) CostComment(_ context.Context, repo string, number int, id, mark, body string) (string, error) {
	f.note(&f.asked, fmt.Sprintf("cost %s#%d id=%s %v", repo, number, id, mark == prCommentMark))
	return "41", nil
}

// #3844: lineage asks the connected Forgejo, by its connection, for a node's title and state,
// a release's pull requests, and the cost comment; and
// reads an issue address on its own host, whose name does not say Forgejo.
func TestLineageAsksForgejo(t *testing.T) {
	d, _, fj, _ := forgejoDaemon(t)
	repo := forgeRepo{"forgejo", "walkalex/app"}
	folder := d.repoFolder(repo)
	if folder == "" {
		t.Fatal("no folder on the connected Forgejo")
	}
	ctx := context.Background()

	// A node's title and state: a merged pull request, and an issue's labels.
	pr, issue := repo.pr(8), repo.issue(7)
	d.resolveNode(ctx, pr)
	d.resolveNode(ctx, issue)
	for n, want := range map[wire.LineageNode]string{pr: "Add a merged []", issue: "Lineage asks Forgejo open [bug]"} {
		e := d.resolveCache[n]
		if got := fmt.Sprintf("%s %s %v", e.resolved.Title, deref(e.resolved.State), e.resolved.Labels); !e.ok || got != want {
			t.Errorf("%s resolved %q (ok %v), want %q", n.Ref, got, e.ok, want)
		}
	}

	// A release: the squash title's (#8), a merge commit's pull request asked.
	if !d.linkRelease(ctx, folder, repo, "v0.2.0", "v0.1.0") {
		t.Fatal("the release is not done")
	}
	release := repo.release("v0.2.0")
	wantLinks(t, active(d, release),
		pr.Ref+" part-of "+release.Ref+" (forge)",
		"forgejo:pr:walkalex/app#9 part-of "+release.Ref+" (forge)")

	// The cost comment, by the connection.
	if id, err := d.forgejoCostComment(ctx, prCommentRecord{Folder: folder, Forge: "forgejo", Path: "walkalex/app", Number: 8}, "body"); err != nil || id != "41" {
		t.Fatalf("the cost comment: %q %v", id, err)
	}

	want := []string{"node walkalex/App#8", "node walkalex/App#7",
		"time walkalex/App v0.2.0", "compare walkalex/App v0.1.0...v0.2.0", "pull of walkalex/App bbb",
		"cost walkalex/App#8 id= true"}
	if fmt.Sprint(fj.asked) != fmt.Sprint(want) {
		t.Errorf("Forgejo was asked\n%v\nwant\n%v", fj.asked, want)
	}

	// An issue address on the connected Forgejo's own host, in a view and in a filed issue's output.
	if n, base, ok := d.nodeOfURLHere("http://localhost:3753/walkalex/App/issues/7"); !ok || n != issue || base != "http://localhost:3753" {
		t.Errorf("a view's address: %+v %q %v", n, base, ok)
	}
	call := wire.ToolCall{RawOutput: []byte(`{"url":"http://localhost:3753/walkalex/App/issues/12"}`)}
	if got := issuesIn(call, "http://localhost:3753/"); len(got) != 1 || got[0] != repo.issue(12) {
		t.Errorf("a filed issue's output: %v", got)
	}
	if got := issuesIn(call, ""); len(got) != 0 {
		t.Errorf("with no Forgejo connected: %v", got)
	}
}

func TestIssueOfURLOn(t *testing.T) {
	for raw, want := range map[string]string{
		"http://localhost:3753/walkalex/App/issues/7":           "forgejo:walkalex/app 7",
		"http://LOCALHOST:3753/walkalex/app/issues/7#c3":        "forgejo:walkalex/app 7",
		"https://localhost:3753/walkalex/app/issues/7":          "",
		"http://localhost:3754/walkalex/app/issues/7":           "",
		"http://localhost:3753/walkalex/issues/7":               "",
		"http://localhost:3753/a/b/c/issues/7":                  "",
		"http://localhost:3753/walkalex/app/issues/0":           "",
		"https://github.com/alexec/Agents/issues/3":             "github:alexec/agents 3",
		"https://git.example.com/forgejo/walkalex/app/issues/2": "",
	} {
		r, n, ok := issueOfURLOn(raw, "http://localhost:3753/")
		got := ""
		if ok {
			got = fmt.Sprintf("%s:%s %d", r.forge, r.path, n)
		}
		if got != want {
			t.Errorf("%s: %q, want %q", raw, got, want)
		}
	}
	if r, n, ok := issueOfURLOn("https://git.example.com/forgejo/walkalex/app/issues/2", "https://git.example.com/forgejo/"); !ok || r.path != "walkalex/app" || n != 2 {
		t.Errorf("a Forgejo under a path: %+v %d %v", r, n, ok)
	}
}

// #3850: the forgejo server's views ask for lineage, by an issue's or a pull request's address
// on the connected Forgejo, and its pull requests' addresses are on the Forgejo's own root.
func TestTheForgejoServersViewsAskForLineage(t *testing.T) {
	d, _, _, _ := forgejoDaemon(t)
	repo := forgeRepo{"forgejo", "walkalex/app"}
	folder := d.repoFolder(repo)
	a := seeded(t, d, folder, func(a *wire.Agent) {
		title := "Fix the walk"
		a.Title = &title
		a.Labels = []wire.SessionLabel{{Value: "#7", Owner: wire.SessionLabelOwnerPerson}, {Value: "P#8", Owner: wire.SessionLabelOwnerPerson}}
	})
	d.noteLineage(nil, a)
	d.lineageEvent(wire.Event{Name: "pr.opened", Details: map[string]string{"payload": `{"pr":{"number":8,"branch":"b",` +
		`"title":"Fix it","url":"http://localhost:3753/walkalex/App/pulls/8","fixes":["#7"]}}`}})

	forgejo := viewServer{name: "forgejo", filled: sdk.McpServer{Stdio: &sdk.McpServerStdio{Name: "forgejo", Command: "forgejo-mcp"}}}
	ask := func(url string) lineageView {
		t.Helper()
		raw, err := d.lineageViewResult(forgejo, json.RawMessage(`{"url":"`+url+`"}`))
		if err != nil {
			t.Fatal(err)
		}
		var r struct {
			StructuredContent lineageView `json:"structuredContent"`
			IsError           bool        `json:"isError"`
		}
		if json.Unmarshal(raw, &r) != nil || r.IsError {
			t.Fatalf("%s: %s", url, raw)
		}
		return r.StructuredContent
	}
	v := ask("http://localhost:3753/walkalex/App/issues/7")
	if v.Ref != repo.issue(7).Ref || len(v.Sessions) != 1 || v.Sessions[0].Title != "Fix the walk" {
		t.Errorf("the issue's: %+v", v)
	}
	if len(v.PRs) != 1 || v.PRs[0].URL != "http://localhost:3753/walkalex/app/pulls/8" {
		t.Errorf("the issue's pull requests: %+v", v.PRs)
	}
	v = ask("http://localhost:3753/walkalex/App/pulls/8")
	if v.Ref != repo.pr(8).Ref || len(v.Sessions) != 1 {
		t.Errorf("the pull request's: %+v", v)
	}
	if len(v.Issues) != 1 || v.Issues[0].URL != "http://localhost:3753/walkalex/app/issues/7" {
		t.Errorf("the pull request's issues: %+v", v.Issues)
	}
}

func TestForgejoOfURLOn(t *testing.T) {
	for _, c := range []struct{ raw, root, sep, want string }{
		{"http://localhost:3753/walkalex/App/pulls/8", "http://localhost:3753/", "/pulls/", "walkalex/app 8"},
		{"http://localhost:3753/walkalex/App/pulls/8/files", "http://localhost:3753/", "/pulls/", "walkalex/app 8"},
		{"https://git.example.com/forgejo/walkalex/app/pulls/2", "https://git.example.com/forgejo/", "/pulls/", "walkalex/app 2"},
		{"https://git.example.com/walkalex/app/pulls/2", "https://git.example.com/forgejo/", "/pulls/", ""},
		{"http://localhost:3753/walkalex/App/issues/8", "http://localhost:3753/", "/pulls/", ""},
		{"http://localhost:3753/walkalex/App/pulls/8", "", "/pulls/", ""},
	} {
		r, n, ok := forgejoOfURLOn(c.raw, c.root, c.sep)
		got := ""
		if ok {
			got = fmt.Sprintf("%s %d", r.path, n)
		}
		if got != c.want {
			t.Errorf("%s on %q: %q, want %q", c.raw, c.root, got, c.want)
		}
	}
}

// #3850: a session that files an issue with Gitea's tea or Forgejo's fj opens it. tea gives
// back the issue's address; fj only `created issue #12`, on its --repo or the folder's.
// The outputs are the scratch Forgejo 17's.
func TestLineageSessionOpensTheIssuesTeaAndFjFile(t *testing.T) {
	d, _, _, _ := forgejoDaemon(t)
	repo := forgeRepo{"forgejo", "walkalex/app"}
	a := seeded(t, d, d.repoFolder(repo), func(*wire.Agent) {})
	l := &live{d: d, id: a.ID}
	call := func(id, command, output string) {
		done := "completed"
		d.noteIssueFiled(l, wire.ToolCall{ToolCallID: &id, Title: "Bash", RawInput: json.RawMessage(`{"command":` + strconv.Quote(command) + `}`)})
		d.noteIssueFiled(l, wire.ToolCall{ToolCallID: &id, Title: "Bash", Status: &done,
			Content: []wire.ToolCallContent{{Type: "content", Content: &wire.ContentBlock{Type: "text", Text: &output}}}})
	}
	call("t1", "tea issues create --title 'Filed by tea' --description walk",
		"\n  # #1 Filed by tea (open)\n\n  @walkalex created 2026-11-07 15:32\n\n  walk\n\nhttp://localhost:3753/walkalex/App/issues/1\n")
	call("f1", "fj issue create 'Filed by fj' --body walk", "created issue #2: Filed by fj\n")
	call("f2", "fj --host http://localhost:3753 issue create --repo kim/Notes 'Elsewhere' --body b", "created issue #5: Elsewhere\n")
	// Not a filing: fj viewing an issue says no "created".
	call("f3", "fj issue view 9", "#9: created issue #9 by walkalex\n")

	settleParents(t, d)
	s := sessionNode(a.ID)
	wantLinks(t, active(d, s),
		s.Ref+" opens "+repo.issue(1).Ref+" (agent)",
		s.Ref+" opens "+repo.issue(2).Ref+" (agent)",
		s.Ref+" opens forgejo:issue:kim/notes#5 (agent)")
	if l.filing["f1"] != (forgeRepo{}) || len(l.filing) != 0 {
		t.Errorf("calls still held: %v", l.filing)
	}
}
