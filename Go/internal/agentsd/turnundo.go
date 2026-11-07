package agentsd

import (
	"context"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// Undo these changes (#3437): the host takes a snapshot of the folder as each turn begins
// and as it ends, the tree of every file git does not ignore (ownTree, an index of its own),
// and records what differs as the turn's turnChanged entry. changes/undoTurn puts those files
// back from the first snapshot. The trees are git objects named only in the entry: no ref
// keeps them, so git's gc lets them go with its other loose objects (two weeks by default),
// and an undo after that says the snapshot is gone.

// listedTurnFiles is the most files a turnChanged entry names; more counts the rest.
const listedTurnFiles = 50

// turnStarts counts the turns begun in each repository, by its top folder, so a turn's end
// can tell whether another agent's turn began in the same folder while it ran.
var turnStarts sync.Map

func turnStartsIn(root string) *atomic.Int64 {
	n, _ := turnStarts.LoadOrStore(root, &atomic.Int64{})
	return n.(*atomic.Int64)
}

// turnSnapshot is the snapshot a turn began with.
type turnSnapshot struct {
	agent, turn  wire.UUID
	root, before string
	started      int64
	shared       bool
}

// snapshotTurn is the snapshot of the folder of agent id as turn (its prompt's entry)
// begins. Nil for a folder git does not hold, or that git could not snapshot.
func (d *Daemon) snapshotTurn(id, turn wire.UUID) *turnSnapshot {
	a := d.Store.Agent(id)
	if a == nil {
		return nil
	}
	root, err := git(store.FolderPath(a.Cwd), "rev-parse", "--show-toplevel")
	if err != nil || root == "" {
		return nil
	}
	_, tree, err := ownTree(root)
	if err != nil {
		return nil
	}
	root = changeKey(root)
	return &turnSnapshot{agent: id, turn: turn, root: root, before: tree,
		started: turnStartsIn(root).Add(1), shared: d.othersInTurn(id, root)}
}

// othersInTurn is whether another agent working in root is in a turn now.
func (d *Daemon) othersInTurn(id wire.UUID, root string) bool {
	for _, o := range d.Store.Agents() {
		if o.ID == id || o.State == wire.AgentStateArchived {
			continue
		}
		cwd := changeKey(store.FolderPath(o.Cwd))
		if !inside(root, cwd) && !inside(cwd, root) {
			continue
		}
		d.mu.Lock()
		l := d.lives[o.ID]
		d.mu.Unlock()
		if l == nil {
			continue
		}
		l.mu.Lock()
		busy := l.inTurn
		l.mu.Unlock()
		if busy {
			return true
		}
	}
	return false
}

// treeChange is one path that differs between two trees, relative to the repository.
type treeChange struct {
	path   string
	status string
}

// treeChanges is git diff-tree between two snapshots: the files added, changed and deleted.
func treeChanges(root, from, to string) ([]treeChange, error) {
	out, err := changesGit(root, "diff-tree", "-r", "-z", "--no-renames", "--name-status", from, to)
	if err != nil {
		return nil, err
	}
	var changes []treeChange
	f := strings.Split(string(out), "\x00")
	for i := 0; i+1 < len(f); i += 2 {
		if f[i] == "" {
			break
		}
		changes = append(changes, treeChange{status: f[i][:1], path: f[i+1]})
	}
	return changes, nil
}

// endTurnSnapshot is the turn's end: the second snapshot, and, when it differs from the
// first, the turn's turnChanged entry. In a folder where another agent's turn ran too, the
// entry names only the files this agent reported editing, so an undo leaves the other's.
func (d *Daemon) endTurnSnapshot(s *turnSnapshot) {
	if s == nil {
		return
	}
	_, after, err := ownTree(s.root)
	if err != nil || after == s.before {
		return
	}
	shared := s.shared || turnStartsIn(s.root).Load() != s.started || d.othersInTurn(s.agent, s.root)
	changes, err := treeChanges(s.root, s.before, after)
	if err != nil {
		return
	}
	reported := d.reportedInTurn(s.agent, s.turn)
	changed := map[string]bool{}
	tc := wire.TurnChanges{Turn: s.turn, Files: []wire.TurnChangedFile{}, Before: &s.before, After: &after}
	n := 0
	for _, c := range changes {
		path := s.root + "/" + c.path
		changed[path] = true
		if shared && !reported[path] {
			continue
		}
		if n++; n > listedTurnFiles {
			continue
		}
		rel := c.path
		state := wire.ChangeStateModified
		switch c.status {
		case "A":
			state = wire.ChangeStateAdded
		case "D":
			state = wire.ChangeStateDeleted
		}
		tc.Files = append(tc.Files, wire.TurnChangedFile{Path: path, RelativePath: &rel, State: state})
	}
	if more := int64(n - listedTurnFiles); more > 0 {
		tc.More = &more
	}
	tc.CannotUndo = cannotUndo(s.root, reported, changed)
	if len(tc.Files) == 0 && len(tc.CannotUndo) == 0 {
		return
	}
	if shared {
		yes := true
		tc.OnlyReported = &yes
	}
	d.record(s.agent, wire.TranscriptEntryKind{TurnChanged: &wire.TranscriptEntryKindTurnChanged{Value: tc}})
}

// reportedInTurn is the files the agent reported editing in turn, by their keys.
func (d *Daemon) reportedInTurn(id, turn wire.UUID) map[string]bool {
	entries, _, _ := d.Store.Transcript(id, 0)
	at := -1
	for i, e := range entries {
		if e.ID == turn {
			at = i
		}
	}
	out := map[string]bool{}
	if at < 0 {
		return out
	}
	for _, c := range foldReported(entries[at:]).calls {
		for _, diff := range c.diffs {
			out[*diff.Path] = true
		}
	}
	return out
}

// cannotUndo is the files the agent reported editing that the snapshots do not hold:
// outside the repository, or ignored by git. A reported file that is back as it was has
// no change to undo, and is not here.
func cannotUndo(root string, reported, changed map[string]bool) []string {
	var outside, candidates []string
	for p := range reported {
		if changed[p] {
			continue
		}
		rel, ok := relativeTo(p, root)
		if !ok {
			outside = append(outside, p)
			continue
		}
		candidates = append(candidates, rel)
	}
	if len(candidates) > 0 {
		out, _ := gitRaw(root, []byte(strings.Join(candidates, "\x00")+"\x00"), "check-ignore", "-z", "--stdin")
		for _, rel := range strings.Split(string(out), "\x00") {
			if rel != "" {
				outside = append(outside, root+"/"+rel)
			}
		}
	}
	sort.Strings(outside)
	return outside
}

// treeEntry is a path's mode and object in a snapshot.
type treeEntry struct{ mode, object string }

func treeEntries(root, tree string, rels []string) map[string]treeEntry {
	out := map[string]treeEntry{}
	if len(rels) == 0 {
		return out
	}
	raw, err := gitRawEnv(root, []string{"GIT_LITERAL_PATHSPECS=1"}, nil,
		append([]string{"-c", "core.quotepath=off", "ls-tree", "-r", "-z", "--full-tree", tree, "--"}, rels...)...)
	if err != nil {
		return out
	}
	for _, line := range strings.Split(string(raw), "\x00") {
		meta, rel, ok := strings.Cut(line, "\t")
		if !ok {
			continue
		}
		if f := strings.Fields(meta); len(f) == 3 {
			out[rel] = treeEntry{mode: f[0], object: f[2]}
		}
	}
	return out
}

// currentObjects is the object each file would be if git added it now, by its path
// relative to root; a file that is not there has none.
func currentObjects(root string, rels []string) map[string]string {
	out := map[string]string{}
	var there []string
	for _, rel := range rels {
		if fi, err := os.Lstat(filepath.Join(root, rel)); err == nil && !fi.IsDir() {
			there = append(there, rel)
		}
	}
	if len(there) == 0 {
		return out
	}
	raw, err := gitRaw(root, []byte(strings.Join(there, "\n")+"\n"), "hash-object", "--stdin-paths")
	if err != nil {
		return out
	}
	for i, h := range strings.Split(strings.TrimSpace(string(raw)), "\n") {
		if i < len(there) {
			out[there[i]] = h
		}
	}
	return out
}

func (d *Daemon) undoTurn(r wire.UndoTurnRequest) (wire.UndoTurnResult, error) {
	a := d.Store.Agent(r.AgentID)
	if a == nil {
		return wire.UndoTurnResult{}, noSuchAgent()
	}
	l := d.live(a.ID)
	l.mu.Lock()
	busy := l.inTurn
	l.mu.Unlock()
	if busy {
		return wire.UndoTurnResult{}, &Error{Code: wire.FailureBusy, Message: "The agent is working. Wait for its turn to end, or stop it, and undo then."}
	}
	entries, _, err := d.Store.Transcript(a.ID, 0)
	if err != nil {
		return wire.UndoTurnResult{}, err
	}
	var tc *wire.TurnChanges
	for _, e := range entries {
		if k := e.Kind.TurnChanged; k != nil && k.Value.Turn == r.Turn {
			tc = &k.Value
		}
		if k := e.Kind.TurnUndone; k != nil && k.Value.Turn == r.Turn {
			return wire.UndoTurnResult{}, &Error{Code: wire.FailureNotChanged, Message: "That turn's changes are undone already."}
		}
	}
	if tc == nil || tc.Before == nil || tc.After == nil {
		return wire.UndoTurnResult{}, Invalid("That turn changed no files the app can put back.")
	}
	root, err := git(store.FolderPath(a.Cwd), "rev-parse", "--show-toplevel")
	if err != nil {
		return wire.UndoTurnResult{}, &Error{Code: wire.FailureFolderGone, Message: store.FolderPath(a.Cwd) + " is not a git folder any more."}
	}
	root = changeKey(root)
	var rels []string
	if tc.More != nil && (tc.OnlyReported == nil || !*tc.OnlyReported) {
		changes, err := treeChanges(root, *tc.Before, *tc.After)
		if err != nil {
			return wire.UndoTurnResult{}, &Error{Code: wire.FailureNotChanged, Message: "The snapshot of that turn is gone, so its changes cannot be put back."}
		}
		for _, c := range changes {
			rels = append(rels, c.path)
		}
	} else {
		for _, f := range tc.Files {
			// The path within the repository, as the turn's end recorded it.
			if f.RelativePath != nil {
				rels = append(rels, *f.RelativePath)
			} else if rel, ok := relativeTo(changeKey(f.Path), root); ok {
				rels = append(rels, rel)
			}
		}
	}
	if len(rels) == 0 {
		return wire.UndoTurnResult{}, Invalid("That turn changed no files the app can put back.")
	}
	if _, err := git(root, "cat-file", "-e", *tc.Before+"^{tree}"); err != nil {
		return wire.UndoTurnResult{}, &Error{Code: wire.FailureNotChanged, Message: "The snapshot of that turn is gone, so its changes cannot be put back."}
	}
	before := treeEntries(root, *tc.Before, rels)
	after := treeEntries(root, *tc.After, rels)
	now := currentObjects(root, rels)
	result := wire.UndoTurnResult{PutBack: []string{}, ChangedSince: []string{}}
	for _, rel := range rels {
		if now[rel] != after[rel].object {
			result.ChangedSince = append(result.ChangedSince, root+"/"+rel)
		}
	}
	if len(result.ChangedSince) > 0 && (r.Confirmed == nil || !*r.Confirmed) {
		return result, nil
	}
	var restore []string
	for _, rel := range rels {
		path := filepath.Join(root, rel)
		if _, ok := before[rel]; ok {
			if now[rel] != before[rel].object {
				restore = append(restore, rel)
			}
			continue
		}
		// Made in the turn: it goes.
		if _, there := now[rel]; there {
			if err := os.Remove(path); err != nil {
				return result, fileError(CodeFileNotReadable, err.Error())
			}
			removeEmptyParents(root, filepath.Dir(path))
		}
		result.PutBack = append(result.PutBack, root+"/"+rel)
	}
	if len(restore) > 0 {
		// A file is put back as checkout would write it (its filters and mode), and the
		// folder's index is left as it was.
		_, err := gitRawEnv(root, []string{"GIT_LITERAL_PATHSPECS=1"}, []byte(strings.Join(restore, "\x00")+"\x00"),
			"restore", "--worktree", "--source="+*tc.Before, "--pathspec-from-file=-", "--pathspec-file-nul")
		if err != nil {
			return result, &Error{Code: CodeServer, Message: "Could not put the files back: " + err.Error()}
		}
	}
	for _, rel := range rels {
		if _, ok := before[rel]; ok {
			result.PutBack = append(result.PutBack, root+"/"+rel)
		}
	}
	sort.Strings(result.PutBack)
	d.record(a.ID, wire.TranscriptEntryKind{TurnUndone: &wire.TranscriptEntryKindTurnUndone{Value: wire.TurnUndo{Turn: r.Turn, PutBack: result.PutBack}}})
	d.undoNotes.remember(a.ID, root, result.PutBack)
	return result, nil
}

// removeEmptyParents removes the folders a removed file leaves empty, up to root.
func removeEmptyParents(root, dir string) {
	for dir != root && inside(root, dir) {
		if os.Remove(dir) != nil {
			return
		}
		dir = filepath.Dir(dir)
	}
}

// undoNotes is the files put back since each agent's last turn, told to its runtime ahead
// of its next prompt: it would otherwise go on as if its edits were still there.
type undoNotes struct {
	mu      sync.Mutex
	byAgent map[wire.UUID][]string
}

func (u *undoNotes) remember(id wire.UUID, root string, paths []string) {
	u.mu.Lock()
	defer u.mu.Unlock()
	if u.byAgent == nil {
		u.byAgent = map[wire.UUID][]string{}
	}
	for _, p := range paths {
		// Capped as it is written (#3650): take tells pageEditLimit and "and others", so
		// one more than that is all it needs.
		if len(u.byAgent[id]) > pageEditLimit {
			break
		}
		if rel, ok := relativeTo(p, root); ok {
			p = rel
		}
		u.byAgent[id] = append(u.byAgent[id], p)
	}
}

// forget drops an agent's notes, when it is archived or deleted.
func (u *undoNotes) forget(id wire.UUID) {
	u.mu.Lock()
	delete(u.byAgent, id)
	u.mu.Unlock()
}

func (u *undoNotes) take(id wire.UUID) string {
	u.mu.Lock()
	paths := u.byAgent[id]
	delete(u.byAgent, id)
	u.mu.Unlock()
	if len(paths) == 0 {
		return ""
	}
	if len(paths) > pageEditLimit {
		paths = append(paths[:pageEditLimit:pageEditLimit], "and others")
	}
	return "(The person undid changes of an earlier turn of yours: these files are back as they were before it: " +
		strings.Join(paths, ", ") + ". Read them again before you change them.)"
}

func (d *Daemon) registerTurnUndo() {
	On(d, wire.CallChangesUndoTurn, func(ctx context.Context, cl *Client, r wire.UndoTurnRequest) (wire.UndoTurnResult, error) {
		return d.undoTurn(r)
	})
}

// lastPrompt is the entry of the agent's last prompt: the turn a prompt sent again after a
// rate limit belongs to, which is not recorded twice.
func (d *Daemon) lastPrompt(id wire.UUID) (wire.UUID, bool) {
	entries, _, _ := d.Store.Transcript(id, 0)
	for i := len(entries) - 1; i >= 0; i-- {
		if entries[i].Kind.UserMessage != nil {
			return entries[i].ID, true
		}
	}
	return "", false
}
