package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/agentloops-dev/agents/Go/internal/jiramcp"
	"github.com/agentloops-dev/agents/Go/wire"
)

// board is a project's board as the control plane keeps it.
func board(name, url string, forge wire.ConnectionProvider, key, site string) wire.ProjectBoard {
	return wire.ProjectBoard{Name: name, URL: url, Forge: &forge, Key: &key, Site: &site}
}

// #3282: forge/boards lists the boards of the folders' projects, each once; forge/issues'
// board reads only that board, on its own forge: GitHub's project: in the project's repos,
// a GitLab group board's scope in the group's projects, a Linear team, a Jira board's filter;
// a board no folder's project has lists nothing and asks no forge.
func TestABoardNarrowsWorkToItsForge(t *testing.T) {
	d, c, gh, gl, ln, _ := allForgesDaemon(t)
	j := &fakeForgeJira{}
	d.newForgeJira = func(jiramcp.Auth) forgeJira { return j }
	home := os.Getenv("AGENTS_PERSONAL_HOME")
	os.MkdirAll(filepath.Join(home, ".agents-secrets"), 0o700)
	os.WriteFile(filepath.Join(home, ".agents-secrets", "secrets.env"),
		[]byte("JIRA_URL=https://acme.atlassian.net/\nJIRA_EMAIL=kim@acme.com\nJIRA_API_TOKEN=tok\n"), 0o600)

	// The folders on alexec/agents are in one project; the GitLab folder on Group/App in another.
	var agents, app []string
	for _, f := range d.folderPaths() {
		switch strings.ToLower(d.folderRepo(f).path) {
		case "alexec/agents":
			agents = append(agents, f)
		case "group/app":
			app = append(app, f)
		}
	}
	if len(agents) != 2 || len(app) != 1 {
		t.Fatalf("agents %v app %v", agents, app)
	}
	agentsID, _, _ := d.folderProject(agents[0])
	for _, f := range agents[1:] {
		writeFolderProject(t, f, agentsID)
	}
	appID, _, _ := d.folderProject(app[0])
	webBoard := board("Web", "https://github.com/orgs/acme/projects/7", wire.ConnectionProviderGithub, "acme/7", "github.com")
	platform := board("Platform", "https://linear.app/acme/team/PLAT", wire.ConnectionProviderLinear, "PLAT", "linear.app")
	teamA := board("Team A", "https://gitlab.com/groups/Group/-/boards/5", wire.ConnectionProviderGitlab, "Group#5", "gitlab.com")
	billing := board("Billing", "https://acme.atlassian.net/jira/software/projects/PROJ/boards/12", wire.ConnectionProviderAtlassian, "12", "acme.atlassian.net")
	d.heardProjects(wire.MachineProjects{Projects: []wire.ProjectTools{
		{ID: agentsID, Name: "Agents", Slots: []wire.ProjectSlot{}, Boards: []wire.ProjectBoard{webBoard}},
		{ID: appID, Name: "App", Slots: []wire.ProjectSlot{}, Boards: []wire.ProjectBoard{platform, teamA, billing}},
	}})

	var boards wire.ForgeBoards
	json.Unmarshal(c.call(t, 1, "forge/boards", wire.ForgeBoardsRequest{}), &boards)
	var urls []string
	for _, b := range boards.Boards {
		urls = append(urls, b.URL)
	}
	slices.Sort(urls)
	if want := []string{billing.URL, webBoard.URL, teamA.URL, platform.URL}; !slices.Equal(urls, want) {
		t.Fatalf("boards %v, want %v", urls, want)
	}
	json.Unmarshal(c.call(t, 2, "forge/boards", wire.ForgeBoardsRequest{Folder: &app[0]}), &boards)
	if len(boards.Boards) != 3 || boards.Boards[0].Name != "Platform" {
		t.Fatalf("app's boards %+v", boards.Boards)
	}

	ghBefore, _ := gh.asked()
	var list wire.ForgeList
	json.Unmarshal(c.call(t, 3, "forge/issues", wire.ForgeListRequest{Board: &webBoard.URL}), &list)
	searches, _ := gh.asked()
	if len(searches) != len(ghBefore)+1 || !strings.HasPrefix(searches[len(searches)-1], "alexec/agents is:issue is:open repo:alexec/agents project:acme/7") {
		t.Fatalf("GitHub searches %q", searches)
	}
	if len(gl.searches) != 0 || len(ln.searches) != 0 || len(j.searches) != 0 || len(list.Items) == 0 {
		t.Fatalf("gitlab %q linear %q jira %q items %+v", gl.searches, ln.searches, j.searches, list.Items)
	}

	json.Unmarshal(c.call(t, 4, "forge/issues", wire.ForgeListRequest{Board: &platform.URL}), &list)
	if !slices.Equal(ln.searches, []string{"PLAT after="}) || len(list.Items) != 1 || deref(list.Items[0].Folder) != app[0] {
		t.Fatalf("linear %q items %+v", ln.searches, list.Items)
	}

	json.Unmarshal(c.call(t, 5, "forge/issues", wire.ForgeListRequest{Board: &teamA.URL}), &list)
	if !slices.Equal(gl.searches, []string{"Group/App after= board=team-a@0.17"}) || len(list.Items) != 2 {
		t.Fatalf("gitlab %q items %+v", gl.searches, list.Items)
	}

	json.Unmarshal(c.call(t, 6, "forge/issues", wire.ForgeListRequest{Board: &billing.URL}), &list)
	if len(j.searches) != 1 || !strings.HasPrefix(j.searches[0], "filter = 10040 AND statusCategory != 3") ||
		len(list.Items) != 1 || deref(list.Items[0].Folder) != app[0] {
		t.Fatalf("jira %q items %+v", j.searches, list.Items)
	}

	// A board of no folder's project, here or in a folder not in its project: nothing, and no forge asked.
	other := "https://github.com/orgs/acme/projects/99"
	before, _ := gh.asked()
	json.Unmarshal(c.call(t, 7, "forge/issues", wire.ForgeListRequest{Board: &other}), &list)
	var narrowed wire.ForgeList
	json.Unmarshal(c.call(t, 8, "forge/issues", wire.ForgeListRequest{Board: &webBoard.URL, Folder: &app[0]}), &narrowed)
	after, _ := gh.asked()
	if len(list.Items) != 0 || len(narrowed.Items) != 0 || len(after) != len(before) {
		t.Fatalf("other board %+v, app's folder %+v, searches %q", list, narrowed, after[len(before):])
	}

	// Features: only the epics on the board.
	gh.mu.Lock()
	gh.epics = nil
	gh.mu.Unlock()
	before, _ = gh.asked()
	c.call(t, 9, "forge/features", wire.ForgeFeaturesRequest{Board: &webBoard.URL})
	searches, _ = gh.asked()
	searches = searches[len(before):]
	epics := slices.IndexFunc(searches, func(s string) bool { return strings.Contains(s, `label:"epic"`) })
	if epics < 0 || !strings.Contains(searches[epics], "project:acme/7") {
		t.Fatalf("features searches %q", searches)
	}
}

// writeFolderProject puts folder in project id, as the Project picker writes it.
func writeFolderProject(t *testing.T, folder, id string) {
	t.Helper()
	os.MkdirAll(filepath.Join(folder, ".agents"), 0o755)
	path := filepath.Join(folder, ".agents", "folder.json")
	m := map[string]any{}
	if b, err := os.ReadFile(path); err == nil {
		json.Unmarshal(b, &m)
	}
	m["project"] = id
	b, _ := json.Marshal(m)
	if err := os.WriteFile(path, b, 0o644); err != nil {
		t.Fatal(err)
	}
}
