//go:build linux || darwin

package agentsd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// file.added and file.removed (#3795): raised only for the paths a wait or a trigger
// watches, once for every file that came or went together.

// fileWait is an agent in folder waiting on event with paths, its call answered on the
// channel it returns.
func fileWait(t *testing.T, d *Daemon, folder, event string, paths ...string) (wire.UUID, chan string) {
	t.Helper()
	a := seeded(t, d, folder, nil)
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	answered := make(chan string, 1)
	go func() {
		text, _ := m.tool(2, "wait_for_event", map[string]any{"events": event, "where": map[string]any{"paths": paths}, "until_minutes": 10})
		answered <- text
	}()
	waitFor(t, "the wait", func() bool {
		w := d.Store.Agent(a.ID).EventWait
		if w == nil || w.Ending != nil {
			return false
		}
		d.fileMu.Lock()
		defer d.fileMu.Unlock()
		return d.fileWatches[folder] != nil
	})
	return a.ID, answered
}

func answer(t *testing.T, answered chan string) string {
	t.Helper()
	select {
	case text := <-answered:
		return text
	case <-time.After(10 * time.Second):
		t.Fatal("the wait was not answered in 10 s")
		return ""
	}
}

func TestAPullThatAddsThreeWatchedFilesWakesOnceWithThePaths(t *testing.T) {
	folder := canonical(t.TempDir())
	os.MkdirAll(filepath.Join(folder, "reports"), 0o755)
	os.WriteFile(filepath.Join(folder, "reports", "old.csv"), []byte("old"), 0o644)
	d, _ := watched(t, folder)
	_, answered := fileWait(t, d, folder, "file.added", "reports/*.csv")
	for _, name := range []string{"a.csv", "b.csv", "c.csv", "notes.txt"} {
		os.WriteFile(filepath.Join(folder, "reports", name), []byte("x"), 0o644)
	}
	text := answer(t, answered)
	if !strings.HasPrefix(text, "file.added happened at ") || !strings.Contains(text, "reports/a.csv") ||
		!strings.Contains(text, "reports/c.csv") || strings.Contains(text, "notes.txt") || strings.Contains(text, "old.csv") {
		t.Fatal(text)
	}
	time.Sleep(3 * dropboxSettle)
	got := raised(d, "file.added")
	if len(got) != 1 {
		t.Fatalf("%d events: %+v", len(got), got)
	}
	if e := got[0]; e.Details["count"] != "3" || e.Details["paths"] != `["reports/a.csv","reports/b.csv","reports/c.csv"]` ||
		e.Sentence != "reports/a.csv and 2 more files were added." {
		t.Fatalf("%+v", e)
	}
}

func TestAWatchedFileDeletedOrMovedAwayIsRemoved(t *testing.T) {
	folder := canonical(t.TempDir())
	os.MkdirAll(filepath.Join(folder, "reports"), 0o755)
	for _, name := range []string{"a.csv", "b.csv"} {
		os.WriteFile(filepath.Join(folder, "reports", name), []byte("x"), 0o644)
	}
	d, _ := watched(t, folder)
	_, answered := fileWait(t, d, folder, "file.removed", "reports/**")
	os.Remove(filepath.Join(folder, "reports", "a.csv"))
	if text := answer(t, answered); !strings.HasPrefix(text, "file.removed happened at ") || !strings.Contains(text, "reports/a.csv") {
		t.Fatal(text)
	}
	// Moved away is removed, and moved in under another name is added: a move is both.
	_, answered = fileWait(t, d, folder, "file.*", "reports/*.csv")
	os.Rename(filepath.Join(folder, "reports", "b.csv"), filepath.Join(folder, "b.csv"))
	if text := answer(t, answered); !strings.HasPrefix(text, "file.removed happened at ") || !strings.Contains(text, "reports/b.csv") {
		t.Fatal(text)
	}
}

func TestAChangeNothingWatchesWritesNothing(t *testing.T) {
	folder := canonical(t.TempDir())
	os.MkdirAll(filepath.Join(folder, "reports"), 0o755)
	os.WriteFile(filepath.Join(folder, "reports", "kept.csv"), []byte("old"), 0o644)
	d, _ := watched(t, folder)
	// No wait at all: nothing is looked at.
	os.WriteFile(filepath.Join(folder, "reports", "early.csv"), []byte("x"), 0o644)
	time.Sleep(3 * dropboxSettle)
	agent, answered := fileWait(t, d, folder, "file.added", "reports/*.csv")
	// Not watched, written over, or the folder itself: nothing.
	os.WriteFile(filepath.Join(folder, "notes.txt"), []byte("x"), 0o644)
	os.WriteFile(filepath.Join(folder, "reports", "kept.csv"), []byte("new and longer"), 0o644)
	os.WriteFile(filepath.Join(folder, "reports", "early.csv"), []byte("again"), 0o644)
	time.Sleep(3 * dropboxSettle)
	if got := append(raised(d, "file.added"), raised(d, "file.removed")...); len(got) != 0 {
		t.Fatalf("%+v", got)
	}
	// Its call is answered before the daemon goes.
	d.endWait(agent, "person", false)
	answer(t, answered)
}

func TestAFileStillBeingWrittenIsAddedOnceAfterItStops(t *testing.T) {
	folder := canonical(t.TempDir())
	d, _ := watched(t, folder)
	_, answered := fileWait(t, d, folder, "file.added", "**/*.log")
	p := filepath.Join(folder, "out", "run.log")
	os.MkdirAll(filepath.Dir(p), 0o755)
	f, err := os.Create(p)
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 4; i++ {
		f.WriteString("line\n")
		time.Sleep(dropboxSettle / 3)
	}
	f.Close()
	if text := answer(t, answered); !strings.Contains(text, "out/run.log") {
		t.Fatal(text)
	}
	time.Sleep(3 * dropboxSettle)
	if got := raised(d, "file.added"); len(got) != 1 {
		t.Fatalf("%d events: %+v", len(got), got)
	}
}

func TestAFileWaitWithoutPathsIsRefusedAtOnce(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	a := seeded(t, d, t.TempDir(), nil)
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	for _, event := range []string{"file.added", "file.removed", "file.*"} {
		text, isErr := m.tool(2, "wait_for_event", map[string]any{"events": event, "until_minutes": 10})
		if !isErr || !strings.Contains(text, "Say which files to watch with `paths`") {
			t.Fatalf("%s: %s", event, text)
		}
	}
	text, isErr := m.tool(3, "wait_for_event", map[string]any{"events": "file.added", "where": map[string]any{"paths": []string{"/etc/*"}}, "until_minutes": 10})
	if !isErr || !strings.Contains(text, "is not a glob relative to the folder") {
		t.Fatal(text)
	}
	if d.Store.Agent(a.ID).EventWait != nil {
		t.Fatal("waiting")
	}
}

func TestAFileTriggerWithoutPathsIsUnreadable(t *testing.T) {
	if _, problem := parsePattern("file.added", map[string][]string{}); !strings.Contains(problem, "`paths`") {
		t.Fatal(problem)
	}
	if _, problem := parsePattern("file.removed", map[string][]string{"paths": {"docs/**/*.md"}}); problem != "" {
		t.Fatal(problem)
	}
}

func TestAFilePatternMatchesWhenOneOfItsPathsDoes(t *testing.T) {
	p := waitPattern{name: "file.*", filters: map[string][]string{"paths": {"reports/*.csv", "docs/**/*.md"}}}
	for paths, want := range map[string]bool{
		`["reports/a.csv"]`:         true,
		`["x.txt","docs/a/b/c.md"]`: true,
		`["reports/deep/a.csv"]`:    false,
		`["x.txt"]`:                 false,
		`not a list`:                false,
	} {
		e := wire.Event{Name: "file.added", Details: map[string]string{"paths": paths}}
		if got := p.matches(e); got != want {
			t.Errorf("%s: %v", paths, got)
		}
	}
	if p.matches(wire.Event{Name: "dropbox.file_added", Details: map[string]string{"paths": `["reports/a.csv"]`}}) {
		t.Error("another event")
	}
}

func TestGlobsCouldHoldOnlyTheFoldersTheyReach(t *testing.T) {
	globs := []string{"reports/*.csv", "docs/**/*.md"}
	for dir, want := range map[string]bool{"": true, "reports": true, "reports/old": false, "docs": true, "docs/a/b": true, "src": false} {
		if got := globsCouldHold(dir, globs); got != want {
			t.Errorf("%s: %v", dir, got)
		}
	}
	if !globsCouldHold("anything", []string{"**/*.log"}) || !globsCouldHold("x", []string{"{x,y}/a"}) {
		t.Error("** and braces reach everywhere")
	}
}

func TestAFileEventStaysOnItsMachine(t *testing.T) {
	e := wire.Event{Name: "file.added"}
	if scopeOf(fireRequest{event: &e}) != scopeMachine {
		t.Fatal("file.added left its machine")
	}
	if g, ok := eventGroup("file.removed"); !ok || g != wire.EventGroupDropbox {
		t.Fatal(g)
	}
}
