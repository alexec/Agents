package controlplane

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

func listedProjects(t *testing.T, s *controllink.Session) []wire.Project {
	t.Helper()
	var listed wire.ProjectList
	json.Unmarshal(call(t, s, "", "projects/list", nil), &listed)
	return listed.Projects
}

func joinFolders(t *testing.T, p *plane, host string, folders ...wire.JoinedFolder) {
	t.Helper()
	params, _ := json.Marshal(wire.ProjectsJoined{Folders: folders})
	if _, err := p.s.methods.HostSaid(host, "projects/joined", params); err != nil {
		t.Fatal(err)
	}
}

// US1, US2 (#2317): a machine names each folder's project id; an id the control plane does
// not know is adopted with the folder's name, owned by the machine's owner; a clone on a
// second machine that names the same id joins it.
func TestAMachinesFolderIdsAreAdopted(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	mac := p.host("MAC")
	box := p.host("BOX")
	_, owner := p.client("Alex's Mac")

	joinFolders(t, p, mac.member.Host, wire.JoinedFolder{Folder: "file:///Users/a/Agents/", Name: "Agents", Project: "p-agents"})
	waitNote(t, owner, "control/projectsChanged")
	got := listedProjects(t, owner)
	if len(got) != 1 || got[0].ID != "p-agents" || got[0].Name != "Agents" || !got[0].MayChange || len(got[0].Folders) != 1 {
		t.Fatalf("%+v", got)
	}
	// The same repository cloned on another machine: one project, two folders.
	joinFolders(t, p, box.member.Host, wire.JoinedFolder{Folder: "file:///home/a/Agents/", Name: "Agents", Project: "p-agents"},
		wire.JoinedFolder{Folder: "file:///home/a/agents-2/", Name: "agents", Project: "p-other"})
	got = listedProjects(t, owner)
	if len(got) != 2 || got[0].Name != "Agents" || len(got[0].Folders) != 2 {
		t.Fatalf("%+v", got)
	}
	// A clash of names, in any case, gets a number.
	if got[1].ID != "p-other" || got[1].Name != "agents 2" {
		t.Fatalf("%+v", got[1])
	}
	// Not an id: refused, nothing kept.
	params, _ := json.Marshal(wire.ProjectsJoined{Folders: []wire.JoinedFolder{{Folder: "file:///x/", Name: "x", Project: "no spaces"}}})
	if _, err := p.s.methods.HostSaid(mac.member.Host, "projects/joined", params); err == nil {
		t.Fatal("a bad id was kept")
	}
}

// US2, US3 (#2317): make, rename and remove; removal is refused while a folder names the
// project; a removed id that a folder names again comes back with its old name.
func TestMakeRenameAndRemoveAProject(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	mac := p.host("MAC")
	_, owner := p.client("Alex's Mac")

	var made wire.Project
	json.Unmarshal(call(t, owner, "", "projects/set", wire.ProjectSet{Name: "  Agents app "}), &made)
	if !strings.HasPrefix(made.ID, "p-") || len(made.ID) != 14 || made.Name != "Agents app" || !made.MayChange {
		t.Fatalf("%+v", made)
	}
	if e := callError(t, owner, "", "projects/set", wire.ProjectSet{Name: "AGENTS APP"}); !strings.Contains(e, "already a project") {
		t.Fatal(e)
	}
	if e := callError(t, owner, "", "projects/set", wire.ProjectSet{Name: " "}); !strings.Contains(e, "1 to 80") {
		t.Fatal(e)
	}
	renamed := "Agents"
	call(t, owner, "", "projects/set", wire.ProjectSet{ID: &made.ID, Name: renamed})
	if got := listedProjects(t, owner); len(got) != 1 || got[0].Name != renamed {
		t.Fatalf("%+v", got)
	}

	joinFolders(t, p, mac.member.Host, wire.JoinedFolder{Folder: "file:///Users/a/Agents/", Name: "Agents", Project: made.ID})
	if e := callError(t, owner, "", "projects/remove", wire.ProjectRequest{ID: made.ID}); !strings.Contains(e, "Move its folders") {
		t.Fatal(e)
	}
	joinFolders(t, p, mac.member.Host)
	call(t, owner, "", "projects/remove", wire.ProjectRequest{ID: made.ID})
	if got := listedProjects(t, owner); len(got) != 0 {
		t.Fatalf("%+v", got)
	}
	// An offline machine's clone names it later: it comes back.
	joinFolders(t, p, mac.member.Host, wire.JoinedFolder{Folder: "file:///Users/a/clone/", Name: "clone", Project: made.ID})
	if got := listedProjects(t, owner); len(got) != 1 || got[0].ID != made.ID || got[0].Name != renamed {
		t.Fatalf("%+v", got)
	}
}

// US3 AS3 (#2317, #1117): a member makes and joins projects; only the owner or an admin
// renames or removes one; a member sees the folders on their own machines only.
func TestOnlyTheOwnerOrAnAdminChangesAProject(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	_, owner := p.client("Alex's Mac")
	sam := p.invite(owner, "Sam", wire.UserRoleMember)
	kim := p.invite(owner, "Kim", wire.UserRoleMember)
	samsBox := p.machine(sam, "Sam's box")

	var mine wire.Project
	json.Unmarshal(call(t, sam.window, "", "projects/set", wire.ProjectSet{Name: "Sam's"}), &mine)
	if mine.Owner != sam.id || !mine.MayChange {
		t.Fatalf("%+v", mine)
	}
	joinFolders(t, p, samsBox.member.Host, wire.JoinedFolder{Folder: "file:///home/sam/app/", Name: "app", Project: mine.ID})

	name := "Kim's now"
	if e := callError(t, kim.window, "", "projects/set", wire.ProjectSet{ID: &mine.ID, Name: name}); !strings.Contains(e, "owner or an admin") {
		t.Fatal(e)
	}
	if e := callError(t, kim.window, "", "projects/remove", wire.ProjectRequest{ID: mine.ID}); !strings.Contains(e, "owner or an admin") {
		t.Fatal(e)
	}
	// Kim sees the project, not Sam's machine's folder in it, and may not change it.
	if got := listedProjects(t, kim.window); len(got) != 1 || got[0].MayChange || len(got[0].Folders) != 0 {
		t.Fatalf("%+v", got)
	}
	if got := listedProjects(t, sam.window); len(got) != 1 || len(got[0].Folders) != 1 {
		t.Fatalf("%+v", got)
	}
	// The admin may.
	call(t, owner, "", "projects/set", wire.ProjectSet{ID: &mine.ID, Name: "Renamed by admin"})
	if got := listedProjects(t, owner); len(got) != 1 || !got[0].MayChange || len(got[0].Folders) != 1 || got[0].Name != "Renamed by admin" {
		t.Fatalf("%+v", got)
	}
}
