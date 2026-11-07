package agentsd

import (
	"encoding/json"
	"path/filepath"
	"testing"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// Ports DaemonAdoptTests: a runtime's own conversations are listed for a folder, one taken
// over becomes a finished agent whose transcript is its replay, and deleting one needs a yes.

func TestTheirConversationsTakenOver(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := t.TempDir()
	var list []wire.RuntimeSession
	json.Unmarshal(c.call(t, 1, "sessions/list", map[string]any{"runtimeID": "claude", "cwd": "file://" + dir}), &list)
	if len(list) != 1 || list[0].SessionID != "theirs" || *list[0].Title != "Their talk" || list[0].UpdatedAt == nil || *list[0].IsHeld {
		t.Fatalf("%+v", list)
	}
	var id wire.UUID
	json.Unmarshal(c.call(t, 2, "sessions/adopt", map[string]any{"runtimeID": "claude", "sessionID": "theirs", "cwd": "file://" + dir}), &id)
	a := d.Store.Agent(id)
	if a == nil || a.State != wire.AgentStateFinished || *a.RuntimeSessionID != "theirs" {
		t.Fatalf("%+v", a)
	}
	if u := userMessages(d, id); len(u) != 1 || u[0] != "What is two and two?" {
		t.Fatalf("%q", u)
	}
	if k := kinds(d, id); len(k) < 3 || k[len(k)-1] != "agentMessage" {
		t.Fatal(k)
	}
	// Taken over once: the same agent, and listed as held.
	var again wire.UUID
	json.Unmarshal(c.call(t, 3, "sessions/adopt", map[string]any{"runtimeID": "claude", "sessionID": "theirs", "cwd": "file://" + dir}), &again)
	list = nil
	json.Unmarshal(c.call(t, 4, "sessions/list", map[string]any{"runtimeID": "claude", "cwd": "file://" + dir}), &list)
	if again != id || !*list[0].IsHeld {
		t.Fatalf("%s %+v", again, list)
	}
	if e := c.callError(t, 5, "sessions/delete", map[string]any{"runtimeID": "claude", "sessionID": "theirs"}); e.Code != wire.FailureNotConfirmed {
		t.Fatalf("%+v", e)
	}
	c.call(t, 6, "sessions/delete", map[string]any{"runtimeID": "claude", "sessionID": "theirs", "confirmed": true})
	if a := d.Store.Agent(id); a.RuntimeSessionID != nil {
		t.Fatal(*a.RuntimeSessionID)
	}
}

// Another tool's worktree of the folder's repository, as Conductor makes one (#3716): its
// conversations are listed with the folder's, and one taken over keeps its worktree and
// sits under the folder.
func TestConversationsInAnotherToolsWorktreeAreTheFolders(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := repo(t)
	other := filepath.Join(canonical(t.TempDir()), "workspace-oslo")
	run(t, dir, "git", "worktree", "add", "-q", "-b", "oslo", other)
	var list []wire.RuntimeSession
	json.Unmarshal(c.call(t, 1, "sessions/list", map[string]any{"runtimeID": "claude", "cwd": "file://" + dir}), &list)
	if len(list) != 2 || list[0].SessionID != "theirs" || list[1].SessionID != "theirs-oslo" || store.FolderPath(list[1].Cwd) != other {
		t.Fatalf("%+v", list)
	}
	var id wire.UUID
	json.Unmarshal(c.call(t, 2, "sessions/adopt", map[string]any{"runtimeID": "claude", "sessionID": "theirs-oslo", "cwd": list[1].Cwd}), &id)
	a := d.Store.Agent(id)
	if a == nil || a.Worktree == nil || store.FolderPath(a.Worktree.Root) != other || *a.Worktree.Branch != "oslo" || a.Worktree.MadeByApp {
		t.Fatalf("%+v", a)
	}
	if folderPath(a) != canonical(dir) {
		t.Fatalf("%s, want %s", folderPath(a), dir)
	}
	// One in the main checkout has no worktree.
	json.Unmarshal(c.call(t, 3, "sessions/adopt", map[string]any{"runtimeID": "claude", "sessionID": "theirs", "cwd": "file://" + dir}), &id)
	if a := d.Store.Agent(id); a.Worktree != nil {
		t.Fatalf("%+v", a.Worktree)
	}
}
