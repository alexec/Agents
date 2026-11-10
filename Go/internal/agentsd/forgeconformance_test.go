package agentsd

import (
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/connections"
	"github.com/alexec/agents/Go/internal/githubmcp"
	"github.com/alexec/agents/Go/internal/gitlabmcp"
	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/wire"
)

// The conformance test (#4329, #4352): one row for each forge on the interface, each with its
// fake and fixed data (an open issue, a closed issue, an open pull request and a merged one, each
// where the forge has them), and the same checks on every row. A new forge gets its row and
// passes it before it gets its own tests.
//
// The checks of ForgeItemDetail.actions, authorAvatar and stateReason come with the tasks that
// put them on the wire (#4327's tasks 10, 12 and 14).

type conformRow struct {
	name string
	// daemon is a daemon with the forge's fake and its fixed data, and a client on it.
	daemon func(t *testing.T) (*Daemon, *conn)
}

var conformRows = []conformRow{
	{name: "github", daemon: conformGitHubDaemon},
	{name: "gitlab", daemon: conformGitLabDaemon},
}

// conformGitHub is GitHub with four items on alexec/agents, which pages by its cursor.
type conformGitHub struct {
	*fakeForgeGitHub
}

var conformGitHubItems = []githubmcp.Item{
	{Repo: "alexec/agents", Number: 4, PR: true, State: "merged", Title: "Merged", URL: "https://github.com/alexec/agents/pull/4",
		Author: "alexec", Labels: []string{"enhancement"}, LabelColors: map[string]string{"enhancement": "#a2eeef"},
		UpdatedAt: "2026-11-04T10:00:00Z", Comments: 1},
	{Repo: "alexec/agents", Number: 3, PR: true, State: "open", Title: "Open", URL: "https://github.com/alexec/agents/pull/3",
		Author: "alexec", Labels: []string{"bug"}, LabelColors: map[string]string{"bug": "#d73a4a"}, Assignees: []string{"alexec"},
		UpdatedAt: "2026-11-03T10:00:00Z", Checks: "failing"},
	{Repo: "alexec/agents", Number: 2, State: "closed", Title: "Closed", URL: "https://github.com/alexec/agents/issues/2",
		Author: "alexec", UpdatedAt: "2026-11-02T10:00:00Z"},
	{Repo: "alexec/agents", Number: 1, State: "open", Title: "Open issue", URL: "https://github.com/alexec/agents/issues/1",
		Author: "alexec", Labels: []string{"task", "feature:work"}, LabelColors: map[string]string{"task": "#c5def5", "feature:work": "#1d76db"},
		UpdatedAt: "2026-11-01T10:00:00Z", Comments: 2},
}

func (g conformGitHub) Search(_ context.Context, _ []string, sf githubmcp.SearchFilter, after string, first int) (githubmcp.SearchPage, error) {
	var kept []githubmcp.Item
	for _, i := range conformGitHubItems {
		open := i.State == "open"
		if i.PR == sf.PRs && (sf.State == "all" || (sf.State == "closed") != open) {
			kept = append(kept, i)
		}
	}
	from, _ := strconv.Atoi(after)
	var page githubmcp.SearchPage
	for n := from; n < len(kept) && len(page.Items) < first; n++ {
		page.Items = append(page.Items, kept[n])
		page.Cursors = append(page.Cursors, strconv.Itoa(n+1))
	}
	if end := from + len(page.Items); end < len(kept) {
		page.Next = strconv.Itoa(end)
	}
	return page, nil
}

func (g conformGitHub) ItemPage(_ context.Context, _ string, number int, _ string) (githubmcp.ItemDetail, error) {
	for _, i := range conformGitHubItems {
		if i.Number == number {
			d := githubmcp.ItemDetail{Item: i, Body: "The body.",
				Thread: []githubmcp.Comment{{Author: "alexec", Body: "A comment.", At: i.UpdatedAt}}}
			if i.PR {
				d.Head, d.MergeMethods = "abc", []string{"squash"}
				d.CheckRuns = []githubmcp.Check{{Name: "test", State: "failing", URL: "https://github.com/alexec/agents/actions/runs/7"}}
			}
			return d, nil
		}
	}
	return githubmcp.ItemDetail{}, &githubmcp.GitHubError{Kind: githubmcp.NotFound, Message: "not found on GitHub"}
}

func (g conformGitHub) Plan(_ context.Context, _ string, number int) (githubmcp.Plan, error) {
	return githubmcp.Plan{Epic: conformGitHubItems[3]}, nil
}

func (g conformGitHub) CreateIssue(_ context.Context, repo, title string, _ []string) (int, string, error) {
	g.note("create %s %s", repo, title)
	return 9, "https://github.com/" + repo + "/issues/9", nil
}

func (g conformGitHub) AddSubIssue(_ context.Context, repo string, number int, childRepo string, childNumber int) error {
	g.note("sub-issue %s#%d %s#%d", repo, number, childRepo, childNumber)
	return nil
}

func (g conformGitHub) SetBlockedBy(_ context.Context, repo string, number int, blockerRepo string, blockerNumber int, blocked bool) error {
	g.note("blocked-by %s#%d %s#%d %v", repo, number, blockerRepo, blockerNumber, blocked)
	return nil
}

func conformGitHubDaemon(t *testing.T) (*Daemon, *conn) {
	d, c, gh, _ := forgeDaemon(t)
	fake := conformGitHub{gh}
	d.newForgeGitHub = func(string) forgeGitHub { return fake }
	return d, c
}

// conformGitLab is GitLab with four items on Group/App, which pages by its cursor.
type conformGitLab struct {
	*fakeForgeGitLab
}

var conformGitLabItems = []gitlabmcp.Item{
	{Project: "Group/App", Number: 4, MR: true, State: "merged", Title: "Merged", URL: "https://gitlab.com/Group/App/-/merge_requests/4",
		Author: "kim", Labels: []string{"enhancement"}, LabelColors: map[string]string{"enhancement": "#a2eeef"},
		UpdatedAt: "2026-11-04T10:00:00Z", Comments: 1},
	{Project: "Group/App", Number: 3, MR: true, State: "open", Title: "Open", URL: "https://gitlab.com/Group/App/-/merge_requests/3",
		Author: "kim", Labels: []string{"bug"}, LabelColors: map[string]string{"bug": "#d9534f"}, Assignees: []string{"kim"},
		UpdatedAt: "2026-11-03T10:00:00Z", Checks: "failing"},
	{Project: "Group/App", Number: 2, State: "closed", Title: "Closed", URL: "https://gitlab.com/Group/App/-/issues/2",
		Author: "kim", UpdatedAt: "2026-11-02T10:00:00Z"},
	{Project: "Group/App", Number: 1, State: "open", Title: "Open issue", URL: "https://gitlab.com/Group/App/-/issues/1",
		Author: "kim", Labels: []string{"task"}, LabelColors: map[string]string{"task": "#c5def5"},
		UpdatedAt: "2026-11-01T10:00:00Z", Comments: 2},
}

func (g conformGitLab) Search(_ context.Context, _ []string, sf gitlabmcp.SearchFilter, after string, first int) (gitlabmcp.SearchPage, error) {
	var kept []gitlabmcp.Item
	for _, i := range conformGitLabItems {
		open := i.State == "open"
		if i.MR == sf.MRs && (sf.State == "all" || (sf.State == "closed") != open) {
			kept = append(kept, i)
		}
	}
	from, _ := strconv.Atoi(after)
	var page gitlabmcp.SearchPage
	for n := from; n < len(kept) && len(page.Items) < first; n++ {
		page.Items = append(page.Items, kept[n])
		page.Cursors = append(page.Cursors, strconv.Itoa(n+1))
	}
	if end := from + len(page.Items); end < len(kept) {
		page.Next = strconv.Itoa(end)
	}
	return page, nil
}

func (g conformGitLab) ItemPage(_ context.Context, _ string, number int, mr bool, _ string) (gitlabmcp.ItemDetail, error) {
	for _, i := range conformGitLabItems {
		if i.Number == number && i.MR == mr {
			d := gitlabmcp.ItemDetail{Item: i, Body: "The body.",
				Thread: []gitlabmcp.Comment{{Author: "kim", Body: "A comment.", At: i.UpdatedAt}}}
			if i.MR {
				d.Head, d.Pipeline = "abc", 7
				d.CheckRuns = []gitlabmcp.Check{{Name: "test: unit", State: "failing"}}
			}
			return d, nil
		}
	}
	return gitlabmcp.ItemDetail{}, &gitlabmcp.GitLabError{Kind: gitlabmcp.NotFound, Message: "not found on GitLab"}
}

func (g conformGitLab) Plan(_ context.Context, _ string, _ int) (gitlabmcp.Plan, error) {
	return gitlabmcp.Plan{Epic: conformGitLabItems[3]}, nil
}

// conformGitLabDaemon is a daemon with one folder on Group/App on the connected gitlab.com.
func conformGitLabDaemon(t *testing.T) (*Daemon, *conn) {
	t.Helper()
	t.Setenv("AGENTS_PERSONAL_HOME", t.TempDir())
	d, c := start(t, t.TempDir())
	t.Cleanup(d.Shutdown)
	file := &connections.File{Path: filepath.Join(t.TempDir(), ".agents-secrets", connections.FileName)}
	d.connStoreFor = func() (connections.Store, error) { return file, nil }
	fake := conformGitLab{&fakeForgeGitLab{}}
	d.newForgeGitLab = func(string, string) forgeGitLab { return fake }
	c.call(t, 100, "folders/add", map[string]any{"folder": "file://" + gitFolder(t, "git@gitlab.com:Group/App.git")})
	if err := file.Put(connections.Connection{Provider: connections.GitLab, Login: "kim", Access: "gloas-secret", URL: connections.GitLabCom,
		AccessExpiresAt: time.Now().Add(time.Hour), ConnectedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	return d, c
}

// conformList is every item of a forge/issues or forge/pulls list, a page of limit at a time.
func conformList(t *testing.T, c *conn, method string, limit int64) []wire.ForgeItem {
	t.Helper()
	var items []wire.ForgeItem
	var cursor *string
	for n := 0; ; n++ {
		if n > 20 {
			t.Fatalf("%s: the list does not end", method)
		}
		var page wire.ForgeList
		if err := json.Unmarshal(c.call(t, 1000+n, method, wire.ForgeListRequest{State: new("all"), Limit: new(limit), Cursor: cursor}), &page); err != nil {
			t.Fatal(err)
		}
		if len(page.Errors) > 0 {
			t.Fatalf("%s: %+v", method, page.Errors)
		}
		items = append(items, page.Items...)
		if page.Cursor == nil {
			return items
		}
		cursor = page.Cursor
	}
}

var labelColor = regexp.MustCompile(`^#[0-9a-f]{6}$`)

func TestForgeConformance(t *testing.T) {
	for _, row := range conformRows {
		t.Run(row.name, func(t *testing.T) {
			d, c := row.daemon(t)
			var f Forge
			for _, g := range d.forges() {
				if g.Name() == row.name {
					f = g
				}
			}
			if f == nil {
				t.Fatalf("%s is not in the registry", row.name)
			}
			caps := f.Caps()
			ctx := context.Background()

			all := map[bool][]wire.ForgeItem{}
			for _, prs := range []bool{false, true} {
				method := map[bool]string{false: "forge/issues", true: "forge/pulls"}[prs]
				all[prs] = conformList(t, c, method, forgeListMost)
				// 4. The list pages: a limit of 1 gives every item once, by the cursors.
				d.forgeWrote()
				one := conformList(t, c, method, 1)
				if !slices.EqualFunc(one, all[prs], func(a, b wire.ForgeItem) bool { return a.Node == b.Node }) {
					t.Errorf("%s by ones: %v, want %v", method, conformNodes(one), conformNodes(all[prs]))
				}
			}
			// Issues and PRs agree with the kinds that List returns.
			if caps.Issues != (len(all[false]) > 0) || caps.PRs != (len(all[true]) > 0) {
				t.Errorf("caps say issues=%v prs=%v; the lists gave %d and %d", caps.Issues, caps.PRs, len(all[false]), len(all[true]))
			}

			refs := map[string]forgeRef{}
			for prs, items := range all {
				for _, i := range items {
					// 1. The node goes round, and no other forge owns it.
					r, ok := f.Owns(i.Node)
					if !ok || r.Node != i.Node {
						t.Fatalf("Owns(%v) = %+v, %v", i.Node, r, ok)
					}
					if (i.Node.Kind == lineage.KindPR) != prs {
						t.Errorf("%v is in the wrong list", i.Node)
					}
					for _, g := range d.forges() {
						if _, ok := g.Owns(i.Node); ok && g.Name() != f.Name() {
							t.Errorf("%s owns %s's %v too", g.Name(), f.Name(), i.Node)
						}
					}
					detail, err := f.Item(ctx, r, "")
					if err != nil || detail.Item.Node != i.Node {
						t.Fatalf("Item(%v) = %v, %v", i.Node, detail.Item.Node, err)
					}
					// 3. The model is filled.
					for _, m := range []wire.ForgeItem{i, detail.Item} {
						conformModel(t, caps, m)
					}
					refs[i.Node.Kind+" "+i.State] = r
				}
			}

			// 2. Caps agrees with the methods.
			for kind, actions := range map[string]forgeActions{lineage.KindIssue: caps.Issue, lineage.KindPR: caps.PR} {
				r, ok := refs[kind+" open"]
				if !ok {
					continue
				}
				for name, call := range conformActions(f, r) {
					err := call(ctx)
					cannotNow := errors.Is(err, errForgeCannot)
					switch {
					case actions.on(name) && cannotNow:
						t.Errorf("%s %s: caps say yes, the method says %v", kind, name, err)
					case !actions.on(name) && !cannotNow:
						t.Errorf("%s %s: caps say no, the method says %v", kind, name, err)
					case !actions.on(name):
						if cannotReason(f, err) == "" {
							t.Errorf("%s %s: no reason", kind, name)
						}
					}
				}
			}
			if r, ok := refs[lineage.KindIssue+" open"]; ok {
				for name, on := range map[string]bool{actionPlan: caps.Plan, actionAddChild: caps.AddChild, actionBlockedBy: caps.BlockedBy} {
					var err error
					switch name {
					case actionPlan:
						_, err = f.Plan(ctx, r)
					case actionAddChild:
						_, err = f.AddChild(ctx, r, forgeChild{Title: "A child"})
					case actionBlockedBy:
						err = f.SetBlockedBy(ctx, r, refs[lineage.KindIssue+" closed"], true)
					}
					if errors.Is(err, errForgeCannot) == on {
						t.Errorf("issue %s: caps say %v, the method says %v", name, on, err)
					}
				}
			}
		})
	}
}

// conformActions are the writes of forgeActions on r, by name.
func conformActions(f Forge, r forgeRef) map[string]func(context.Context) error {
	return map[string]func(context.Context) error{
		actionComment: func(ctx context.Context) error { _, err := f.Comment(ctx, r, "A comment."); return err },
		actionLabel:   func(ctx context.Context) error { return f.SetLabels(ctx, r, []string{"bug"}, nil) },
		actionClose:   func(ctx context.Context) error { return f.SetState(ctx, r, true, "") },
		actionReopen:  func(ctx context.Context) error { return f.SetState(ctx, r, false, "") },
		actionTransition: func(ctx context.Context) error {
			return f.SetState(ctx, r, true, "31")
		},
		actionMerge:     func(ctx context.Context) error { _, err := f.Merge(ctx, r, "abc", "", false); return err },
		actionAutoMerge: func(ctx context.Context) error { _, err := f.Merge(ctx, r, "abc", "", true); return err },
		actionApprove:   func(ctx context.Context) error { _, err := f.Approve(ctx, r, "abc"); return err },
		actionRerun:     func(ctx context.Context) error { _, err := f.Rerun(ctx, r); return err },
		actionLog:       func(ctx context.Context) error { _, err := f.Log(ctx, r, ""); return err },
		actionDiff:      func(ctx context.Context) error { _, err := f.Diff(ctx, r); return err },
	}
}

func conformModel(t *testing.T, caps forgeCaps, i wire.ForgeItem) {
	t.Helper()
	if i.Labels == nil || i.Assignees == nil {
		t.Errorf("%v: labels %v, assignees %v", i.Node, i.Labels, i.Assignees)
	}
	if i.UpdatedAt == 0 {
		t.Errorf("%v: no updatedAt", i.Node)
	}
	if !slices.Contains([]string{"open", "closed", "merged"}, i.State) {
		t.Errorf("%v: state %q", i.Node, i.State)
	}
	for _, l := range i.Labels {
		if caps.LabelColors && !labelColor.MatchString(deref(l.Color)) {
			t.Errorf("%v: label %s's colour is %q, not #rrggbb", i.Node, l.Name, deref(l.Color))
		}
	}
}

func conformNodes(items []wire.ForgeItem) []string {
	var out []string
	for _, i := range items {
		out = append(out, i.Node.Ref)
	}
	return out
}

// noForge does nothing but say so, as forgeNone makes a forge that has not written a method.
type noForge struct{ forgeNone }

func (noForge) Name() string { return "none" }
func (noForge) Caps() forgeCaps {
	return forgeCaps{Reasons: map[string]string{actionMerge: "this forge has no merge"}}
}
func (noForge) Owns(wire.LineageNode) (forgeRef, bool) { return forgeRef{}, false }
func (noForge) Sources(context.Context, []string, bool) (forgeScope, error) {
	return githubScope{}, nil
}

// #4352: forgeNone says "cannot" for each action, and the answer is Invalid with the forge's own
// reason when Caps gives one, else one that names the action.
func TestForgeNoneCannotAnything(t *testing.T) {
	ctx := context.Background()
	var f Forge = noForge{}
	r := forgeRef{Node: wire.LineageNode{Kind: lineage.KindPR, Ref: "none:a#1"}}
	calls := conformActions(f, r)
	calls[actionPlan] = func(ctx context.Context) error { _, err := f.Plan(ctx, r); return err }
	calls[actionAddChild] = func(ctx context.Context) error { _, err := f.AddChild(ctx, r, forgeChild{}); return err }
	calls[actionBlockedBy] = func(ctx context.Context) error { return f.SetBlockedBy(ctx, r, r, true) }
	calls["labels"] = func(ctx context.Context) error { _, err := f.Labels(ctx, r); return err }
	calls["read"] = func(ctx context.Context) error { _, err := f.Item(ctx, r, ""); return err }
	for name, call := range calls {
		err := call(ctx)
		if !errors.Is(err, errForgeCannot) {
			t.Errorf("%s: %v, not errForgeCannot", name, err)
			continue
		}
		reason := cannotReason(f, err)
		if name == actionMerge && reason != "this forge has no merge" || reason == "" {
			t.Errorf("%s: %q", name, reason)
		}
	}
	if p, err := f.List(ctx, githubScope{}, forgeFilter{}, "", 1); err != nil || len(p.items) > 0 {
		t.Errorf("list: %+v, %v", p, err)
	}
	if by, err := f.Blockers(ctx, []forgeRef{r}); err != nil || len(by) > 0 {
		t.Errorf("blockers: %v, %v", by, err)
	}
	var e *Error
	if !errors.As(forgeCannotErr("forge/x", f, cannot(actionLog)), &e) || e.Code != CodeInvalidParams {
		t.Errorf("cannot is not Invalid: %v", e)
	}
	if other := errors.New("down"); forgeCannotErr("forge/x", f, other) != other {
		t.Error("another error changed")
	}
}

// cannotReason is the reason a person reads when f cannot do what err says, or "".
func cannotReason(f Forge, err error) string {
	var e *Error
	if !errors.As(forgeCannotErr("forge/x", f, err), &e) {
		return ""
	}
	return strings.TrimSpace(strings.TrimPrefix(e.Message, "forge/x:"))
}
