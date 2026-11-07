package controlplane

import (
	"encoding/json"
	"strings"
	"sync"
	"testing"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// #3282: a board's address names its forge and the board there, in one form.
func TestABoardsAddressNamesItsForge(t *testing.T) {
	t.Parallel()
	for _, c := range []struct{ address, url, forge, key, site string }{
		{"https://github.com/orgs/acme/projects/7/views/2?filterQuery=x", "https://github.com/orgs/acme/projects/7", "github", "acme/7", "github.com"},
		{"https://github.com/users/sam/projects/3/", "https://github.com/users/sam/projects/3", "github", "sam/3", "github.com"},
		{"https://acme.atlassian.net/jira/software/projects/WEB/boards/12", "https://acme.atlassian.net/jira/software/projects/WEB/boards/12", "atlassian", "12", "acme.atlassian.net"},
		{"https://acme.atlassian.net/jira/software/c/projects/WEB/boards/12/backlog", "https://acme.atlassian.net/jira/software/c/projects/WEB/boards/12", "atlassian", "12", "acme.atlassian.net"},
		{"https://jira.acme.com/secure/RapidBoard.jspa?rapidView=40&view=planning", "https://jira.acme.com/secure/RapidBoard.jspa?rapidView=40", "atlassian", "40", "jira.acme.com"},
		{"https://linear.app/acme/team/eng/active", "https://linear.app/acme/team/ENG", "linear", "ENG", "linear.app"},
		{"https://gitlab.com/groups/acme/web/-/boards/5", "https://gitlab.com/groups/acme/web/-/boards/5", "gitlab", "acme/web#5", "gitlab.com"},
		{"https://GitLab.Acme.com/groups/platform/-/boards/9?label_name[]=x", "https://gitlab.acme.com/groups/platform/-/boards/9", "gitlab", "platform#9", "gitlab.acme.com"},
		// #3816: a team's Azure Boards board or backlog, on dev.azure.com, *.visualstudio.com or a server.
		{"https://dev.azure.com/acme/Web%20App/_boards/board/t/Web%20App%20Team/Stories", "https://dev.azure.com/acme/Web%20App/_boards/board/t/Web%20App%20Team", "azuredevops", "acme/Web App/Web App Team", "dev.azure.com"},
		{"https://dev.azure.com/acme/Web%20App/_backlogs/backlog/Payments/Backlog%20items/?showParents=true", "https://dev.azure.com/acme/Web%20App/_boards/board/t/Payments", "azuredevops", "acme/Web App/Payments", "dev.azure.com"},
		{"https://acme.visualstudio.com/Web%20App/_boards/board/t/Payments", "https://dev.azure.com/acme/Web%20App/_boards/board/t/Payments", "azuredevops", "acme/Web App/Payments", "dev.azure.com"},
		{"https://ado.acme.com/DefaultCollection/Shop/_boards/board/t/Shop%20Team/Issues", "https://ado.acme.com/DefaultCollection/Shop/_boards/board/t/Shop%20Team", "azuredevops", "DefaultCollection/Shop/Shop Team", "ado.acme.com"},
	} {
		b, ok := boardFromAddress(c.address)
		if !ok || b.URL != c.url || string(*b.Forge) != c.forge || *b.Key != c.key || *b.Site != c.site {
			t.Errorf("%s: %+v %v", c.address, b, ok)
		}
	}
	for _, bad := range []string{"", "acme/7", "ftp://github.com/orgs/acme/projects/7", "https://github.com/acme/Agents",
		"https://github.com/orgs/acme/projects/x", "https://linear.app/acme/issue/ENG-1", "https://gitlab.com/acme/web/-/boards/5",
		"https://example.com/boards/3", "https://u:p@github.com/orgs/acme/projects/7",
		"https://dev.azure.com/acme/Web%20App/_boards/board/t/", "https://dev.azure.com/acme/_boards/board/t/Payments",
		"https://dev.azure.com/acme/Web%20App/_boards/board/t/A%2FB", "https://dev.azure.com/acme/Web%20App/_workitems/edit/12"} {
		if b, ok := boardFromAddress(bad); ok {
			t.Errorf("%s: %+v", bad, b)
		}
	}
}

// #3282: the owner or an admin sets a project's boards, all of them each time; a machine
// hears them with its folders' projects; a member who is neither may not set them; a bad
// address, a name missing, a board twice and too many are refused.
func TestAProjectsBoardsGoToItsMachines(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	var mu sync.Mutex
	var heard []wire.MachineProjects
	p.told = func(host, method string, params json.RawMessage) {
		if method != wire.NotifyMachineProjects.Name {
			return
		}
		var m wire.MachineProjects
		json.Unmarshal(params, &m)
		mu.Lock()
		heard = append(heard, m)
		mu.Unlock()
	}
	_, owner := p.client("Alex's Mac")
	sam := p.invite(owner, "Sam", wire.UserRoleMember)
	mac := p.host("MAC")

	var made wire.Project
	json.Unmarshal(call(t, owner, "", "projects/set", wire.ProjectSet{Name: "Agents"}), &made)
	params, _ := json.Marshal(wire.ProjectsJoined{Folders: []wire.JoinedFolder{{Folder: "file:///Users/a/Agents/", Name: "Agents", Project: made.ID}}})
	if _, err := p.s.methods.HostSaid(mac.member.Host, "projects/joined", params); err != nil {
		t.Fatal(err)
	}

	set := wire.ProjectBoardsSet{ID: made.ID, Boards: []wire.ProjectBoard{
		{Name: " Web ", URL: "https://github.com/orgs/acme/projects/7/views/1"},
		{Name: "Platform", URL: "https://linear.app/acme/team/plat"},
	}}
	if e := callError(t, sam.window, "", "projects/setBoards", set); !strings.Contains(e, "owner or an admin") {
		t.Fatal(e)
	}
	var got wire.Project
	json.Unmarshal(call(t, owner, "", "projects/setBoards", set), &got)
	if len(got.Boards) != 2 || got.Boards[0].Name != "Web" || got.Boards[0].URL != "https://github.com/orgs/acme/projects/7" ||
		*got.Boards[1].Key != "PLAT" {
		t.Fatalf("%+v", got)
	}
	if listed := listedProjects(t, owner); len(listed[0].Boards) != 2 {
		t.Fatalf("%+v", listed)
	}
	waitFor(t, func() bool {
		mu.Lock()
		defer mu.Unlock()
		return len(heard) > 0 && len(heard[len(heard)-1].Projects) == 1 && len(heard[len(heard)-1].Projects[0].Boards) == 2
	})

	for _, c := range []struct {
		boards []wire.ProjectBoard
		says   string
	}{
		{[]wire.ProjectBoard{{Name: "Web", URL: "https://github.com/acme/Agents"}}, "is not the address"},
		{[]wire.ProjectBoard{{Name: " ", URL: "https://linear.app/acme/team/ENG"}}, "a name"},
		{[]wire.ProjectBoard{{Name: "A", URL: "https://linear.app/acme/team/ENG"}, {Name: "B", URL: "https://linear.app/acme/team/eng/"}}, "twice"},
		{make([]wire.ProjectBoard, mostBoards+1), "at most"},
	} {
		if e := callError(t, owner, "", "projects/setBoards", wire.ProjectBoardsSet{ID: made.ID, Boards: c.boards}); !strings.Contains(e, c.says) {
			t.Errorf("%q: %s", c.says, e)
		}
	}

	// None leaves Tasks with no boards.
	var none wire.Project
	json.Unmarshal(call(t, owner, "", "projects/setBoards", wire.ProjectBoardsSet{ID: made.ID, Boards: []wire.ProjectBoard{}}), &none)
	if none.ID != made.ID || len(none.Boards) != 0 || len(listedProjects(t, owner)[0].Boards) != 0 {
		t.Fatalf("%+v", none)
	}
}
