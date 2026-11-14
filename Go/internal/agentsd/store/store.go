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
	"sync/atomic"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/agentsd/diskjson"
	"github.com/agentloops-dev/agent-loops/Go/internal/agentsd/redact"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// Store holds the root's agents and folders. Agent records are kept in memory, as the
// Swift daemon keeps them; transcripts are read from disk when asked for, never held.
type Store struct {
	Loc Locations
	// RootID is this root's id (root-id.json, #228): every agent made here is stamped with
	// it, and one stamped with another root's is never run.
	RootID string

	mu     sync.Mutex
	agents map[wire.UUID]*wire.Agent
	// inFolder is each folder's agents (AgentFolder → ids), and indexed the folder each
	// agent is filed under there, so a summary reads its own few records, not every one
	// (#4507). Kept true with agents, under mu.
	inFolder map[string]map[wire.UUID]struct{}
	indexed  map[wire.UUID]string
	// live is the agents not archived, and liveIn each folder's, so the paths that need
	// only those (the summary, approvals, idle, helper limits) skip the 99% that are
	// archived (#4510). tallies is each folder's archived agents summed (ArchivedIn), made
	// when first asked for and dropped when one of them changes. Kept true with agents.
	live    map[wire.UUID]struct{}
	liveIn  map[string]map[wire.UUID]struct{}
	tallies map[string]ArchivedTally
	// visited is how many records were copied out of the store: a test's count (#4510).
	visited atomic.Int64
	// stamps is each archived record's file as its summary was made of it, the archived
	// records being held as summaries (summaries.go, #4653); summaryTimer is the write of
	// the summaries' file that is due, and summaryWrite lets one write at a time.
	stamps       map[wire.UUID]stamp
	summaryTimer *time.Timer
	summaryWrite sync.Mutex
	folders      []wire.Folder
	// lines is each transcript's count of lines, once counted, for an entry's index.
	lines map[wire.UUID]int
	// ib is where the lines of the transcripts read most recently end (lineindex.go).
	ib indexBook
	// held is each agent's lines the disk refused, waiting for space (held.go, #3245).
	held map[wire.UUID]*heldLines
	// rev is the order of changes to the records (revisions.go, #4785). Under mu.
	rev revisions
	// OnGap is told the notice written where lines a full hold let go would have been, so
	// the clients showing the agent see it.
	OnGap func(id wire.UUID, e wire.TranscriptEntry, index int)
}

// Open reads the root, making what is missing.
func Open(root string) (*Store, error) {
	loc := At(root)
	for _, d := range []string{loc.Root, loc.Agents()} {
		if err := os.MkdirAll(d, 0o700); err != nil {
			return nil, err
		}
	}
	s := &Store{Loc: loc, agents: map[wire.UUID]*wire.Agent{}, inFolder: map[string]map[wire.UUID]struct{}{}, indexed: map[wire.UUID]string{},
		live: map[wire.UUID]struct{}{}, liveIn: map[string]map[wire.UUID]struct{}{}, tallies: map[string]ArchivedTally{}, stamps: map[wire.UUID]stamp{}, lines: map[wire.UUID]int{}, held: map[wire.UUID]*heldLines{}}
	id, adopts := loadOrMakeRootID(loc.RootIdentity(), loc.Root)
	s.RootID = id
	s.folders = s.loadFolders()
	finishDeleting(loc)
	// The archived records come from their summaries, each read in full only when its
	// record changed since its summary was made (#4653).
	summaries, why := s.readSummaries()
	if adopts {
		summaries, why = nil, "made before this root had an id"
	}
	read, archived := 0, 0
	entries, _ := os.ReadDir(loc.Agents())
	for _, e := range entries {
		name := e.Name()
		if !wireUUID(name) {
			continue
		}
		if a, st, ok := s.trusted(summaries, name); ok {
			s.put(a)
			s.stamps[a.ID] = st
			archived++
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
		if changed {
			if err := s.write(a); err != nil {
				log.Printf("could not save agent %s: %v", a.ID, err)
			}
		}
		s.put(a)
		if a.State == wire.AgentStateArchived {
			if fi, err := os.Stat(s.Loc.Record(string(a.ID))); err == nil {
				s.stamps[a.ID] = stampOf(fi)
			}
			read++
			archived++
		}
	}
	s.revisionsAtOpen()
	// A summary of no record there now (deleted by another build) is gone too.
	gone := 0
	for id := range summaries {
		if _, ok := s.stamps[id]; !ok {
			gone++
		}
	}
	if read > 0 || gone > 0 {
		if why == "" {
			why = fmt.Sprintf("%d new or changed, %d gone", read, gone)
		}
		log.Printf("the archived agents' summaries were %s: read %d of %d archived records in full, and wrote them again", why, read, archived)
		if err := s.WriteSummaries(); err != nil {
			log.Printf("could not write the archived agents' summaries: %v", err)
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
	if s.agents[id] != nil {
		s.noteRemoved(id, time.Now())
	}
	s.drop(id)
	delete(s.lines, id)
	delete(s.held, id)
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
	// A summary copied out of the store (Agents) has no commands: they stay those on disk.
	s.mu.Lock()
	held := s.agents[a.ID]
	// The record's place in the order of changes (#4785), held back from the current
	// revision until the record is put.
	rev := s.nextRevision()
	s.rev.pending[rev] = struct{}{}
	s.mu.Unlock()
	a.Revision = &rev
	if held != nil && held.State == wire.AgentStateArchived && len(a.AvailableCommands) == 0 {
		a.AvailableCommands = s.commandsOnDisk(a.ID)
	}
	if err := s.write(&a); err != nil {
		s.mu.Lock()
		delete(s.rev.pending, rev)
		s.mu.Unlock()
		return err
	}
	var st stamp
	if a.State == wire.AgentStateArchived {
		if fi, err := os.Stat(s.Loc.Record(string(a.ID))); err == nil {
			st = stampOf(fi)
		}
	}
	s.mu.Lock()
	s.put(&a)
	s.stampSummary(&a, st)
	delete(s.rev.pending, rev)
	s.mu.Unlock()
	return nil
}

// put keeps a record, an archived one as its summary, and files it under its folder, out
// of the one it was in. With mu held.
func (s *Store) put(a *wire.Agent) {
	s.drop(a.ID)
	if a.State == wire.AgentStateArchived {
		a = summary(a)
	}
	s.agents[a.ID] = a
	f := AgentFolder(a)
	file(s.inFolder, f, a.ID)
	s.indexed[a.ID] = f
	if a.State == wire.AgentStateArchived {
		delete(s.tallies, f)
	} else {
		s.live[a.ID] = struct{}{}
		file(s.liveIn, f, a.ID)
	}
}

// drop forgets a record and its place in the folder index. With mu held.
func (s *Store) drop(id wire.UUID) {
	if a := s.agents[id]; a != nil && a.State == wire.AgentStateArchived {
		delete(s.tallies, s.indexed[id])
	}
	delete(s.agents, id)
	delete(s.live, id)
	if _, ok := s.stamps[id]; ok {
		delete(s.stamps, id)
		s.summariesSoon()
	}
	f, ok := s.indexed[id]
	if !ok {
		return
	}
	delete(s.indexed, id)
	unfile(s.inFolder, f, id)
	unfile(s.liveIn, f, id)
}

func file(index map[string]map[wire.UUID]struct{}, f string, id wire.UUID) {
	ids := index[f]
	if ids == nil {
		ids = map[wire.UUID]struct{}{}
		index[f] = ids
	}
	ids[id] = struct{}{}
}

func unfile(index map[string]map[wire.UUID]struct{}, f string, id wire.UUID) {
	if ids := index[f]; ids != nil {
		delete(ids, id)
		if len(ids) == 0 {
			delete(index, f)
		}
	}
}

// AgentFolder is the folder an agent is in: its worktree's folder, else its cwd.
func AgentFolder(a *wire.Agent) string {
	if a.Worktree != nil && a.Worktree.Folder != "" {
		return FolderPath(a.Worktree.Folder)
	}
	return FolderPath(a.Cwd)
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

// Agent is one record, a copy, or nil. An archived one is whole: its commands are read
// from its file (#4653).
func (s *Store) Agent(id wire.UUID) *wire.Agent {
	s.mu.Lock()
	a := s.agents[wire.UUID(strings.ToUpper(string(id)))]
	s.mu.Unlock()
	if a == nil {
		return nil
	}
	c := *a
	if c.State == wire.AgentStateArchived {
		c.AvailableCommands = s.commandsOnDisk(c.ID)
	}
	return &c
}

// Has says whether the store has the agent, reading no file.
func (s *Store) Has(id wire.UUID) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.agents[wire.UUID(strings.ToUpper(string(id)))] != nil
}

// AgentsIn is the records in one folder (AgentFolder), copies in no order: O(the
// folder's agents), not the whole store's (#4507).
func (s *Store) AgentsIn(folder string) []wire.Agent {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.copies(s.inFolder[folder])
}

// LiveAgentsIn is AgentsIn without the archived records (#4510).
func (s *Store) LiveAgentsIn(folder string) []wire.Agent {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.copies(s.liveIn[folder])
}

// copies is the records of ids, in no order. With mu held.
func (s *Store) copies(ids map[wire.UUID]struct{}) []wire.Agent {
	if len(ids) == 0 {
		return nil
	}
	out := make([]wire.Agent, 0, len(ids))
	for id := range ids {
		out = append(out, *s.agents[id])
	}
	s.visited.Add(int64(len(out)))
	return out
}

// Agents is every record, archived ones too as summaries (no commands), newest activity
// first.
func (s *Store) Agents() []wire.Agent {
	s.mu.Lock()
	out := make([]wire.Agent, 0, len(s.agents))
	for _, a := range s.agents {
		out = append(out, *a)
	}
	s.mu.Unlock()
	s.visited.Add(int64(len(out)))
	return newestFirst(out)
}

// LiveAgents is every record that is not archived, newest activity first (#4510): what
// a path that skips the archived reads, so it does not copy them only to throw them away.
func (s *Store) LiveAgents() []wire.Agent {
	s.mu.Lock()
	out := s.copies(s.live)
	s.mu.Unlock()
	return newestFirst(out)
}

func newestFirst(out []wire.Agent) []wire.Agent {
	sort.Slice(out, func(i, j int) bool {
		if out[i].LastActivityAt != out[j].LastActivityAt {
			return out[i].LastActivityAt > out[j].LastActivityAt
		}
		return out[i].ID < out[j].ID
	})
	return out
}

// AgentFolders is every folder some agent is in, in no order.
func (s *Store) AgentFolders() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]string, 0, len(s.inFolder))
	for f := range s.inFolder {
		out = append(out, f)
	}
	return out
}

// ArchivedTally is what a folder's summary needs of its archived agents (#4510): their
// count, their cost summed, the earliest made and the latest activity.
type ArchivedTally struct {
	Count          int64
	CostToDate     map[string]float64
	FirstCreatedAt wire.Date
	LastActivityAt wire.Date
}

// ArchivedIn is the folder's archived agents summed: read once, then kept until one of
// them changes, so a summary reads only its live records (#4510). The cost is a copy.
func (s *Store) ArchivedIn(folder string) ArchivedTally {
	s.mu.Lock()
	defer s.mu.Unlock()
	t, ok := s.tallies[folder]
	if !ok {
		t = ArchivedTally{CostToDate: map[string]float64{}}
		for id := range s.inFolder[folder] {
			a := s.agents[id]
			if a.State != wire.AgentStateArchived {
				continue
			}
			if t.Count == 0 || a.CreatedAt < t.FirstCreatedAt {
				t.FirstCreatedAt = a.CreatedAt
			}
			if a.LastActivityAt > t.LastActivityAt {
				t.LastActivityAt = a.LastActivityAt
			}
			for cur, v := range a.CostToDate {
				t.CostToDate[cur] += v
			}
			t.Count++
		}
		s.visited.Add(t.Count)
		s.tallies[folder] = t
	}
	cost := make(map[string]float64, len(t.CostToDate))
	for cur, v := range t.CostToDate {
		cost[cur] = v
	}
	t.CostToDate = cost
	return t
}

// Visited is how many records the store has copied out or summed since it opened: a
// test's count of the work a path does (#4510).
func (s *Store) Visited() int64 { return s.visited.Load() }

// Append adds an entry to an agent's transcript and says its index: the line it is.
// The entry is redacted as AppendMany does it; AppendOne also gives it back.
func (s *Store) Append(id wire.UUID, e wire.TranscriptEntry) (int, error) {
	n, _, err := s.AppendOne(id, e)
	return n, err
}

// AppendOne is Append that also gives back the entry as it was written: redacted when it
// held a known token shape (#1001).
//
// A line the disk refuses is held (held.go, #3245): the index and the entry are given back
// with an error that is ErrHeld, and the line is written ahead of the next one, or at the
// next WriteHeld. A line past the hold's bound is let go, with an error that is not.
func (s *Store) AppendOne(id wire.UUID, e wire.TranscriptEntry) (int, wire.TranscriptEntry, error) {
	es := []wire.TranscriptEntry{e}
	n, err := s.appendEntries(id, es, true)
	return n, es[0], err
}

// openTranscript opens a transcript to append to; a test counts the opens through it, or
// refuses them as a full disk does.
var openTranscript = func(file string) (*os.File, error) {
	return os.OpenFile(file, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
}

// AppendMany adds entries to an agent's transcript with one open and one write, and says
// the index of the first (#1852): a branch copies up to 10,000 entries at once, and the
// store's lock, which every agent lookup takes, is held once rather than for each.
//
// Each line is written with its known token shapes redacted (#1001), and an entry that
// held one is changed in es to what was written, for the caller to send on. Lines the
// agent has held are written first; entries the disk refuses here are not held, for the
// caller says the refusal.
func (s *Store) AppendMany(id wire.UUID, es []wire.TranscriptEntry) (int, error) {
	return s.appendEntries(id, es, false)
}

func (s *Store) appendEntries(id wire.UUID, es []wire.TranscriptEntry, hold bool) (int, error) {
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
	n, ok := s.lines[id]
	if !ok {
		n = countLines(s.Loc.Transcript(string(id)))
		s.lines[id] = n
	}
	if len(es) == 0 {
		s.mu.Unlock()
		return n + s.held[id].count(), nil
	}
	n, gap, err := s.writeLocked(id, buf, len(es), hold)
	s.mu.Unlock()
	s.tellGap(id, gap)
	return n, err
}

// writeTranscript appends whole lines to a transcript. A write the disk cut short is
// taken back, so the next line is never glued to half of this one.
func (s *Store) writeTranscript(id wire.UUID, buf []byte) error {
	if err := os.MkdirAll(s.Loc.Agent(string(id)), 0o755); err != nil {
		return err
	}
	f, err := openTranscript(s.Loc.Transcript(string(id)))
	if err != nil {
		return err
	}
	defer f.Close()
	var size int64 = -1
	if info, err := f.Stat(); err == nil {
		size = info.Size()
	}
	if _, err := f.Write(buf); err != nil {
		if size >= 0 {
			f.Truncate(size)
		}
		return err
	}
	return nil
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

// folderPaths is each URL's path as FolderPath made it, so a read of a record's folder
// does not unescape it again (#4511): put fills it as a record loads or saves. A URL's
// path never changes, so no entry goes stale; a record that moves has a new URL, and
// that is a new key. At most maxFolderPaths are kept: when full, it starts again.
var folderPaths = struct {
	sync.RWMutex
	m map[wire.URL]string
}{m: map[wire.URL]string{}}

const maxFolderPaths = 8192

// FolderPath is a file URL's path, without the trailing slash; a plain path as it is.
func FolderPath(u wire.URL) string {
	folderPaths.RLock()
	p, ok := folderPaths.m[u]
	folderPaths.RUnlock()
	if ok {
		return p
	}
	p = folderPath(u)
	folderPaths.Lock()
	if len(folderPaths.m) >= maxFolderPaths {
		clear(folderPaths.m)
	}
	folderPaths.m[u] = p
	folderPaths.Unlock()
	return p
}

func folderPath(u wire.URL) string {
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
