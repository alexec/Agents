package store

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/diskjson"
	"github.com/alexec/agents/Go/internal/agentsd/redact"
	"github.com/alexec/agents/Go/wire"
)

// Store holds the root's agents and folders. Agent records are kept in memory, as the
// Swift daemon keeps them; transcripts are read from disk when asked for, never held.
type Store struct {
	Loc Locations
	// RootID is this root's id (root-id.json, #228): every agent made here is stamped with
	// it, and one stamped with another root's is never run.
	RootID string

	mu      sync.Mutex
	agents  map[wire.UUID]*wire.Agent
	folders []wire.Folder
	// lines is each transcript's count of lines, once counted, for an entry's index.
	lines map[wire.UUID]int
	// ib is where the lines of the transcripts read most recently end (lineindex.go).
	ib indexBook
}

// Open reads the root, making what is missing.
func Open(root string) (*Store, error) {
	loc := At(root)
	for _, d := range []string{loc.Root, loc.Agents()} {
		if err := os.MkdirAll(d, 0o700); err != nil {
			return nil, err
		}
	}
	s := &Store{Loc: loc, agents: map[wire.UUID]*wire.Agent{}, lines: map[wire.UUID]int{}}
	id, adopts := loadOrMakeRootID(loc.RootIdentity(), loc.Root)
	s.RootID = id
	s.folders = s.loadFolders()
	finishDeleting(loc)
	entries, _ := os.ReadDir(loc.Agents())
	for _, e := range entries {
		name := e.Name()
		if !wireUUID(name) {
			continue
		}
		a, filled, err := s.load(name)
		if err != nil {
			// Left where it is, for a build that can read it, and said (AgentStore.load).
			log.Printf("could not read agent %s, left on disk: %v", name, err)
			continue
		}
		changed := mend(a) || filled
		if a.MadeInRoot == nil && adopts {
			a.MadeInRoot = &id
			changed = true
		}
		s.agents[a.ID] = a
		if changed {
			if err := s.write(a); err != nil {
				log.Printf("could not save agent %s: %v", a.ID, err)
			}
		}
	}
	// The Swift daemon's index of archived agents is a cache this host does not keep. It
	// goes, so a Swift daemon started on this root later makes it again from the records
	// rather than trusting one older than them.
	os.Remove(loc.ArchiveIndex())
	return s, nil
}

func wireUUID(s string) bool {
	return len(s) == 36 && strings.Count(s, "-") == 4 && s == strings.ToUpper(s)
}

// load reads a record, and says whether it filled the worktree's folder (FillFolder).
func (s *Store) load(id string) (*wire.Agent, bool, error) {
	b, err := os.ReadFile(s.Loc.Record(id))
	if err != nil {
		return nil, false, err
	}
	var a wire.Agent
	if err := diskjson.Unmarshal(b, &a); err != nil {
		return nil, false, err
	}
	a.ID = wire.UUID(strings.ToUpper(string(a.ID)))
	return &a, FillFolder(&a, b), nil
}

// FillFolder gives a worktree with no folder one (#2650). #2617 renamed the record's
// "project" key to "folder" with no migration, and records written since have "folder": "",
// which no client reads as a URL. The folder is the old "project" key when the record has
// it, else the repository the worktree's root belongs to, else the folder its
// .agents/worktrees is in, else the root itself: never empty.
func FillFolder(a *wire.Agent, record []byte) bool {
	w := a.Worktree
	if w == nil || w.Folder != "" {
		return false
	}
	var old struct {
		Worktree *struct {
			Project wire.URL `json:"project"`
		} `json:"worktree"`
	}
	if json.Unmarshal(record, &old) == nil && old.Worktree != nil && old.Worktree.Project != "" {
		w.Folder = old.Worktree.Project
	} else {
		w.Folder = repositoryFolder(FolderPath(w.Root))
	}
	log.Printf("agent %s: its worktree had no folder; it is %s now", a.ID, w.Folder)
	return true
}

// repositoryFolder is the folder a worktree at root is of: the parent of git's common
// dir, else what comes before .agents/worktrees in root, else root.
func repositoryFolder(root string) wire.URL {
	if root == "" {
		return PathURL("/")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "git", "-C", root, "rev-parse", "--path-format=absolute", "--git-common-dir")
	cmd.Env = append(os.Environ(), "GIT_OPTIONAL_LOCKS=0")
	if out, err := cmd.Output(); err == nil {
		if dir := strings.TrimSpace(string(out)); dir != "" {
			return FolderURL(filepath.Dir(dir))
		}
	}
	marker := string(filepath.Separator) + filepath.Join(".agents", "worktrees") + string(filepath.Separator)
	if i := strings.Index(root, marker); i > 0 {
		return FolderURL(root[:i])
	}
	return FolderURL(root)
}

// mend brings a record the rules forbid to one they allow (AgentStore.mended), and ends
// what was running when the daemon went: nothing here picks a turn back up yet.
func mend(a *wire.Agent) bool {
	reason := func(r wire.EndedReason) *wire.EndedReason { return &r }
	switch {
	case a.State == wire.AgentStateArchived && a.ArchivedReason == nil:
		r := wire.AgentArchivedReasonByUser
		a.ArchivedReason = &r
	case a.State == wire.AgentStateStopped && a.EndedReason == nil:
		a.EndedReason = reason(wire.EndedReasonUnrecognised)
	case a.State == wire.AgentStateFinished && (a.EndedReason == nil || *a.EndedReason != wire.EndedReasonEndTurn):
		a.State = wire.AgentStateStopped
		if a.EndedReason == nil {
			a.EndedReason = reason(wire.EndedReasonUnrecognised)
		}
	case a.State == wire.AgentStateStarting && (a.EndedReason != nil || a.ArchivedReason != nil):
		// A start that carries an ending was cut off as it began (AgentStore's mend). The
		// rest left working are the daemon's to find (DaemonCore+Recovery).
		a.State = wire.AgentStateStopped
		a.EndedReason = reason(wire.EndedReasonDaemonGone)
		a.ArchivedReason = nil
	default:
		return false
	}
	return true
}

// Refused is a record that breaks one of the store's rules (AgentStore.refusal).
type Refused struct{ Why string }

func (r *Refused) Error() string { return r.Why }

func refusal(a *wire.Agent) error {
	switch {
	case a.State == wire.AgentStateArchived && a.ArchivedReason == nil:
		return &Refused{fmt.Sprintf("refused to save agent %s: archived with no reason for it", a.ID)}
	case a.State == wire.AgentStateStopped && a.EndedReason == nil:
		return &Refused{fmt.Sprintf("refused to save agent %s: stopped with no ending", a.ID)}
	case a.State == wire.AgentStateFinished && (a.EndedReason == nil || *a.EndedReason != wire.EndedReasonEndTurn):
		return &Refused{fmt.Sprintf("refused to save agent %s: finished, but not at the end of a turn", a.ID)}
	case a.State == wire.AgentStateStarting && (a.EndedReason != nil || a.ArchivedReason != nil):
		return &Refused{fmt.Sprintf("refused to save agent %s: starting, but carrying an ending", a.ID)}
	}
	return nil
}

// setAsidePrefix is AgentStore.setAsidePrefix: a folder being deleted.
const setAsidePrefix = ".deleting-"

// Delete removes an agent from the disk as AgentStore.delete does: its turns, then its
// folder, set aside first so a delete cut off is finished at the next start.
func (s *Store) Delete(id wire.UUID) error {
	id = wire.UUID(strings.ToUpper(string(id)))
	s.mu.Lock()
	delete(s.agents, id)
	delete(s.lines, id)
	s.mu.Unlock()
	s.ib.mu.Lock()
	delete(s.ib.indexes, id)
	s.ib.mu.Unlock()
	if err := os.Remove(s.Loc.Turns(string(id))); err != nil && !os.IsNotExist(err) {
		return err
	}
	folder := s.Loc.Agent(string(id))
	if _, err := os.Stat(folder); os.IsNotExist(err) {
		return nil
	}
	aside := filepath.Join(s.Loc.Agents(), setAsidePrefix+string(id))
	os.RemoveAll(aside)
	if err := os.Rename(folder, aside); err != nil {
		return err
	}
	return os.RemoveAll(aside)
}

// finishDeleting removes the folders a delete cut off set aside (AgentStore.finishDeleting).
func finishDeleting(loc Locations) {
	entries, _ := os.ReadDir(loc.Agents())
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), setAsidePrefix) {
			log.Printf("finishing the delete of %s, cut off last time", e.Name())
			os.RemoveAll(filepath.Join(loc.Agents(), e.Name()))
		}
	}
}

// Save writes a record whole, refusing one the rules forbid, as AgentStore.save does.
func (s *Store) Save(a wire.Agent) error {
	if err := refusal(&a); err != nil {
		log.Print(err)
		return err
	}
	if a.State != wire.AgentStateArchived {
		a.ArchivedAt = nil
	}
	if err := s.write(&a); err != nil {
		return err
	}
	s.mu.Lock()
	s.agents[a.ID] = &a
	s.mu.Unlock()
	return nil
}

func (s *Store) write(a *wire.Agent) error {
	b, err := diskjson.Marshal(a)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(s.Loc.Agent(string(a.ID)), 0o755); err != nil {
		return err
	}
	return WriteAtomically(s.Loc.Record(string(a.ID)), b, 0o644)
}

// Agent is one record, a copy, or nil.
func (s *Store) Agent(id wire.UUID) *wire.Agent {
	s.mu.Lock()
	defer s.mu.Unlock()
	a := s.agents[wire.UUID(strings.ToUpper(string(id)))]
	if a == nil {
		return nil
	}
	c := *a
	return &c
}

// Agents is every record, newest activity first.
func (s *Store) Agents() []wire.Agent {
	s.mu.Lock()
	out := make([]wire.Agent, 0, len(s.agents))
	for _, a := range s.agents {
		out = append(out, *a)
	}
	s.mu.Unlock()
	sort.Slice(out, func(i, j int) bool {
		if out[i].LastActivityAt != out[j].LastActivityAt {
			return out[i].LastActivityAt > out[j].LastActivityAt
		}
		return out[i].ID < out[j].ID
	})
	return out
}

// Append adds an entry to an agent's transcript and says its index: the line it is.
// The entry is redacted as AppendMany does it; AppendOne also gives it back.
func (s *Store) Append(id wire.UUID, e wire.TranscriptEntry) (int, error) {
	n, _, err := s.AppendOne(id, e)
	return n, err
}

// AppendOne is Append that also gives back the entry as it was written: redacted when it
// held a known token shape (#1001).
func (s *Store) AppendOne(id wire.UUID, e wire.TranscriptEntry) (int, wire.TranscriptEntry, error) {
	es := []wire.TranscriptEntry{e}
	n, err := s.AppendMany(id, es)
	return n, es[0], err
}

// openTranscript opens a transcript to append to; a test counts the opens through it.
var openTranscript = func(file string) (*os.File, error) {
	return os.OpenFile(file, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
}

// AppendMany adds entries to an agent's transcript with one open and one write, and says
// the index of the first (#1852): a branch copies up to 10,000 entries at once, and the
// store's lock, which every agent lookup takes, is held once rather than for each.
//
// Each line is written with its known token shapes redacted (#1001), and an entry that
// held one is changed in es to what was written, for the caller to send on.
func (s *Store) AppendMany(id wire.UUID, es []wire.TranscriptEntry) (int, error) {
	var buf []byte
	for i, e := range es {
		b, err := diskjson.Marshal(e)
		if err != nil {
			return 0, err
		}
		if r, changed := redact.Bytes(b); changed {
			var cut wire.TranscriptEntry
			if err := diskjson.Unmarshal(r, &cut); err != nil {
				return 0, fmt.Errorf("redact an entry: %w", err)
			}
			b, es[i] = r, cut
		}
		buf = append(append(buf, b...), '\n')
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	n, ok := s.lines[id]
	if !ok {
		n = countLines(s.Loc.Transcript(string(id)))
	}
	if len(es) == 0 {
		return n, nil
	}
	if err := os.MkdirAll(s.Loc.Agent(string(id)), 0o755); err != nil {
		return 0, err
	}
	f, err := openTranscript(s.Loc.Transcript(string(id)))
	if err != nil {
		return 0, err
	}
	_, err = f.Write(buf)
	f.Close()
	if err != nil {
		return 0, err
	}
	s.lines[id] = n + len(es)
	return n, nil
}

func countLines(file string) int {
	f, err := os.Open(file)
	if err != nil {
		return 0
	}
	defer f.Close()
	n := 0
	r := bufio.NewReaderSize(f, 1<<16)
	for {
		line, err := r.ReadSlice('\n')
		if len(line) > 0 && line[len(line)-1] == '\n' {
			n++
		}
		if err == bufio.ErrBufferFull {
			continue
		}
		if err != nil {
			return n
		}
	}
}

// Transcript is an agent's entries from line from (0 for all), each with its index.
// A line that will not decode is skipped, as TranscriptReader skips one.
func (s *Store) Transcript(id wire.UUID, from int) ([]wire.TranscriptEntry, []int, error) {
	f, err := os.Open(s.Loc.Transcript(string(id)))
	if os.IsNotExist(err) {
		return nil, nil, nil
	}
	if err != nil {
		return nil, nil, err
	}
	defer f.Close()
	var out []wire.TranscriptEntry
	var at []int
	r := bufio.NewScanner(f)
	r.Buffer(make([]byte, 1<<20), 256<<20)
	for i := 0; r.Scan(); i++ {
		if i < from || len(bytes.TrimSpace(r.Bytes())) == 0 {
			continue
		}
		var e wire.TranscriptEntry
		if diskjson.Unmarshal(r.Bytes(), &e) == nil {
			out = append(out, e)
			at = append(at, i)
		}
	}
	return out, at, r.Err()
}

// MARK: folders.json

func (s *Store) loadFolders() []wire.Folder {
	b, err := os.ReadFile(s.Loc.Folders())
	if err != nil {
		return nil
	}
	var ps []wire.Folder
	if err := diskjson.Unmarshal(b, &ps); err != nil {
		log.Printf("folders.json could not be read, starting with no archived folders: %v", err)
		return nil
	}
	seen := map[wire.URL]bool{}
	out := ps[:0]
	for _, p := range ps {
		if !seen[p.Folder] {
			seen[p.Folder] = true
			out = append(out, p)
		}
	}
	return out
}

// Folders is the folders.json list.
func (s *Store) Folders() []wire.Folder {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]wire.Folder(nil), s.folders...)
}

// SaveFolders writes the list, sorted by folder, as FolderStore.save does.
func (s *Store) SaveFolders(ps []wire.Folder) error {
	ps = append([]wire.Folder(nil), ps...)
	sort.SliceStable(ps, func(i, j int) bool { return FolderPath(ps[i].Folder) < FolderPath(ps[j].Folder) })
	b, err := diskjson.Marshal(ps)
	if err != nil {
		return err
	}
	if err := WriteAtomically(s.Loc.Folders(), b, 0o644); err != nil {
		return err
	}
	s.mu.Lock()
	s.folders = ps
	s.mu.Unlock()
	return nil
}

// FolderPath is a file URL's path, without the trailing slash; a plain path as it is.
func FolderPath(u wire.URL) string {
	p := strings.TrimPrefix(string(u), "file://")
	if q, err := unescape(p); err == nil {
		p = q
	}
	if len(p) > 1 {
		p = strings.TrimSuffix(p, "/")
	}
	return p
}

// FolderURL is a folder as Folder.standardize makes it: the path cleaned, its
// links resolved, and no trailing slash ("file:///home/a/src/x").
func FolderURL(path string) wire.URL {
	path = filepath.Clean(path)
	if r, err := Resolve(path); err == nil {
		path = r
	}
	return PathURL(path)
}

// PathURL is a path as a file URL with its links kept, so a link is listed under its own name.
func PathURL(path string) wire.URL {
	return wire.URL("file://" + escapePath(filepath.Clean(path)))
}

// MARK: root-id.json

type rootIdentity struct {
	ID     string `json:"id"`
	MadeAt string `json:"madeAt"`
	Path   string `json:"path"`
}

// loadOrMakeRootID is RootIdentity.loadOrMake: the root's id, and whether it was made
// just now for a root that had none (then unstamped records are this root's own).
func loadOrMakeRootID(file, root string) (string, bool) {
	here, err := Resolve(root)
	if err != nil {
		here = root
	}
	adopts := true
	if b, err := os.ReadFile(file); err == nil {
		adopts = false
		var kept rootIdentity
		if json.Unmarshal(b, &kept) == nil && kept.ID != "" {
			if kept.Path == here {
				return kept.ID, false
			}
			log.Printf("root id %s was made at %s, not %s: a copied root; this one gets its own", kept.ID, kept.Path, here)
		}
	}
	made := rootIdentity{ID: newUUID(), MadeAt: time.Now().UTC().Format("2006-01-02T15:04:05Z"), Path: here}
	// Swift's JSONEncoder with .prettyPrinted and .sortedKeys, which escapes slashes.
	text := fmt.Sprintf("{\n  \"id\" : %s,\n  \"madeAt\" : %s,\n  \"path\" : %s\n}", quote(made.ID), quote(made.MadeAt), quote(made.Path))
	if err := WriteAtomically(file, []byte(text), 0o644); err != nil {
		log.Printf("could not write %s: %v", file, err)
	}
	return made.ID, adopts
}

func quote(s string) string {
	var buf bytes.Buffer
	e := json.NewEncoder(&buf)
	e.SetEscapeHTML(false)
	e.Encode(s)
	return strings.ReplaceAll(strings.TrimSuffix(buf.String(), "\n"), "/", `\/`)
}

func newUUID() string {
	b := make([]byte, 16)
	rand.Read(b)
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return strings.ToUpper(fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:]))
}

// NewUUID is a new upper-case UUID, as Swift writes them.
func NewUUID() wire.UUID { return wire.UUID(newUUID()) }
