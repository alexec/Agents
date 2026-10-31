package agentsd

import (
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
)

// #2292: host files that were never removed each have a bound. Each test makes one more
// than the bound and finds the bound.

func dirNames(t *testing.T, dir string) []string {
	t.Helper()
	entries, _ := os.ReadDir(dir)
	var out []string
	for _, e := range entries {
		out = append(out, e.Name())
	}
	return out
}

// A copy of an approved workflow goes once no record names it: an edit approved again
// leaves only the new copy.
func TestOnlyTheNamedWorkflowCopiesAreKept(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	folder := store.FolderURL(dir)
	os.MkdirAll(workflowsFolder(dir), 0o755)
	file := filepath.Join(workflowsFolder(dir), "nightly.md")
	stray := strings.Repeat("ab", 32)
	os.MkdirAll(d.workflowCopies(), 0o755)
	os.WriteFile(filepath.Join(d.workflowCopies(), stray), []byte("an old version"), 0o644)
	var first []string
	for i := range 3 {
		os.WriteFile(file, fmt.Appendf(nil, "---\non:\n  - schedule:\n      at: \":00\"\n---\nTidy up %d.\n", i), 0o644)
		approveAll(t, c, folder)
		copies := dirNames(t, d.workflowCopies())
		if len(copies) != 1 {
			t.Fatalf("version %d: %v, want the one copy", i, copies)
		}
		if i > 0 && copies[0] == first[0] {
			t.Fatalf("version %d kept the copy of version 0", i)
		}
		if i == 0 {
			first = copies
		}
	}
}

// The newest 50 assessments are kept, each with its score and its scope file.
func TestTheNewestAssessmentsAreKept(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	dir := d.assessmentsPath()
	os.MkdirAll(dir, 0o755)
	old := time.Now().Add(-time.Hour)
	for i := range assessmentsKept + 1 {
		id := fmt.Sprintf("agent-%02d", i)
		scope := filepath.Join(dir, "scope-"+id+".txt")
		os.WriteFile(scope, []byte("scope"), 0o644)
		os.WriteFile(filepath.Join(dir, id+".json"), []byte("{}"), 0o644)
		kept := filepath.Join(dir, id+".start.json")
		writeStore(kept, assessStart{AgentID: "x", ScopePath: scope})
		// agent-00 is the oldest.
		at := old.Add(time.Duration(i) * time.Second)
		os.Chtimes(kept, at, at)
	}
	d.dropOldAssessments()
	got := dirNames(t, dir)
	if len(got) != 3*assessmentsKept {
		t.Fatalf("%d files, want %d", len(got), 3*assessmentsKept)
	}
	for _, gone := range []string{"agent-00.start.json", "agent-00.json", "scope-agent-00.txt"} {
		if slices.Contains(got, gone) {
			t.Errorf("%s was kept", gone)
		}
	}
}

// mcp-logs keeps the newest 32 servers' logs, the one opened among them.
func TestTheNewestServerLogsAreKept(t *testing.T) {
	dir := t.TempDir()
	old := time.Now().Add(-time.Hour)
	for i := range hostedLogsKept + 1 {
		p := filepath.Join(dir, fmt.Sprintf("server-%02d.log", i))
		os.WriteFile(p, []byte("x"), 0o600)
		os.WriteFile(p+".1", []byte("x"), 0o600)
		at := old.Add(time.Duration(i) * time.Second)
		os.Chtimes(p, at, at)
	}
	// The one opened is the oldest, and stays.
	dropOldHostedLogs(dir, "server-00.log")
	got := dirNames(t, dir)
	if len(got) != 2*hostedLogsKept {
		t.Fatalf("%d files, want %d: %v", len(got), 2*hostedLogsKept, got)
	}
	for _, gone := range []string{"server-01.log", "server-01.log.1"} {
		if slices.Contains(got, gone) {
			t.Errorf("%s was kept", gone)
		}
	}
	if !slices.Contains(got, "server-00.log") || !slices.Contains(got, "server-32.log") {
		t.Errorf("the opened or the newest log went: %v", got)
	}
}

// A folder that is no longer a folder leaves events-state.json's branch tips. On the
// map alone: a started daemon's own folder watch drops "/kept" too, as it has no folder.
func TestBranchTipsOfAGoneFolderGo(t *testing.T) {
	tips := map[string]map[string]string{"/kept": {"main": "a"}, "/gone": {"main": "b"}}
	if !dropGone(tips, map[string]bool{"/kept": true}) {
		t.Fatal("nothing went")
	}
	if _, ok := tips["/gone"]; ok || len(tips) != 1 {
		t.Fatalf("%v", tips)
	}
	if dropGone(tips, map[string]bool{"/kept": true}) {
		t.Fatal("a second drop said one went")
	}
}
