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

	"github.com/agentloops-dev/agent-loops/Go/internal/agentsd/store"
	"github.com/agentloops-dev/agent-loops/Go/internal/connections"
	"github.com/agentloops-dev/agent-loops/Go/internal/forgejomcp"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// fakeForgeForgejo is Forgejo's lists, item reads and writes, and what each was asked.
type fakeForgeForgejo struct {
	mu       sync.Mutex
	searches []string
	items    []string
	wrote    []string
	// asked is what lineage asked (lineageforgejo_test.go).
	asked []string
	// blocked are the numbers Blockers was asked about (#4242).
	blocked []string
	// parented are the numbers Parents was asked about (#4335).
	parented []string
}

func (f *fakeForgeForgejo) note(to *[]string, s string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	*to = append(*to, s)
}

func (f *fakeForgeForgejo) Search(_ context.Context, repos []string, sf forgejomcp.SearchFilter, after string, first int) (forgejomcp.SearchPage, error) {
	f.note(&f.searches, fmt.Sprintf("%v prs=%v label=%s after=%s first=%d", repos, sf.PRs, sf.Label, after, first))
	page := forgejomcp.SearchPage{}
	labels := []string{"bug"}
	if sf.Label == "epic" {
		labels = []string{"epic", "feature:Export"}
	}
	for n, repo := range repos {
		page.Items = append(page.Items, forgejomcp.Item{Repo: repo, Number: 7 + n, PR: sf.PRs, State: "open", Title: "On " + repo,
			URL: "http://localhost:3753/" + repo + "/issues/7", Author: "kim", UpdatedAt: "2026-11-07T10:00:00Z",
			Labels: labels, LabelColors: map[string]string{"bug": "#ee0701", "feature:Export": "#5319e7"}, Mergeable: "unknown"})
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

func (f *fakeForgeForgejo) SetAssignees(_ context.Context, repo string, number int, add, remove []string) error {
	f.note(&f.wrote, fmt.Sprintf("assignees %s#%d +%v -%v", repo, number, add, remove))
	return nil
}

func (f *fakeForgeForgejo) SetState(_ context.Context, repo string, number int, closed bool) error {
	f.note(&f.wrote, fmt.Sprintf("state %s#%d closed=%v", repo, number, closed))
	return nil
}

func (f *fakeForgeForgejo) RepoLabels(context.Context, string) ([]string, map[string]string, error) {
	return []string{"bug", "docs"}, map[string]string{"bug": "#ee0701", "docs": "0075ca"}, nil
}

func (f *fakeForgeForgejo) MergeMethods(context.Context, string) ([]string, error) {
	return []string{"squash", "merge"}, nil
}

func (f *fakeForgeForgejo) Merge(_ context.Context, repo string, number int, sha, method string, auto bool) error {
	f.note(&f.wrote, fmt.Sprintf("merge %s#%d %s %s auto=%v", repo, number, sha, method, auto))
	return nil
}

func (f *fakeForgeForgejo) CancelAutoMerge(_ context.Context, repo string, number int) error {
	f.note(&f.wrote, fmt.Sprintf("auto-merge off %s#%d", repo, number))
	return nil
}

func (f *fakeForgeForgejo) MarkReady(_ context.Context, repo string, number int) error {
	f.note(&f.wrote, fmt.Sprintf("ready %s#%d", repo, number))
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

func (f *fakeForgeForgejo) Blockers(_ context.Context, repo string, numbers []int) (map[int][]forgejomcp.Ref, error) {
	f.note(&f.blocked, fmt.Sprint(repo, numbers))
	return map[int][]forgejomcp.Ref{numbers[0]: {{Repo: "kim/Notes", Number: 9, PR: true, Open: true}, {Repo: "walkalex/App", Number: 5}}}, nil
}

func (f *fakeForgeForgejo) Parents(_ context.Context, repo string, numbers []int) (map[int]forgejomcp.Ref, error) {
	f.note(&f.parented, fmt.Sprint(repo, numbers))
	return map[int]forgejomcp.Ref{numbers[0]: {Repo: "walkalex/App", Number: 1, Open: true}}, nil
}

func (f *fakeForgeForgejo) Plan(_ context.Context, repo string, number int) (forgejomcp.Plan, error) {
	f.note(&f.items, fmt.Sprintf("plan %s#%d", repo, number))
	if number == 404 {
		return forgejomcp.Plan{}, &forgejomcp.ForgejoError{Kind: forgejomcp.NotFound, Message: "not found on Forgejo"}
	}
	issue := func(n int, state string, labels ...string) forgejomcp.Item {
		return forgejomcp.Item{Repo: repo, Number: n, State: state, Title: fmt.Sprint("Issue ", n), Labels: labels, UpdatedAt: "2026-11-07T10:00:00Z"}
	}
	return forgejomcp.Plan{Epic: issue(number, "open", "epic", "feature:Export"), Children: []forgejomcp.PlanChild{
		{Item: issue(2, "open", "story"), BlockedBy: []forgejomcp.Ref{{Repo: repo, Number: 3}}},
		{Item: issue(3, "closed", "task"), BlockedBy: []forgejomcp.Ref{}},
		{Item: issue(4, "open"), BlockedBy: []forgejomcp.Ref{{Repo: "kim/notes", Number: 9, Open: true}}},
	}}, nil
}

func (f *fakeForgeForgejo) CreateIssue(_ context.Context, repo, title string, labels []string) (int, string, error) {
	f.note(&f.wrote, fmt.Sprintf("create %s %s %v", repo, title, labels))
	return 12, "http://localhost:3753/" + repo + "/issues/12", nil
}

func (f *fakeForgeForgejo) SetBlockedBy(_ context.Context, repo string, number int, blockerRepo string, blockerNumber int, blocked bool) error {
	f.note(&f.wrote, fmt.Sprintf("blocked %s#%d by %s#%d %v", repo, number, blockerRepo, blockerNumber, blocked))
	return nil
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
	if item == nil || item.Node != (wire.LineageNode{Kind: "issue", Ref: "forgejo:issue:walkalex/app#7"}) || deref(item.Folder) == "" ||
		item.Labels[0].Name != "bug" || deref(item.Labels[0].Color) != "#ee0701" || item.UpdatedAt == 0 {
		t.Fatalf("the Forgejo item: %+v in %+v", item, list)
	}
	if len(list.Errors) != 0 {
		t.Fatalf("a Forgejo folder elsewhere says nothing while one is on the connected Forgejo: %+v", list.Errors)
	}
	var pulls wire.ForgeList
	json.Unmarshal(c.call(t, 2, "forge/pulls", wire.ForgeListRequest{}), &pulls)
	for _, i := range pulls.Items {
		if i.Node.Ref == "forgejo:issue:walkalex/app#7" && (i.Node.Kind != "pr" || deref(i.Mergeable) != "unknown") {
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
	json.Unmarshal(c.call(t, 1, "forge/issue", wire.ForgeItemRequest{Node: wire.LineageNode{Kind: "issue", Ref: "forgejo:issue:walkalex/app#7"}}), &issue)
	if issue.Body != "The body." || deref(issue.Cursor) != "1" || len(issue.Comments) != 1 || issue.Comments[0].Bot == nil || issue.Start == nil ||
		!strings.Contains(issue.Start.Prompt, "Work on this Forgejo issue: http://localhost:3753/walkalex/App/issues/7") || issue.Start.Labels[0] != "#7" {
		t.Fatalf("issue: %+v", issue)
	}
	var pr wire.ForgeItemDetail
	json.Unmarshal(c.call(t, 2, "forge/pull", wire.ForgeItemRequest{Node: wire.LineageNode{Kind: "pr", Ref: "forgejo:pr:walkalex/app#8"}}), &pr)
	if deref(pr.Head) != "abc123" || len(pr.Checks) != 1 || *pr.FilesChanged != 2 || len(pr.MergeMethods) != 2 || pr.MergeMethods[0] != "squash" ||
		deref(pr.Item.Review) != "approved" || pr.Start != nil {
		t.Fatalf("pull: %+v", pr)
	}
	if fj.items[0] != "walkalex/App#7 pr=false before=" || fj.items[1] != "walkalex/App#8 pr=true before=" {
		t.Fatalf("Forgejo was asked %v", fj.items)
	}
	for i, n := range []wire.LineageNode{
		{Kind: "issue", Ref: "forgejo:issue:walkalex/app#404"},
		{Kind: "issue", Ref: "forgejo:issue:kim/notes#1"},
		{Kind: "issue", Ref: "forgejo:issue:nobody#1"},
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
	issue := wire.LineageNode{Kind: "issue", Ref: "forgejo:issue:walkalex/app#7"}
	pr := wire.LineageNode{Kind: "pr", Ref: "forgejo:pr:walkalex/app#8"}
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
	if e := c.callError(t, 9, "forge/log", wire.ForgeLogRequest{Node: pr}); e == nil || !strings.Contains(e.Message, "open the check on Forgejo") {
		t.Fatalf("log: %v", e)
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
		"forgejo:issue:walkalex/app#7": "walkalex/app 7",
		"forgejo:issue:a/b#0":          "",
		"forgejo:issue:a#1":            "",
		"forgejo:issue:a/b/c#1":        "",
		"forgejo:issue:/b#1":           "",
		"gitlab:issue:a/b#1":           "",
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

// #3835: a Forgejo epic's plan is the issues it depends on, in steps by their own dependencies;
// a blocker outside the plan is said; the children say the epic is their parent.
func TestForgePlanReadsAForgejoEpic(t *testing.T) {
	_, c, fj, _ := forgejoDaemon(t)
	epic := wire.LineageNode{Kind: "issue", Ref: "forgejo:issue:walkalex/app#1"}
	var plan wire.ForgePlan
	json.Unmarshal(c.call(t, 1, "forge/plan", wire.ForgePlanRequest{Node: epic}), &plan)
	if deref(plan.Item.Level) != "epic" || deref(plan.Item.Feature) != "Export" || plan.Item.Progress == nil ||
		plan.Item.Progress.Done != 1 || plan.Item.Progress.Total != 3 || deref(plan.Item.Folder) == "" {
		t.Fatalf("epic: %+v", plan.Item)
	}
	var got []string
	for _, ch := range plan.Children {
		got = append(got, fmt.Sprintf("%s step=%d level=%s parent=%v outside=%v", ch.Item.Node.Ref, ch.Step, deref(ch.Item.Level),
			ch.Item.Parent != nil && *ch.Item.Parent == epic, ch.BlockedOutside))
	}
	want := []string{
		"forgejo:issue:walkalex/app#3 step=1 level=task parent=true outside=[]",
		"forgejo:issue:walkalex/app#4 step=1 level= parent=true outside=[{issue forgejo:issue:kim/notes#9}]",
		"forgejo:issue:walkalex/app#2 step=2 level=story parent=true outside=[]",
	}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("children:\n%s", strings.Join(got, "\n"))
	}
	if fj.items[0] != "plan walkalex/App#1" {
		t.Fatalf("Forgejo was asked %v", fj.items)
	}
	for i, n := range []wire.LineageNode{{Kind: "issue", Ref: "forgejo:issue:walkalex/app#404"}, {Kind: "issue", Ref: "forgejo:issue:kim/notes#1"}} {
		if e := c.callError(t, 10+i, "forge/plan", wire.ForgePlanRequest{Node: n}); e == nil || !strings.Contains(e.Message, "forge/plan") {
			t.Fatalf("%s: %v", n.Ref, e)
		}
	}
}

// forge/features counts a Forgejo epic under its feature:<name> label.
func TestForgeFeaturesCountForgejoEpics(t *testing.T) {
	_, c, _, _ := forgejoDaemon(t)
	var features wire.ForgeFeatures
	json.Unmarshal(c.call(t, 1, "forge/features", wire.ForgeFeaturesRequest{}), &features)
	var export *wire.ForgeFeature
	for _, f := range features.Features {
		if f.Name == "Export" {
			export = &f
		}
	}
	if export == nil || export.Epics != 1 || export.Open != 1 || deref(export.Color) != "#5319e7" {
		t.Fatalf("features: %+v", features)
	}
}

// Add child makes the Forgejo epic depend on a new issue (in the epic's feature) or one that is
// there; Blocked by makes a child depend on another, or no longer.
func TestForgePlanWritesOnAForgejoEpic(t *testing.T) {
	_, c, fj, _ := forgejoDaemon(t)
	epic := wire.LineageNode{Kind: "issue", Ref: "forgejo:issue:walkalex/app#1"}
	var done wire.ForgeDone
	json.Unmarshal(c.call(t, 1, "forge/add-child", wire.ForgeAddChildRequest{Node: epic, Title: new("Export as CSV"), Level: new("story")}), &done)
	if deref(done.URL) != "http://localhost:3753/walkalex/App/issues/12" {
		t.Fatalf("add child: %+v", done)
	}
	c.call(t, 2, "forge/add-child", wire.ForgeAddChildRequest{Node: epic, Issue: new("#5")})
	c.call(t, 3, "forge/add-child", wire.ForgeAddChildRequest{Node: epic, Issue: new("walkalex/lib#6")})
	c.call(t, 4, "forge/add-child", wire.ForgeAddChildRequest{Node: epic, Issue: new("http://localhost:3753/walkalex/App/issues/7")})
	child := wire.LineageNode{Kind: "issue", Ref: "forgejo:issue:walkalex/app#2"}
	c.call(t, 5, "forge/blocked-by", wire.ForgeBlockedByRequest{Node: child, Add: []wire.LineageNode{{Kind: "issue", Ref: "forgejo:issue:walkalex/app#4"}},
		Remove: []wire.LineageNode{{Kind: "issue", Ref: "forgejo:issue:walkalex/app#3"}}})
	want := []string{"create walkalex/App Export as CSV [story feature:Export]", "blocked walkalex/App#1 by walkalex/App#12 true",
		"blocked walkalex/App#1 by walkalex/app#5 true", "blocked walkalex/App#1 by walkalex/lib#6 true",
		"blocked walkalex/App#1 by walkalex/app#7 true",
		"blocked walkalex/App#2 by walkalex/app#4 true", "blocked walkalex/App#2 by walkalex/app#3 false"}
	if strings.Join(fj.wrote, "\n") != strings.Join(want, "\n") {
		t.Fatalf("wrote:\n%s", strings.Join(fj.wrote, "\n"))
	}
	for i, r := range []struct{ issue, says string }{
		{"#1", "not its own child"},
		{"https://codeberg.org/kim/notes/issues/3", "not an issue on the connected Forgejo"},
		{"ENG-4", "not an issue on the connected Forgejo"},
	} {
		if e := c.callError(t, 10+i, "forge/add-child", wire.ForgeAddChildRequest{Node: epic, Issue: new(r.issue)}); e == nil || !strings.Contains(e.Message, r.says) {
			t.Fatalf("%s: %v", r.issue, e)
		}
	}
	if e := c.callError(t, 20, "forge/blocked-by", wire.ForgeBlockedByRequest{Node: child, Add: []wire.LineageNode{{Kind: "issue", Ref: "github:issue:alexec/agents#1"}}}); e == nil ||
		!strings.Contains(e.Message, "not on the forge") {
		t.Fatalf("a blocker on GitHub: %v", e)
	}
}

// A list narrowed to a board has no Forgejo items: Forgejo's API cannot read its project boards.
func TestABoardLeavesForgejoOut(t *testing.T) {
	d, _, fj, _ := forgejoDaemon(t)
	scope := forgejoScope{root: "http://localhost:3753/", repos: []string{"walkalex/App"}}
	p, err := forgejoForge{d: d}.List(context.Background(), scope, forgeFilter{Board: &forgeBoard{forge: "forgejo"}}, "", 10)
	if err != nil || len(p.items) > 0 || len(fj.searches) > 0 {
		t.Fatalf("a board's list: %+v, %v, searched %v", p, err, fj.searches)
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
	pr := wire.LineageNode{Kind: "pr", Ref: "forgejo:pr:walkalex/app#8"}
	wantLinks(t, active(d, pr),
		s.Ref+" opens "+pr.Ref+" (branch)",
		pr.Ref+" fixes forgejo:issue:walkalex/app#7 (pr-body)")
	wantLinks(t, active(d, s),
		s.Ref+" works-on forgejo:issue:walkalex/app#7 (start)",
		s.Ref+" opens "+pr.Ref+" (branch)")
	if n, ok := d.labelNode(codeberg, "P#4"); !ok || n != (wire.LineageNode{Kind: "pr", Ref: "forgejo:pr:kim/notes#4"}) {
		t.Fatalf("a Codeberg folder's P#4: %+v", n)
	}
	if _, _, ok := nodeOfRepo(pr); ok {
		t.Fatal("a Forgejo node is asked of gh")
	}
	if _, _, ok := askedNode(pr); !ok {
		t.Fatal("a Forgejo node is not asked of its connection")
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
