package agentsd

import (
	"context"
	"encoding/json"
	"log"
	"path/filepath"
	"sync"
	"sync/atomic"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// A folder's project (#2317, specs/2317-projects): the id that .agents/folder.json names
// ("project"). This machine makes one for a folder with none, so each folder is in a
// project of its own name until the person picks another, and tells the control plane
// which folder names which (projects/joined), which adopts an id it does not know.

const folderConfig = ".agents/folder.json"

type projectBook struct {
	// joinedSending keeps one projects/joined at a time; joinedQueued says one is on its
	// way, so a burst of changes sends once.
	joinedSending sync.Mutex
	joinedQueued  atomic.Bool
}

// projectIn is the project id the file names, or why the folder is in no project.
func projectIn(m map[string]any, readErr error) (id, problem string) {
	if readErr != nil {
		return "", "The folder is in no project: " + readErr.Error()
	}
	v, ok := m["project"]
	if !ok {
		return "", ""
	}
	if s, ok := v.(string); ok && wire.ValidProjectID(s) {
		return s, ""
	}
	return "", ".agents/folder.json names a project id that is not valid. Pick a project to write a good one."
}

// ensureProject writes a new project id into a folder that names none (FR-008). It leaves
// alone a folder that is not there, an .agents that is a link, a file that is not an
// object, one that names any project, and one with a change waiting for Keep or Undo.
func (d *Daemon) ensureProject(folder string) bool {
	if !isDir(folder) || !ownFolders(folder, ".agents") {
		return false
	}
	m, err := readFolderConfig(folder)
	if err != nil {
		return false
	}
	if _, named := m["project"]; named {
		return false
	}
	if !d.settled(folder, folderConfig) {
		return false
	}
	if err := setFolderConfig(folder, "project", wire.NewProjectID()); err != nil {
		log.Printf("project: %s: %v", folder, err)
		return false
	}
	d.approveWrite(folder, folderConfig)
	return true
}

// StartProjects gives each folder with none a project id, at start-up, and then says
// them to the control plane.
func (d *Daemon) StartProjects() {
	safe.Go("folder projects", func() {
		for _, p := range d.Store.Folders() {
			folder := store.FolderPath(p.Folder)
			if d.ensureProject(folder) {
				d.sendFolder(folder)
			}
		}
		d.sendJoinedSoon()
	})
}

// joined is projects/joined: every folder this machine has, archived ones too, that names
// a valid project id.
func (d *Daemon) joined() wire.ProjectsJoined {
	out := wire.ProjectsJoined{Folders: []wire.JoinedFolder{}}
	for _, p := range d.Store.Folders() {
		folder := store.FolderPath(p.Folder)
		if !isDir(folder) {
			continue
		}
		m, err := readFolderConfig(folder)
		if id, _ := projectIn(m, err); id != "" {
			out.Folders = append(out.Folders, wire.JoinedFolder{Folder: p.Folder, Name: filepath.Base(folder), Project: id})
		}
	}
	return out
}

// sendJoinedSoon sends projects/joined once for a burst of folder changes.
func (d *Daemon) sendJoinedSoon() {
	if d.askControl.Load() == nil || d.joinedQueued.Swap(true) {
		return
	}
	safe.Go("projects/joined", d.sendJoined)
}

// sendJoined tells the control plane, if this machine has one, which folder names which
// project. A failed send is tried again when it next connects or a folder changes.
func (d *Daemon) sendJoined() {
	d.joinedSending.Lock()
	defer d.joinedSending.Unlock()
	d.joinedQueued.Store(false)
	ask := d.askControl.Load()
	if ask == nil {
		return
	}
	ctx, cancel := context.WithTimeout(d.ctx, reportPatience)
	defer cancel()
	answer, err := (*ask)(ctx, wire.CallProjectsJoined.Name, d.joined())
	if err != nil {
		log.Printf("projects/joined: not sent, tried again on the next change: %v", err)
		return
	}
	// The answer is the folders' projects' slots (#2669); a control plane from before them
	// answers {}, which says nothing.
	var projects wire.MachineProjects
	if json.Unmarshal(answer, &projects) == nil && projects.Projects != nil {
		d.heardProjects(projects)
	}
}

// setProject is folders/setProject: the folder joins the project (FR-010).
func (d *Daemon) setProject(r wire.SetFolderProjectRequest) (wire.FolderSummary, error) {
	folder := store.FolderPath(r.Folder)
	if _, ok := d.summaryFor(folder); !ok {
		return wire.FolderSummary{}, noSuchFolder(folder + " is not a folder.")
	}
	if !wire.ValidProjectID(r.Project) {
		return wire.FolderSummary{}, Invalid("%q is not a project id.", r.Project)
	}
	if !isDir(folder) {
		return wire.FolderSummary{}, noSuchFolder(folder + " is not there, so its settings cannot be written.")
	}
	if !d.settled(folder, folderConfig) {
		return wire.FolderSummary{}, guardedRefusal(folderConfig, "The project was not changed: ")
	}
	defer d.approveWrite(folder, folderConfig)
	if err := setFolderConfig(folder, "project", r.Project); err != nil {
		return wire.FolderSummary{}, configWriteError(err)
	}
	return d.sendFolder(folder)
}
