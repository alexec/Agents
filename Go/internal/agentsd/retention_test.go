package agentsd

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/agentloops-dev/agents/Go/internal/agentsd/store"
	"github.com/agentloops-dev/agents/Go/wire"
)

func TestRetentionDeletesOldArchivedAgents(t *testing.T) {
	clock := atTime(t, time.Date(2026, 10, 19, 12, 0, 0, 0, time.UTC))
	root := t.TempDir()
	d, c := start(t, root)
	defer d.Shutdown()
	dir := folder(t, c, 1)
	byUser := wire.AgentArchivedReasonByUser
	archived := func(ago time.Duration) wire.Agent {
		return seeded(t, d, dir, func(a *wire.Agent) {
			at := wire.DateOf(clock.now().Add(-ago))
			a.State, a.ArchivedAt, a.ArchivedReason = wire.AgentStateArchived, &at, &byUser
		})
	}
	old := archived(31 * 24 * time.Hour)
	recent := archived(29 * 24 * time.Hour)
	noTime := seeded(t, d, dir, func(a *wire.Agent) {
		a.State, a.ArchivedReason = wire.AgentStateArchived, &byUser
	})
	live := seeded(t, d, dir, func(a *wire.Agent) {
		at := wire.DateOf(clock.now().Add(-100 * 24 * time.Hour))
		a.ArchivedAt = &at // not archived: a stale time is not enough
	})
	// A pin made while it was finished, then archived outside the app: kept.
	pinned := seeded(t, d, dir, nil)
	c.call(t, 2, "pins/pinSession", map[string]any{"folder": store.FolderURL(dir), "agentID": pinned.ID})
	at := wire.DateOf(clock.now().Add(-60 * 24 * time.Hour))
	pinned.State, pinned.ArchivedAt, pinned.ArchivedReason = wire.AgentStateArchived, &at, &byUser
	if err := d.Store.Save(pinned); err != nil {
		t.Fatal(err)
	}

	// The default is 30 days.
	if n := d.sweepArchived(); n != 1 || d.Store.Agent(old.ID) != nil {
		t.Fatalf("deleted %d, old still there: %v", n, d.Store.Agent(old.ID) != nil)
	}
	if _, err := os.Stat(filepath.Join(root, "agents", string(old.ID))); !os.IsNotExist(err) {
		t.Fatalf("folder left: %v", err)
	}
	for _, id := range []wire.UUID{recent.ID, noTime.ID, live.ID, pinned.ID} {
		if d.Store.Agent(id) == nil {
			t.Fatalf("%s was deleted", id)
		}
	}

	if a := d.Store.Agent(noTime.ID); a.ArchivedAt == nil || *a.ArchivedAt != wire.DateOf(clock.now()) {
		t.Fatalf("no archive time stamped: %+v", a.ArchivedAt)
	}

	// Forever deletes nothing, however old.
	os.MkdirAll(d.SettingsDir, 0o700)
	os.WriteFile(filepath.Join(d.SettingsDir, "retention.json"), []byte(`{"keepFor":"forever"}`), 0o600)
	clock.add(365 * 24 * time.Hour)
	if n := d.sweepArchived(); n != 0 || d.Store.Agent(recent.ID) == nil {
		t.Fatalf("forever deleted %d", n)
	}

	// Seven days: the recent one goes too; a value this build cannot read is 30 days.
	os.WriteFile(filepath.Join(d.SettingsDir, "retention.json"), []byte(`{"keepFor":"days7"}`), 0o600)
	clock.set(time.Date(2026, 10, 19, 12, 0, 0, 0, time.UTC))
	if n := d.sweepArchived(); n != 1 || d.Store.Agent(recent.ID) != nil || d.Store.Agent(pinned.ID) == nil || d.Store.Agent(noTime.ID) == nil {
		t.Fatalf("days7 deleted %d", n)
	}
	os.WriteFile(filepath.Join(d.SettingsDir, "retention.json"), []byte(`{"keepFor":"days1000"}`), 0o600)
	if d.keepFor() != wire.RetentionKeepForDays30 {
		t.Fatal(d.keepFor())
	}
}

// What a crash left is swept at start, but not what was made since (#3649).
func TestStartSweepsCrashLeftovers(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	old := time.Now().Add(-time.Hour)
	made := func(path string, at time.Time) string {
		t.Helper()
		if err := os.MkdirAll(path, 0o700); err != nil {
			t.Fatal(err)
		}
		os.Chtimes(path, at, at)
		return path
	}
	restore := made(filepath.Join(d.Store.Loc.Root, ".restore-123"), old)
	other := made(filepath.Join(d.Store.Loc.Root, ".kept"), old)
	staged := made(filepath.Join(d.Store.Loc.Cache, "catalog-staging", "A"), old)
	output := made(filepath.Join(d.Store.Loc.Cache, "browser", "output", "B"), old)
	since := made(filepath.Join(d.Store.Loc.Cache, "browser", "output", "C"), time.Now().Add(time.Minute))
	d.sweepCrashLeftovers(time.Now())
	for path, want := range map[string]bool{restore: false, staged: false, output: false, other: true, since: true} {
		if _, err := os.Stat(path); (err == nil) != want {
			t.Errorf("%s: kept %v, want %v", path, err == nil, want)
		}
	}
}

// The hour's sweep lets go of a week-old run whose agent ended, and of an abandoned
// transfer, without waiting for a start or the next send (#3649).
func TestTheHourlySweepAppliesLateBounds(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	ended := seeded(t, d, t.TempDir(), func(a *wire.Agent) { a.State = wire.AgentStateFinished })
	working := seeded(t, d, t.TempDir(), func(a *wire.Agent) { a.State = wire.AgentStateRunning })
	weekAgo := wire.DateOf(time.Now().Add(-8 * 24 * time.Hour))
	d.workflowMu.Lock()
	d.recordsLocked().Runs = []workflowRun{
		{ID: store.NewUUID(), WorkflowID: "ended", AgentID: &ended.ID, StartedAt: weekAgo},
		{ID: store.NewUUID(), WorkflowID: "working", AgentID: &working.ID, StartedAt: weekAgo},
		{ID: store.NewUUID(), WorkflowID: "young", AgentID: &ended.ID, StartedAt: wire.DateOf(time.Now())},
	}
	d.workflowMu.Unlock()
	transfer := func(dir, name string, at time.Time) string {
		t.Helper()
		os.MkdirAll(dir, 0o700)
		path := filepath.Join(dir, name)
		os.WriteFile(path, []byte("x"), 0o600)
		os.Chtimes(path, at, at)
		return path
	}
	stale := transfer(d.incomingFolder(), "stale", time.Now().Add(-2*transferLimit))
	fresh := transfer(d.outgoingFolder(), "fresh", time.Now())
	d.sweepHourly()
	d.workflowMu.Lock()
	var left []string
	for _, r := range d.recordsLocked().Runs {
		left = append(left, r.WorkflowID)
	}
	d.workflowMu.Unlock()
	if len(left) != 2 || left[0] != "working" || left[1] != "young" {
		t.Fatalf("runs left %v, want [working young]", left)
	}
	if _, err := os.Stat(stale); err == nil {
		t.Fatal("an abandoned transfer was kept")
	}
	if _, err := os.Stat(fresh); err != nil {
		t.Fatal("a transfer under way was deleted")
	}
}
