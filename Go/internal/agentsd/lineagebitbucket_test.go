package agentsd

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/bitbucketmcp"
	"github.com/alexec/agents/Go/internal/connections"
	"github.com/alexec/agents/Go/wire"
	sdk "github.com/coder/acp-go-sdk"
)

func (f *fakeForgeBitbucket) Node(_ context.Context, repo string, number int, pr bool) (bitbucketmcp.Node, error) {
	f.note(&f.asked, fmt.Sprintf("node %s#%d pr=%v", repo, number, pr))
	if pr {
		return bitbucketmcp.Node{Title: "Add a", State: "merged", Labels: []string{}}, nil
	}
	return bitbucketmcp.Node{Title: "Lineage asks Bitbucket", State: "open", Labels: []string{"bug", "api"}}, nil
}

func (f *fakeForgeBitbucket) CommitTime(_ context.Context, repo, ref string) (time.Time, error) {
	f.note(&f.asked, "time "+repo+" "+ref)
	return time.Date(2026, 11, 7, 13, 17, 47, 0, time.UTC), nil
}

func (f *fakeForgeBitbucket) Compare(_ context.Context, repo, base, head string) ([]bitbucketmcp.Commit, error) {
	f.note(&f.asked, "compare "+repo+" "+base+"..."+head)
	return []bitbucketmcp.Commit{{SHA: "aaa", Message: "Merged in agents/7-fix (pull request #8)\n\nAdd a"}, {SHA: "bbb", Message: "Fix b"}}, nil
}

func (f *fakeForgeBitbucket) CommitPR(_ context.Context, repo, sha string) (int, error) {
	f.note(&f.asked, "pull of "+repo+" "+sha)
	return 9, nil
}

func (f *fakeForgeBitbucket) CostComment(_ context.Context, repo string, number int, id, mark, body string) (string, error) {
	f.note(&f.asked, fmt.Sprintf("cost %s#%d id=%s %v", repo, number, id, mark == prCommentMark))
	return "41", nil
}

// bitbucketFolder is the bitbucketDaemon's folder on Bitbucket.
func bitbucketFolder(t *testing.T, d *Daemon) string {
	t.Helper()
	for _, f := range d.folderPaths() {
		if d.folderRepo(f) == (forgeRepo{"bitbucket", "walkalex/app"}) {
			return f
		}
	}
	t.Fatalf("no folder on bitbucket:walkalex/app: %v", d.folderPaths())
	return ""
}

// #3879: lineage takes a Bitbucket folder's labels and pull request events as Bitbucket nodes,
// by its remote's host, with or without a connection. Nothing is asked of gh or glab about them.
func TestLineageOnABitbucketFolder(t *testing.T) {
	d, _, _, file := bitbucketDaemon(t)
	folder := bitbucketFolder(t, d)
	branch := "agents/7-fix"
	a := seeded(t, d, folder, func(a *wire.Agent) {
		a.Labels = []wire.SessionLabel{{Value: "#7", Owner: wire.SessionLabelOwnerPerson}}
		a.Worktree = &wire.AgentWorktree{Name: "7-fix", Branch: &branch, Folder: store.FolderURL(folder)}
	})
	d.noteLineage(nil, a)
	s := sessionNode(a.ID)
	d.lineageEvent(wire.Event{Name: "pr.opened", Details: map[string]string{"payload": `{"pr":{"number":8,"branch":"agents/7-fix",` +
		`"url":"https://bitbucket.org/walkalex/App/pull-requests/8","fixes":["#7"]}}`}})
	pr := wire.LineageNode{Kind: "pr", Ref: "bitbucket:walkalex/app#8"}
	issue := wire.LineageNode{Kind: "issue", Ref: "bitbucket:walkalex/app#7"}
	wantLinks(t, active(d, pr),
		s.Ref+" opens "+pr.Ref+" (branch)",
		pr.Ref+" fixes "+issue.Ref+" (pr-body)")
	wantLinks(t, active(d, s),
		s.Ref+" works-on "+issue.Ref+" (start)",
		s.Ref+" opens "+pr.Ref+" (branch)")
	if n, ok := d.labelNode(folder, "P#4"); !ok || n != (wire.LineageNode{Kind: "pr", Ref: "bitbucket:walkalex/app#4"}) {
		t.Fatalf("P#4: %+v", n)
	}
	if _, _, ok := nodeOfRepo(pr); ok {
		t.Fatal("a Bitbucket node is asked of gh")
	}
	if r, n, ok := askedNode(issue); !ok || r != (forgeRepo{"bitbucket", "walkalex/app"}) || n != 7 {
		t.Fatalf("not asked of Bitbucket: %+v %d %v", r, n, ok)
	}

	// A Pipelines run builds the pull request; its node says pipelines, not GitHub's actions.
	d.lineageCIEvent(wire.Event{Name: "checks.failed", Details: map[string]string{"payload": `{"pr":{"number":8,` +
		`"url":"https://bitbucket.org/walkalex/App/pull-requests/8"},"run":{"id":12}}`}})
	settleParents(t, d)
	if !active(d, pr)["bitbucket:walkalex/app/pipelines/12 builds "+pr.Ref+" (forge)"] {
		t.Errorf("the run: %v", active(d, pr))
	}

	// With no connection the folder is still on Bitbucket, by its host.
	file.Delete(connections.Bitbucket)
	if r := d.folderRepo(folder); r != (forgeRepo{"bitbucket", "walkalex/app"}) {
		t.Fatalf("with no Bitbucket connection: %+v", r)
	}
}

// #3879: lineage asks the connected Bitbucket, by its connection, for a node's title and state,
// a release's pull requests, and the cost comment.
func TestLineageAsksBitbucket(t *testing.T) {
	d, _, bb, _ := bitbucketDaemon(t)
	repo := forgeRepo{"bitbucket", "walkalex/app"}
	folder := bitbucketFolder(t, d)
	ctx := context.Background()

	// A node's title and state: a merged pull request, and an issue's kind and component.
	pr, issue := repo.pr(8), repo.issue(7)
	d.resolveNode(ctx, pr)
	d.resolveNode(ctx, issue)
	for n, want := range map[wire.LineageNode]string{pr: "Add a merged []", issue: "Lineage asks Bitbucket open [bug api]"} {
		e := d.resolveCache[n]
		if got := fmt.Sprintf("%s %s %v", e.resolved.Title, deref(e.resolved.State), e.resolved.Labels); !e.ok || got != want {
			t.Errorf("%s resolved %q (ok %v), want %q", n.Ref, got, e.ok, want)
		}
	}

	// A release: the merge title's (pull request #8), another commit's pull request asked.
	if !d.linkRelease(ctx, folder, repo, "v0.2.0", "v0.1.0") {
		t.Fatal("the release is not done")
	}
	release := repo.release("v0.2.0")
	wantLinks(t, active(d, release),
		pr.Ref+" part-of "+release.Ref+" (forge)",
		"bitbucket:walkalex/app#9 part-of "+release.Ref+" (forge)")

	// The cost comment, by the connection.
	asks, _ := d.connectionAsks("bitbucket")
	if id, err := asks.costComment(ctx, prCommentRecord{Folder: folder, Forge: "bitbucket", Path: "walkalex/app", Number: 8}, "body"); err != nil || id != "41" {
		t.Fatalf("the cost comment: %q %v", id, err)
	}

	want := []string{"node walkalex/App#8 pr=true", "node walkalex/App#7 pr=false",
		"time walkalex/App v0.2.0", "compare walkalex/App v0.1.0...v0.2.0", "pull of walkalex/App bbb",
		"cost walkalex/App#8 id= true"}
	if fmt.Sprint(bb.asked) != fmt.Sprint(want) {
		t.Errorf("Bitbucket was asked\n%v\nwant\n%v", bb.asked, want)
	}
}

// #3879: the bitbucket server's views ask for lineage by an issue's or a pull request's address.
func TestTheBitbucketServersViewsAskForLineage(t *testing.T) {
	d, _, _, _ := bitbucketDaemon(t)
	folder := bitbucketFolder(t, d)
	a := seeded(t, d, folder, func(a *wire.Agent) {
		title := "Fix the walk"
		a.Title = &title
		a.Labels = []wire.SessionLabel{{Value: "#7", Owner: wire.SessionLabelOwnerPerson}, {Value: "P#8", Owner: wire.SessionLabelOwnerPerson}}
	})
	d.noteLineage(nil, a)
	d.lineageEvent(wire.Event{Name: "pr.opened", Details: map[string]string{"payload": `{"pr":{"number":8,"branch":"b",` +
		`"title":"Fix it","url":"https://bitbucket.org/walkalex/App/pull-requests/8","fixes":["#7"]}}`}})

	bitbucket := viewServer{name: "bitbucket", filled: sdk.McpServer{Stdio: &sdk.McpServerStdio{Name: "bitbucket", Command: "bitbucket-mcp"}}}
	raw, err := d.lineageViewResult(bitbucket, json.RawMessage(`{"url":"https://bitbucket.org/walkalex/App/issues/7"}`))
	if err != nil {
		t.Fatal(err)
	}
	var r struct {
		StructuredContent lineageView `json:"structuredContent"`
		IsError           bool        `json:"isError"`
	}
	if json.Unmarshal(raw, &r) != nil || r.IsError {
		t.Fatalf("the issue's: %s", raw)
	}
	v := r.StructuredContent
	if v.Ref != "bitbucket:walkalex/app#7" || len(v.Sessions) != 1 || v.Sessions[0].Title != "Fix the walk" {
		t.Errorf("the issue's: %+v", v)
	}
	if len(v.PRs) != 1 || v.PRs[0].URL != "https://bitbucket.org/walkalex/app/pull-requests/8" {
		t.Errorf("the issue's pull requests: %+v", v.PRs)
	}
}
