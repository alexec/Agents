package agentsd

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// folder.idle (#1368), as DaemonCore+FolderIdle: once a busy period, after the settle,
// with every agent that worked counted; the clean-up's own agents are not work.
func TestAFolderThatStopsWorkingIsIdleOnce(t *testing.T) {
	old := folderIdleSettle
	folderIdleSettle = 100 * time.Millisecond
	defer func() { folderIdleSettle = old }()
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	running := func(a *wire.Agent) { a.State, a.EndedReason = wire.AgentStateRunning, nil }
	finish := func(id wire.UUID) {
		d.change(id, func(a *wire.Agent) { a.State, a.EndedReason = wire.AgentStateFinished, reason(wire.EndedReasonEndTurn) })
	}
	one := seeded(t, d, dir, running)
	two := seeded(t, d, dir, running)
	d.watchForIdle(dir)
	finish(one.ID)
	// One still works: nothing yet.
	time.Sleep(3 * folderIdleSettle)
	if n := countEvents(d, "folder.idle"); n != 0 {
		t.Fatalf("%d", n)
	}
	d.change(two.ID, func(a *wire.Agent) {
		a.State, a.EndedReason = wire.AgentStateStopped, reason(wire.EndedReasonProcessDied)
	})
	waitFor(t, "folder.idle", func() bool { return countEvents(d, "folder.idle") == 1 })
	e := lastEvent(d, "folder.idle")
	if e.Scope.Folder == nil || store.FolderPath(e.Scope.Folder.Value) != dir || e.Details["agents"] != "2" ||
		e.Details["finished"] != "1" || e.Details["failed"] != "1" || e.Sentence != "Every agent here has stopped: 2 worked (1 finished, 1 failed)." {
		t.Fatalf("%+v", e)
	}
	// Quiet stays quiet: no second one.
	d.change(one.ID, func(a *wire.Agent) { a.Title = nil })
	time.Sleep(3 * folderIdleSettle)
	if n := countEvents(d, "folder.idle"); n != 1 {
		t.Fatalf("%d", n)
	}
	// The clean-up's own agent, started by a folder.idle workflow, is not work.
	os.MkdirAll(workflowsFolder(dir), 0o755)
	os.WriteFile(filepath.Join(workflowsFolder(dir), "tidy.md"), []byte("---\non: folder.idle\n---\nTidy.\n"), 0o644)
	d.rescanWorkflows(dir)
	tidy := "tidy"
	job := seeded(t, d, dir, func(a *wire.Agent) { running(a); a.StartedByWorkflow = &tidy })
	if !d.isIdleJob(&job) {
		t.Fatal("not the clean-up")
	}
	helper := seeded(t, d, dir, func(a *wire.Agent) { running(a); a.StartedByAgent = &job.ID })
	if !d.isIdleJob(&helper) {
		t.Fatal("its helper is not the clean-up's")
	}
	d.watchForIdle(dir)
	finish(job.ID)
	finish(helper.ID)
	time.Sleep(3 * folderIdleSettle)
	if n := countEvents(d, "folder.idle"); n != 1 {
		t.Fatalf("%d", n)
	}
}
