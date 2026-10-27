package agentsd

import (
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"sync"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/githubmcp"
	"github.com/alexec/agents/Go/internal/gitlabmcp"
	"github.com/alexec/agents/Go/wire"
)

// A project's tools (#2669, specs/2317-projects User Story 4): the Tasks, Code review and
// CI slots that a folder's project sets, for every folder in it. The control plane sends
// them in projects/joined's answer and again in host/projects; this machine keeps the last
// it heard in <root>/projects.json, so a folder keeps its project's slots while the
// control plane is away. A slot the project does not set is the folder's own, from its git
// remote, as before.

type projectToolsBook struct {
	projectToolsMu sync.Mutex
	// projectTools is by project id; nil until read from disk.
	projectTools map[string]wire.ProjectTools
}

func (d *Daemon) projectToolsPath() string { return filepath.Join(d.Store.Loc.Root, "projects.json") }

// projectToolsLocked reads the file once. projectToolsMu is held.
func (d *Daemon) projectToolsLocked() map[string]wire.ProjectTools {
	if d.projectTools == nil {
		d.projectTools = map[string]wire.ProjectTools{}
		var kept wire.MachineProjects
		if b, err := os.ReadFile(d.projectToolsPath()); err == nil && json.Unmarshal(b, &kept) == nil {
			for _, p := range kept.Projects {
				d.projectTools[p.ID] = p
			}
		}
	}
	return d.projectTools
}

// heardProjects keeps what the control plane said of this machine's folders' projects, all
// of them each time, and says each folder's pins again when it changed: the pages follow
// the project.
func (d *Daemon) heardProjects(m wire.MachineProjects) {
	next := map[string]wire.ProjectTools{}
	for _, p := range m.Projects {
		if wire.ValidProjectID(p.ID) {
			next[p.ID] = p
		}
	}
	d.projectToolsMu.Lock()
	before, _ := json.Marshal(d.projectToolsLocked())
	after, _ := json.Marshal(next)
	changed := string(before) != string(after)
	if changed {
		d.projectTools = next
		b, err := json.Marshal(m)
		if err == nil {
			err = store.WriteAtomically(d.projectToolsPath(), b, 0o600)
		}
		if err != nil {
			log.Printf("projects: the project's slots were not kept: %v", err)
		}
	}
	d.projectToolsMu.Unlock()
	if !changed {
		return
	}
	log.Printf("projects: %d projects' slots heard", len(next))
	for _, p := range d.Store.Folders() {
		d.pinsChanged(store.FolderPath(p.Folder))
	}
}

// toldProjects is host/projects.
func (d *Daemon) toldProjects(params json.RawMessage) {
	var m wire.MachineProjects
	if err := json.Unmarshal(params, &m); err != nil {
		log.Printf("projects: %s: %v", wire.NotifyHostProjects.Name, err)
		return
	}
	d.heardProjects(m)
}

// folderProject is the folder's project id and, once the control plane said it, its name
// and slots.
func (d *Daemon) folderProject(folder string) (id string, tools wire.ProjectTools, known bool) {
	m, err := readFolderConfig(folder)
	id, _ = projectIn(m, err)
	if id == "" {
		return "", wire.ProjectTools{}, false
	}
	d.projectToolsMu.Lock()
	defer d.projectToolsMu.Unlock()
	tools, known = d.projectToolsLocked()[id]
	return id, tools, known
}

// projectSlot is the folder's project's setting for kind, if it sets one.
func (d *Daemon) projectSlot(folder string, kind wire.ConnectorSlotKind) (wire.ProjectSlot, bool) {
	_, tools, _ := d.folderProject(folder)
	for _, s := range tools.Slots {
		if s.Slot == kind {
			return s, true
		}
	}
	return wire.ProjectSlot{}, false
}

// projectForge is the forge a project's slot names.
func projectForge(s wire.ProjectSlot) forge {
	f := forge{provider: wire.ConnectionProviderGithub, repo: deref(s.Repository), site: "github.com"}
	if s.Forge != nil && *s.Forge == wire.ConnectionProviderGitlab {
		f.provider, f.site = wire.ConnectionProviderGitlab, "gitlab.com"
		if s.Site != nil && *s.Site != "" {
			f.site = *s.Site
		}
		f.root = gitlabmcp.BaseURL(f.site)
	}
	return f
}

// viewSlot is the slot whose repository one of our list views shows: the Issues page is
// Tasks, the Pull requests (merge requests) page is Code review.
func viewSlot(ours, uri string) (wire.ConnectorSlotKind, wire.ConnectionProvider, string, bool) {
	switch ours + " " + uri {
	case "agents/github " + githubmcp.IssuesURI:
		return wire.ConnectorSlotKindTasks, wire.ConnectionProviderGithub, "repo", true
	case "agents/github " + githubmcp.PullsURI:
		return wire.ConnectorSlotKindCodeReview, wire.ConnectionProviderGithub, "repo", true
	case "agents/gitlab " + gitlabmcp.IssuesURI:
		return wire.ConnectorSlotKindTasks, wire.ConnectionProviderGitlab, "project", true
	case "agents/gitlab " + gitlabmcp.MergeRequestsURI:
		return wire.ConnectorSlotKindCodeReview, wire.ConnectionProviderGitlab, "project", true
	}
	return "", "", "", false
}

// projectViewArguments is the arguments that point one of our views at the folder's
// project's repository, when the project sets its slot on that view's forge. ok says the
// view belongs in the folder whatever its own remote is.
func (d *Daemon) projectViewArguments(folder, ours, uri string) (wire.JSONValue, bool) {
	kind, provider, key, ok := viewSlot(ours, uri)
	if !ok {
		return nil, false
	}
	s, set := d.projectSlot(folder, kind)
	if !set || (s.Skipped != nil && *s.Skipped) || deref(s.Repository) == "" {
		return nil, false
	}
	if f := projectForge(s); f.provider != provider {
		return nil, false
	}
	b, _ := json.Marshal(map[string]string{key: *s.Repository})
	return b, true
}

// projectFills says the folder's project points one of ours's views at a repository.
func (d *Daemon) projectFills(folder, ours string) bool {
	for _, uri := range []string{githubmcp.IssuesURI, githubmcp.PullsURI, gitlabmcp.IssuesURI, gitlabmcp.MergeRequestsURI} {
		if _, ok := d.projectViewArguments(folder, ours, uri); ok {
			return true
		}
	}
	return false
}
