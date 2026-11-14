package controlplane

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/agentloops-dev/agents/Go/internal/controllink"
	"github.com/agentloops-dev/agents/Go/internal/controlplane/records"
	"github.com/agentloops-dev/agents/Go/internal/controlplane/store"
	"github.com/agentloops-dev/agents/Go/wire"
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
	// None yet; and the window, having asked, is told of changes.
	if got := listedProjects(t, owner); len(got) != 0 {
		t.Fatalf("%+v", got)
	}

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
	// A removed machine's folder list goes with it (#3125).
	call(t, owner, "", "machines/remove", map[string]string{"host": box.member.Host})
	if o, _ := p.store.Get(context.Background(), projectFoldersKey(box.member.Host)); o != nil {
		t.Fatal("a removed machine's folders stayed")
	}
	if o, _ := p.store.Get(context.Background(), projectFoldersKey(mac.member.Host)); o == nil {
		t.Fatal("another machine's folders went")
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

// US4 (#2669): the owner or an admin sets a project's Tasks, Code review and CI; a machine
// gets its folders' projects' slots in projects/joined's answer and again in machine/projects
// when one changes; a member who is neither may not set them.
func TestAProjectsSlotsGoToItsMachines(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	var mu sync.Mutex
	heard := map[string][]wire.MachineProjects{}
	p.told = func(host, method string, params json.RawMessage) {
		if method != wire.NotifyMachineProjects.Name {
			return
		}
		var m wire.MachineProjects
		json.Unmarshal(params, &m)
		mu.Lock()
		heard[host] = append(heard[host], m)
		mu.Unlock()
	}
	_, owner := p.client("Alex's Mac")
	sam := p.invite(owner, "Sam", wire.UserRoleMember)
	mac := p.host("MAC")
	other := p.host("OTHER")

	var made wire.Project
	json.Unmarshal(call(t, owner, "", "projects/set", wire.ProjectSet{Name: "Agents"}), &made)
	params, _ := json.Marshal(wire.ProjectsJoined{Folders: []wire.JoinedFolder{{Folder: "file:///Users/a/Agents/", Name: "Agents", Project: made.ID}}})
	answer, err := p.s.methods.HostSaid(mac.member.Host, "projects/joined", params)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(answer)
	var first wire.MachineProjects
	json.Unmarshal(b, &first)
	if len(first.Projects) != 1 || first.Projects[0].ID != made.ID || len(first.Projects[0].Slots) != 0 {
		t.Fatalf("%s", b)
	}

	forge, repo := wire.ConnectionProviderGithub, " alexec/Agents/ "
	set := wire.ProjectSlotSet{ID: made.ID, Slot: wire.ConnectorSlotKindCodeReview, Value: &wire.ProjectSlot{Slot: wire.ConnectorSlotKindCodeReview, Forge: &forge, Repository: &repo}}
	if e := callError(t, sam.window, "", "projects/setSlot", set); !strings.Contains(e, "owner or an admin") {
		t.Fatal(e)
	}
	var got wire.Project
	json.Unmarshal(call(t, owner, "", "projects/setSlot", set), &got)
	if len(got.Slots) != 1 || *got.Slots[0].Repository != "alexec/Agents" || *got.Slots[0].Site != "github.com" {
		t.Fatalf("%+v", got)
	}
	yes := true
	call(t, owner, "", "projects/setSlot", wire.ProjectSlotSet{ID: made.ID, Slot: wire.ConnectorSlotKindTasks, Value: &wire.ProjectSlot{Slot: wire.ConnectorSlotKindTasks, Skipped: &yes}})
	if listed := listedProjects(t, owner); len(listed[0].Slots) != 2 || listed[0].Slots[0].Slot != wire.ConnectorSlotKindTasks {
		t.Fatalf("%+v", listed)
	}
	// Each machine hears its own folders' projects: the Mac this one, the other none.
	waitFor(t, func() bool {
		mu.Lock()
		defer mu.Unlock()
		list := heard[mac.member.Host]
		return len(list) > 0 && len(list[len(list)-1].Projects) == 1 && len(list[len(list)-1].Projects[0].Slots) == 2
	})
	mu.Lock()
	for _, m := range heard[other.member.Host] {
		if len(m.Projects) != 0 {
			t.Fatalf("%+v", m)
		}
	}
	mu.Unlock()

	// No value gives the slot back to each folder; workspace and bad repositories are refused.
	json.Unmarshal(call(t, owner, "", "projects/setSlot", wire.ProjectSlotSet{ID: made.ID, Slot: wire.ConnectorSlotKindCodeReview}), &got)
	if len(got.Slots) != 1 || got.Slots[0].Slot != wire.ConnectorSlotKindTasks {
		t.Fatalf("%+v", got)
	}
	if e := callError(t, owner, "", "projects/setSlot", wire.ProjectSlotSet{ID: made.ID, Slot: wire.ConnectorSlotKindWorkspace}); !strings.Contains(e, "only Tasks") {
		t.Fatal(e)
	}
	bad := "just-a-name"
	if e := callError(t, owner, "", "projects/setSlot", wire.ProjectSlotSet{ID: made.ID, Slot: wire.ConnectorSlotKindCi, Value: &wire.ProjectSlot{Slot: wire.ConnectorSlotKindCi, Repository: &bad}}); !strings.Contains(e, "owner/name") {
		t.Fatal(e)
	}
	// A Forgejo repository (#3752): owner/name, on Codeberg when no site is given.
	forgejo, fjRepo := wire.ConnectionProviderForgejo, "agentstest/agents-walk"
	json.Unmarshal(call(t, owner, "", "projects/setSlot", wire.ProjectSlotSet{ID: made.ID, Slot: wire.ConnectorSlotKindCi,
		Value: &wire.ProjectSlot{Slot: wire.ConnectorSlotKindCi, Forge: &forgejo, Repository: &fjRepo}}), &got)
	if len(got.Slots) != 2 || *got.Slots[1].Forge != forgejo || *got.Slots[1].Site != "codeberg.org" {
		t.Fatalf("%+v", got)
	}
	// A Bitbucket repository (#3785): workspace/name, always on bitbucket.org.
	bitbucket, bbRepo, elsewhere := wire.ConnectionProviderBitbucket, "agentstest/agents-walk", "bitbucket.example.com"
	json.Unmarshal(call(t, owner, "", "projects/setSlot", wire.ProjectSlotSet{ID: made.ID, Slot: wire.ConnectorSlotKindCodeReview,
		Value: &wire.ProjectSlot{Slot: wire.ConnectorSlotKindCodeReview, Forge: &bitbucket, Repository: &bbRepo, Site: &elsewhere}}), &got)
	var review *wire.ProjectSlot
	for i := range got.Slots {
		if got.Slots[i].Slot == wire.ConnectorSlotKindCodeReview {
			review = &got.Slots[i]
		}
	}
	if review == nil || *review.Forge != bitbucket || *review.Site != "bitbucket.org" {
		t.Fatalf("%+v", got)
	}
	deep := "group/sub/app"
	if e := callError(t, owner, "", "projects/setSlot", wire.ProjectSlotSet{ID: made.ID, Slot: wire.ConnectorSlotKindCi,
		Value: &wire.ProjectSlot{Slot: wire.ConnectorSlotKindCi, Forge: &forgejo, Repository: &deep}}); !strings.Contains(e, "owner/name") {
		t.Fatal(e)
	}
}

// waitFor waits up to five seconds for ok.
func waitFor(t *testing.T, ok func() bool) {
	t.Helper()
	for deadline := time.Now().Add(5 * time.Second); !ok(); time.Sleep(10 * time.Millisecond) {
		if time.Now().After(deadline) {
			t.Fatal("not in time")
		}
	}
}

// prefixReads counts the store's reads and listings under each of two prefixes.
type prefixReads struct {
	store.Store
	folderGets, projectLists atomic.Int64
}

func (c *prefixReads) Get(ctx context.Context, key string) (*store.Object, error) {
	if strings.HasPrefix(key, projectFoldersPrefix) {
		c.folderGets.Add(1)
	}
	return c.Store.Get(ctx, key)
}

func (c *prefixReads) List(ctx context.Context, prefix string) ([]store.Key, error) {
	if prefix == records.ProjectsPrefix {
		c.projectLists.Add(1)
	}
	return c.Store.List(ctx, prefix)
}

// #2735: a project change reads no machine's folder list that has not changed, and tells
// only the machines whose projects it changed; a machine's new ids are adopted in one
// pass, each with a free name.
func TestAProjectChangeReadsAndTellsOnlyWhatChanged(t *testing.T) {
	t.Parallel()
	st := &prefixReads{Store: store.NewMemory()}
	p := startPlane(t, st, controllink.NewPrivateKey())
	var mu sync.Mutex
	heard := map[string]int{}
	p.told = func(host, method string, params json.RawMessage) {
		if method == wire.NotifyMachineProjects.Name {
			mu.Lock()
			heard[host]++
			mu.Unlock()
		}
	}
	_, owner := p.client("Alex's Mac")
	mac, box := p.host("MAC"), p.host("BOX")
	settled := func() {
		t.Helper()
		waitFor(t, func() bool {
			p.s.toldProjects.mu.Lock()
			defer p.s.toldProjects.mu.Unlock()
			return !p.s.toldProjects.running
		})
	}

	// Fifty folders on the box, fifty new ids of one name: one read of the projects, and
	// fifty names.
	var many []wire.JoinedFolder
	for i := range 50 {
		many = append(many, wire.JoinedFolder{Folder: wire.URL(fmt.Sprintf("file:///home/a/app-%d/", i)), Name: "app", Project: fmt.Sprintf("p-app%d", i)})
	}
	before := st.projectLists.Load()
	joinFolders(t, p, box.member.Host, many...)
	if lists := st.projectLists.Load() - before; lists > 2 {
		t.Fatalf("the projects were listed %d times for one join", lists)
	}
	names := map[string]bool{}
	for _, project := range listedProjects(t, owner) {
		names[project.Name] = true
	}
	if len(names) != 50 || !names["app"] || !names["app 50"] {
		t.Fatalf("%v", names)
	}
	joinFolders(t, p, mac.member.Host, wire.JoinedFolder{Folder: "file:///Users/a/Agents/", Name: "Agents", Project: "p-agents"})
	settled()
	// Each machine has its projects from its own answer: nothing more to send.
	mu.Lock()
	if heard[mac.member.Host] != 0 || heard[box.member.Host] != 0 {
		t.Fatalf("told after their own answers: %v", heard)
	}
	mu.Unlock()

	// A rename of the Mac's project: the Mac is told, the box is not, and no folder list
	// is read again.
	st.folderGets.Store(0)
	id := "p-agents"
	call(t, owner, "", "projects/set", wire.ProjectSet{ID: &id, Name: "Agents app"})
	waitFor(t, func() bool { mu.Lock(); defer mu.Unlock(); return heard[mac.member.Host] == 1 })
	settled()
	p.s.tellMachinesProjects()
	listedProjects(t, owner)
	mu.Lock()
	if heard[mac.member.Host] != 1 || heard[box.member.Host] != 0 {
		t.Fatalf("%v", heard)
	}
	mu.Unlock()
	if gets := st.folderGets.Load(); gets != 0 {
		t.Fatalf("%d folder lists read again", gets)
	}
}

// #2711: one person's project records are bounded. Ids past the bound are not adopted, and
// projects/set refuses a new one.
func TestAPersonsProjectsAreBounded(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	mac := p.host("MAC")
	_, owner := p.client("Alex's Mac")
	folders := make([]wire.JoinedFolder, 0, mostOwnedProjects+1)
	for n := range mostOwnedProjects + 1 {
		folders = append(folders, wire.JoinedFolder{Folder: wire.URL(fmt.Sprintf("file:///x/%d/", n)), Name: fmt.Sprint(n), Project: fmt.Sprintf("p-%d", n)})
	}
	joinFolders(t, p, mac.member.Host, folders...)
	if got := listedProjects(t, owner); len(got) != mostOwnedProjects {
		t.Fatalf("%d projects", len(got))
	}
	if e := callError(t, owner, "", "projects/set", wire.ProjectSet{Name: "One more"}); !strings.Contains(e, "Remove one first") {
		t.Fatal(e)
	}
}

// #3276: projects/sessions asks each of the caller's machines that has a folder of the
// project for its sessions in it, keeps only those that say the project, newest first,
// each with its machine, and says which machines it could not reach.
func TestAProjectsSessionsOnEveryMachine(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	mac, box, off := p.host("MAC"), p.host("BOX"), p.host("OFF")
	_, window := p.client("Window")
	joinFolders(t, p, mac.member.Host, wire.JoinedFolder{Folder: "file:///Users/a/Agents/", Name: "Agents", Project: "p-agents"})
	joinFolders(t, p, box.member.Host, wire.JoinedFolder{Folder: "file:///home/a/Agents/", Name: "Agents", Project: "p-agents"},
		wire.JoinedFolder{Folder: "file:///home/a/www/", Name: "www", Project: "p-www"})
	joinFolders(t, p, off.member.Host, wire.JoinedFolder{Folder: "file:///work/Agents/", Name: "Agents", Project: "p-agents"})
	off.stop()

	var asked []wire.ListRequest
	var askedMu sync.Mutex
	answer := func(list []map[string]any) func(json.RawMessage) any {
		return func(params json.RawMessage) any {
			var r wire.ListRequest
			json.Unmarshal(params, &r)
			askedMu.Lock()
			asked = append(asked, r)
			askedMu.Unlock()
			return list
		}
	}
	mac.mu.Lock()
	mac.agents = answer([]map[string]any{{"id": "A1", "cwd": "file:///Users/a/Agents/", "state": "running", "lastActivityAt": 10, "project": "p-agents"}})
	mac.mu.Unlock()
	box.mu.Lock()
	// B2 is in another project, and B3 is from a machine too old to say one: neither is listed.
	box.agents = answer([]map[string]any{
		{"id": "B1", "cwd": "file:///home/a/Agents/", "state": "finished", "lastActivityAt": 20, "project": "p-agents"},
		{"id": "B2", "cwd": "file:///home/a/www/", "state": "running", "lastActivityAt": 30, "project": "p-www"},
		{"id": "B3", "cwd": "file:///home/a/Agents/", "state": "running", "lastActivityAt": 40},
	})
	box.mu.Unlock()

	var got wire.ProjectSessions
	json.Unmarshal(call(t, window, "", "projects/sessions", map[string]any{"project": "p-agents"}), &got)
	if len(got.Sessions) != 2 || got.Sessions[0].Session.ID != "B1" || got.Sessions[1].Session.ID != "A1" {
		t.Fatalf("%+v", got.Sessions)
	}
	if got.Sessions[0].Machine != wire.MachineRef(box.member.Host) || got.Sessions[0].MachineName != "box BOX" ||
		got.Sessions[1].Machine != wire.MachineRef(mac.member.Host) {
		t.Fatalf("%+v", got.Sessions)
	}
	if len(got.Unreached) != 1 || got.Unreached[0].Machine != wire.MachineRef(off.member.Host) || got.Unreached[0].MachineName != "box OFF" {
		t.Fatalf("%+v", got.Unreached)
	}
	// Each machine was asked once, lean, for the project's sessions alone.
	askedMu.Lock()
	defer askedMu.Unlock()
	if len(asked) != 2 {
		t.Fatalf("%+v", asked)
	}
	for _, r := range asked {
		if !r.Lean || r.Project == nil || *r.Project != "p-agents" || r.IncludeArchived || r.Limit == nil {
			t.Fatalf("%+v", r)
		}
	}

	// A project no machine has a folder of: nothing, and nobody asked.
	got = wire.ProjectSessions{}
	json.Unmarshal(call(t, window, "", "projects/sessions", map[string]any{"project": "p-none"}), &got)
	if len(got.Sessions) != 0 || len(got.Unreached) != 0 {
		t.Fatalf("%+v", got)
	}
	if e := callError(t, window, "", "projects/sessions", map[string]any{"project": "not an id"}); !strings.Contains(e, "not a project id") {
		t.Fatal(e)
	}
}
