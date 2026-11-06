package skillcatalog

import (
	"context"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// Personas from a marketplace (#3665): a repository a marketplace names holds them as
// personas/<id>.md, next to its skills. One is added as that one file, at one commit, to
// .agents/personas in a folder or in the person's home, and its lock names it under
// personas. The app never updates or removes a persona no lock names, and never updates
// one without the person's yes: a persona sets the permission mode and the runtime.

// PersonaFolder is where the destination's personas are: beside its skills.
func (p Place) PersonaFolder() string { return filepath.Join(filepath.Dir(p.Skills), "personas") }

// MaxPersonaBytes is the most a persona file can be, as the editor allows (savePersonaFile).
const MaxPersonaBytes = 256 << 10

// PersonaFiles is each personas/<id>.md at the top of a repository, by id.
func PersonaFiles(tree []TreeEntry) []Folder {
	var out []Folder
	for _, e := range tree {
		id, ok := personaID(e.Path)
		if e.Type != "blob" || !ok || e.Mode == "120000" {
			continue
		}
		out = append(out, Folder{id, e.Path})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}

func personaID(path string) (string, bool) {
	rest, ok := strings.CutPrefix(path, "personas/")
	if !ok || strings.Contains(rest, "/") || !strings.HasSuffix(rest, ".md") {
		return "", false
	}
	id := strings.TrimSuffix(rest, ".md")
	return id, plainName(id) && !strings.HasPrefix(id, ".")
}

// SearchPersonas is every persona in the repository whose id holds the query; an empty
// query lists them all. The tree is read as GitHubSkills reads it, kept ten minutes.
func (g GitHubSkills) SearchPersonas(ctx context.Context, query string) ([]wire.CatalogResult, error) {
	head, err := g.GitHub.Head(ctx, g.Owner, g.Repo)
	if err != nil {
		return nil, err
	}
	tree, err := personaTrees.get(ctx, g.GitHub, g.Owner, g.Repo, head.Commit)
	if err != nil {
		return nil, err
	}
	want := strings.ToLower(strings.TrimSpace(query))
	out := []wire.CatalogResult{}
	for _, f := range PersonaFiles(tree) {
		if want != "" && !strings.Contains(strings.ToLower(f.ID), want) {
			continue
		}
		path, market := f.Path, g.Marketplace
		out = append(out, wire.CatalogResult{ID: g.Owner + "/" + g.Repo + "/" + f.Path, Name: f.ID, Owner: g.Owner, Repo: g.Repo,
			SkillID: f.ID, Known: KnownOwner(g.Owner), Marketplace: &market, SkillPath: &path})
	}
	return out, nil
}

// personaTrees is each repository's tree at a commit, so a search typed letter by letter
// reads it once.
var personaTrees = &treeCache{m: map[string]treeHit{}}

type treeCache struct {
	sync.Mutex
	m map[string]treeHit
}

type treeHit struct {
	at   time.Time
	tree []TreeEntry
}

func (c *treeCache) get(ctx context.Context, g GitHub, owner, repo, commit string) ([]TreeEntry, error) {
	key := owner + "/" + repo + "@" + commit
	c.Lock()
	hit, ok := c.m[key]
	c.Unlock()
	if ok && time.Since(hit.at) < 10*time.Minute {
		return hit.tree, nil
	}
	tree, err := g.Tree(ctx, owner, repo, commit)
	if err != nil {
		return nil, err
	}
	c.Lock()
	for k, h := range c.m {
		if time.Since(h.at) >= 10*time.Minute {
			delete(c.m, k)
		}
	}
	c.m[key] = treeHit{time.Now(), tree}
	c.Unlock()
	return tree, nil
}

// StagedPersona is a persona fetched at one commit, held in memory: what Add writes is
// exactly what was fetched and shown.
type StagedPersona struct {
	Preview   wire.PersonaPreview
	Data      []byte
	CreatedAt time.Time
}

// PersonaStaging is the persona previews waiting to be added: at most eight, each kept half
// an hour, as Staging keeps skills.
type PersonaStaging struct {
	mu    sync.Mutex
	items map[wire.UUID]StagedPersona
}

func (s *PersonaStaging) Put(st StagedPersona) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.items == nil {
		s.items = map[wire.UUID]StagedPersona{}
	}
	s.items[st.Preview.PreviewID] = st
	s.sweep(time.Now())
}

// Take is the preview for adding: used up whether the add succeeds or not.
func (s *PersonaStaging) Take(id wire.UUID) (StagedPersona, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.sweep(time.Now())
	st, ok := s.items[id]
	delete(s.items, id)
	return st, ok
}

func (s *PersonaStaging) sweep(now time.Time) {
	for id, st := range s.items {
		if now.Sub(st.CreatedAt) > stagingLifetime {
			delete(s.items, id)
		}
	}
	for len(s.items) > stagingMost {
		var oldest wire.UUID
		var at time.Time
		for id, st := range s.items {
			if at.IsZero() || st.CreatedAt.Before(at) {
				oldest, at = id, st.CreatedAt
			}
		}
		delete(s.items, oldest)
	}
}

// StagePersona fetches result's persona file at its repository's current commit and checks
// it against the commit's blob. parse reads it as the start form will.
func StagePersona(ctx context.Context, g GitHub, result wire.CatalogResult, id wire.UUID, origin wire.PersonaOrigin,
	parse func(text, id, origin string) wire.Persona, now time.Time) (StagedPersona, error) {
	owner, repo := result.Owner, result.Repo
	path := "personas/" + result.SkillID + ".md"
	if result.SkillPath != nil {
		path = *result.SkillPath
	}
	fileID, ok := personaID(path)
	if _, _, okSource := GitHubSource(owner + "/" + repo); !okSource || !ok {
		return StagedPersona{}, CannotAdd([]wire.PreviewProblem{{NotFoundInRepo: &struct{}{}}})
	}
	head, err := g.Head(ctx, owner, repo)
	if err != nil {
		return StagedPersona{}, err
	}
	tree, err := personaTrees.get(ctx, g, owner, repo, head.Commit)
	if err != nil {
		return StagedPersona{}, err
	}
	var entry *TreeEntry
	for i, e := range tree {
		if e.Type == "blob" && e.Path == path && e.Mode != "120000" {
			entry = &tree[i]
		}
	}
	if entry == nil {
		return StagedPersona{}, CannotAdd([]wire.PreviewProblem{{NotFoundInRepo: &struct{}{}}})
	}
	if entry.Size != nil && *entry.Size > MaxPersonaBytes {
		return StagedPersona{}, CannotAdd([]wire.PreviewProblem{{TooLarge: &wire.PreviewProblemTooLarge{Bytes: *entry.Size, Files: 1}}})
	}
	data, err := g.Raw(ctx, owner, repo, head.Commit, path, entry.SHA, head.SignedIn)
	if err != nil {
		return StagedPersona{}, err
	}
	if BlobSHA(data) != entry.SHA {
		if head.SignedIn {
			return StagedPersona{}, Unreachable("github.com")
		}
		return StagedPersona{}, Unreachable(host(g.Endpoints.Raw))
	}
	if len(data) > MaxPersonaBytes {
		return StagedPersona{}, CannotAdd([]wire.PreviewProblem{{TooLarge: &wire.PreviewProblemTooLarge{Bytes: int64(len(data)), Files: 1}}})
	}
	preview := wire.PersonaPreview{PreviewID: id, Result: result, Path: path, Commit: head.Commit, BlobSHA: entry.SHA,
		Markdown: string(data), Persona: parse(string(data), fileID, string(origin)),
		DestinationState: wire.DestinationState{Free: &struct{}{}}}
	if at := g.CommitDate(ctx, owner, repo, head.Commit, path); at != nil {
		d := wire.DateOf(*at)
		preview.CommittedAt = &d
	}
	return StagedPersona{Preview: preview, Data: data, CreatedAt: now}, nil
}

// PersonaInstaller puts personas in place and takes them out. A file no lock names is
// never written, moved or removed.
type PersonaInstaller struct{}

// Managed is every persona at place a lock names whose file is there, by id.
func (PersonaInstaller) Managed(place Place) map[string]wire.ManagedPersona {
	out := map[string]wire.ManagedPersona{}
	lock, err := LoadLock(place.LockKind, place.Lock)
	if err != nil {
		return out
	}
	for _, id := range lock.PersonaIDs() {
		e, ok := lock.Persona(id)
		if !ok {
			continue
		}
		data, err := os.ReadFile(filepath.Join(place.PersonaFolder(), id+".md"))
		if err != nil {
			continue
		}
		out[id] = wire.ManagedPersona{Destination: place.Destination, ID: id, Source: e.Source, Path: e.Path,
			Commit: optional(e.Commit), Edited: BlobSHA(data) != e.BlobSHA, Update: wire.UpdateState{Unknown: &struct{}{}}}
	}
	return out
}

// State is what is at the destination already, for the persona a preview is of.
func (PersonaInstaller) State(p wire.PersonaPreview, place Place) wire.DestinationState {
	lock, err := LoadLock(place.LockKind, place.Lock)
	if err != nil {
		return wire.DestinationState{Unavailable: &wire.DestinationStateUnavailable{Value: why(err)}}
	}
	id := p.Persona.ID
	if e, ok := lock.Persona(id); ok {
		if !strings.EqualFold(e.Source, p.Result.Owner+"/"+p.Result.Repo) || e.Path != p.Path {
			return wire.DestinationState{ManagedOther: &wire.DestinationStateManagedOther{Source: e.Source}}
		}
		return wire.DestinationState{SameSkill: &wire.DestinationStateSameSkill{Update: e.BlobSHA != p.BlobSHA}}
	}
	target := filepath.Join(place.PersonaFolder(), id+".md")
	if exists(target) {
		return wire.DestinationState{Unmanaged: &wire.DestinationStateUnmanaged{Path: target}}
	}
	return wire.DestinationState{Free: &struct{}{}}
}

// Add writes a staged persona, in full or not at all: the old file to the Trash, the new
// one written, the lock written; a step that fails undoes the ones before it.
func (in PersonaInstaller) Add(st StagedPersona, place Place, replace bool, now time.Time) (wire.ManagedPersona, error) {
	p := st.Preview
	if p.Persona.Problem != nil {
		return wire.ManagedPersona{}, Failed("its metadata can't be read: " + *p.Persona.Problem)
	}
	switch s := in.State(p, place); {
	case s.Free != nil:
		if replace {
			return wire.ManagedPersona{}, ReplaceMismatch()
		}
	case s.SameSkill != nil:
		if s.SameSkill.Update && !replace {
			return wire.ManagedPersona{}, ReplaceMismatch()
		}
	case s.ManagedOther != nil:
		if !replace {
			return wire.ManagedPersona{}, ReplaceMismatch()
		}
	case s.Unmanaged != nil:
		return wire.ManagedPersona{}, Unmanaged(s.Unmanaged.Path)
	case s.Unavailable != nil:
		return wire.ManagedPersona{}, &Error{s.Unavailable.Value}
	}
	lock, err := LoadLock(place.LockKind, place.Lock)
	if err != nil {
		return wire.ManagedPersona{}, err
	}
	folder := place.PersonaFolder()
	if err := os.MkdirAll(folder, 0o755); err != nil {
		return wire.ManagedPersona{}, Failed("could not make " + folder)
	}
	id := p.Persona.ID
	target := filepath.Join(folder, id+".md")
	trashed := ""
	if exists(target) {
		if trashed, err = Trash(target, place.Trash, now); err != nil {
			return wire.ManagedPersona{}, Failed("could not move the old copy to the Trash")
		}
	}
	putBack := func() {
		os.Remove(target)
		if trashed != "" {
			os.Rename(trashed, target)
		}
	}
	if err := store.WriteAtomically(target, st.Data, 0o644); err != nil {
		putBack()
		return wire.ManagedPersona{}, Failed("could not write " + id + ".md")
	}
	source := p.Result.Owner + "/" + p.Result.Repo
	lock.UpsertPersona(id, PersonaEntry{Source: source, Path: p.Path, Commit: p.Commit, BlobSHA: p.BlobSHA}, now)
	if err := lock.Write(); err != nil {
		putBack()
		return wire.ManagedPersona{}, Failed("could not write " + filepath.Base(place.Lock))
	}
	return wire.ManagedPersona{Destination: place.Destination, ID: id, Source: source, Path: p.Path, Commit: optional(p.Commit),
		Update: wire.UpdateState{Current: &struct{}{}}}, nil
}

// Remove takes out a persona a lock names: its file to the Trash, then its lock entry. A
// file no lock names is refused and left as it is.
func (PersonaInstaller) Remove(id string, place Place, now time.Time) (string, error) {
	lock, err := LoadLock(place.LockKind, place.Lock)
	if err != nil {
		return "", err
	}
	if _, ok := lock.Persona(id); !ok || !plainName(id) {
		return "", NotManaged(id)
	}
	target := filepath.Join(place.PersonaFolder(), id+".md")
	trashed := ""
	if exists(target) {
		if trashed, err = Trash(target, place.Trash, now); err != nil {
			return "", Failed("could not move it to the Trash")
		}
	}
	lock.RemovePersona(id)
	if err := lock.Write(); err != nil {
		if trashed != "" {
			os.Rename(trashed, target)
		}
		return "", Failed("could not write " + filepath.Base(place.Lock))
	}
	if trashed == "" {
		return target, nil
	}
	return trashed, nil
}

// CheckPersonas is the update state of each managed persona, by id: per repository at most
// once an hour, as Check does for skills and with the same answers. A persona whose file
// has the same blob at the new HEAD is current.
func (u Updates) CheckPersonas(ctx context.Context, managed map[string]wire.ManagedPersona, place Place, now time.Time) map[string]wire.UpdateState {
	out := map[string]wire.UpdateState{}
	lock, err := LoadLock(place.LockKind, place.Lock)
	if err != nil {
		return out
	}
	bySource := map[string][]wire.ManagedPersona{}
	for _, m := range managed {
		bySource[strings.ToLower(m.Source)] = append(bySource[strings.ToLower(m.Source)], m)
	}
	unknown := wire.UpdateState{Unknown: &struct{}{}}
	for source, personas := range bySource {
		owner, repo, ok := GitHubSource(personas[0].Source)
		if !ok {
			continue
		}
		u.Cache.mu.Lock()
		if u.Cache.answers == nil {
			u.Cache.answers = map[string]updateAnswer{}
		}
		answer, had := u.Cache.answers[source]
		u.Cache.mu.Unlock()
		if !had || now.Sub(answer.at) > updateInterval {
			head, err := u.GitHub.Head(ctx, owner, repo)
			if err != nil {
				for _, p := range personas {
					out[p.ID] = unknown
				}
				continue
			}
			answer = updateAnswer{at: now, head: head.Commit}
		}
		moved := false
		for _, p := range personas {
			if p.Commit == nil || *p.Commit != answer.head {
				moved = true
			}
		}
		if moved && answer.blobs == nil {
			if tree, err := u.GitHub.Tree(ctx, owner, repo, answer.head); err == nil {
				answer.blobs, answer.folders = map[string]string{}, map[string]string{}
				for _, e := range tree {
					switch e.Type {
					case "blob":
						answer.blobs[e.Path] = e.SHA
					case "tree":
						answer.folders[e.Path] = e.SHA
					}
				}
			}
		}
		u.Cache.mu.Lock()
		u.Cache.answers[source] = answer
		u.Cache.mu.Unlock()
		written := false
		for _, p := range personas {
			e, _ := lock.Persona(p.ID)
			if p.Commit != nil && *p.Commit == answer.head {
				out[p.ID] = wire.UpdateState{Current: &struct{}{}}
				continue
			}
			sha, ok := answer.blobs[p.Path]
			switch {
			case !ok:
				out[p.ID] = unknown
			case sha == e.BlobSHA:
				// The file is the same at the new HEAD: the next check needs no tree.
				out[p.ID] = wire.UpdateState{Current: &struct{}{}}
				e.Commit = answer.head
				lock.UpsertPersona(p.ID, e, now)
				written = true
			default:
				out[p.ID] = wire.UpdateState{Available: &wire.UpdateStateAvailable{Commit: answer.head}}
			}
		}
		if written {
			lock.Write()
		}
	}
	return out
}

// PersonaSettingChanges is each of runtime and permission-mode that differs between the
// installed persona and the one an update brings, for the warning above the diff.
func PersonaSettingChanges(was, now wire.WorkflowSettings) []wire.PersonaSettingChange {
	out := []wire.PersonaSettingChange{}
	for _, k := range []struct {
		key      string
		old, new *string
	}{{"runtime", was.RuntimeID, now.RuntimeID}, {"permission-mode", was.PermissionMode, now.PermissionMode}} {
		if orEmpty(k.old) != orEmpty(k.new) {
			out = append(out, wire.PersonaSettingChange{Key: k.key, Old: k.old, New: k.new})
		}
	}
	return out
}

func orEmpty(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}
