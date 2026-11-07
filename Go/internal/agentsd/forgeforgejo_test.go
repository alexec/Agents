package agentsd

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/connections"
	"github.com/alexec/agents/Go/internal/forgejomcp"
	"github.com/alexec/agents/Go/wire"
)

// fakeForgeForgejo is Forgejo's lists, item reads and writes, and what each was asked.
type fakeForgeForgejo struct {
	mu       sync.Mutex
	searches []string
	items    []string
	wrote    []string
}

func (f *fakeForgeForgejo) note(to *[]string, s string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	*to = append(*to, s)
}

func (f *fakeForgeForgejo) Search(_ context.Context, repos []string, sf forgejomcp.SearchFilter, after string, first int) (forgejomcp.SearchPage, error) {
	f.note(&f.searches, fmt.Sprintf("%v prs=%v label=%s after=%s first=%d", repos, sf.PRs, sf.Label, after, first))
	page := forgejomcp.SearchPage{}
	for n, repo := range repos {
		page.Items = append(page.Items, forgejomcp.Item{Repo: repo, Number: 7 + n, PR: sf.PRs, State: "open", Title: "On " + repo,
			URL: "http://localhost:3753/" + repo + "/issues/7", Author: "kim", UpdatedAt: "2026-11-07T10:00:00Z",
			Labels: []string{"bug"}, LabelColors: map[string]string{"bug": "#ee0701"}, Mergeable: "unknown"})
		page.Cursors = append(page.Cursors, "c"+repo)
	}
	return page, nil
}

func (f *fakeForgeForgejo) ItemPage(_ context.Context, repo string, number int, pr bool, before string) (forgejomcp.ItemDetail, error) {
	f.note(&f.items, fmt.Sprintf("%s#%d pr=%v before=%s", repo, number, pr, before))
	if number == 404 {
		return forgejomcp.ItemDetail{}, &forgejomcp.ForgejoError{Kind: forgejomcp.NotFound, Message: "not found on Forgejo"}
	}
	d := forgejomcp.ItemDetail{Item: forgejomcp.Item{Repo: repo, Number: number, PR: pr, State: "open", Title: "Export",
		URL: "http://localhost:3753/" + repo + "/issues/" + fmt.Sprint(number), UpdatedAt: "2026-11-07T10:00:00Z"},
		Body: "The body.", Thread: []forgejomcp.Comment{{Author: "renovate-bot", Body: "Hi", At: "2026-11-07T09:00:00Z", Bot: true}}, Before: "1"}
	if pr {
		d.Checks, d.Review, d.Mergeable = "failing", "approved", "mergeable"
		d.CheckRuns = []forgejomcp.CheckRun{{Name: "ci / test", State: "failing", URL: "http://localhost:3753/x/actions/runs/3"}}
		d.Head, d.FilesChanged, d.ReviewThreads = "abc123", 2, 1
	}
	return d, nil
}

func (f *fakeForgeForgejo) Comment(_ context.Context, repo string, number int, body string) (string, error) {
	f.note(&f.wrote, fmt.Sprintf("comment %s#%d %s", repo, number, body))
	return "http://localhost:3753/c/1", nil
}

func (f *fakeForgeForgejo) SetLabels(_ context.Context, repo string, number int, add, remove []string) error {
	f.note(&f.wrote, fmt.Sprintf("labels %s#%d +%v -%v", repo, number, add, remove))
	return nil
}

func (f *fakeForgeForgejo) SetState(_ context.Context, repo string, number int, closed bool) error {
	f.note(&f.wrote, fmt.Sprintf("state %s#%d closed=%v", repo, number, closed))
	return nil
}

func (f *fakeForgeForgejo) RepoLabels(context.Context, string) ([]string, map[string]string, error) {
	return []string{"bug", "docs"}, map[string]string{"bug": "#ee0701"}, nil
}

func (f *fakeForgeForgejo) MergeMethods(context.Context, string) ([]string, error) {
	return []string{"squash", "merge"}, nil
}

func (f *fakeForgeForgejo) Merge(_ context.Context, repo string, number int, sha, method string, auto bool) error {
	f.note(&f.wrote, fmt.Sprintf("merge %s#%d %s %s auto=%v", repo, number, sha, method, auto))
	return nil
}

func (f *fakeForgeForgejo) Approve(_ context.Context, repo string, number int, sha string) (string, error) {
	f.note(&f.wrote, fmt.Sprintf("approve %s#%d %s", repo, number, sha))
	return "http://localhost:3753/r/1", nil
}

func (f *fakeForgeForgejo) PRDiff(_ context.Context, repo string, number int) (map[string]any, error) {
	return map[string]any{"files": []any{map[string]any{"path": "hello.txt", "change": "added", "additions": 1, "deletions": 0,
		"hunks": []any{map[string]any{"oldStart": 0, "newStart": 1, "lines": []any{map[string]any{"kind": "added", "text": "hello"}}}}}}}, nil
}

// forgejoDaemon is a daemon with a folder on the connected Forgejo (localhost:3753), one on
// Codeberg, and one on GitHub, with a Forgejo connection as a fake Forgejo.
func forgejoDaemon(t *testing.T) (*Daemon, *conn, *fakeForgeForgejo, *connections.File) {
	t.Helper()
	t.Setenv("AGENTS_PERSONAL_HOME", t.TempDir())
	d, c := start(t, t.TempDir())
	t.Cleanup(d.Shutdown)
	file := &connections.File{Path: filepath.Join(t.TempDir(), ".agents-secrets", connections.FileName)}
	d.connStoreFor = func() (connections.Store, error) { return file, nil }
	fj := &fakeForgeForgejo{}
	d.newForgeForgejo = func(root, token string) forgeForgejo {
		if root != "http://localhost:3753/" || token != "forgejo-secret" {
			t.Errorf("Forgejo at %q with %q", root, token)
		}
		return fj
	}
	d.newForgeGitHub = func(string) forgeGitHub { return &fakeForgeGitHub{} }
	for i, remote := range []string{"http://localhost:3753/walkalex/App.git", "git@codeberg.org:kim/notes.git", "git@github.com:alexec/agents.git"} {
		c.call(t, 100+i, "folders/add", map[string]any{"folder": "file://" + gitFolder(t, remote)})
	}
	file.Put(connections.Connection{Provider: connections.Forgejo, Login: "walkalex", Access: "forgejo-secret",
		URL: "http://localhost:3753/", ConnectedAt: time.Now()})
	file.Put(connections.Connection{Provider: connections.GitHub, Login: "alexec", Access: "ghu_secret",
		AccessExpiresAt: time.Now().Add(time.Hour), ConnectedAt: time.Now()})
	return d, c, fj, file
}

// #3753: forge/issues and forge/pulls list the repositories on the connected Forgejo, with the
// GitHub folder's, and leave out the Codeberg folder, whose remote is on another Forgejo.
func TestForgeListsTheConnectedForgejosRepositories(t *testing.T) {
	_, c, fj, _ := forgejoDaemon(t)
	var list wire.ForgeList
	json.Unmarshal(c.call(t, 1, "forge/issues", wire.ForgeListRequest{Label: new("bug")}), &list)
	if len(fj.searches) != 1 || fj.searches[0] != "[walkalex/App] prs=false label=bug after= first=50" {
		t.Fatalf("Forgejo was asked %v", fj.searches)
	}
	var item *wire.ForgeItem
	for _, i := range list.Items {
		if strings.HasPrefix(i.Node.Ref, "forgejo:") {
			item = &i
		}
	}
	if item == nil || item.Node != (wire.LineageNode{Kind: "issue", Ref: "forgejo:walkalex/app#7"}) || deref(item.Folder) == "" ||
		item.Labels[0].Name != "bug" || deref(item.Labels[0].Color) != "#ee0701" || item.UpdatedAt == 0 {
		t.Fatalf("the Forgejo item: %+v in %+v", item, list)
	}
	if len(list.Errors) != 0 {
		t.Fatalf("a Forgejo folder elsewhere says nothing while one is on the connected Forgejo: %+v", list.Errors)
	}
	var pulls wire.ForgeList
	json.Unmarshal(c.call(t, 2, "forge/pulls", wire.ForgeListRequest{}), &pulls)
	for _, i := range pulls.Items {
		if i.Node.Ref == "forgejo:walkalex/app#7" && (i.Node.Kind != "pr" || deref(i.Mergeable) != "unknown") {
			t.Fatalf("a Forgejo pull request: %+v", i)
		}
	}
}

// Without a Forgejo connection the list says so for Forgejo, and still lists GitHub's.
func TestForgeListSaysForgejoIsNotConnected(t *testing.T) {
	_, c, fj, file := forgejoDaemon(t)
	file.Delete(connections.Forgejo)
	var list wire.ForgeList
	json.Unmarshal(c.call(t, 1, "forge/issues", wire.ForgeListRequest{}), &list)
	if len(fj.searches) != 0 || len(list.Errors) != 1 || list.Errors[0].Forge != "forgejo" || list.Errors[0].Message != forgejomcp.NotConnected {
		t.Fatalf("list: %+v", list)
	}
}

// forge/issue and forge/pull read a Forgejo item at the connected Forgejo, in the repository as
// its folder's remote says it; Start Agent names the issue; one Forgejo does not have is refused.
func TestForgeReadsAForgejoIssueAndPullRequest(t *testing.T) {
	_, c, fj, _ := forgejoDaemon(t)
	var issue wire.ForgeItemDetail
	json.Unmarshal(c.call(t, 1, "forge/issue", wire.ForgeItemRequest{Node: wire.LineageNode{Kind: "issue", Ref: "forgejo:walkalex/app#7"}}), &issue)
	if issue.Body != "The body." || deref(issue.Cursor) != "1" || len(issue.Comments) != 1 || issue.Comments[0].Bot == nil || issue.Start == nil ||
		!strings.Contains(issue.Start.Prompt, "Work on this Forgejo issue: http://localhost:3753/walkalex/App/issues/7") || issue.Start.Labels[0] != "#7" {
		t.Fatalf("issue: %+v", issue)
	}
	var pr wire.ForgeItemDetail
	json.Unmarshal(c.call(t, 2, "forge/pull", wire.ForgeItemRequest{Node: wire.LineageNode{Kind: "pr", Ref: "forgejo:walkalex/app#8"}}), &pr)
	if deref(pr.Head) != "abc123" || len(pr.Checks) != 1 || *pr.FilesChanged != 2 || len(pr.MergeMethods) != 2 || pr.MergeMethods[0] != "squash" ||
		deref(pr.Item.Review) != "approved" || pr.Start != nil {
		t.Fatalf("pull: %+v", pr)
	}
	if fj.items[0] != "walkalex/App#7 pr=false before=" || fj.items[1] != "walkalex/App#8 pr=true before=" {
		t.Fatalf("Forgejo was asked %v", fj.items)
	}
	for i, n := range []wire.LineageNode{
		{Kind: "issue", Ref: "forgejo:walkalex/app#404"},
		{Kind: "issue", Ref: "forgejo:kim/notes#1"},
		{Kind: "issue", Ref: "forgejo:nobody#1"},
	} {
		if e := c.callError(t, 10+i, "forge/issue", wire.ForgeItemRequest{Node: n}); e == nil || !strings.Contains(e.Message, "forge/issue") {
			t.Fatalf("%s: %v", n.Ref, e)
		}
	}
}

// The Work pages' writes on a Forgejo item go to the connected Forgejo; a merge takes the
// repository's default method; rerun is refused, as Forgejo's API has none.
func TestForgeWritesOnAForgejoItem(t *testing.T) {
	_, c, fj, _ := forgejoDaemon(t)
	issue := wire.LineageNode{Kind: "issue", Ref: "forgejo:walkalex/app#7"}
	pr := wire.LineageNode{Kind: "pr", Ref: "forgejo:walkalex/app#8"}
	var done wire.ForgeDone
	json.Unmarshal(c.call(t, 1, "forge/comment", wire.ForgeCommentRequest{Node: issue, Body: "Done"}), &done)
	if deref(done.URL) != "http://localhost:3753/c/1" {
		t.Fatalf("comment: %+v", done)
	}
	c.call(t, 2, "forge/label", wire.ForgeLabelRequest{Node: issue, Add: []string{"docs"}, Remove: []string{"bug"}})
	c.call(t, 3, "forge/close", wire.ForgeCloseRequest{Node: issue})
	c.call(t, 4, "forge/close", wire.ForgeCloseRequest{Node: pr, Reopen: new(true)})
	c.call(t, 5, "forge/merge", wire.ForgeMergeRequest{Node: pr, Sha: "abc123", Auto: new(true)})
	c.call(t, 6, "forge/approve", wire.ForgeApproveRequest{Node: pr, Sha: "abc123"})
	want := []string{"comment walkalex/App#7 Done", "labels walkalex/App#7 +[docs] -[bug]", "state walkalex/App#7 closed=true",
		"state walkalex/App#8 closed=false", "merge walkalex/App#8 abc123 squash auto=true", "approve walkalex/App#8 abc123"}
	if strings.Join(fj.wrote, "\n") != strings.Join(want, "\n") {
		t.Fatalf("wrote %q", fj.wrote)
	}
	if e := c.callError(t, 7, "forge/merge", wire.ForgeMergeRequest{Node: pr, Sha: "abc123", Method: new(wire.ForgeMergeMethodRebase)}); e == nil ||
		!strings.Contains(e.Message, "squash or merge") {
		t.Fatalf("a method the repository does not allow: %v", e)
	}
	if e := c.callError(t, 8, "forge/rerun", wire.ForgeNodeRequest{Node: pr}); e == nil || !strings.Contains(e.Message, "open the check on Forgejo") {
		t.Fatalf("rerun: %v", e)
	}
	var log wire.ForgeLog
	json.Unmarshal(c.call(t, 9, "forge/log", wire.ForgeLogRequest{Node: pr}), &log)
	if !strings.Contains(log.Text, "open the check on Forgejo") {
		t.Fatalf("log: %+v", log)
	}
	var labels wire.ForgeLabels
	json.Unmarshal(c.call(t, 10, "forge/labels", wire.ForgeNodeRequest{Node: issue}), &labels)
	if len(labels.Labels) != 2 || deref(labels.Labels[0].Color) != "#ee0701" {
		t.Fatalf("labels: %+v", labels)
	}
	var diff wire.ForgeDiff
	json.Unmarshal(c.call(t, 11, "forge/diff", wire.ForgeNodeRequest{Node: pr}), &diff)
	if len(diff.Files) != 1 || diff.Files[0].Path != "hello.txt" || len(diff.Files[0].Hunks[0].Lines) != 1 {
		t.Fatalf("diff: %+v", diff)
	}
}

func TestForgejoOfNode(t *testing.T) {
	for ref, want := range map[string]string{
		"forgejo:walkalex/app#7": "walkalex/app 7",
		"forgejo:a/b#0":          "",
		"forgejo:a#1":            "",
		"forgejo:a/b/c#1":        "",
		"forgejo:/b#1":           "",
		"gitlab:a/b#1":           "",
	} {
		repo, n, ok := forgejoOfNode(wire.LineageNode{Kind: "issue", Ref: ref})
		got := ""
		if ok {
			got = fmt.Sprintf("%s %d", repo, n)
		}
		if got != want {
			t.Errorf("%s: %q, want %q", ref, got, want)
		}
	}
}

// #3834: lineage takes a Forgejo folder's labels and pull request events as Forgejo nodes: a
// folder on the connected Forgejo while it is connected, and a Codeberg folder by its host.
// Nothing is asked of gh or glab about them.
func TestLineageOnAForgejoFolder(t *testing.T) {
	d, _, _, file := forgejoDaemon(t)
	var connected, codeberg string
	for _, f := range d.folderPaths() {
		switch d.folderRepo(f) {
		case forgeRepo{"forgejo", "walkalex/app"}:
			connected = f
		case forgeRepo{"forgejo", "kim/notes"}:
			codeberg = f
		}
	}
	if connected == "" || codeberg == "" {
		t.Fatalf("the Forgejo folders' repos: %v", d.folderPaths())
	}
	branch := "agents/7-fix"
	a := seeded(t, d, connected, func(a *wire.Agent) {
		a.Labels = []wire.SessionLabel{{Value: "#7", Owner: wire.SessionLabelOwnerPerson}}
		a.Worktree = &wire.AgentWorktree{Name: "7-fix", Branch: &branch, Folder: store.FolderURL(connected)}
	})
	d.noteLineage(nil, a)
	s := sessionNode(a.ID)
	d.lineageEvent(wire.Event{Name: "pr.opened", Details: map[string]string{"payload": `{"pr":{"number":8,"branch":"agents/7-fix",` +
		`"url":"http://localhost:3753/walkalex/App/pulls/8","fixes":["#7"]}}`}})
	pr := wire.LineageNode{Kind: "pr", Ref: "forgejo:walkalex/app#8"}
	wantLinks(t, active(d, pr),
		s.Ref+" opens "+pr.Ref+" (branch)",
		pr.Ref+" fixes forgejo:walkalex/app#7 (pr-body)")
	wantLinks(t, active(d, s),
		s.Ref+" works-on forgejo:walkalex/app#7 (start)",
		s.Ref+" opens "+pr.Ref+" (branch)")
	if n, ok := d.labelNode(codeberg, "P#4"); !ok || n != (wire.LineageNode{Kind: "pr", Ref: "forgejo:kim/notes#4"}) {
		t.Fatalf("a Codeberg folder's P#4: %+v", n)
	}
	if _, _, ok := nodeOfRepo(pr); ok {
		t.Fatal("a Forgejo node is asked of gh")
	}

	// Disconnected, the folder is on no forge lineage knows; Codeberg's is by its host.
	file.Delete(connections.Forgejo)
	if r := d.folderRepo(connected); r.forge != "" {
		t.Fatalf("with no Forgejo connection: %+v", r)
	}
	if r := d.folderRepo(codeberg); r != (forgeRepo{"forgejo", "kim/notes"}) {
		t.Fatalf("a Codeberg folder with no connection: %+v", r)
	}
}
