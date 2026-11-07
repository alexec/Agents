package agentsd

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"

	"github.com/alexec/agents/Go/internal/azureboardsmcp"
	"github.com/alexec/agents/Go/wire"
)

// fakeForgeBoards is Azure Boards' lists, item reads and writes, and what each was asked (#3815).
type fakeForgeBoards struct {
	mu       sync.Mutex
	searches []string
	wrote    []string
}

const boardsProjectName = "acme/web app"

func (f *fakeForgeBoards) Search(_ context.Context, projects []string, sf azureboardsmcp.SearchFilter, after string, _ int) (azureboardsmcp.SearchPage, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.searches = append(f.searches, azureboardsmcp.SearchWhere(projects, sf, []string{"Closed"})+" after="+after)
	return azureboardsmcp.SearchPage{Cursors: []string{"acme=1"}, Items: []azureboardsmcp.Item{
		{ID: 12, Project: boardsProjectName, State: "open", Status: "Active", Type: "User Story", Title: "Export the invoices",
			URL: "https://dev.azure.com/acme/web%20app/_workitems/edit/12", Author: "kim@acme.test", Labels: []string{"billing"},
			Assignees: []string{"kim@acme.test"}, UpdatedAt: "2026-11-01T12:00:00.000Z", Comments: 2, Parent: 3},
	}}, nil
}

func (f *fakeForgeBoards) ItemPage(_ context.Context, project string, id int, before string) (azureboardsmcp.ItemDetail, error) {
	if id == 404 {
		return azureboardsmcp.ItemDetail{}, &azureboardsmcp.BoardsError{Kind: azureboardsmcp.NotFound, Message: "Azure Boards: no work item 404"}
	}
	return azureboardsmcp.ItemDetail{Item: azureboardsmcp.Item{ID: id, Project: project, State: "open", Status: "New", Type: "User Story",
		Title: "Export the invoices", URL: fmt.Sprintf("https://dev.azure.com/acme/web%%20app/_workitems/edit/%d", id),
		UpdatedAt: "2026-11-01T12:00:00.000Z", SubTotal: 2},
		Body: "**Bold** words.", Before: "token-2",
		Thread: []azureboardsmcp.ForgeComment{{Author: "Project Collection Build Service (acme)", Body: "Built.", At: "2026-11-01T12:00:00.000Z", Bot: true}},
		Transitions: []azureboardsmcp.Transition{{ID: "Active", Name: "Active", Category: "indeterminate"},
			{ID: "Closed", Name: "Closed", Category: "done"}}}, nil
}

func (f *fakeForgeBoards) note(s string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.wrote = append(f.wrote, s)
	return nil
}

func (f *fakeForgeBoards) Comment(_ context.Context, project string, id int, body string) (string, error) {
	return fmt.Sprintf("https://dev.azure.com/acme/web%%20app/_workitems/edit/%d", id), f.note(fmt.Sprintf("comment %s#%d %s", project, id, body))
}

func (f *fakeForgeBoards) SetTags(_ context.Context, project string, id int, add, remove []string) error {
	return f.note(fmt.Sprintf("tags %s#%d +%s -%s", project, id, strings.Join(add, ","), strings.Join(remove, ",")))
}

func (f *fakeForgeBoards) Labels(context.Context, string, int) ([]string, map[string]string, error) {
	return []string{"billing", "ux"}, map[string]string{}, nil
}

func (f *fakeForgeBoards) SetState(_ context.Context, project string, id int, closed bool) error {
	return f.note(fmt.Sprintf("%s %s#%d", map[bool]string{true: "close", false: "reopen"}[closed], project, id))
}

func (f *fakeForgeBoards) Transition(_ context.Context, project string, id int, state string) error {
	return f.note(fmt.Sprintf("state %s#%d %s", project, id, state))
}

func (f *fakeForgeBoards) Plan(_ context.Context, project string, id int) (azureboardsmcp.Plan, error) {
	return azureboardsmcp.Plan{Epic: azureboardsmcp.Item{ID: id, Project: project, State: "open", Title: "Invoices", SubTotal: 2},
		Children: []azureboardsmcp.PlanChild{
			{Item: azureboardsmcp.Item{ID: 13, Project: project, State: "closed", Title: "Read the invoices"}},
			{Item: azureboardsmcp.Item{ID: 14, Project: project, State: "open", Title: "Write the export"},
				BlockedBy: []azureboardsmcp.Ref{{Project: project, ID: 13}}},
		}}, nil
}

func (f *fakeForgeBoards) AddChild(_ context.Context, project string, parent int, title string, labels []string, level string) (int, string, error) {
	return 15, "https://dev.azure.com/acme/web%20app/_workitems/edit/15",
		f.note(fmt.Sprintf("child %s#%d %q %s %s", project, parent, title, strings.Join(labels, ","), level))
}

func (f *fakeForgeBoards) SetParent(_ context.Context, project string, id, parent int) error {
	return f.note(fmt.Sprintf("parent %s#%d %d", project, id, parent))
}

func (f *fakeForgeBoards) SetBlockedBy(_ context.Context, project string, id, blocker int, blocked bool) error {
	return f.note(fmt.Sprintf("blocked %s#%d %d %v", project, id, blocker, blocked))
}

func (f *fakeForgeBoards) TeamAreas(_ context.Context, project, team string) ([]azureboardsmcp.Area, error) {
	return []azureboardsmcp.Area{{Path: `Web App\Payments`, Under: true}, {Path: "Web App", Under: false}},
		f.note(fmt.Sprintf("areas %s %s", project, team))
}

func (f *fakeForgeBoards) asked() ([]string, []string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return slices.Clone(f.searches), slices.Clone(f.wrote)
}

// boardsDaemon is forgeDaemon with a folder whose .agents/folder.json names an Azure Boards
// project, and the azuredevops connector's token in the secrets.
func boardsDaemon(t *testing.T) (*Daemon, *conn, *fakeForgeBoards, string) {
	t.Helper()
	d, c, _, _ := forgeDaemon(t)
	b := &fakeForgeBoards{}
	d.newForgeAzureBoards = func(base, token string) forgeAzureBoards {
		if base != "https://tfs.acme.test/" || token != "tok" {
			t.Errorf("Azure DevOps at %q with %q", base, token)
		}
		return b
	}
	app := gitFolder(t, "git@github.com:acme/app.git")
	os.MkdirAll(filepath.Join(app, ".agents"), 0o755)
	os.WriteFile(filepath.Join(app, ".agents", "folder.json"), []byte(`{"azureBoardsProjects": ["acme/Web App", "not a project", "a/b/c"]}`), 0o644)
	c.call(t, 300, "folders/add", map[string]any{"folder": "file://" + app})
	home := os.Getenv("AGENTS_PERSONAL_HOME")
	os.MkdirAll(filepath.Join(home, ".agents-secrets"), 0o700)
	os.WriteFile(filepath.Join(home, ".agents-secrets", "secrets.env"),
		[]byte("AZURE_DEVOPS_URL=https://tfs.acme.test/\nAZURE_DEVOPS_TOKEN=tok\n"), 0o600)
	return d, c, b, app
}

var boardsItem = wire.LineageNode{Kind: "issue", Ref: "azureboards:acme/web app#12"}

// #3815: forge/issues reads the Azure Boards projects the folders name, beside GitHub, in the
// one model: an azureboards: node, the state's name beside open or closed, its parent, and the
// folder that names its project. forge/pulls asks Azure Boards nothing.
func TestForgeIssuesReadsTheFoldersAzureBoardsProjects(t *testing.T) {
	d, c, b, app := boardsDaemon(t)
	if got := d.folderBoardsProjects(app); !slices.Equal(got, []string{boardsProjectName}) {
		t.Fatalf("projects: %q", got)
	}
	var list wire.ForgeList
	json.Unmarshal(c.call(t, 1, "forge/issues", wire.ForgeListRequest{Label: new("billing")}), &list)
	searches, _ := b.asked()
	if len(searches) != 1 || searches[0] != `[System.TeamProject] IN ('web app') AND [System.State] NOT IN ('Closed') AND [System.Tags] CONTAINS 'billing' after=` {
		t.Fatalf("Azure Boards searches: %q", searches)
	}
	var item *wire.ForgeItem
	for n, i := range list.Items {
		if strings.HasPrefix(i.Node.Ref, "azureboards:") {
			item = &list.Items[n]
		}
	}
	if item == nil || len(list.Errors) != 0 {
		t.Fatalf("list: %+v", list)
	}
	if item.Node != boardsItem || item.State != "open" || deref(item.Status) != "Active" || deref(item.Folder) != app ||
		item.Comments != 2 || item.Parent == nil || item.Parent.Ref != "azureboards:acme/web app#3" || len(item.Labels) != 1 {
		t.Fatalf("Azure Boards item: %+v", *item)
	}
	json.Unmarshal(c.call(t, 2, "forge/pulls", wire.ForgeListRequest{}), &list)
	if searches, _ = b.asked(); len(searches) != 1 {
		t.Fatalf("forge/pulls asked Azure Boards: %q", searches)
	}
}

// #3815: forge/issue reads a work item with its body, comments, the states it can move to and
// Start Agent, labelled AB#12; one Azure Boards does not have is invalid.
func TestForgeReadsAnAzureBoardsWorkItem(t *testing.T) {
	_, c, _, app := boardsDaemon(t)
	var i wire.ForgeItemDetail
	json.Unmarshal(c.call(t, 1, "forge/issue", wire.ForgeItemRequest{Node: boardsItem}), &i)
	if i.Body != "**Bold** words." || deref(i.Cursor) != "token-2" || len(i.Comments) != 1 || i.Comments[0].Bot == nil ||
		deref(i.Item.Status) != "New" || deref(i.Item.Folder) != app || i.Item.Progress == nil {
		t.Fatalf("work item: %+v", i)
	}
	if len(i.Transitions) != 2 || i.Transitions[0].ID != "Active" || deref(i.Transitions[1].Category) != "done" {
		t.Fatalf("transitions: %+v", i.Transitions)
	}
	if i.Start == nil || !slices.Equal(i.Start.Labels, []string{"AB#12"}) ||
		!strings.Contains(i.Start.Prompt, "Work on this Azure Boards work item: https://dev.azure.com/acme/web%20app/_workitems/edit/12") {
		t.Fatalf("start: %+v", i.Start)
	}
	missing := wire.LineageNode{Kind: "issue", Ref: "azureboards:acme/web app#404"}
	if e := c.callError(t, 2, "forge/issue", wire.ForgeItemRequest{Node: missing}); e == nil || !strings.Contains(e.Message, "forge/issue") {
		t.Fatalf("#404: %+v", e)
	}
	for n, ref := range []string{"azureboards:acme#12", "azureboards:acme/web app#0", "azureboards:acme/web app"} {
		if e := c.callError(t, 3+n, "forge/issue", wire.ForgeItemRequest{Node: wire.LineageNode{Kind: "issue", Ref: ref}}); e == nil {
			t.Fatalf("%s was read", ref)
		}
	}
}

// #3815: a comment, tags, the tag choices, a move to a state, and close and reopen go to Azure
// Boards.
func TestForgeWritesOnAnAzureBoardsWorkItem(t *testing.T) {
	_, c, b, _ := boardsDaemon(t)
	var done wire.ForgeDone
	json.Unmarshal(c.call(t, 1, "forge/comment", wire.ForgeCommentRequest{Node: boardsItem, Body: "On it."}), &done)
	if deref(done.URL) != "https://dev.azure.com/acme/web%20app/_workitems/edit/12" {
		t.Fatalf("comment: %+v", done)
	}
	c.call(t, 2, "forge/label", wire.ForgeLabelRequest{Node: boardsItem, Add: []string{"ux"}, Remove: []string{"billing"}})
	var labels wire.ForgeLabels
	json.Unmarshal(c.call(t, 3, "forge/labels", wire.ForgeNodeRequest{Node: boardsItem}), &labels)
	if len(labels.Labels) != 2 || labels.Labels[1].Name != "ux" {
		t.Fatalf("labels: %+v", labels)
	}
	c.call(t, 4, "forge/close", wire.ForgeCloseRequest{Node: boardsItem, Transition: new("Active")})
	c.call(t, 5, "forge/close", wire.ForgeCloseRequest{Node: boardsItem})
	c.call(t, 6, "forge/close", wire.ForgeCloseRequest{Node: boardsItem, Reopen: new(true)})
	_, wrote := b.asked()
	want := []string{"comment acme/web app#12 On it.", "tags acme/web app#12 +ux -billing", "state acme/web app#12 Active",
		"close acme/web app#12", "reopen acme/web app#12"}
	if !slices.Equal(wrote, want) {
		t.Fatalf("wrote %q, want %q", wrote, want)
	}
}

// #3815: with no Azure DevOps token in the secrets, a read says so; a list still reads the rest.
func TestForgeAzureBoardsNotSignedIn(t *testing.T) {
	_, c, _, _ := boardsDaemon(t)
	os.Remove(filepath.Join(os.Getenv("AGENTS_PERSONAL_HOME"), ".agents-secrets", "secrets.env"))
	var list wire.ForgeList
	json.Unmarshal(c.call(t, 1, "forge/issues", wire.ForgeListRequest{}), &list)
	if len(list.Errors) != 1 || list.Errors[0].Forge != "azureboards" || !strings.Contains(list.Errors[0].Message, "Azure DevOps is not connected") {
		t.Fatalf("errors: %+v", list.Errors)
	}
}

// #3815: forge/plan reads a work item's children in steps, by their predecessors; a new child,
// one that is there, and a blocker go to Azure Boards.
func TestForgePlanOfAnAzureBoardsWorkItem(t *testing.T) {
	_, c, b, _ := boardsDaemon(t)
	var plan wire.ForgePlan
	json.Unmarshal(c.call(t, 1, "forge/plan", wire.ForgePlanRequest{Node: boardsItem}), &plan)
	if plan.Item.Node != boardsItem || len(plan.Children) != 2 || plan.Children[1].Item.Node.Ref != "azureboards:acme/web app#14" || plan.Children[1].Step != 2 {
		t.Fatalf("plan: %+v", plan)
	}
	c.call(t, 2, "forge/add-child", wire.ForgeAddChildRequest{Node: boardsItem, Title: new("Send the export"), Level: new("task")})
	c.call(t, 3, "forge/add-child", wire.ForgeAddChildRequest{Node: boardsItem, Issue: new("AB#20")})
	c.call(t, 4, "forge/add-child", wire.ForgeAddChildRequest{Node: boardsItem, Issue: new("https://dev.azure.com/acme/Web%20App/_workitems/edit/21")})
	other := wire.LineageNode{Kind: "issue", Ref: "azureboards:acme/web app#13"}
	c.call(t, 5, "forge/blocked-by", wire.ForgeBlockedByRequest{Node: boardsItem, Add: []wire.LineageNode{other}})
	_, wrote := b.asked()
	want := []string{`child acme/web app#12 "Send the export" task task`, "parent acme/web app#20 12", "parent acme/web app#21 12",
		"blocked acme/web app#12 13 true"}
	if !slices.Equal(wrote, want) {
		t.Fatalf("wrote %q, want %q", wrote, want)
	}
	for n, r := range []wire.ForgeAddChildRequest{{Node: boardsItem, Issue: new("ENG-4")}, {Node: boardsItem, Issue: new("12")}} {
		if e := c.callError(t, 6+n, "forge/add-child", r); e == nil {
			t.Fatalf("added %s", deref(r.Issue))
		}
	}
	elsewhere := wire.LineageNode{Kind: "issue", Ref: "azureboards:contoso/web#3"}
	if e := c.callError(t, 9, "forge/blocked-by", wire.ForgeBlockedByRequest{Node: boardsItem, Add: []wire.LineageNode{elsewhere}}); e == nil {
		t.Fatal("a blocker in another organization was linked")
	}
}

// #3815: AB#12 is a work item of the folder's first project, as a session's label and in a PR's
// title or branch; a work item's page is its node.
func TestAzureBoardsKeysInLabelsTitlesAndURLs(t *testing.T) {
	d, _, _, app := boardsDaemon(t)
	if n, ok := d.labelNode(app, "AB#12"); !ok || n != boardsItem {
		t.Fatalf("AB#12: %+v", n)
	}
	if _, ok := d.labelNode(t.TempDir(), "AB#12"); ok {
		t.Fatal("AB#12 in a folder with no Azure Boards project")
	}
	if got := boardsKeys("AB#12: Export the invoices (and ab#12, AB#13)"); !slices.Equal(got, []int{12, 13}) {
		t.Fatalf("title keys: %v", got)
	}
	if got := boardsKeys("XAB#12 and AB#12x"); len(got) != 0 {
		t.Fatalf("keys inside words: %v", got)
	}
	for url, want := range map[string]string{
		"https://dev.azure.com/acme/Web%20App/_workitems/edit/12":        boardsItem.Ref,
		"https://tfs.acme.test/DefaultCollection/Web/_workitems/edit/7/": "azureboards:defaultcollection/web#7",
	} {
		if n, _, ok := nodeOfURL(url); !ok || n.Ref != want {
			t.Fatalf("%s: %+v", url, n)
		}
	}
	if refName(boardsItem.Ref, "") != "AB#12" {
		t.Fatalf("name: %q", refName(boardsItem.Ref, ""))
	}
}

// #3816: an Azure Boards board narrows Work to its team: the work items under the team's area
// paths, in its project, on the connected Azure DevOps; a board on another Azure DevOps says
// so; another forge's board asks Azure Boards nothing.
func TestAnAzureBoardsBoardNarrowsWorkToItsTeam(t *testing.T) {
	d, c, b, app := boardsDaemon(t)
	id, _, _ := d.folderProject(app)
	payments := board("Payments", "https://tfs.acme.test/acme/Web%20App/_boards/board/t/Payments", wire.ConnectionProviderAzuredevops,
		"acme/Web App/Payments", "tfs.acme.test")
	shop := board("Shop", "https://tfs.acme.test/acme/Shop/_boards/board/t/Shop%20Team", wire.ConnectionProviderAzuredevops,
		"acme/Shop/Shop Team", "tfs.acme.test")
	cloud := board("Cloud", "https://dev.azure.com/acme/Web%20App/_boards/board/t/Payments", wire.ConnectionProviderAzuredevops,
		"acme/Web App/Payments", "dev.azure.com")
	web := board("Web", "https://github.com/orgs/acme/projects/7", wire.ConnectionProviderGithub, "acme/7", "github.com")
	d.heardProjects(wire.MachineProjects{Projects: []wire.ProjectTools{
		{ID: id, Name: "App", Slots: []wire.ProjectSlot{}, Boards: []wire.ProjectBoard{payments, shop, cloud, web}},
	}})

	var list wire.ForgeList
	json.Unmarshal(c.call(t, 1, "forge/issues", wire.ForgeListRequest{Board: &payments.URL}), &list)
	searches, wrote := b.asked()
	if !slices.Equal(wrote, []string{"areas acme/web app Payments"}) || len(searches) != 1 ||
		searches[0] != `[System.TeamProject] IN ('web app') AND [System.State] NOT IN ('Closed') AND `+
			`([System.AreaPath] UNDER 'Web App\Payments' OR [System.AreaPath] = 'Web App') after=` {
		t.Fatalf("areas %q searches %q", wrote, searches)
	}
	if len(list.Items) != 1 || deref(list.Items[0].Folder) != app || len(list.Errors) != 0 {
		t.Fatalf("list %+v", list)
	}

	// A project no folder names: its work items act from the board's folder.
	json.Unmarshal(c.call(t, 2, "forge/issues", wire.ForgeListRequest{Board: &shop.URL}), &list)
	searches, wrote = b.asked()
	if wrote[len(wrote)-1] != "areas acme/shop Shop Team" || !strings.HasPrefix(searches[len(searches)-1], "[System.TeamProject] IN ('shop')") {
		t.Fatalf("areas %q searches %q", wrote, searches)
	}

	// On another Azure DevOps than the connected one: not read, and the list says why.
	json.Unmarshal(c.call(t, 3, "forge/issues", wire.ForgeListRequest{Board: &cloud.URL}), &list)
	if after, _ := b.asked(); len(after) != len(searches) || len(list.Errors) != 1 || list.Errors[0].Forge != "azureboards" ||
		!strings.Contains(list.Errors[0].Message, "connected at tfs.acme.test") {
		t.Fatalf("searches %q list %+v", after, list)
	}

	// A GitHub board: Azure Boards is not asked.
	c.call(t, 4, "forge/issues", wire.ForgeListRequest{Board: &web.URL})
	if after, _ := b.asked(); len(after) != len(searches) {
		t.Fatalf("a GitHub board asked Azure Boards: %q", after[len(searches):])
	}
}
