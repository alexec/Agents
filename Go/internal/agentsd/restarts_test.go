package agentsd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/diskjson"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// Ports RestartGapTests and the restart half of EventWaitTests (#1219): alive.json says
// how long nothing ran; the next start raises system.restarted with it, and a wait that
// was open over the gap is told at its wake what may be missing.

func writeAliveFile(t *testing.T, root string, a daemonAlive) {
	t.Helper()
	b, err := diskjson.Marshal(a)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "alive.json"), b, 0o644); err != nil {
		t.Fatal(err)
	}
}

func lastEvent(d *Daemon, name string) *wire.Event {
	d.eventMu.Lock()
	defer d.eventMu.Unlock()
	for i := len(d.eventList) - 1; i >= 0; i-- {
		if d.eventList[i].Name == name {
			e := copyEvent(d.eventList[i])
			return &e
		}
	}
	return nil
}

func TestARestartIsSaidAndAWaitOpenOverItIsTold(t *testing.T) {
	fakeRuntimes(t)
	root := t.TempDir()
	// The host before stopped cleanly three minutes ago, with a wait open.
	stopped := wire.DateOf(time.Now().Add(-3 * time.Minute))
	writeAliveFile(t, root, daemonAlive{LastAlive: stopped, StoppedAt: &stopped})
	dir := t.TempDir()
	deadline := wire.DateOf(time.Now().Add(time.Hour))
	waitID := store.NewUUID()
	id := leftWorking(t, root, wire.AgentStateFinished, "", func(a *wire.Agent) {
		a.Cwd = store.FolderURL(dir)
		a.EndedReason = reason(wire.EndedReasonEndTurn)
		a.EventWait = &wire.EventWait{ID: waitID, Patterns: []wire.EventPattern{{Name: "lease.granted", Filters: map[string]string{}}},
			Deadline: &deadline, Since: now()}
	})
	d, _ := start(t, root)
	d.eventMu.Lock()
	gaps := d.eventStateNow.WaitRestarts[string(waitID)]
	d.eventMu.Unlock()
	if len(gaps) != 1 || gaps[0].Reason != "stopped" {
		t.Fatalf("%+v", gaps)
	}
	if b, _ := os.ReadFile(filepath.Join(root, "events-state.json")); !strings.Contains(string(b), `"waitRestarts"`) || !strings.Contains(string(b), `"reason" : "stopped"`) && !strings.Contains(string(b), `"reason":"stopped"`) {
		t.Fatalf("%s", b)
	}

	d.SayRestarted()
	e := lastEvent(d, "system.restarted")
	if e == nil || e.Details["reason"] != "stopped" || e.Details["down_for"] != "180" || e.Details["down_for_text"] != "3 min" ||
		e.Details["down_since"] == "" || e.Sentence != "Agents restarted after a clean stop. It was down for 3 min." || e.Scope.Mac == nil {
		t.Fatalf("%+v", e)
	}

	// Its wake says the host restarted, and that what it waits on may be missing.
	d.raise(wire.EventDraft{Name: "lease.granted", At: now(), Scope: macScope(), Sentence: "x was given build.", Details: map[string]string{"resource": "build"}})
	waitFor(t, "the wake with the notice", func() bool {
		for _, u := range userMessages(d, id) {
			if strings.HasPrefix(u, "The event you were waiting for happened.") && strings.Contains(u, "\nAgents restarted at ") &&
				strings.Contains(u, " while you waited. It was down for about 3 min (from ") &&
				strings.HasSuffix(u, "Events in that time may be missing: lease.granted. Check the state yourself (for example the branch or the PR).") {
				return true
			}
		}
		return false
	})
	waitFor(t, "its turn over", func() bool { return d.Store.Agent(id).State == wire.AgentStateFinished })

	// A clean stop says so.
	d.Shutdown()
	var alive daemonAlive
	b, _ := os.ReadFile(filepath.Join(root, "alive.json"))
	if diskjson.Unmarshal(b, &alive) != nil || alive.StoppedAt == nil {
		t.Fatalf("%s", b)
	}
}

func TestACrashAndAFirstStart(t *testing.T) {
	root := t.TempDir()
	d, _ := start(t, root)
	d.SayRestarted()
	if e := lastEvent(d, "system.restarted"); e == nil || e.Details["reason"] != "first_start" || e.Details["down_for_text"] != "unknown" ||
		e.Details["down_since"] != "" || e.Sentence != "Agents started." {
		t.Fatalf("%+v", e)
	}
	d.Shutdown()

	// Alive 90 s ago, and never stopped: a crash.
	writeAliveFile(t, root, daemonAlive{LastAlive: wire.DateOf(time.Now().Add(-90 * time.Second))})
	d, _ = start(t, root)
	defer d.Shutdown()
	d.SayRestarted()
	if e := lastEvent(d, "system.restarted"); e == nil || e.Details["reason"] != "crashed" ||
		e.Sentence != "Agents restarted after it stopped unexpectedly. It was down for about 2 min." {
		t.Fatalf("%+v", e)
	}
	// The first disk look after it has had its notice; a look marked so says it once.
	if n := d.noticedAfterRestart(); n != nil {
		t.Fatalf("the start's own look did not take it: %v", n)
	}
	d.restartMu.Lock()
	d.diskAfterRestart = true
	d.restartMu.Unlock()
	if n := d.noticedAfterRestart(); n["noticed"] != "after_restart" || d.noticedAfterRestart() != nil {
		t.Fatal("noticed once")
	}
}

func TestRestartWords(t *testing.T) {
	at := wire.DateOf(time.Date(2026, 10, 17, 12, 0, 0, 0, time.UTC))
	for _, c := range []struct {
		seconds float64
		want    string
	}{{40, "40 s"}, {180, "3 min"}, {7500, "2 h 5 min"}, {7200, "2 h"}, {3 * 86400, "3 days"}, {-60, "0 s"}} {
		since := at - wire.Date(c.seconds)
		if got := (restartGap{At: at, Reason: "stopped", DownSince: &since}).downForWords(); got != c.want {
			t.Errorf("%v: %s", c.seconds, got)
		}
	}
	for name, want := range map[string]bool{"pr.merged": true, "pr.*": true, "branch.moved": true, "branch.*": true,
		"system.restarted": true, "machine.disk_low": true, "person.back": true, "agent.finished": false, "lease.granted": false} {
		if caughtUpAfterRestart(name) != want {
			t.Errorf("%s", name)
		}
	}
	w := &wire.EventWait{Patterns: []wire.EventPattern{{Name: "branch.moved"}}}
	got := restartNoticeWords([]restartGap{{At: at, Reason: "first_start"}}, w)
	if !strings.HasPrefix(got, "\n\nAgents restarted at ") || !strings.Contains(got, "How long it was down is unknown: nothing was recorded before it went.") ||
		!strings.HasSuffix(got, "What you wait on was caught up after it: branch.moved.") {
		t.Fatal(got)
	}
}
