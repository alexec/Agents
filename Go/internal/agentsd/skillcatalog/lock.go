package skillcatalog

import (
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
)

// The `skills` CLI's two lock files, read and written in the CLI's own shape (SkillLock),
// so each tool sees what the other added. A skill a lock names is one a tool put there; a
// folder no lock names is the person's own, and is never touched. The app adds no key of
// its own to either file.

type LockKind int

const (
	Personal LockKind = iota
	FolderScope
)

const (
	personalVersion = 3
	folderVersion  = 1
)

// Entry is one lock entry, the fields the CLI writes for a GitHub skill.
type Entry struct {
	Source, SourceType, SourceURL, SkillPath string
	SkillFolderHash, ComputedHash            string
	InstalledAt, UpdatedAt                   string
}

// RecordedHash is the hash whichever kind of lock recorded.
func (e Entry) RecordedHash() string {
	if e.SkillFolderHash != "" {
		return e.SkillFolderHash
	}
	return e.ComputedHash
}

type Lock struct {
	Kind LockKind
	Path string
	root Value
}

// PersonalLockPath is $XDG_STATE_HOME/skills/.skill-lock.json when that is set, as the CLI
// does, otherwise <home>/.agents/.skill-lock.json.
func PersonalLockPath(home string, env func(string) string) string {
	if s := env("XDG_STATE_HOME"); s != "" {
		return filepath.Join(s, "skills", ".skill-lock.json")
	}
	return filepath.Join(home, ".agents", ".skill-lock.json")
}

func FolderLockPath(folder string) string { return filepath.Join(folder, "skills-lock.json") }

// LoadLock reads a lock, or starts an empty one where there is no file. One that cannot be
// read (after a second try), or is of an older version, is refused: the CLI would treat
// it as empty and write over it, and the app will not. It is the CLI's file too, so it is
// never moved aside.
func LoadLock(kind LockKind, path string) (*Lock, error) {
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return &Lock{Kind: kind, Path: path, root: emptyLock(kind)}, nil
	}
	if err != nil {
		if b, err = os.ReadFile(path); err != nil {
			return nil, LockUnreadable(path)
		}
	}
	want := personalVersion
	if kind == FolderScope {
		want = folderVersion
	}
	root, err := Parse(b)
	if err != nil || root.Kind != 'o' {
		return nil, LockUnreadable(path)
	}
	v, ok := root.Get("version")
	n, nerr := strconv.ParseFloat(v.String, 64)
	skills, sok := root.Get("skills")
	if !ok || v.Kind != 'n' || nerr != nil || int(n) < want || !sok || skills.Kind != 'o' {
		return nil, LockUnreadable(path)
	}
	return &Lock{Kind: kind, Path: path, root: root}, nil
}

func emptyLock(kind LockKind) Value {
	if kind == Personal {
		return Object(Pair{"version", Number(strconv.Itoa(personalVersion))}, Pair{"skills", Object()},
			Pair{"dismissed", Object()})
	}
	return Object(Pair{"version", Number(strconv.Itoa(folderVersion))}, Pair{"skills", Object()})
}

func (l *Lock) skills() Value {
	s, _ := l.root.Get("skills")
	return s
}

// Names is the lock's skills in its own order.
func (l *Lock) Names() []string {
	var out []string
	for _, p := range l.skills().Pairs {
		out = append(out, p.Key)
	}
	return out
}

// Entry is the entry under name, if it has a source.
func (l *Lock) Entry(name string) (Entry, bool) {
	e, ok := l.skills().Get(name)
	if !ok || e.Kind != 'o' {
		return Entry{}, false
	}
	source, ok := e.Str("source")
	if !ok {
		return Entry{}, false
	}
	s := func(k string) string { v, _ := e.Str(k); return v }
	return Entry{Source: source, SourceType: s("sourceType"), SourceURL: s("sourceUrl"), SkillPath: s("skillPath"),
		SkillFolderHash: s("skillFolderHash"), ComputedHash: s("computedHash"), InstalledAt: s("installedAt"),
		UpdatedAt: s("updatedAt")}, true
}

// Upsert adds or replaces a GitHub skill's entry, as the CLI's addSkillToLock and
// addSkillToLocalLock write it. A personal entry keeps its first installedAt.
func (l *Lock) Upsert(name, source, skillPath, hash string, now time.Time) {
	skills := l.skills()
	switch l.Kind {
	case Personal:
		stamp := Stamp(now)
		installed := stamp
		if e, ok := l.Entry(name); ok && e.InstalledAt != "" {
			installed = e.InstalledAt
		}
		skills.Set(name, Object(Pair{"source", String(source)}, Pair{"sourceType", String("github")},
			Pair{"sourceUrl", String("https://github.com/" + source + ".git")}, Pair{"skillPath", String(skillPath)},
			Pair{"skillFolderHash", String(hash)}, Pair{"installedAt", String(installed)}, Pair{"updatedAt", String(stamp)}))
	case FolderScope:
		skills.Set(name, Object(Pair{"source", String(source)}, Pair{"sourceType", String("github")},
			Pair{"skillPath", String(skillPath)}, Pair{"computedHash", String(hash)}))
	}
	l.root.Set("skills", skills)
}

func (l *Lock) Remove(name string) {
	skills := l.skills()
	skills.Remove(name)
	l.root.Set("skills", skills)
}

// Text is the file as the CLI writes it: personal as JSON.stringify(lock, null, 2) with no
// newline; folder with only version and skills, skills sorted by name, and a newline.
func (l *Lock) Text() string {
	if l.Kind == Personal {
		return l.root.Stringified()
	}
	skills := append([]Pair(nil), l.skills().Pairs...)
	sort.SliceStable(skills, func(i, j int) bool { return skills[i].Key < skills[j].Key })
	version, ok := l.root.Get("version")
	if !ok {
		version = Number("1")
	}
	return Object(Pair{"version", version}, Pair{"skills", Object(skills...)}).Stringified() + "\n"
}

// Write puts the file whole, beside it and renamed, so a reader never sees half of one.
func (l *Lock) Write() error {
	if err := os.MkdirAll(filepath.Dir(l.Path), 0o755); err != nil {
		return err
	}
	return store.WriteAtomically(l.Path, []byte(l.Text()), 0o644)
}

// Stamp is `new Date().toISOString()`: milliseconds, UTC, Z.
func Stamp(t time.Time) string { return t.UTC().Format("2006-01-02T15:04:05.000Z") }
