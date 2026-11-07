package agentsd

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/forgejomcp"
	"github.com/alexec/agents/Go/wire"
)

func (f *fakeForgeForgejo) Node(_ context.Context, repo string, number int) (forgejomcp.Node, error) {
	f.note(&f.asked, fmt.Sprintf("node %s#%d", repo, number))
	if number == 8 {
		return forgejomcp.Node{Title: "Add a", State: "merged"}, nil
	}
	return forgejomcp.Node{Title: "Lineage asks Forgejo", State: "open", Labels: []string{"bug"}, Milestone: 3}, nil
}

func (f *fakeForgeForgejo) MilestoneNode(_ context.Context, repo string, id int) (forgejomcp.Node, error) {
	f.note(&f.asked, fmt.Sprintf("milestone %s/%d", repo, id))
	return forgejomcp.Node{Title: "0.2 Lineage", State: "open"}, nil
}

func (f *fakeForgeForgejo) Milestones(_ context.Context, repo string) ([]forgejomcp.Milestone, error) {
	f.note(&f.asked, "milestones "+repo)
	return []forgejomcp.Milestone{{ID: 3, Title: "0.2 Lineage"}, {ID: 4, Title: "0.3 Later"}}, nil
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
// an issue's milestone, a release's pull requests and milestones, and the cost comment; and
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
	d.resolveNode(ctx, repo.milestone(3))
	for n, want := range map[wire.LineageNode]string{pr: "Add a merged []", issue: "Lineage asks Forgejo open [bug]", repo.milestone(3): "0.2 Lineage open []"} {
		e := d.resolveCache[n]
		if got := fmt.Sprintf("%s %s %v", e.resolved.Title, deref(e.resolved.State), e.resolved.Labels); !e.ok || got != want {
			t.Errorf("%s resolved %q (ok %v), want %q", n.Ref, got, e.ok, want)
		}
	}

	// An issue's milestone.
	d.askIssueMilestone(milestoneJob{folder, repo, 7})
	wantLinks(t, active(d, issue), issue.Ref+" part-of forgejo:walkalex/app/milestone/3 (forge)")

	// A release: the squash title's (#8), a merge commit's pull request asked, the milestone by its version.
	if !d.linkRelease(ctx, folder, repo, "v0.2.0", "v0.1.0") {
		t.Fatal("the release is not done")
	}
	release := repo.release("v0.2.0")
	wantLinks(t, active(d, release),
		pr.Ref+" part-of "+release.Ref+" (forge)",
		"forgejo:walkalex/app#9 part-of "+release.Ref+" (forge)",
		"forgejo:walkalex/app/milestone/3 shipped-in "+release.Ref+" (forge)")

	// The cost comment, by the connection.
	if id, err := d.forgejoCostComment(ctx, prCommentRecord{Folder: folder, Forge: "forgejo", Path: "walkalex/app", Number: 8}, "body"); err != nil || id != "41" {
		t.Fatalf("the cost comment: %q %v", id, err)
	}

	want := []string{"node walkalex/App#8", "node walkalex/App#7", "milestone walkalex/App/3", "node walkalex/App#7",
		"time walkalex/App v0.2.0", "compare walkalex/App v0.1.0...v0.2.0", "pull of walkalex/App bbb", "milestones walkalex/App",
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
