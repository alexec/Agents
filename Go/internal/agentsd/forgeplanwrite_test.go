package agentsd

import (
	"context"
	"encoding/json"
	"slices"
	"strings"
	"testing"

	"github.com/agentloops-dev/agent-loops/Go/internal/githubmcp"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

func (f *fakeForgeGitHub) CreateIssue(_ context.Context, repo, title string, labels []string) (int, string, error) {
	f.note("create %s %s [%s]", repo, title, strings.Join(labels, ","))
	return 50, "https://github.com/" + repo + "/issues/50", nil
}

func (f *fakeForgeGitHub) AddSubIssue(_ context.Context, repo string, number int, childRepo string, childNumber int) error {
	f.note("sub %s#%d %s#%d", repo, number, childRepo, childNumber)
	return nil
}

func (f *fakeForgeGitHub) SetBlockedBy(_ context.Context, repo string, number int, blockerRepo string, blockerNumber int, blocked bool) error {
	f.note("blocked %s#%d by %s#%d %v", repo, number, blockerRepo, blockerNumber, blocked)
	return nil
}

func (f *fakeForgeLinear) AddChild(_ context.Context, epic, title string, labels []string) (string, string, error) {
	f.note("child %s %s [%s]", epic, title, strings.Join(labels, ","))
	return "ENG-50", "https://linear.app/x/issue/ENG-50", nil
}

func (f *fakeForgeLinear) SetParent(_ context.Context, identifier, epic string) error {
	f.note("parent %s %s", identifier, epic)
	return nil
}

func (f *fakeForgeLinear) SetBlockedBy(_ context.Context, identifier, blocker string, blocked bool) error {
	f.note("blocked %s by %s %v", identifier, blocker, blocked)
	return nil
}

// #3271: Add child makes a new issue with its level and the epic's feature and makes it a
// sub-issue, or moves one that is there under the epic (#12, owner/repo#12 or its URL); Blocked
// by adds and takes off links, each on the forge, and the plan is read again after a write.
func TestPlanWritesGoToGitHub(t *testing.T) {
	_, c, gh, _ := forgeDaemon(t)
	gh.plan = githubmcp.Plan{Epic: planIssue(3265, "open", "epic", "feature:work")}
	epic := wire.LineageNode{Kind: "issue", Ref: "github:issue:alexec/agents#3265"}
	child := wire.LineageNode{Kind: "issue", Ref: "github:issue:alexec/agents#3271"}
	var done wire.ForgeDone
	json.Unmarshal(c.call(t, 1, "forge/add-child", wire.ForgeAddChildRequest{Node: epic, Title: new("  Add a child  "), Level: new("Task")}), &done)
	if done.URL == nil || *done.URL != "https://github.com/alexec/agents/issues/50" {
		t.Fatalf("done: %+v", done)
	}
	c.call(t, 2, "forge/add-child", wire.ForgeAddChildRequest{Node: epic, Issue: new("#3270")})
	c.call(t, 3, "forge/add-child", wire.ForgeAddChildRequest{Node: epic, Issue: new("alexec/Web#9")})
	c.call(t, 4, "forge/add-child", wire.ForgeAddChildRequest{Node: epic, Issue: new("https://github.com/o/r/issues/8")})
	c.call(t, 5, "forge/blocked-by", wire.ForgeBlockedByRequest{Node: child,
		Add: []wire.LineageNode{{Kind: "issue", Ref: "github:issue:alexec/agents#3268"}}, Remove: []wire.LineageNode{{Kind: "issue", Ref: "github:issue:alexec/web#9"}}})
	c.call(t, 6, "forge/plan", wire.ForgePlanRequest{Node: epic})
	want := []string{"create alexec/agents Add a child [task,feature:work]", "sub alexec/agents#3265 alexec/agents#50",
		"sub alexec/agents#3265 alexec/agents#3270", "sub alexec/agents#3265 alexec/web#9", "sub alexec/agents#3265 o/r#8",
		"blocked alexec/agents#3271 by alexec/agents#3268 true", "blocked alexec/agents#3271 by alexec/web#9 false"}
	if got := gh.writes(); !slices.Equal(got, want) {
		t.Fatalf("writes:\n%q\nwant\n%q", got, want)
	}
	gh.mu.Lock()
	plans := gh.plans
	gh.mu.Unlock()
	if plans != 2 {
		t.Fatalf("the plan was read %d times, not again after the writes", plans)
	}
}

// #3271: Linear takes the same: a new child in the epic's team, a child moved by its key or URL,
// a block by key.
func TestPlanWritesGoToLinear(t *testing.T) {
	_, c, _, _, ln, _ := allForgesDaemon(t)
	epic := wire.LineageNode{Kind: "issue", Ref: "linear:issue:eng#ENG-5"}
	c.call(t, 1, "forge/add-child", wire.ForgeAddChildRequest{Node: epic, Title: new("New")})
	c.call(t, 2, "forge/add-child", wire.ForgeAddChildRequest{Node: epic, Issue: new("https://linear.app/acme/issue/eng-7/a-title")})
	c.call(t, 3, "forge/blocked-by", wire.ForgeBlockedByRequest{Node: wire.LineageNode{Kind: "issue", Ref: "linear:issue:eng#ENG-7"},
		Add: []wire.LineageNode{{Kind: "issue", Ref: "linear:issue:eng#ENG-6"}}})
	ln.mu.Lock()
	got := slices.Clone(ln.wrote)
	ln.mu.Unlock()
	want := []string{"child ENG-5 New [feature:Billing]", "parent ENG-7 ENG-5", "blocked ENG-7 by ENG-6 true"}
	if !slices.Equal(got, want) {
		t.Fatalf("writes:\n%q\nwant\n%q", got, want)
	}
}

// #3271: a plan's write says what is wrong with it and asks the forge nothing: no title and no
// issue, both, an unknown level, an issue that is not one, the epic as its own child, a blocker on
// another forge or the child itself, a pull request, GitLab and Jira; and no agent may call one.
func TestPlanWritesRefuseWhatIsWrong(t *testing.T) {
	_, c, gh, _, ln, _ := allForgesDaemon(t)
	epic := wire.LineageNode{Kind: "issue", Ref: "github:issue:alexec/agents#3265"}
	for i, ask := range []struct {
		method string
		params any
	}{
		{"forge/add-child", wire.ForgeAddChildRequest{Node: epic}},
		{"forge/add-child", wire.ForgeAddChildRequest{Node: epic, Title: new("A"), Issue: new("#2")}},
		{"forge/add-child", wire.ForgeAddChildRequest{Node: epic, Title: new("A"), Level: new("epic")}},
		{"forge/add-child", wire.ForgeAddChildRequest{Node: epic, Issue: new("ENG-4")}},
		{"forge/add-child", wire.ForgeAddChildRequest{Node: epic, Issue: new("#3265")}},
		{"forge/add-child", wire.ForgeAddChildRequest{Node: ghPull, Title: new("A")}},
		{"forge/add-child", wire.ForgeAddChildRequest{Node: wire.LineageNode{Kind: "issue", Ref: "linear:issue:eng#ENG-5"}, Issue: new("#4")}},
		{"forge/add-child", wire.ForgeAddChildRequest{Node: wire.LineageNode{Kind: "issue", Ref: "gitlab:issue:group/app#3"}, Title: new("A")}},
		{"forge/blocked-by", wire.ForgeBlockedByRequest{Node: ghIssue}},
		{"forge/blocked-by", wire.ForgeBlockedByRequest{Node: ghIssue, Add: []wire.LineageNode{{Kind: "issue", Ref: "linear:issue:eng#ENG-6"}}}},
		{"forge/blocked-by", wire.ForgeBlockedByRequest{Node: ghIssue, Add: []wire.LineageNode{ghIssue}}},
		{"forge/blocked-by", wire.ForgeBlockedByRequest{Node: ghIssue, Remove: []wire.LineageNode{ghPull}}},
	} {
		if e := c.callError(t, 10+i, ask.method, ask.params); e == nil || !strings.Contains(e.Message, ask.method) {
			t.Fatalf("%d %s: %v", i, ask.method, e)
		}
	}
	if got := gh.writes(); len(got) != 0 {
		t.Fatalf("a refused write asked GitHub: %q", got)
	}
	ln.mu.Lock()
	defer ln.mu.Unlock()
	if len(ln.wrote) != 0 {
		t.Fatalf("a refused write asked Linear: %q", ln.wrote)
	}
	for _, m := range []string{"forge/add-child", "forge/blocked-by"} {
		if RoleAgent.Allows(m) {
			t.Fatalf("an agent may call %s", m)
		}
	}
}
