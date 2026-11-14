package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"testing"

	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// Undo These Changes (#3437): a turn's snapshots, its card, and the undo.

func turnChanges(d *Daemon, id wire.UUID) []wire.TurnChanges {
	entries, _, _ := d.Store.Transcript(id, 0)
	var out []wire.TurnChanges
	for _, e := range entries {
		if e.Kind.TurnChanged != nil {
			out = append(out, e.Kind.TurnChanged.Value)
		}
	}
	return out
}

// runTurn starts an agent in dir that writes path, and is the turn's card once it ends.
func runTurn(t *testing.T, d *Daemon, c *conn, dir, path string) (wire.UUID, wire.TurnChanges) {
	t.Helper()
	id := startAgent(t, c, 1, dir, "write the file "+path)
	c.until(t, "the turn", ended(id, wire.AgentStateFinished))
	var tc []wire.TurnChanges
	waitFor(t, "the turn's card", func() bool { tc = turnChanges(d, id); return len(tc) == 1 })
	return id, tc[0]
}

func TestUndoPutsBackWhatATurnChanged(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := repo(t)
	path := filepath.Join(dir, "a.txt")
	os.WriteFile(path, []byte("one\n"), 0o644)
	git(dir, "add", "a.txt")
	git(dir, "commit", "-q", "-m", "a")
	id, tc := runTurn(t, d, c, dir, path)
	if len(tc.Files) != 1 || tc.Files[0].Path != path || tc.Files[0].State != wire.ChangeStateModified || tc.Before == nil || tc.After == nil {
		t.Fatalf("%+v", tc)
	}
	var r wire.UndoTurnResult
	json.Unmarshal(c.call(t, 2, "changes/undoTurn", map[string]any{"agentID": id, "turn": tc.Turn}), &r)
	if b, _ := os.ReadFile(path); string(b) != "one\n" || len(r.PutBack) != 1 || r.PutBack[0] != path || len(r.ChangedSince) != 0 {
		t.Fatalf("%q %+v", b, r)
	}
	// The folder's index is the person's: the undo leaves it as it was.
	if status, _ := git(dir, "status", "--porcelain"); status != "" {
		t.Fatalf("status %q", status)
	}
	if e := c.callError(t, 3, "changes/undoTurn", map[string]any{"agentID": id, "turn": tc.Turn}); e.Code != wire.FailureNotChanged {
		t.Fatalf("%+v", e)
	}
	// The runtime hears of it ahead of its next prompt.
	if note := d.undoNotes.take(id); note == "" {
		t.Fatal("no note for the runtime")
	}
}

func TestUndoRemovesAFileTheTurnMade(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := repo(t)
	path := filepath.Join(dir, "new", "b.txt")
	id, tc := runTurn(t, d, c, dir, path)
	if len(tc.Files) != 1 || tc.Files[0].State != wire.ChangeStateAdded || *tc.Files[0].RelativePath != "new/b.txt" {
		t.Fatalf("%+v", tc)
	}
	c.call(t, 2, "changes/undoTurn", map[string]any{"agentID": id, "turn": tc.Turn})
	if _, err := os.Stat(filepath.Join(dir, "new")); !os.IsNotExist(err) {
		t.Fatalf("the folder it made is still there: %v", err)
	}
}

func TestUndoAsksFirstWhenAFileChangedAgain(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := repo(t)
	path := filepath.Join(dir, "a.txt")
	os.WriteFile(path, []byte("one\n"), 0o644)
	git(dir, "add", "a.txt")
	git(dir, "commit", "-q", "-m", "a")
	id, tc := runTurn(t, d, c, dir, path)
	os.WriteFile(path, []byte("person's\n"), 0o644)
	var r wire.UndoTurnResult
	json.Unmarshal(c.call(t, 2, "changes/undoTurn", map[string]any{"agentID": id, "turn": tc.Turn}), &r)
	if b, _ := os.ReadFile(path); string(b) != "person's\n" || len(r.ChangedSince) != 1 || len(r.PutBack) != 0 {
		t.Fatalf("%q %+v", b, r)
	}
	r = wire.UndoTurnResult{}
	json.Unmarshal(c.call(t, 3, "changes/undoTurn", map[string]any{"agentID": id, "turn": tc.Turn, "confirmed": true}), &r)
	if b, _ := os.ReadFile(path); string(b) != "one\n" || len(r.PutBack) != 1 {
		t.Fatalf("%q %+v", b, r)
	}
}

func TestATurnOutsideTheFolderCannotBeUndone(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := repo(t)
	os.WriteFile(filepath.Join(dir, ".gitignore"), []byte("build/\n"), 0o644)
	git(dir, "add", ".gitignore")
	git(dir, "commit", "-q", "-m", "ignore")
	ignored := filepath.Join(dir, "build", "out.txt")
	os.MkdirAll(filepath.Dir(ignored), 0o755)
	os.WriteFile(ignored, []byte("old\n"), 0o644)
	id := startAgent(t, c, 1, dir, "write the file "+ignored)
	c.until(t, "the turn", ended(id, wire.AgentStateFinished))
	// The snapshots hold no ignored file, so the trees are the same and no card is made.
	if tc := turnChanges(d, id); len(tc) != 0 {
		t.Fatalf("%+v", tc)
	}
	// cannotUndo sorts its paths; where the temp folder sorts against /elsewhere differs
	// by machine (/tmp on Linux, /Users/runner/… on CI's macOS: #3517).
	want := []string{ignored, "/elsewhere/x"}
	sort.Strings(want)
	if got := cannotUndo(dir, map[string]bool{ignored: true, "/elsewhere/x": true}, map[string]bool{}); !slices.Equal(got, want) {
		t.Fatalf("%v, want %v", got, want)
	}
}

// A turn's summary keeps its card as an outcome, with the undo said on it.
func TestATurnsSummaryKeepsItsCardAndItsUndo(t *testing.T) {
	es := entriesOf(t,
		`{"userMessage":{"_0":"Fix it"}}`,
		`{"agentMessage":{"messageID":"m1","text":"Fixed."}}`,
		`{"stateChanged":{"_0":"finished","reason":"endTurn"}}`,
		`{"turnChanged":{"_0":{"turn":"00000000-0000-0000-0000-000000000001","files":[{"path":"/r/a.txt","state":"modified"}]}}}`,
		`{"turnUndone":{"_0":{"turn":"00000000-0000-0000-0000-000000000001","putBack":["/r/a.txt"]}}}`,
	)
	s := turnSummaryOf(es, 0)
	last := s.Outcome[len(s.Outcome)-1]
	if last.Kind.TurnChanged == nil || last.Kind.TurnChanged.Value.Undone == nil || len(last.Kind.TurnChanged.Value.Undone.PutBack) != 1 {
		b, _ := json.Marshal(s.Outcome)
		t.Fatalf("%s", b)
	}
}
