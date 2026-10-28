package controlplane

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"slices"
	"strings"
	"sync"
	"unicode/utf8"

	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// Projects (#2317, specs/2317-projects): what people work on, the record that folders
// join. A machine names each folder's project id (projects/joined); the control plane
// adopts an id it does not know, with the folder's name. Any person makes a project; its
// owner or an admin renames and removes it.

// projectFoldersPrefix holds what each machine last said of its folders, one object a
// machine, written only by that machine's projects/joined.
const projectFoldersPrefix = "v1/projectFolders/"

const (
	mostJoinedFolders = 1000
	mostProjectName   = 80
)

func projectFoldersKey(host string) string { return projectFoldersPrefix + host + ".json" }

type storedProjectFolders struct {
	Folders []wire.JoinedFolder `json:"folders"`
}

// joinedFolders is every machine's folders as it last sent them, by machine. A machine
// that is no longer known is left out. A list whose entity tag has not moved since this
// copy last read it is not read again (#2735): one listing, and a read only for each
// machine whose list changed, at this copy or another.
func (s *Service) joinedFolders(ctx context.Context) (map[string][]wire.JoinedFolder, error) {
	listed, err := s.cfg.Store.List(ctx, projectFoldersPrefix)
	if err != nil {
		return nil, err
	}
	keys := make([]store.Key, 0, len(listed))
	for _, k := range listed {
		if s.records.Host(joinedHost(k.Key)) != nil {
			keys = append(keys, k)
		}
	}
	data, err := s.storeReads.read(ctx, s.cfg.Store, projectFoldersPrefix, listed, keys)
	if err != nil {
		return nil, err
	}
	out := map[string][]wire.JoinedFolder{}
	for i, k := range keys {
		var kept storedProjectFolders
		if data[i] == nil || json.Unmarshal(data[i], &kept) != nil {
			continue
		}
		out[joinedHost(k.Key)] = kept.Folders
	}
	return out, nil
}

func joinedHost(key string) string {
	return strings.TrimSuffix(strings.TrimPrefix(key, projectFoldersPrefix), ".json")
}

func cleanProjectName(name string) (string, error) {
	name = strings.TrimSpace(name)
	if name == "" || utf8.RuneCountInString(name) > mostProjectName {
		return "", fail(invalidParams, "Give the project a name of 1 to %d characters.", mostProjectName)
	}
	return name, nil
}

// projectNames is each project's name in lower case, and its id: what freeProjectName
// tries names against, read once for a machine's new ids (#2735).
func (s *Service) projectNames() map[string]string {
	out := map[string]string{}
	for _, p := range s.records.Projects() {
		out[strings.ToLower(p.Name)] = p.ID
	}
	return out
}

// nameTaken is the project, other than id, already called name in any case.
func (s *Service) nameTaken(name, id string) *records.Project {
	for _, p := range s.records.Projects() {
		if p.ID != id && strings.EqualFold(p.Name, name) {
			return &p
		}
	}
	return nil
}

// freeProjectName is name, or name with " 2", " 3", … when another project in names
// (projectNames) has it. The name it gives is added to names.
func freeProjectName(names map[string]string, name, id string) string {
	if utf8.RuneCountInString(name) > mostProjectName {
		name = string([]rune(name)[:mostProjectName])
	}
	if strings.TrimSpace(name) == "" {
		name = "Project"
	}
	taken := func(try string) bool {
		other, ok := names[strings.ToLower(try)]
		return ok && other != id
	}
	try := name
	for n := 2; taken(try); n++ {
		try = fmt.Sprintf("%s %d", name, n)
	}
	names[strings.ToLower(try)] = id
	return try
}

// keepJoined is projects/joined: the machine's list written over its last, and each id
// that no project has, or a removed one has, adopted with its folder's name (FR-007). Its
// answer is the folders' projects, which the machine then has: host/projects tells it
// again only when they change.
func (s *Service) keepJoined(ctx context.Context, host string, joined wire.ProjectsJoined) (wire.MachineProjects, error) {
	if s.records.Host(host) == nil {
		return wire.MachineProjects{}, fail(noSuchHost, "No machine is called %s.", host)
	}
	if len(joined.Folders) > mostJoinedFolders {
		return wire.MachineProjects{}, fail(invalidParams, "Send at most %d folders.", mostJoinedFolders)
	}
	folders := []wire.JoinedFolder{}
	for _, f := range joined.Folders {
		if !wire.ValidProjectID(f.Project) {
			return wire.MachineProjects{}, fail(invalidParams, "%q is not a project id.", f.Project)
		}
		if utf8.RuneCountInString(f.Name) > 200 {
			f.Name = string([]rune(f.Name)[:200])
		}
		folders = append(folders, f)
	}
	data, err := records.Encode(storedProjectFolders{Folders: folders})
	if err != nil {
		return wire.MachineProjects{}, err
	}
	// Only this machine writes its own list; the same list again changes nothing.
	changed := true
	if before, err := s.cfg.Store.Get(ctx, projectFoldersKey(host)); err == nil && before != nil && bytes.Equal(before.Data, data) {
		changed = false
	} else if _, err := s.cfg.Store.Put(ctx, projectFoldersKey(host), data, store.Always); err != nil {
		return wire.MachineProjects{}, err
	}
	// The ids no project has, each once, adopted in one hold of the write lock (#2735).
	var unknown []string
	names := map[string]string{}
	for _, f := range folders {
		if s.records.Project(f.Project) == nil && !slices.Contains(unknown, f.Project) {
			unknown = append(unknown, f.Project)
			names[f.Project] = f.Name
		}
	}
	if len(unknown) > 0 {
		owner := s.ownerOf(host)
		if owner == "" {
			owner = s.localOwner()
		}
		var taken map[string]string
		err := s.records.ChangeProjects(ctx, unknown, func(id string, p *records.Project) (*records.Project, error) {
			if p != nil && !p.IsRemoved() {
				return nil, nil
			}
			if taken == nil {
				// Read under the lock, after projects were read again.
				taken = s.projectNames()
			}
			changed = true
			if p != nil {
				// A removed id that a folder names again comes back, with its old name.
				next := *p
				next.Removed, next.RemovedAt = nil, nil
				next.Name = freeProjectName(taken, p.Name, p.ID)
				return &next, nil
			}
			return &records.Project{ID: id, Name: freeProjectName(taken, names[id], id), Owner: owner, MadeAt: records.Now()}, nil
		})
		if err != nil {
			return wire.MachineProjects{}, err
		}
	}
	answer := s.machineProjects(folders)
	s.toldProjects.note(host, answer)
	if changed {
		s.projectsChanged("", false)
	}
	return answer, nil
}

// projectsMethod answers projects/list, projects/set, projects/setSlot and projects/remove.
func (m *Methods) projectsMethod(ctx context.Context, method string, params json.RawMessage, from Caller) (any, error) {
	user := m.callerPerson(from)
	admin := m.s.isAdmin(user)
	switch method {
	case "projects/list":
		joined, err := m.s.joinedFolders(ctx)
		if err != nil {
			return nil, err
		}
		return m.s.projectList(user, admin, joined), nil
	case "projects/set":
		request, err := require[wire.ProjectSet](params, "ProjectSet")
		if err != nil {
			return nil, err
		}
		return m.setProject(ctx, request, user, admin)
	case "projects/setSlot":
		request, err := require[wire.ProjectSlotSet](params, "ProjectSlotSet")
		if err != nil {
			return nil, err
		}
		return m.setProjectSlot(ctx, request, user, admin)
	case "projects/remove":
		request, err := require[wire.ProjectRequest](params, "ProjectRequest")
		if err != nil {
			return nil, err
		}
		return wire.Empty{}, m.removeProject(ctx, request.ID, user, admin)
	}
	return nil, notFound(method)
}

// projectList is every project, with its folders: an admin's on every machine, a
// person's on their own machines only, as another person's machines are not theirs to see
// (#1117).
func (s *Service) projectList(user string, admin bool, joined map[string][]wire.JoinedFolder) wire.ProjectList {
	byProject := map[string][]wire.ProjectFolder{}
	for host, folders := range joined {
		if !admin && s.ownerOf(host) != user {
			continue
		}
		for _, f := range folders {
			byProject[f.Project] = append(byProject[f.Project], wire.ProjectFolder{Machine: wire.MachineRef(host), Folder: f.Folder, Name: f.Name})
		}
	}
	out := wire.ProjectList{Projects: []wire.Project{}}
	for _, p := range s.records.Projects() {
		out.Projects = append(out.Projects, projectOnWire(p, byProject[p.ID], admin || p.Owner == user))
	}
	return out
}

func projectOnWire(p records.Project, folders []wire.ProjectFolder, mayChange bool) wire.Project {
	if folders == nil {
		folders = []wire.ProjectFolder{}
	}
	out := wire.Project{ID: p.ID, Name: p.Name, Owner: p.Owner, Folders: folders, MayChange: mayChange}
	if len(p.Slots) > 0 {
		out.Slots = p.Slots
	}
	return out
}

func (m *Methods) setProject(ctx context.Context, request wire.ProjectSet, user string, admin bool) (wire.Project, error) {
	name, err := cleanProjectName(request.Name)
	if err != nil {
		return wire.Project{}, err
	}
	id := deref(request.ID)
	if other := m.s.nameTaken(name, id); other != nil {
		return wire.Project{}, fail(invalidParams, "There is already a project called %s.", other.Name)
	}
	making := id == ""
	if making {
		id = wire.NewProjectID()
	}
	kept, err := m.records.ChangeProject(ctx, id, func(p *records.Project) (*records.Project, error) {
		if making {
			return &records.Project{ID: id, Name: name, Owner: user, MadeAt: records.Now()}, nil
		}
		if p == nil || p.IsRemoved() {
			return nil, fail(invalidParams, "There is no such project.")
		}
		if !admin && p.Owner != user {
			return nil, fail(notPermitted, "Only the project's owner or an admin can change it.")
		}
		next := *p
		next.Name = name
		return &next, nil
	})
	if err != nil {
		return wire.Project{}, err
	}
	m.s.projectsChanged(id, false)
	return projectOnWire(*kept, nil, admin || kept.Owner == user), nil
}

func (m *Methods) removeProject(ctx context.Context, id, user string, admin bool) error {
	p := m.records.Project(id)
	if p == nil {
		return fail(invalidParams, "There is no such project.")
	}
	if !admin && p.Owner != user {
		return fail(notPermitted, "Only the project's owner or an admin can change it.")
	}
	joined, err := m.s.joinedFolders(ctx)
	if err != nil {
		return err
	}
	for _, folders := range joined {
		for _, f := range folders {
			if f.Project == id {
				return fail(notPermitted, "A folder is still in %s. Move its folders to another project first.", p.Name)
			}
		}
	}
	_, err = m.records.ChangeProject(ctx, id, func(p *records.Project) (*records.Project, error) {
		if p == nil || p.IsRemoved() {
			return nil, nil
		}
		yes, now := true, records.Now()
		next := *p
		next.Removed, next.RemovedAt = &yes, &now
		return &next, nil
	})
	if err != nil {
		return err
	}
	m.s.projectsChanged(id, true)
	return nil
}

// projectsChanged tells this copy's clients and machines, and every other copy, that
// projects changed.
func (s *Service) projectsChanged(id string, removed bool) {
	s.tellProjectsChanged(id, removed)
	s.announce("projectsChanged", id, "")
}

func (s *Service) tellProjectsChanged(id string, removed bool) {
	change := wire.ProjectsChanged{}
	if id != "" {
		change.ID = &id
	}
	if removed {
		change.Removed = &removed
	}
	s.router.BroadcastControl(wire.NotifyControlProjectsChanged.Name, change)
	s.toldProjects.soon(s.tellMachinesProjects)
}

// The project's slots (#2669, specs/2317-projects User Story 4): Tasks, Code review and
// CI, one per slot, set by the project's owner or an admin, for every folder in the
// project. A machine gets them in projects/joined's answer, and again (host/projects) when
// a project changes; a slot the project does not set is each folder's own.

// projectSlots is the slots a project may set, in the page's order.
var projectSlots = []wire.ConnectorSlotKind{wire.ConnectorSlotKindTasks, wire.ConnectorSlotKindCodeReview, wire.ConnectorSlotKindCi}

const mostSlotText = 200

// machineProjects is the projects that folders name, with their slots.
func (s *Service) machineProjects(folders []wire.JoinedFolder) wire.MachineProjects {
	out := wire.MachineProjects{Projects: []wire.ProjectTools{}}
	seen := map[string]bool{}
	for _, f := range folders {
		if seen[f.Project] {
			continue
		}
		seen[f.Project] = true
		if p := s.records.Project(f.Project); p != nil {
			slots := p.Slots
			if slots == nil {
				slots = []wire.ProjectSlot{}
			}
			out.Projects = append(out.Projects, wire.ProjectTools{ID: p.ID, Name: p.Name, Slots: slots})
		}
	}
	return out
}

// toldProjects is what each machine here was last sent of its folders' projects, by a
// hash (#2735), so a change tells only the machines whose projects it changed. One send to
// the machines runs at a time; a change while it runs makes one more.
type toldProjects struct {
	mu      sync.Mutex
	last    map[string][sha256.Size]byte
	running bool
	again   bool
}

func projectsSum(m wire.MachineProjects) [sha256.Size]byte {
	b, _ := json.Marshal(m)
	return sha256.Sum256(b)
}

// note is what a machine has now: projects/joined's answer, or a send it took.
func (t *toldProjects) note(host string, m wire.MachineProjects) {
	sum := projectsSum(m)
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.last == nil {
		t.last = map[string][sha256.Size]byte{}
	}
	t.last[host] = sum
}

// same says the machine has m already.
func (t *toldProjects) same(host string, m wire.MachineProjects) bool {
	sum := projectsSum(m)
	t.mu.Lock()
	defer t.mu.Unlock()
	last, ok := t.last[host]
	return ok && last == sum
}

// keepOnly forgets each machine not in hosts: one whose uplink went is told again.
func (t *toldProjects) keepOnly(hosts []string) {
	here := make(map[string]bool, len(hosts))
	for _, host := range hosts {
		here[host] = true
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	for host := range t.last {
		if !here[host] {
			delete(t.last, host)
		}
	}
}

func (t *toldProjects) forget(host string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	delete(t.last, host)
}

// soon runs send, now if none is running, else once more when it ends.
func (t *toldProjects) soon(send func()) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.running {
		t.again = true
		return
	}
	t.running = true
	safe.Go("host/projects", func() {
		defer func() {
			t.mu.Lock()
			t.running = false
			t.mu.Unlock()
		}()
		for {
			send()
			t.mu.Lock()
			again := t.again
			t.again = false
			t.mu.Unlock()
			if !again {
				return
			}
		}
	})
}

// tellMachinesProjects sends each machine on this copy its folders' projects, when they
// are not what it was last sent. No lock is held while it sends.
func (s *Service) tellMachinesProjects() {
	held := s.router.HostsHeldHere()
	s.toldProjects.keepOnly(held)
	if len(held) == 0 {
		return
	}
	joined, err := s.joinedFolders(context.Background())
	if err != nil {
		s.log("projects could not be sent to the machines: " + err.Error())
		return
	}
	for _, host := range held {
		folders, ok := joined[host]
		if !ok {
			continue
		}
		projects := s.machineProjects(folders)
		if s.toldProjects.same(host, projects) {
			continue
		}
		if s.router.Tell(host, wire.NotifyHostProjects.Name, projects) {
			s.toldProjects.note(host, projects)
		} else {
			s.toldProjects.forget(host)
		}
	}
}

// cleanProjectSlot is value as the project keeps it, or why it is not taken.
func cleanProjectSlot(slot wire.ConnectorSlotKind, value *wire.ProjectSlot) (*wire.ProjectSlot, error) {
	if !slices.Contains(projectSlots, slot) {
		return nil, fail(invalidParams, "A project sets only Tasks, Code review and CI.")
	}
	if value == nil {
		return nil, nil
	}
	if value.Slot != "" && value.Slot != slot {
		return nil, fail(invalidParams, "The value is for another slot.")
	}
	if value.Skipped != nil && *value.Skipped {
		yes := true
		return &wire.ProjectSlot{Slot: slot, Skipped: &yes}, nil
	}
	forge := wire.ConnectionProviderGithub
	if value.Forge != nil {
		forge = *value.Forge
	}
	if forge != wire.ConnectionProviderGithub && forge != wire.ConnectionProviderGitlab {
		return nil, fail(invalidParams, "A project's slot is on GitHub or GitLab.")
	}
	repo := strings.Trim(strings.TrimSpace(deref(value.Repository)), "/")
	site := strings.ToLower(strings.TrimSpace(deref(value.Site)))
	if site == "" {
		site = map[wire.ConnectionProvider]string{wire.ConnectionProviderGithub: "github.com", wire.ConnectionProviderGitlab: "gitlab.com"}[forge]
	}
	if forge == wire.ConnectionProviderGithub {
		site = "github.com"
	}
	parts := strings.Split(repo, "/")
	if len(parts) < 2 || (forge == wire.ConnectionProviderGithub && len(parts) != 2) || slices.Contains(parts, "") ||
		utf8.RuneCountInString(repo) > mostSlotText || strings.ContainsAny(repo, " \t\n?#") {
		return nil, fail(invalidParams, "Give the repository as owner/name, or a GitLab group/project.")
	}
	if utf8.RuneCountInString(site) > mostSlotText || strings.ContainsAny(site, "/ \t\n?#@") {
		return nil, fail(invalidParams, "Give the site as a host name, such as gitlab.com.")
	}
	return &wire.ProjectSlot{Slot: slot, Forge: &forge, Repository: &repo, Site: &site}, nil
}

// setProjectSlot is projects/setSlot: only the owner or an admin.
func (m *Methods) setProjectSlot(ctx context.Context, request wire.ProjectSlotSet, user string, admin bool) (wire.Project, error) {
	value, err := cleanProjectSlot(request.Slot, request.Value)
	if err != nil {
		return wire.Project{}, err
	}
	kept, err := m.records.ChangeProject(ctx, request.ID, func(p *records.Project) (*records.Project, error) {
		if p == nil || p.IsRemoved() {
			return nil, fail(invalidParams, "There is no such project.")
		}
		if !admin && p.Owner != user {
			return nil, fail(notPermitted, "Only the project's owner or an admin can change it.")
		}
		next := *p
		next.Slots = nil
		for _, slot := range projectSlots {
			if slot == request.Slot {
				if value != nil {
					next.Slots = append(next.Slots, *value)
				}
				continue
			}
			for _, had := range p.Slots {
				if had.Slot == slot {
					next.Slots = append(next.Slots, had)
				}
			}
		}
		return &next, nil
	})
	if err != nil {
		return wire.Project{}, err
	}
	m.s.projectsChanged(request.ID, false)
	return projectOnWire(*kept, nil, true), nil
}
