package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// Ports GuardedFilesTests: a change to the app's own files made while an agent works waits,
// the app goes on with the approved copy and will not write over it, and Keep and Undo
// settle it; the person's own edit is theirs; a pull's waits too.

func TestAChangeWhileAnAgentWorksWaitsForKeepOrUndo(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	folder := store.FolderURL(dir)
	os.WriteFile(filepath.Join(dir, "a.md"), nil, 0o644)
	c.call(t, 2, "pins/pin", map[string]any{"folder": folder, "path": "a.md"})
	approved, _ := os.ReadFile(filepath.Join(dir, ".agents", "pins.json"))
	worker := seeded(t, d, dir, func(a *wire.Agent) {
		title := "Tidy"
		a.State, a.EndedReason, a.Title = wire.AgentStateRunning, nil, &title
	})
	os.WriteFile(filepath.Join(dir, ".agents", "pins.json"), []byte(`{"pins":[]}`), 0o644)
	if f := d.readPins(dir); len(f.pins) != 1 {
		t.Fatalf("the change was used: %+v", f.pins)
	}
	if e := c.callError(t, 3, "pins/unpin", map[string]any{"folder": folder, "path": "a.md"}); !strings.HasSuffix(e.Message, "is waiting for the person to keep or undo the change in Folder Settings.") {
		t.Fatal(e.Message)
	}
	s, _ := d.summaryFor(dir)
	if len(s.GuardedChanges) != 1 || s.GuardedChanges[0].ChangedBy[0] != "Tidy" || *s.GuardedChanges[0].AskedIn != worker.ID ||
		len(s.Approvals) != 1 || s.Approvals[0].Line != "Changed by Tidy" || len(s.Approvals[0].Actions) != 3 {
		t.Fatalf("%+v %+v", s.GuardedChanges, s.Approvals)
	}
	if n := d.attentionPending().Needs; len(n) != 1 || n[0].Kind != wire.NeedKindGuardedChange || n[0].Headline.H3 != "Tidy changed .agents/pins.json" {
		t.Fatalf("%+v", n)
	}
	var reading wire.GuardedChangeReading
	json.Unmarshal(c.call(t, 4, "folders/readGuardedChange", map[string]any{"folder": folder, "path": ".agents/pins.json"}), &reading)
	if reading.Approved == nil || *reading.Approved != string(approved) || reading.Current == nil || len(reading.Lines) == 0 {
		t.Fatalf("%+v", reading)
	}
	// Undo, with the digest that was looked at: the approved copy goes back.
	if e := c.callError(t, 5, "folders/undoGuardedChange", map[string]any{"folder": folder, "path": ".agents/pins.json", "digest": "stale"}); e.Code != wire.FailureNotChanged {
		t.Fatalf("%+v", e)
	}
	c.call(t, 6, "approvals/answer", map[string]any{"folder": folder, "kind": "file", "key": ".agents/pins.json", "digest": reading.Digest, "action": "deny"})
	if b, _ := os.ReadFile(filepath.Join(dir, ".agents", "pins.json")); string(b) != string(approved) {
		t.Fatalf("%s", b)
	}
	if s, _ := d.summaryFor(dir); len(s.GuardedChanges) != 0 {
		t.Fatalf("%+v", s.GuardedChanges)
	}
	// Changed again and kept: the change is used from now on.
	os.WriteFile(filepath.Join(dir, ".agents", "pins.json"), []byte(`{"pins":[]}`), 0o644)
	d.readPins(dir)
	json.Unmarshal(c.call(t, 7, "folders/readGuardedChange", map[string]any{"folder": folder, "path": ".agents/pins.json"}), &reading)
	c.call(t, 8, "folders/keepGuardedChange", map[string]any{"folder": folder, "path": ".agents/pins.json", "digest": reading.Digest})
	if f := d.readPins(dir); len(f.pins) != 0 {
		t.Fatalf("%+v", f.pins)
	}
}

func TestThePersonsOwnEditIsTheirs(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	os.WriteFile(filepath.Join(dir, "a.md"), nil, 0o644)
	c.call(t, 2, "pins/pin", map[string]any{"folder": store.FolderURL(dir), "path": "a.md"})
	os.WriteFile(filepath.Join(dir, ".agents", "pins.json"), []byte(`{"pins":[]}`), 0o644)
	if f := d.readPins(dir); len(f.pins) != 0 {
		t.Fatal("an edit with nothing running, outside a repository, is the person's")
	}
}

func TestAPullsChangeWaits(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := repo(t)
	c.call(t, 1, "folders/add", map[string]any{"folder": store.FolderURL(dir)})
	os.MkdirAll(filepath.Join(dir, ".agents"), 0o755)
	os.WriteFile(filepath.Join(dir, ".agents", "folder.json"), []byte(`{"diskSpace":{"lowGB":30}}`), 0o644)
	d.checkGuarded(dir, ".agents/folder.json", nil) // first seen: approved
	pulled := []byte(`{"diskSpace":{"lowGB":90}}`)
	os.WriteFile(filepath.Join(dir, ".agents", "folder.json"), pulled, 0o644)
	git(dir, "add", ".agents/folder.json")
	git(dir, "commit", "-q", "-m", "pulled")
	d.checkGuarded(dir, ".agents/folder.json", nil)
	s, _ := d.summaryFor(dir)
	if len(s.GuardedChanges) != 1 || !s.GuardedChanges[0].ByGit || s.Approvals[0].Line != "Changed with the last pull" ||
		s.Folder.DiskSpace == nil || *s.Folder.DiskSpace.LowGB != 30 {
		t.Fatalf("%+v %+v %+v", s.GuardedChanges, s.Approvals, s.Folder.DiskSpace)
	}
	if e := c.callError(t, 2, "folders/setDiskSpace", map[string]any{"folder": store.FolderURL(dir), "diskSpace": map[string]any{"lowGB": 40}}); !strings.HasPrefix(e.Message, "The disk space lines were not changed: ") {
		t.Fatal(e.Message)
	}
}

func TestDiffLines(t *testing.T) {
	got := diffLines("a\nb\nc\n", "a\nB\nc\nd\n")
	var s []string
	for _, l := range got {
		s = append(s, string(l.Kind)+":"+l.Text)
	}
	if strings.Join(s, " ") != "same:a removed:b added:B same:c added:d" {
		t.Fatal(s)
	}
}

// A change waiting on a file the app no longer keeps goes when the records are read (#2680).
func TestAFileTheAppNoLongerKeepsWaitsForNothing(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	recs := guardedRecords{States: []guardedState{
		{Folder: store.FolderURL(dir), Path: ".agents/project.json", Pending: &guardedPending{ChangedByIDs: []wire.UUID{}, ChangedBy: []string{"Tidy"}}},
		{Folder: store.FolderURL(dir), Path: ".agents/pins.json", Pending: &guardedPending{ChangedByIDs: []wire.UUID{}, ChangedBy: []string{"Tidy"}}},
	}}
	b, _ := json.Marshal(recs)
	os.WriteFile(d.guardedFile(), b, 0o644)
	d.guardedMu.Lock()
	d.guarded = nil
	d.guardedMu.Unlock()
	if s, _ := d.summaryFor(dir); len(s.GuardedChanges) != 1 || s.GuardedChanges[0].Path != ".agents/pins.json" {
		t.Fatalf("%+v", s.GuardedChanges)
	}
}
