package agentsd

import (
	"context"
	"errors"
	"log"
	"os"
	"path/filepath"
	goruntime "runtime"
	"strings"

	"github.com/alexec/agents/Go/internal/agentsd/skillcatalog"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// The skills in the person's ~/.agents/skills or a folder's .agents/skills, each with
// where a lock says it came from, and taking out one a tool added (DaemonCore+Catalog).
// A person's: an agent's own connection is never sent these.

func (d *Daemon) registerSkills() {
	On(d, wire.CallSkillsList, func(ctx context.Context, c *Client, r wire.SkillsListRequest) (wire.SkillsListAnswer, error) {
		place, err := d.skillPlace(r.Destination)
		if err != nil {
			return wire.SkillsListAnswer{}, catalogRefusal(err)
		}
		return wire.SkillsListAnswer{Skills: d.skillInstaller().List(place)}, nil
	})
	On(d, wire.CallSkillsRemove, func(ctx context.Context, c *Client, r wire.SkillNameRequest) (wire.SkillRemoveAnswer, error) {
		place, err := d.skillPlace(r.Destination)
		if err != nil {
			return wire.SkillRemoveAnswer{}, catalogRefusal(err)
		}
		trashed, err := d.skillInstaller().Remove(r.Name, place, nowFunc())
		if err != nil {
			return wire.SkillRemoveAnswer{}, catalogRefusal(err)
		}
		where := "personal"
		if place.Folder != "" {
			where = "folder " + filepath.Base(place.Folder)
		}
		log.Printf("catalog: remove %s → %s", r.Name, where)
		return wire.SkillRemoveAnswer{TrashedTo: trashed}, nil
	})
}

func (d *Daemon) skillInstaller() skillcatalog.Installer {
	return skillcatalog.Installer{Sidecar: filepath.Join(d.Store.Loc.Root, "catalog-skills.json")}
}

// skillPlace is where a destination is. A scratch root or a named personal home never
// uses the person's real Trash.
func (d *Daemon) skillPlace(dest wire.SkillDestination) (skillcatalog.Place, error) {
	return skillcatalog.Resolve(dest, d.personalHome(), d.Store.Loc.Root, d.usesRealTrash(), os.Getenv, d.isFolderPath)
}

// usesRealTrash is the ordinary daemon on a Mac: the standard root, with no personal home
// named.
func (d *Daemon) usesRealTrash() bool {
	return goruntime.GOOS == "darwin" && os.Getenv("AGENTS_PERSONAL_HOME") == "" && store.IsStandard(d.Store.Loc.Root)
}

// isFolderPath is a folder here, one an agent has worked in, or a worktree of either
// (DaemonCore.isFolderPath).
func (d *Daemon) isFolderPath(folder string) bool {
	folder = filepath.Clean(folder)
	known := func(f string) bool {
		for _, p := range d.Store.Folders() {
			if store.FolderPath(p.Folder) == f {
				return true
			}
		}
		for _, a := range d.Store.Agents() {
			if folderPath(&a) == f || store.FolderPath(a.Cwd) == f {
				return true
			}
		}
		return false
	}
	if known(folder) {
		return true
	}
	if i := strings.Index(folder, "/.agents/worktrees/"); i >= 0 {
		return known(folder[:i])
	}
	return false
}

// catalogRefusal is a catalogue refusal as the sheet reads it: -32080 with the reason.
func catalogRefusal(err error) error {
	var ce *skillcatalog.Error
	if errors.As(err, &ce) {
		return &Error{Code: wire.FailureCatalogRefused, Message: ce.Error(), Data: ce.Why}
	}
	return &Error{Code: wire.FailureCatalogRefused, Message: skillcatalog.Sentence(skillcatalog.Failed(err.Error()).Why),
		Data: skillcatalog.Failed(err.Error()).Why}
}
