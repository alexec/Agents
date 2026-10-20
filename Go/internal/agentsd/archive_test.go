package agentsd

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// An archive during a turn (#1611): the runtime that only a SIGTERM ends is not taken for
// a crash, nothing asks for the person, the session stays archived, and the next start
// does not pick it back up (#1605).
func TestAnArchiveDuringATurnStaysArchived(t *testing.T) {
	fakeRuntimes(t)
	root := t.TempDir()
	first, c := start(t, root)
	id := startAgent(t, c, 1, t.TempDir(), "keep going")
	c.until(t, "running", ended(id, wire.AgentStateRunning))
	c.call(t, 2, "agents/archive", map[string]any{"agentID": id})
	settled := func(d *Daemon) {
		t.Helper()
		a := d.Store.Agent(id)
		if a.State != wire.AgentStateArchived || a.ArchivedReason == nil || *a.ArchivedReason != wire.AgentArchivedReasonByUser {
			t.Fatalf("%s %v", a.State, a.ArchivedReason)
		}
		entries, _, _ := d.Store.Transcript(id, 0)
		for _, e := range entries {
			if n := e.Kind.Notice; n != nil && n.Value.Severity == "error" {
				t.Fatalf("notice %q", n.Value.Title)
			}
			if sc := e.Kind.StateChanged; sc != nil && sc.Reason != nil && (*sc.Reason == wire.EndedReasonProcessDied || *sc.Reason == wire.EndedReasonDaemonGone) {
				t.Fatalf("ended %s", *sc.Reason)
			}
		}
		for _, n := range names(d) {
			if n == "agent.failed" || n == "agent.stopped" || n == "agent.needs_you" {
				t.Fatalf("raised %s: %v", n, names(d))
			}
		}
	}
	waitFor(t, "the runtime gone", func() bool {
		l := first.live(id)
		l.mu.Lock()
		defer l.mu.Unlock()
		return !l.inTurn
	})
	time.Sleep(200 * time.Millisecond)
	settled(first)
	first.Shutdown()

	d, _ := start(t, root)
	defer d.Shutdown()
	d.PickUpAfterRestart()
	time.Sleep(500 * time.Millisecond)
	settled(d)
}

// An archive while a card waits for the person: the card's answer does not take the
// session out of the archive (#1611).
func TestAnArchiveWhileACardWaitsStaysArchived(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	var id wire.UUID
	json.Unmarshal(c.call(t, 1, "agents/start", map[string]any{"runtimeID": "claude", "cwd": "file://" + t.TempDir(),
		"prompt": "Please ask, then write hi.txt"}), &id)
	c.until(t, "a card", func(method string, _ json.RawMessage) bool { return method == "agent/permission" })
	c.call(t, 2, "agents/archive", map[string]any{"agentID": id})
	waitFor(t, "the turn over", func() bool {
		l := d.live(id)
		l.mu.Lock()
		defer l.mu.Unlock()
		return !l.inTurn
	})
	time.Sleep(200 * time.Millisecond)
	if a := d.Store.Agent(id); a.State != wire.AgentStateArchived {
		t.Fatalf("%s", a.State)
	}
	if n := strings.Join(names(d), " "); strings.Contains(n, "agent.failed") {
		t.Fatal(n)
	}
}
