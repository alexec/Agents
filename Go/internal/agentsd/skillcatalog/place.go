package skillcatalog

import (
	"os"
	"path/filepath"

	"github.com/alexec/agents/Go/wire"
)

// Place is where a destination is on disk (SkillPlace): its skills folder, its lock, and
// where something replaced or removed there is put.
type Place struct {
	Destination wire.SkillDestination
	// Skills is ~/.agents/skills or <folder>/.agents/skills.
	Skills   string
	LockKind LockKind
	Lock     string
	// Folder is the project or worktree folder, for a project destination.
	Folder string
	// Trash is where a replaced or removed skill goes; "" is the person's real Trash,
	// which only the ordinary daemon on a Mac uses.
	Trash string
}

// Resolve finds a destination. personalHome is "" for a scratch root with none named;
// isProject says whether a folder is a project here, or a worktree of one.
func Resolve(d wire.SkillDestination, personalHome, root string, realTrash bool, env func(string) string,
	isProject func(string) bool) (Place, error) {
	trash := ""
	if !realTrash {
		trash = filepath.Join(root, "trash")
	}
	switch d.Kind {
	case wire.SkillDestinationKindPersonal:
		if personalHome == "" {
			return Place{}, NoPersonalHome()
		}
		return Place{Destination: d, Skills: filepath.Join(personalHome, ".agents", "skills"), LockKind: Personal,
			Lock: PersonalLockPath(personalHome, env), Trash: trash}, nil
	case wire.SkillDestinationKindProject:
		path := ""
		if d.Folder != nil {
			path = *d.Folder
		}
		folder := filepath.Clean(path)
		info, err := os.Stat(folder)
		if path == "" || err != nil || !info.IsDir() || !isProject(folder) {
			return Place{}, NotAProject(path)
		}
		return Place{Destination: wire.SkillDestination{Kind: wire.SkillDestinationKindProject, Folder: &folder},
			Skills: filepath.Join(folder, ".agents", "skills"), LockKind: Project, Lock: ProjectLockPath(folder),
			Folder: folder, Trash: trash}, nil
	}
	return Place{}, Failed("no destination " + string(d.Kind))
}

// ManagedEntry is the lock entry naming the skill in folder name, and its key. The CLI keys
// by the skill's own name and folders it by sanitizeName, nearly always the same; where
// they differ, the key whose folder this is counts.
func (p Place) ManagedEntry(name string, lock *Lock) (string, Entry, bool) {
	if e, ok := lock.Entry(name); ok {
		return name, e, true
	}
	for _, key := range lock.Names() {
		if FolderName(key) == name {
			if e, ok := lock.Entry(key); ok {
				return key, e, true
			}
		}
	}
	return "", Entry{}, false
}
