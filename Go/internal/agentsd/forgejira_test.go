package agentsd

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"

	"github.com/alexec/agents/Go/internal/jiramcp"
	"github.com/alexec/agents/Go/wire"
)

// fakeForgeJira is Jira's lists, item reads and writes, and what each was asked (#3260).
type fakeForgeJira struct {
	mu       sync.Mutex
	searches []string
	wrote    []string
}

func (f *fakeForgeJira) Search(_ context.Context, projects []string, sf jiramcp.SearchFilter, after string, _ int) (jiramcp.SearchPage, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.searches = append(f.searches, jiramcp.SearchJQL(projects, sf)+" after="+after)
	return jiramcp.SearchPage{Cursors: []string{"~1"}, Items: []jiramcp.Item{
		{Key: "PROJ-7", Project: "PROJ", State: "open", Status: "In Review", Title: "Export the invoices", URL: "https://acme.atlassian.net/browse/PROJ-7",
			Author: "Kim", Milestone: "2.4", Labels: []string{"billing"}, Assignees: []string{"Kim"}, UpdatedAt: "2026-11-01T12:00:00.000Z",
			Comments: 2, Parent: "PROJ-1"},
	}}, nil
}

func (f *fakeForgeJira) ItemPage(_ context.Context, key, before string) (jiramcp.ItemDetail, error) {
	if key == "PROJ-404" {
		return jiramcp.ItemDetail{}, &jiramcp.JiraError{Kind: jiramcp.NotFound, Message: "Jira: Issue does not exist"}
	}
	return jiramcp.ItemDetail{Item: jiramcp.Item{Key: key, Project: "PROJ", State: "open", Status: "To Do", Title: "Export the invoices",
		URL: "https://acme.atlassian.net/browse/" + key, UpdatedAt: "2026-11-01T12:00:00.000Z", SubTotal: 2, SubDone: 1},
		Body: "**Bold** words.", Before: "3",
		Thread:      []jiramcp.Comment{{Author: "Automation for Jira", Body: "Moved.", At: "2026-11-01T12:00:00.000Z", Bot: true}},
		Transitions: []jiramcp.Transition{{ID: "21", Name: "Start Progress", Category: "indeterminate"}, {ID: "31", Name: "Done", Category: "done"}}}, nil
}

func (f *fakeForgeJira) note(s string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.wrote = append(f.wrote, s)
	return nil
}

func (f *fakeForgeJira) Comment(_ context.Context, key, body string) (string, error) {
	return "https://acme.atlassian.net/browse/" + key + "?focusedCommentId=9", f.note("comment " + key + " " + body)
}

func (f *fakeForgeJira) SetLabels(_ context.Context, key string, add, remove []string) error {
	return f.note("labels " + key + " +" + strings.Join(add, ",") + " -" + strings.Join(remove, ","))
}

func (f *fakeForgeJira) Labels(context.Context, string) ([]string, map[string]string, error) {
	return []string{"billing", "ux"}, map[string]string{}, nil
}

func (f *fakeForgeJira) SetState(_ context.Context, key string, closed bool) error {
	return f.note(map[bool]string{true: "close ", false: "reopen "}[closed] + key)
}

func (f *fakeForgeJira) Transition(_ context.Context, key, id string) error {
	return f.note("transition " + key + " " + id)
}

func (f *fakeForgeJira) Plan(_ context.Context, key string) (jiramcp.Plan, error) {
	return jiramcp.Plan{Epic: jiramcp.Item{Key: key, Project: "PROJ", State: "open", Title: "Invoices", SubTotal: 2},
		Children: []jiramcp.PlanChild{
			{Item: jiramcp.Item{Key: "PROJ-8", Project: "PROJ", State: "closed", Title: "Read the invoices"}},
			{Item: jiramcp.Item{Key: "PROJ-9", Project: "PROJ", State: "open", Title: "Write the export"}, BlockedBy: []jiramcp.Ref{{Key: "PROJ-8"}}},
		}}, nil
}

func (f *fakeForgeJira) asked() ([]string, []string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return slices.Clone(f.searches), slices.Clone(f.wrote)
}

// jiraDaemon is forgeDaemon with a folder whose .agents/folder.json names Jira projects, and
// the jira connector's sign-in in the secrets.
func jiraDaemon(t *testing.T) (*Daemon, *conn, *fakeForgeJira, string) {
	t.Helper()
	d, c, _, _ := forgeDaemon(t)
	j := &fakeForgeJira{}
	d.newForgeJira = func(auth jiramcp.Auth) forgeJira {
		if auth.Site != "https://acme.atlassian.net" || !auth.Cloud {
			t.Errorf("Jira auth %+v", auth)
		}
		return j
	}
	app := gitFolder(t, "git@github.com:acme/app.git")
	os.MkdirAll(filepath.Join(app, ".agents"), 0o755)
	os.WriteFile(filepath.Join(app, ".agents", "folder.json"), []byte(`{"jiraProjects": ["proj", "not a project"]}`), 0o644)
	c.call(t, 300, "folders/add", map[string]any{"folder": "file://" + app})
	home := os.Getenv("AGENTS_PERSONAL_HOME")
	os.MkdirAll(filepath.Join(home, ".agents-secrets"), 0o700)
	os.WriteFile(filepath.Join(home, ".agents-secrets", "secrets.env"),
		[]byte("JIRA_URL=https://acme.atlassian.net/\nJIRA_EMAIL=kim@acme.com\nJIRA_API_TOKEN=tok\n"), 0o600)
	return d, c, j, app
}

// #3260: forge/issues reads the Jira projects the folders name, beside GitHub, in the one
// model: a jira: node, the status beside the state, the fix version as the milestone, and the
// folder that names its project. forge/pulls asks Jira nothing.
func TestForgeIssuesReadsTheFoldersJiraProjects(t *testing.T) {
	d, c, j, _ := jiraDaemon(t)
	var list wire.ForgeList
	json.Unmarshal(c.call(t, 1, "forge/issues", wire.ForgeListRequest{Label: new("billing")}), &list)
	searches, _ := j.asked()
	if len(searches) != 1 || searches[0] != `project in ("PROJ") AND statusCategory != 3 AND labels = "billing" ORDER BY updated DESC after=` {
		t.Fatalf("Jira searches: %q", searches)
	}
	var jira *wire.ForgeItem
	for n, i := range list.Items {
		if strings.HasPrefix(i.Node.Ref, "jira:") {
			jira = &list.Items[n]
		}
	}
	if jira == nil || len(list.Errors) != 0 {
		t.Fatalf("list: %+v", list)
	}
	if jira.Node != (wire.LineageNode{Kind: "issue", Ref: "jira:PROJ-7"}) || jira.State != "open" || deref(jira.Status) != "In Review" ||
		deref(jira.Milestone) != "2.4" || deref(jira.Folder) == "" ||
		jira.Comments != 2 || jira.Parent == nil || jira.Parent.Ref != "jira:PROJ-1" || len(jira.Labels) != 1 || jira.Labels[0].Color != nil {
		t.Fatalf("Jira item: %+v", *jira)
	}
	if d.jiraFolder("PROJ") != deref(jira.Folder) {
		t.Fatalf("folder %q, not %q", deref(jira.Folder), d.jiraFolder("PROJ"))
	}
	json.Unmarshal(c.call(t, 2, "forge/pulls", wire.ForgeListRequest{}), &list)
	if searches, _ = j.asked(); len(searches) != 1 {
		t.Fatalf("forge/pulls asked Jira: %q", searches)
	}
}

// #3260: forge/issue reads a Jira issue with its body, comments, transitions and Start Agent;
// one Jira does not have is invalid.
func TestForgeReadsAJiraIssue(t *testing.T) {
	_, c, _, _ := jiraDaemon(t)
	var i wire.ForgeItemDetail
	json.Unmarshal(c.call(t, 1, "forge/issue", wire.ForgeItemRequest{Node: wire.LineageNode{Kind: "issue", Ref: "jira:PROJ-7"}}), &i)
	if i.Body != "**Bold** words." || deref(i.Cursor) != "3" || len(i.Comments) != 1 || i.Comments[0].Bot == nil ||
		deref(i.Item.Status) != "To Do" || deref(i.Item.Folder) == "" || i.Item.Progress == nil {
		t.Fatalf("Jira issue: %+v", i)
	}
	if len(i.Transitions) != 2 || i.Transitions[0].ID != "21" || i.Transitions[0].Name != "Start Progress" || deref(i.Transitions[1].Category) != "done" {
		t.Fatalf("transitions: %+v", i.Transitions)
	}
	if i.Start == nil || !slices.Equal(i.Start.Labels, []string{"PROJ-7"}) || !strings.Contains(i.Start.Prompt, "Work on this Jira issue: https://acme.atlassian.net/browse/PROJ-7") {
		t.Fatalf("start: %+v", i.Start)
	}
	if e := c.callError(t, 2, "forge/issue", wire.ForgeItemRequest{Node: wire.LineageNode{Kind: "issue", Ref: "jira:PROJ-404"}}); e == nil || !strings.Contains(e.Message, "forge/issue") {
		t.Fatalf("PROJ-404: %+v", e)
	}
	if e := c.callError(t, 3, "forge/pull", wire.ForgeItemRequest{Node: wire.LineageNode{Kind: "pr", Ref: "jira:PROJ-7"}}); e == nil || !strings.Contains(e.Message, "forge/pull") {
		t.Fatalf("a Jira pull request: %+v", e)
	}
}

// #3260: a comment, labels, the label choices, a transition, and close and reopen by the
// workflow's own transitions go to Jira; a transition on another forge is invalid.
func TestForgeWritesOnAJiraIssue(t *testing.T) {
	_, c, j, _ := jiraDaemon(t)
	node := wire.LineageNode{Kind: "issue", Ref: "jira:PROJ-7"}
	var done wire.ForgeDone
	json.Unmarshal(c.call(t, 1, "forge/comment", wire.ForgeCommentRequest{Node: node, Body: "On it."}), &done)
	if deref(done.URL) != "https://acme.atlassian.net/browse/PROJ-7?focusedCommentId=9" {
		t.Fatalf("comment: %+v", done)
	}
	c.call(t, 2, "forge/label", wire.ForgeLabelRequest{Node: node, Add: []string{"ux"}, Remove: []string{"billing"}})
	var labels wire.ForgeLabels
	json.Unmarshal(c.call(t, 3, "forge/labels", wire.ForgeNodeRequest{Node: node}), &labels)
	if len(labels.Labels) != 2 || labels.Labels[1].Name != "ux" {
		t.Fatalf("labels: %+v", labels)
	}
	c.call(t, 4, "forge/close", wire.ForgeCloseRequest{Node: node, Transition: new("21")})
	c.call(t, 5, "forge/close", wire.ForgeCloseRequest{Node: node})
	c.call(t, 6, "forge/close", wire.ForgeCloseRequest{Node: node, Reopen: new(true)})
	_, wrote := j.asked()
	want := []string{"comment PROJ-7 On it.", "labels PROJ-7 +ux -billing", "transition PROJ-7 21", "close PROJ-7", "reopen PROJ-7"}
	if !slices.Equal(wrote, want) {
		t.Fatalf("wrote %q, want %q", wrote, want)
	}
	gh := wire.LineageNode{Kind: "issue", Ref: "github:alexec/agents#5"}
	if e := c.callError(t, 7, "forge/close", wire.ForgeCloseRequest{Node: gh, Transition: new("21")}); e == nil || !strings.Contains(e.Message, "forge/close") {
		t.Fatalf("a transition on GitHub: %+v", e)
	}
}

// #3260: with no jira sign-in in the secrets, a Jira read says so; a list still reads the rest.
func TestForgeJiraNotSignedIn(t *testing.T) {
	_, c, _, _ := jiraDaemon(t)
	os.Remove(filepath.Join(os.Getenv("AGENTS_PERSONAL_HOME"), ".agents-secrets", "secrets.env"))
	var list wire.ForgeList
	json.Unmarshal(c.call(t, 1, "forge/issues", wire.ForgeListRequest{}), &list)
	if len(list.Errors) != 1 || list.Errors[0].Forge != "jira" || !strings.Contains(list.Errors[0].Message, "Jira is not signed in") {
		t.Fatalf("errors: %+v", list.Errors)
	}
}

// #3260: a key label is a Jira issue in a folder that names its project, else a Linear one;
// a PR's title and branch name the Jira keys of its folder's projects.
func TestJiraKeysInLabelsTitlesAndBranches(t *testing.T) {
	d, _, _, app := jiraDaemon(t)
	if n, _ := d.labelNode(app, "PROJ-7"); n.Ref != "jira:PROJ-7" {
		t.Fatalf("PROJ-7 in a Jira folder: %+v", n)
	}
	if n, _ := d.labelNode(app, "ENG-4"); n.Ref != "linear:ENG-4" {
		t.Fatalf("ENG-4 in a Jira folder: %+v", n)
	}
	jira := []string{"PROJ"}
	if got := jiraKeys("PROJ-7: Export the invoices (and PROJ-7, ENG-4)", jira); !slices.Equal(got, []string{"PROJ-7"}) {
		t.Fatalf("title keys: %q", got)
	}
	if got := jiraKeys("kim/proj-12-export", jira); !slices.Equal(got, []string{"PROJ-12"}) {
		t.Fatalf("branch keys: %q", got)
	}
	if got := jiraKeys("XPROJ-7 and PROJ-7x", jira); len(got) != 0 {
		t.Fatalf("keys inside words: %q", got)
	}
}

// #3260: forge/plan reads a Jira parent's children in steps, by their Blocks links.
func TestForgePlanReadsAJiraParent(t *testing.T) {
	_, c, _, _ := jiraDaemon(t)
	var plan wire.ForgePlan
	json.Unmarshal(c.call(t, 1, "forge/plan", wire.ForgePlanRequest{Node: wire.LineageNode{Kind: "issue", Ref: "jira:PROJ-7"}}), &plan)
	if plan.Item.Node.Ref != "jira:PROJ-7" || len(plan.Children) != 2 || plan.Children[1].Item.Node.Ref != "jira:PROJ-9" || plan.Children[1].Step != 2 {
		t.Fatalf("plan: %+v", plan)
	}
}
