package controlplane

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"slices"
	"strings"
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
// that is no longer known is left out.
func (s *Service) joinedFolders(ctx context.Context) (map[string][]wire.JoinedFolder, error) {
	keys, err := s.cfg.Store.List(ctx, projectFoldersPrefix)
	if err != nil {
		return nil, err
	}
	out := map[string][]wire.JoinedFolder{}
	for _, k := range keys {
		host := strings.TrimSuffix(strings.TrimPrefix(k.Key, projectFoldersPrefix), ".json")
		if s.records.Host(host) == nil {
			continue
		}
		object, err := s.cfg.Store.Get(ctx, k.Key)
		if err != nil {
			return nil, err
		}
		if object == nil {
			continue
		}
		var kept storedProjectFolders
		if json.Unmarshal(object.Data, &kept) != nil {
			continue
		}
		out[host] = kept.Folders
	}
	return out, nil
}

func cleanProjectName(name string) (string, error) {
	name = strings.TrimSpace(name)
	if name == "" || utf8.RuneCountInString(name) > mostProjectName {
		return "", fail(invalidParams, "Give the project a name of 1 to %d characters.", mostProjectName)
	}
	return name, nil
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

// freeProjectName is name, or name with " 2", " 3", … when another project has it.
func (s *Service) freeProjectName(name, id string) string {
	if utf8.RuneCountInString(name) > mostProjectName {
		name = string([]rune(name)[:mostProjectName])
	}
	if strings.TrimSpace(name) == "" {
		name = "Project"
	}
	try := name
	for n := 2; s.nameTaken(try, id) != nil; n++ {
		try = fmt.Sprintf("%s %d", name, n)
	}
	return try
}

// keepJoined is projects/joined: the machine's list written over its last, and each id
// that no project has, or a removed one has, adopted with its folder's name (FR-007).
func (s *Service) keepJoined(ctx context.Context, host string, joined wire.ProjectsJoined) error {
	if s.records.Host(host) == nil {
		return fail(noSuchHost, "No machine is called %s.", host)
	}
	if len(joined.Folders) > mostJoinedFolders {
		return fail(invalidParams, "Send at most %d folders.", mostJoinedFolders)
	}
	folders := []wire.JoinedFolder{}
	for _, f := range joined.Folders {
		if !wire.ValidProjectID(f.Project) {
			return fail(invalidParams, "%q is not a project id.", f.Project)
		}
		if utf8.RuneCountInString(f.Name) > 200 {
			f.Name = string([]rune(f.Name)[:200])
		}
		folders = append(folders, f)
	}
	data, err := records.Encode(storedProjectFolders{Folders: folders})
	if err != nil {
		return err
	}
	// Only this machine writes its own list; the same list again changes nothing.
	changed := true
	if before, err := s.cfg.Store.Get(ctx, projectFoldersKey(host)); err == nil && before != nil && bytes.Equal(before.Data, data) {
		changed = false
	} else if _, err := s.cfg.Store.Put(ctx, projectFoldersKey(host), data, store.Always); err != nil {
		return err
	}
	owner := s.ownerOf(host)
	if owner == "" {
		owner = s.localOwner()
	}
	for _, f := range folders {
		if s.records.Project(f.Project) != nil {
			continue
		}
		name := f.Name
		_, err := s.records.ChangeProject(ctx, f.Project, func(p *records.Project) (*records.Project, error) {
			if p != nil && !p.IsRemoved() {
				return nil, nil
			}
			if p != nil {
				// A removed id that a folder names again comes back, with its old name.
				next := *p
				next.Removed, next.RemovedAt = nil, nil
				next.Name = s.freeProjectName(p.Name, p.ID)
				return &next, nil
			}
			return &records.Project{ID: f.Project, Name: s.freeProjectName(name, f.Project), Owner: owner, MadeAt: records.Now()}, nil
		})
		if err != nil {
			return err
		}
		changed = true
	}
	if changed {
		s.projectsChanged("", false)
	}
	return nil
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
	safe.Go("host/projects", s.tellMachinesProjects)
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

// tellMachinesProjects sends each machine on this copy its folders' projects, when they
// are not what it was last sent.
func (s *Service) tellMachinesProjects() {
	joined, err := s.joinedFolders(context.Background())
	if err != nil {
		s.log("projects could not be sent to the machines: " + err.Error())
		return
	}
	for host, folders := range joined {
		s.router.Tell(host, wire.NotifyHostProjects.Name, s.machineProjects(folders))
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
