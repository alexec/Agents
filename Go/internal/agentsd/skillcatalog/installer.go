package skillcatalog

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
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
// hash of the folder as added, or for a folder the lock's computedHash. A personal skill
// the CLI added has only a tree SHA, which a folder with a followed link never matches, so
// it is never called edited.
func Edited(folder string, e Entry, kind LockKind, record *SidecarRecord) bool {
	written := ""
	switch {
	case record != nil && record.FolderHash != nil:
		written = *record.FolderHash
	case kind == FolderScope:
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

// State is what is at the destination already, for the skill a preview is of.
func (in Installer) State(p wire.SkillPreview, place Place) wire.DestinationState {
	lock, err := LoadLock(place.LockKind, place.Lock)
	if err != nil {
		return wire.DestinationState{Unavailable: &wire.DestinationStateUnavailable{Value: why(err)}}
	}
	if _, e, ok := place.ManagedEntry(p.Name, lock); ok {
		same := strings.EqualFold(e.Source, p.Result.Owner+"/"+p.Result.Repo) && (e.SkillPath == "" || e.SkillPath == p.SkillPath)
		if !same {
			return wire.DestinationState{ManagedOther: &wire.DestinationStateManagedOther{Source: e.Source}}
		}
		now := p.ComputedHash
		if place.LockKind == Personal {
			now = p.TreeSHA
		}
		return wire.DestinationState{SameSkill: &wire.DestinationStateSameSkill{Update: e.RecordedHash() != now}}
	}
	target := filepath.Join(place.Skills, p.Name)
	if exists(target) {
		return wire.DestinationState{Unmanaged: &wire.DestinationStateUnmanaged{Path: target}}
	}
	return wire.DestinationState{Free: &struct{}{}}
}

func why(err error) wire.CatalogError {
	if ce, ok := err.(*Error); ok {
		return ce.Why
	}
	return Failed(err.Error()).Why
}

// pending is an add under way, written before anything moves and removed once the lock is
// written; a daemon that died in between undoes the add at its next start (Recover).
type pending struct {
	Lock     string  `json:"lock"`
	Personal bool    `json:"personal"`
	Key      string  `json:"key"`
	Hash     string  `json:"hash"`
	Target   string  `json:"target"`
	Trashed  *string `json:"trashed,omitempty"`
}

func (in Installer) journal() string {
	return filepath.Join(filepath.Dir(in.Sidecar), "catalog-pending.json")
}

// Recover undoes an add a dead daemon left unfinished, and says what it undid.
func (in Installer) Recover() string {
	b, err := os.ReadFile(in.journal())
	if err != nil {
		return ""
	}
	defer os.Remove(in.journal())
	var p pending
	if json.Unmarshal(b, &p) != nil {
		return ""
	}
	kind := FolderScope
	if p.Personal {
		kind = Personal
	}
	if lock, err := LoadLock(kind, p.Lock); err == nil {
		if e, ok := lock.Entry(p.Key); ok && e.RecordedHash() == p.Hash {
			return ""
		}
	}
	os.RemoveAll(p.Target)
	if p.Trashed != nil {
		os.Rename(*p.Trashed, p.Target)
	}
	return "undid an unfinished add of " + filepath.Base(p.Target)
}

// Add puts a staged skill in place, in full or not at all: the old folder to the Trash, the
// staged one renamed in, the lock written; a step that fails undoes the ones before it.
func (in Installer) Add(st Staged, place Place, replace bool, now time.Time) (wire.ManagedSkill, error) {
	p := st.Preview
	if !CanAdd(p) {
		var blocking []wire.PreviewProblem
		for _, x := range p.Problems {
			if x.Skipped == nil {
				blocking = append(blocking, x)
			}
		}
		return wire.ManagedSkill{}, CannotAdd(blocking)
	}
	switch s := in.State(p, place); {
	case s.Free != nil:
		if replace {
			return wire.ManagedSkill{}, ReplaceMismatch()
		}
	case s.SameSkill != nil:
		if s.SameSkill.Update && !replace {
			return wire.ManagedSkill{}, ReplaceMismatch()
		}
	case s.ManagedOther != nil:
		if !replace {
			return wire.ManagedSkill{}, ReplaceMismatch()
		}
	case s.Unmanaged != nil:
		return wire.ManagedSkill{}, Unmanaged(s.Unmanaged.Path)
	case s.Unavailable != nil:
		return wire.ManagedSkill{}, &Error{s.Unavailable.Value}
	}
	lock, err := LoadLock(place.LockKind, place.Lock)
	if err != nil {
		return wire.ManagedSkill{}, err
	}
	target := filepath.Join(place.Skills, p.Name)
	if err := os.MkdirAll(place.Skills, 0o755); err != nil {
		return wire.ManagedSkill{}, Failed("could not make " + place.Skills)
	}
	hash := p.ComputedHash
	if place.LockKind == Personal {
		hash = p.TreeSHA
	}
	// 0. The journal, before anything moves.
	j := pending{Lock: place.Lock, Personal: place.LockKind == Personal, Key: st.LockKey, Hash: hash, Target: target}
	writeJournal := func() error {
		b, _ := json.Marshal(j)
		os.MkdirAll(filepath.Dir(in.journal()), 0o755)
		return os.WriteFile(in.journal(), b, 0o644)
	}
	if writeJournal() != nil {
		return wire.ManagedSkill{}, Failed("could not note the add before starting it")
	}
	// 1. The old folder, if any, to the Trash, remembered so it can come back.
	trashed := ""
	if exists(target) {
		if trashed, err = Trash(target, place.Trash, now); err != nil {
			os.Remove(in.journal())
			return wire.ManagedSkill{}, Failed("could not move the old copy to the Trash")
		}
		j.Trashed = &trashed
		writeJournal()
	}
	// 2. The staged folder into place.
	if err := os.Rename(st.Folder, target); err != nil {
		if trashed != "" {
			os.Rename(trashed, target)
		}
		os.Remove(in.journal())
		return wire.ManagedSkill{}, Failed("could not move the skill into " + place.Skills)
	}
	// 3. The lock. A failure here takes the new folder out and puts the old one back.
	if key, _, ok := place.ManagedEntry(p.Name, lock); ok && key != st.LockKey {
		lock.Remove(key)
	}
	lock.Upsert(st.LockKey, p.Result.Owner+"/"+p.Result.Repo, p.SkillPath, hash, now)
	if err := lock.Write(); err != nil {
		os.RemoveAll(target)
		if trashed != "" {
			os.Rename(trashed, target)
		}
		os.Remove(in.journal())
		return wire.ManagedSkill{}, Failed("could not write " + filepath.Base(place.Lock))
	}
	os.Remove(in.journal())
	// 4. The folder's Claude link, if it has none.
	if place.Folder != "" {
		linkClaudeSkills(place.Folder)
	}
	// 5. The sidecar: worth having, not worth failing for.
	catalogue := SkillsShID
	if p.Result.Marketplace != nil {
		catalogue = *p.Result.Marketplace
	}
	side := LoadSidecar(in.Sidecar)
	record := SidecarRecord{Commit: p.Commit, TreeSHA: p.TreeSHA, Catalogue: catalogue, AddedAt: now}
	if p.CommittedAt != nil {
		t := p.CommittedAt.Time()
		record.CommittedAt = &t
	}
	if h, err := ComputedHash(target); err == nil {
		record.FolderHash = &h
	}
	side.Skills[SidecarKey(place.Destination, p.Name)] = record
	side.Save(in.Sidecar)
	return wire.ManagedSkill{Destination: place.Destination, Name: p.Name, Source: p.Result.Owner + "/" + p.Result.Repo,
		SkillPath: optional(p.SkillPath), RecordedHash: optional(hash), Commit: optional(p.Commit), CommittedAt: p.CommittedAt,
		Catalogue: &catalogue, Update: wire.UpdateState{Current: &struct{}{}}}, nil
}

// linkClaudeSkills is .claude/skills -> ../.agents/skills, only where nothing is there.
func linkClaudeSkills(folder string) {
	link := filepath.Join(folder, ".claude", "skills")
	if exists(link) {
		return
	}
	os.MkdirAll(filepath.Dir(link), 0o755)
	os.Symlink("../.agents/skills", link)
}

// Changes is the files added, changed and removed going from the installed folder to a
// staged one, by path and content.
func Changes(installed, staged string) wire.SkillChanges {
	before, after := blobs(installed), blobs(staged)
	out := wire.SkillChanges{Added: []string{}, Changed: []string{}, Removed: []string{}}
	for p, sha := range after {
		if was, ok := before[p]; !ok {
			out.Added = append(out.Added, p)
		} else if was != sha {
			out.Changed = append(out.Changed, p)
		}
	}
	for p := range before {
		if _, ok := after[p]; !ok {
			out.Removed = append(out.Removed, p)
		}
	}
	sort.Strings(out.Added)
	sort.Strings(out.Changed)
	sort.Strings(out.Removed)
	return out
}

func blobs(folder string) map[string]string {
	out := map[string]string{}
	filepath.Walk(folder, func(path string, info os.FileInfo, err error) error {
		if err != nil || !info.Mode().IsRegular() {
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return nil
		}
		rel, _ := filepath.Rel(folder, path)
		out[filepath.ToSlash(rel)] = BlobSHA(data)
		return nil
	})
	return out
}
