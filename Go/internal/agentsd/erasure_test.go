package agentsd

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// eraseInTests turns the eraser on for one test, as TestMain leaves it off.
func eraseInTests(t *testing.T) {
	erasing = true
	t.Cleanup(func() { erasing = false })
}

// erasuresDone is whether the queue is empty and the eraser idle.
func (d *Daemon) erasuresDone() bool {
	d.erasures.mu.Lock()
	defer d.erasures.mu.Unlock()
	_, err := os.Stat(d.erasuresPath())
	return os.IsNotExist(err) && !d.erasures.busy
}

func archivedWithSession(t *testing.T, d *Daemon, dir, session string) wire.Agent {
	byUser := wire.AgentArchivedReasonByUser
	return seeded(t, d, dir, func(a *wire.Agent) {
		a.State, a.ArchivedReason, a.RuntimeSessionID = wire.AgentStateArchived, &byUser, &session
	})
}

// Delete asks the runtime to delete its copy and leaves no file of the session in
// Claude's config folder (#1001, SC-002).
func TestDeleteLeavesNoRuntimeSessionFile(t *testing.T) {
	eraseInTests(t)
	fakeRuntimes(t)
	scratch := t.TempDir()
	claude := filepath.Join(scratch, "claude")
	t.Setenv("HOME", filepath.Join(scratch, "home"))
	t.Setenv("CLAUDE_CONFIG_DIR", claude)
	deleted := filepath.Join(scratch, "deleted")
	t.Setenv("AGENTS_FAKE_DELETED", deleted)

	d, c := start(t, t.TempDir())
	dir := folder(t, c, 1)
	session := "5b0f6a1e-1c2d-4e3f-8a9b-0c1d2e3f4a5b"
	a := archivedWithSession(t, d, dir, session)
	theirs := []string{
		filepath.Join(claude, "folders", "-w", session+".jsonl"),
		filepath.Join(claude, "folders", "-w", session, "subagents", "agent-1.jsonl"),
		filepath.Join(claude, "todos", session+"-agent-"+session+".json"),
		filepath.Join(claude, "file-history", session, "a.txt"),
	}
	other := filepath.Join(claude, "folders", "-w", "another-session.jsonl")
	for _, f := range append(theirs, other) {
		writeFile(t, f, "{}\n")
	}

	c.call(t, 2, "agents/delete", map[string]any{"agentID": a.ID})
	waitFor(t, "the erasure", d.erasuresDone)
	for _, f := range theirs {
		if _, err := os.Stat(f); !os.IsNotExist(err) {
			t.Errorf("left behind: %s (%v)", f, err)
		}
	}
	if _, err := os.Stat(filepath.Join(claude, "folders", "-w", session)); !os.IsNotExist(err) {
		t.Error("the session's folder is left")
	}
	if _, err := os.Stat(other); err != nil {
		t.Errorf("another session's file went: %v", err)
	}
	if b, _ := os.ReadFile(deleted); strings.TrimSpace(string(b)) != session {
		t.Errorf("the runtime was asked to delete %q", b)
	}
	if got := lastEvent(d, "agent.deleted"); got == nil || got.Details["runtimeCopy"] != "queued" {
		t.Errorf("agent.deleted is %+v", got)
	}
}

// A runtime that cannot be started: Codex's files are removed all the same, from the home
// its launch would name.
func TestCodexFilesGoWithoutTheRuntime(t *testing.T) {
	home := t.TempDir()
	session := "019a2b3c-4d5e-7f60-8a9b-0c1d2e3f4a5b"
	mine := filepath.Join(home, "sessions", "2026", "10", "22", "rollout-2026-10-22T06-00-00-"+session+".jsonl")
	archived := filepath.Join(home, "archived_sessions", "rollout-2026-10-01T06-00-00-"+session+".jsonl")
	other := filepath.Join(home, "sessions", "2026", "10", "22", "rollout-2026-10-22T06-00-00-019a0000-0000-7000-8000-000000000000.jsonl")
	for _, f := range []string{mine, archived, other} {
		writeFile(t, f, "{}\n")
	}
	known, removed := eraseRuntimeFiles("codex", session, []string{"HOME=/nowhere", "CODEX_HOME=" + home})
	if !known || removed != 2 {
		t.Fatalf("known %v, removed %d", known, removed)
	}
	if _, err := os.Stat(other); err != nil {
		t.Fatalf("another session's file went: %v", err)
	}
	// A session ID that could reach outside the folder is never put in a pattern.
	for _, bad := range []string{"../x", "*", "a/b", ""} {
		if known, removed := eraseRuntimeFiles("claude", bad, nil); known || removed != 0 {
			t.Fatalf("%q: known %v, removed %d", bad, known, removed)
		}
	}
	if known, _ := eraseRuntimeFiles("grok", session, nil); known {
		t.Fatal("grok's layout is not known")
	}
}

// Only a runtime copy this set-up made, and that no kept agent still holds, is erased.
func TestDeleteErasesOnlyItsOwnRuntimeCopy(t *testing.T) {
	d, c := start(t, t.TempDir())
	dir := folder(t, c, 1)
	other := "another-root"
	copied := archivedWithSession(t, d, dir, "copied")
	d.change(copied.ID, func(a *wire.Agent) { a.MadeInRoot = &other })
	shared := archivedWithSession(t, d, dir, "shared")
	archivedWithSession(t, d, dir, "shared")
	own := archivedWithSession(t, d, dir, "own")
	for i, a := range []wire.Agent{copied, shared, own} {
		c.call(t, 2+i, "agents/delete", map[string]any{"agentID": a.ID})
	}
	if q := d.readErasures(); len(q) != 1 || q[0].SessionID != "own" {
		t.Fatalf("queued %+v", q)
	}
	if got := lastEvent(d, "agent.deleted"); got == nil || got.Details["runtimeCopy"] != "queued" {
		t.Errorf("agent.deleted is %+v", got)
	}
}

// The queue is bounded, and kept across a restart only for erasureTries and erasureKeep.
func TestTheErasureQueueIsBounded(t *testing.T) {
	root := t.TempDir()
	d, c := start(t, root)
	dir := folder(t, c, 1)
	full := make([]erasure, erasuresMost)
	for i := range full {
		full[i] = erasure{AgentID: store.NewUUID(), RuntimeID: "claude", SessionID: "s", QueuedAt: nowFunc()}
	}
	d.writeErasures(full)
	a := archivedWithSession(t, d, dir, "newest")
	c.call(t, 2, "agents/delete", map[string]any{"agentID": a.ID})
	q := d.readErasures()
	if len(q) != erasuresMost || q[0].AgentID == full[0].AgentID || q[len(q)-1].SessionID != "newest" {
		t.Fatalf("queue of %d, first %s, last %s", len(q), q[0].AgentID, q[len(q)-1].SessionID)
	}

	keep := erasure{AgentID: store.NewUUID(), RuntimeID: "claude", SessionID: "keep", QueuedAt: nowFunc(), Tries: erasureTries - 1}
	d.writeErasures([]erasure{
		keep,
		{AgentID: store.NewUUID(), RuntimeID: "claude", SessionID: "tried", QueuedAt: nowFunc(), Tries: erasureTries},
		{AgentID: store.NewUUID(), RuntimeID: "claude", SessionID: "old", QueuedAt: nowFunc().Add(-erasureKeep - time.Hour)},
	})
	d.Shutdown()
	d, _ = start(t, root)
	if q := d.readErasures(); len(q) != 1 || q[0].SessionID != "keep" {
		t.Fatalf("after a restart: %+v", q)
	}
}

// The erased list is bounded by count, oldest out, and by age.
func TestTheErasedListIsBounded(t *testing.T) {
	d, _ := start(t, t.TempDir())
	old := map[wire.UUID]time.Time{store.NewUUID(): nowFunc().Add(-erasedKeep - time.Hour)}
	d.erasures.mu.Lock()
	d.noteErasedLocked(old)
	if len(d.readErasedLocked()) != 0 {
		t.Fatal("an ID past erasedKeep is kept")
	}
	many := map[wire.UUID]time.Time{}
	first := store.NewUUID()
	many[first] = nowFunc().Add(-time.Hour)
	for range erasedMost {
		many[store.NewUUID()] = nowFunc()
	}
	d.noteErasedLocked(many)
	list := d.readErasedLocked()
	d.erasures.mu.Unlock()
	if _, ok := list[first]; ok || len(list) != erasedMost {
		t.Fatalf("%d IDs, oldest kept %v", len(list), ok)
	}
}

// A restore never brings back an agent this machine deleted, also from another machine's
// backup that carries its list (#1001, SC-003).
func TestARestoreSkipsAnErasedAgent(t *testing.T) {
	clock := atTime(t, time.Date(2026, 10, 22, 9, 0, 0, 0, time.UTC))
	shared := t.TempDir()
	a, ca := start(t, t.TempDir())
	dir := folder(t, ca, 1)
	ca.call(t, 2, "backups/configure", map[string]any{"every": "off", "keep": 3, "folder": shared})
	kept := archivedWithSession(t, a, dir, "kept")
	gone := archivedWithSession(t, a, dir, "gone")
	made, err := a.makeBackup()
	if err != nil {
		t.Fatal(err)
	}
	ca.call(t, 3, "agents/delete", map[string]any{"agentID": gone.ID})

	var res wire.BackupRestoreResult
	if err := json.Unmarshal(ca.call(t, 4, "backups/restore", map[string]any{"id": made.ID}), &res); err != nil {
		t.Fatal(err)
	}
	if a.Store.Agent(gone.ID) != nil || res.Restored != 0 || res.Skipped != 2 {
		t.Fatalf("restored %+v, the deleted agent back: %v", res, a.Store.Agent(gone.ID) != nil)
	}

	// A newer backup carries the list: a new machine that restores it, then the older one,
	// does not bring the deleted agent back either.
	clock.add(time.Hour)
	newer, err := a.makeBackup()
	if err != nil {
		t.Fatal(err)
	}
	b, cb := start(t, t.TempDir())
	cb.call(t, 1, "backups/configure", map[string]any{"every": "off", "keep": 3, "folder": shared})
	cb.call(t, 2, "backups/restore", map[string]any{"id": newer.ID})
	cb.call(t, 3, "backups/restore", map[string]any{"id": made.ID})
	if b.Store.Agent(gone.ID) != nil || b.Store.Agent(kept.ID) == nil {
		t.Fatalf("on the new machine: deleted back %v, kept missing %v", b.Store.Agent(gone.ID) != nil, b.Store.Agent(kept.ID) == nil)
	}
	if !strings.Contains(string(mustRead(t, filepath.Join(b.Store.Loc.Root, erasedFile))), string(gone.ID)) {
		t.Fatal("the new machine's list does not name the deleted agent")
	}
}

func mustRead(t *testing.T, file string) []byte {
	t.Helper()
	b, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// A sweep of 200 archived agents starts the runtime once a batch to erase them, and writes
// each file a few times, not 3 times an agent; an adapter that cannot delete is not
// started again for the next sweep (#2427).
func TestASweepStartsTheRuntimeOnce(t *testing.T) {
	eraseInTests(t)
	fakeRuntimes(t)
	scratch := t.TempDir()
	t.Setenv("HOME", filepath.Join(scratch, "home"))
	t.Setenv("CLAUDE_CONFIG_DIR", filepath.Join(scratch, "claude"))
	starts, deleted := filepath.Join(scratch, "starts"), filepath.Join(scratch, "deleted")
	t.Setenv("AGENTS_FAKE_STARTS", starts)
	t.Setenv("AGENTS_FAKE_DELETED", deleted)
	var writes atomic.Int64
	old := writeErasureFile
	writeErasureFile = func(file string, data []byte, mode os.FileMode) error {
		writes.Add(1)
		return old(file, data, mode)
	}
	t.Cleanup(func() { writeErasureFile = old })
	lines := func(file string) int {
		b, _ := os.ReadFile(file)
		return strings.Count(string(b), "\n")
	}

	d, c := start(t, t.TempDir())
	dir := folder(t, c, 1)
	// Nobody reads this client's notifications: drop them, so a broadcast never waits.
	quiet := make(chan struct{})
	t.Cleanup(func() { close(quiet) })
	go func() {
		for {
			select {
			case <-c.out:
			case <-quiet:
				return
			}
		}
	}()
	sweep := func(n int) {
		t.Helper()
		byUser := wire.AgentArchivedReasonByUser
		for i := range n {
			session := fmt.Sprintf("s%d-%d", lines(starts), i)
			seeded(t, d, dir, func(a *wire.Agent) {
				at := wire.DateOf(nowFunc().Add(-31 * 24 * time.Hour))
				a.State, a.ArchivedAt, a.ArchivedReason, a.RuntimeSessionID = wire.AgentStateArchived, &at, &byUser, &session
			})
		}
		began := time.Now()
		if got := d.sweepArchived(); got != n {
			t.Fatalf("deleted %d of %d", got, n)
		}
		waitFor(t, "the erasures", d.erasuresDone)
		t.Logf("%d agents: %d runtime starts, %d file writes, %v", n, lines(starts), writes.Load(), time.Since(began))
	}

	sweep(200)
	if n := lines(deleted); n != 200 {
		t.Fatalf("the runtime deleted %d of 200", n)
	}
	if n := lines(starts); n > 200/eraseBatch+1 {
		t.Fatalf("%d runtime starts for 200 agents", n)
	}
	if n := writes.Load(); n > 20 {
		t.Fatalf("%d file writes for 200 agents", n)
	}

	// An adapter that cannot delete: asked once, then not started again.
	t.Setenv("AGENTS_FAKE_NO_DELETE", "1")
	os.Remove(starts)
	sweep(20)
	sweep(20)
	if n := lines(starts); n != 1 {
		t.Fatalf("%d runtime starts for an adapter that cannot delete", n)
	}
}
