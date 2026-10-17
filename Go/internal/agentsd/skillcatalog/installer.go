package skillcatalog

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// Installer puts staged skills in place and takes them out (SkillInstaller). A folder no
// lock names is never written, moved or removed.
type Installer struct {
	// Sidecar is the daemon's catalog-skills.json.
	Sidecar string
}

// Managed is every skill at place a lock names, by folder name.
func (in Installer) Managed(place Place) map[string]wire.ManagedSkill {
	out := map[string]wire.ManagedSkill{}
	lock, err := LoadLock(place.LockKind, place.Lock)
	if err != nil {
		return out
	}
	side := LoadSidecar(in.Sidecar)
	for _, key := range lock.Names() {
		e, ok := lock.Entry(key)
		if !ok || e.SourceType != "github" {
			continue
		}
		name := FolderName(key)
		folder := filepath.Join(place.Skills, name)
		if !exists(folder) {
			continue
		}
		m := wire.ManagedSkill{Destination: place.Destination, Name: name, Source: e.Source,
			SkillPath: optional(e.SkillPath), RecordedHash: optional(e.RecordedHash()), Update: wire.UpdateState{Unknown: &struct{}{}}}
		record, has := side.Skills[SidecarKey(place.Destination, name)]
		if has {
			m.Commit, m.Catalogue = optional(record.Commit), optional(record.Catalogue)
			if record.CommittedAt != nil {
				at := wire.DateOf(*record.CommittedAt)
				m.CommittedAt = &at
			}
		}
		var r *SidecarRecord
		if has {
			r = &record
		}
		m.Edited = Edited(folder, e, place.LockKind, r)
		out[name] = m
	}
	return out
}

// List is every skill in the destination's folder, a lock's or the person's own, by name.
// A folder with no SKILL.md is not a skill; a missing folder is an empty list.
func (in Installer) List(place Place) []wire.ListedSkill {
	managed := in.Managed(place)
	entries, _ := os.ReadDir(place.Skills)
	var names []string
	for _, e := range entries {
		names = append(names, e.Name())
	}
	sort.Strings(names)
	out := []wire.ListedSkill{}
	for _, name := range names {
		if strings.HasPrefix(name, ".") {
			continue
		}
		folder := filepath.Join(place.Skills, name)
		text, err := os.ReadFile(filepath.Join(folder, "SKILL.md"))
		if err != nil {
			continue
		}
		s := wire.ListedSkill{Name: name, Description: optional(ParseSkillFile(string(text)).Description), Folder: folder}
		if m, ok := managed[name]; ok {
			s.Managed = &m
		}
		out = append(out, s)
	}
	return out
}

// Edited is whether the folder no longer hashes to what was written there: the sidecar's
// hash of the folder as added, or for a project the lock's computedHash. A personal skill
// the CLI added has only a tree SHA, which a folder with a followed link never matches, so
// it is never called edited.
func Edited(folder string, e Entry, kind LockKind, record *SidecarRecord) bool {
	written := ""
	switch {
	case record != nil && record.FolderHash != nil:
		written = *record.FolderHash
	case kind == Project:
		written = e.ComputedHash
	}
	if written == "" {
		return false
	}
	now, err := ComputedHash(folder)
	return err == nil && now != written
}

// Remove takes out a skill a lock names: its folder to the Trash, then its lock entry and
// its sidecar record. A folder no lock names is refused and left as it is. If the lock
// cannot be written, the folder comes back.
func (in Installer) Remove(name string, place Place, now time.Time) (string, error) {
	lock, err := LoadLock(place.LockKind, place.Lock)
	if err != nil {
		return "", err
	}
	key, _, ok := place.ManagedEntry(name, lock)
	if !ok {
		return "", NotManaged(name)
	}
	folder := filepath.Join(place.Skills, name)
	trashed := ""
	if exists(folder) {
		if trashed, err = Trash(folder, place.Trash, now); err != nil {
			return "", Failed("could not move it to the Trash")
		}
	}
	lock.Remove(key)
	if err := lock.Write(); err != nil {
		if trashed != "" {
			os.Rename(trashed, folder)
		}
		return "", Failed("could not write " + filepath.Base(place.Lock))
	}
	side := LoadSidecar(in.Sidecar)
	if _, ok := side.Skills[SidecarKey(place.Destination, name)]; ok {
		delete(side.Skills, SidecarKey(place.Destination, name))
		side.Save(in.Sidecar)
	}
	if trashed == "" {
		return folder, nil
	}
	return trashed, nil
}

// Trash moves path into folder under a name of its own, or with folder "", into the
// person's Trash (~/.Trash), and says where it went.
func Trash(path, folder string, now time.Time) (string, error) {
	var b [2]byte
	rand.Read(b[:])
	suffix := fmt.Sprintf("%d-%s", now.UnixMilli(), strings.ToUpper(hex.EncodeToString(b[:])))
	if folder == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		folder = filepath.Join(home, ".Trash")
		to := filepath.Join(folder, filepath.Base(path))
		if exists(to) {
			to = filepath.Join(folder, filepath.Base(path)+" "+suffix)
		}
		return to, os.Rename(path, to)
	}
	if err := os.MkdirAll(folder, 0o755); err != nil {
		return "", err
	}
	to := filepath.Join(folder, filepath.Base(path)+"-"+suffix)
	return to, os.Rename(path, to)
}

func exists(path string) bool {
	_, err := os.Lstat(path)
	return err == nil
}

func optional(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}
