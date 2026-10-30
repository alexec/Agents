package agentsd

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// runtimeNotes is what the app said in a session's chat.
func runtimeNotes(d *Daemon, id wire.UUID) []string {
	entries, _, _ := d.Store.Transcript(id, 0)
	var out []string
	for _, e := range entries {
		if e.Kind.RuntimeNote != nil {
			out = append(out, e.Kind.RuntimeNote.Value)
		}
	}
	return out
}

// inWorktree puts a seeded session in a worktree of folder on branch, at root.
func inWorktree(folder, root, branch string) func(a *wire.Agent) {
	return func(a *wire.Agent) {
		a.Worktree = &wire.AgentWorktree{Name: filepath.Base(root), Root: store.FolderURL(root), Branch: &branch,
			MadeByApp: true, Folder: store.FolderURL(folder)}
	}
}

// mergedEvent is a server's pr.merged for a pull request from branch, as raiseMCPEvent
// gives it.
func mergedEvent(folder, branch string, number int) wire.Event {
	payload, _ := json.Marshal(map[string]any{"pr": map[string]any{"number": number, "title": "Fix it", "branch": branch, "url": "u"}})
	return wire.Event{Name: "pr.merged", Scope: folderScope(folder),
		Details: map[string]string{"server": "github", "payload": string(payload)}}
}

// #2886: a session whose pull request merges is archived when its turn has ended and its
// worktree has nothing uncommitted; any other is told, once; the switch off does nothing.
func TestASessionIsArchivedWhenItsPullRequestMerges(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	trees := t.TempDir()

	done := seeded(t, d, dir, inWorktree(dir, filepath.Join(trees, "done"), "agents/done"))
	d.archiveMergedSessions(mergedEvent(dir, "agents/done", 7))
	if a := d.Store.Agent(done.ID); a.State != wire.AgentStateArchived || a.ArchivedReason == nil ||
		*a.ArchivedReason != wire.AgentArchivedReasonByAgent {
		t.Fatalf("a done session whose pull request merged is archived: %+v", a.State)
	}
	if notes := runtimeNotes(d, done.ID); len(notes) != 1 || notes[0] != "Its pull request #7 merged, so it was archived, as this folder's settings say." {
		t.Fatalf("%q", notes)
	}

	// Another branch, another folder: nothing.
	other := seeded(t, d, dir, inWorktree(dir, filepath.Join(trees, "other"), "agents/other"))
	d.archiveMergedSessions(mergedEvent(dir, "agents/done", 7))
	d.archiveMergedSessions(mergedEvent(t.TempDir(), "agents/other", 8))
	if a := d.Store.Agent(other.ID); a.State == wire.AgentStateArchived || len(runtimeNotes(d, other.ID)) != 0 {
		t.Fatalf("only the merged branch's session, in its folder: %+v", a.State)
	}

	// Working: told once, however many subscriptions heard it.
	working := seeded(t, d, dir, func(a *wire.Agent) {
		inWorktree(dir, filepath.Join(trees, "working"), "agents/working")(a)
		a.State, a.EndedReason = wire.AgentStateRunning, nil
	})
	d.archiveMergedSessions(mergedEvent(dir, "agents/working", 9))
	d.archiveMergedSessions(mergedEvent(dir, "agents/working", 9))
	if a := d.Store.Agent(working.ID); a.State != wire.AgentStateRunning {
		t.Fatalf("a working session is not archived: %+v", a.State)
	}
	if notes := runtimeNotes(d, working.ID); len(notes) != 1 || !strings.HasPrefix(notes[0], "Its pull request #9 merged. It was not archived") {
		t.Fatalf("%q", notes)
	}

	// Done, but with something uncommitted in its worktree: told.
	dirty := filepath.Join(trees, "dirty")
	if err := os.MkdirAll(dirty, 0o755); err != nil {
		t.Fatal(err)
	}
	if out, err := exec.Command("git", "-C", dirty, "init", "-q").CombinedOutput(); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	if err := os.WriteFile(filepath.Join(dirty, "notes.txt"), []byte("not yet\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	uncommitted := seeded(t, d, dir, inWorktree(dir, dirty, "agents/dirty"))
	d.archiveMergedSessions(mergedEvent(dir, "agents/dirty", 10))
	if a := d.Store.Agent(uncommitted.ID); a.State == wire.AgentStateArchived || len(runtimeNotes(d, uncommitted.ID)) != 1 {
		t.Fatalf("uncommitted work is not archived: %+v", a.State)
	}

	// The switch off: nothing, and the file keeps the choice.
	c.call(t, 2, "folders/setHelperLimits", map[string]any{"folder": store.FolderURL(dir), "limits": map[string]any{"archiveWhenMerged": false}})
	if d.archivesWhenMerged(dir) {
		t.Fatal("the switch is off")
	}
	off := seeded(t, d, dir, inWorktree(dir, filepath.Join(trees, "off"), "agents/off"))
	d.archiveMergedSessions(mergedEvent(dir, "agents/off", 11))
	if a := d.Store.Agent(off.ID); a.State == wire.AgentStateArchived || len(runtimeNotes(d, off.ID)) != 0 {
		t.Fatalf("the switch off archives nothing: %+v", a.State)
	}
	if folders := d.mergeArchiveFolders(); len(folders) != 0 {
		t.Fatalf("nothing to hear with the switch off: %v", folders)
	}
	// On again is the default, so no choice is kept.
	c.call(t, 3, "folders/setHelperLimits", map[string]any{"folder": store.FolderURL(dir), "limits": map[string]any{"archiveWhenMerged": true}})
	if m, _ := readFolderConfig(dir); m["helperLimits"] != nil {
		t.Fatalf("the default is no choice at all: %v", m["helperLimits"])
	}
}

// #2886: with no workflow and no wait, a session in a worktree is enough for this host to
// hear its server's pr.merged, and a merge archives it.
func TestAMergeHeardWithNoWorkflowArchivesItsSession(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	ci := newEventsServer(t)
	serverHome(t, d, ci.URL)
	quickPolls(d)
	dir := folder(t, c, 1)
	a := seeded(t, d, dir, inWorktree(dir, filepath.Join(t.TempDir(), "lane"), "agents/lane"))
	d.StartMCPEvents()

	waitFor(t, "the first poll", func() bool { return ci.polled("c1") })
	ci.mu.Lock()
	ci.queued = []map[string]any{{"eventId": "m1", "name": "pr.merged",
		"data": map[string]any{"pr": map[string]any{"number": 7, "branch": "agents/lane"}}}}
	ci.mu.Unlock()
	waitFor(t, "the session archived", func() bool { return d.Store.Agent(a.ID).State == wire.AgentStateArchived })
	key := mcpTrigger{event: "pr.merged", arguments: map[string]json.RawMessage{}}.subscriptionKey("ci")
	if got := mcpEventsRaised(d, "m1"); len(got) != 1 || got[0].Details["subscription"] != key {
		t.Fatalf("raised once, on the subscription a workflow on pr.merged would share: %+v", got)
	}
}
