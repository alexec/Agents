package controlplane

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"unicode/utf8"

	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
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

// projectsMethod answers projects/list, projects/set and projects/remove.
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
	return wire.Project{ID: p.ID, Name: p.Name, Owner: p.Owner, Folders: folders, MayChange: mayChange}
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

// projectsChanged tells this copy's clients, and every other copy, that projects changed.
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
}
