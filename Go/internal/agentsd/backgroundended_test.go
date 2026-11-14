package agentsd

import (
	"os"
	"os/exec"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/agentsd/acp"
	"github.com/agentloops-dev/agent-loops/Go/internal/agentsd/diskjson"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// asNotWakingItself makes the fake runtime one that does not start itself again when its
// background command ends, as Codex does not (#4577).
func asNotWakingItself(t *testing.T) {
	was := wakesItself
	wakesItself = func(string) bool { return false }
	t.Cleanup(func() { wakesItself = was })
}

// backgroundEvents is the agent.background_ended events on the log for the agent.
func backgroundEvents(d *Daemon, id wire.UUID) []wire.Event {
	d.eventMu.Lock()
	defer d.eventMu.Unlock()
	var out []wire.Event
	for _, e := range d.eventList {
		if e.Name == backgroundEndedEvent && e.Details["agent"] == string(id) {
			out = append(out, copyEvent(e))
		}
	}
	return out
}

// woken is whether the agent's chat has the wake's words.
func woken(d *Daemon, id wire.UUID) bool {
	for _, u := range userMessages(d, id) {
		if strings.HasPrefix(u, "The event you were waiting for happened.") {
			return true
		}
	}
	return false
}

// A look gives what ended once: after processes were seen, and not before.
func TestNoteBackgroundGivesWhatEndedOnce(t *testing.T) {
	var p warmLive
	if e := p.noteBackground(nil); e != nil {
		t.Fatalf("nothing ran, yet %v", e)
	}
	build := []acp.Command{{Pid: 7, Line: "make build"}}
	if e := p.noteBackground(build); e != nil {
		t.Fatalf("still running, yet %v", e)
	}
	if e := p.noteBackground(nil); len(e) != 1 || e[0].Line != "make build" {
		t.Fatalf("ended %v", e)
	}
	if e := p.noteBackground(nil); e != nil {
		t.Fatalf("ended twice: %v", e)
	}
}

func TestCommandNamesShortensAndCounts(t *testing.T) {
	cmds := []acp.Command{{Line: "a"}, {Line: "b"}, {Line: "c"}, {Line: strings.Repeat("x", 70)}, {Line: "e"}, {Line: "f"}}
	got := commandNames(cmds)
	if !strings.HasPrefix(got, "`a`, `b`, `c`, `"+strings.Repeat("x", 60)+"…`") || !strings.HasSuffix(got, ", and 2 more") {
		t.Fatal(got)
	}
}

// A session that waits for its background command, on a runtime that does not wake
// itself, is started again when the warm pass sees the command end.
func TestBackgroundEndedWakesTheWaitingSession(t *testing.T) {
	fakeRuntimes(t)
	asNotWakingItself(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	id := warmAgent(t, d, c, t.TempDir())
	was := eventHoldLimit
	eventHoldLimit = 200 * time.Millisecond
	t.Cleanup(func() { eventHoldLimit = was })
	m := appClient(t, d, id)
	m.post("initialize", map[string]any{}, 1)
	// No pass after the first turn looks between the seen command and the wait.
	d.warmMu.Lock()
	l := d.live(id)
	l.mu.Lock()
	l.pool.seen = []acp.Command{{Pid: 999999, Line: "go test ./..."}}
	l.mu.Unlock()
	text, _ := m.tool(2, "wait_for_event", map[string]any{"events": backgroundEndedEvent, "until_minutes": 60})
	d.warmMu.Unlock()
	if !strings.HasPrefix(text, "Still waiting for ") {
		t.Fatal(text)
	}

	d.warmPass()
	es := backgroundEvents(d, id)
	if len(es) != 1 || es[0].Details["commands"] != "`go test ./...`" || es[0].Details["count"] != "1" || es[0].Details["after_restart"] != "" {
		t.Fatalf("%+v", es)
	}
	waitFor(t, "the wake's turn", func() bool {
		a := d.Store.Agent(id)
		return woken(d, id) && a.State == wire.AgentStateFinished && len(a.QueuedPrompts) == 0
	})
	d.warmPass()
	if n := len(backgroundEvents(d, id)); n != 1 {
		t.Fatalf("%d events, want 1", n)
	}
}

// Another session's background commands wake nobody else.
func TestBackgroundEndedWakesOnlyItsOwnSession(t *testing.T) {
	fakeRuntimes(t)
	asNotWakingItself(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := t.TempDir()
	mine := warmAgent(t, d, c, dir)
	other := warmAgent(t, d, c, dir)
	d.warmMu.Lock()
	l := d.live(mine)
	l.mu.Lock()
	l.pool.seen = []acp.Command{{Pid: 999999, Line: "npm run build"}}
	l.mu.Unlock()
	d.warmMu.Unlock()
	was := eventHoldLimit
	eventHoldLimit = 200 * time.Millisecond
	t.Cleanup(func() { eventHoldLimit = was })
	m := appClient(t, d, other)
	m.post("initialize", map[string]any{}, 1)
	// The other waits on agent.background_ended, which a pattern alone would match for mine.
	if text, _ := m.tool(2, "wait_for_event", map[string]any{"events": "agent.messaged", "until_minutes": 60}); !strings.HasPrefix(text, "Still waiting for ") {
		t.Fatal(text)
	}
	d.change(other, func(a *wire.Agent) {
		w := *a.EventWait
		w.Patterns = []wire.EventPattern{{Name: backgroundEndedEvent, Filters: map[string]string{}}}
		a.EventWait = &w
	})
	d.warmPass()
	if len(backgroundEvents(d, mine)) != 1 {
		t.Fatal("no event")
	}
	time.Sleep(300 * time.Millisecond)
	if a := d.Store.Agent(other); waitOf(a) == nil || woken(d, other) {
		t.Fatal("another session's background commands woke it")
	}
}

// A wait on it alone is refused where nothing would raise it: a runtime that wakes itself,
// and nothing in the background.
func TestBackgroundWaitRefusedWhenNothingWouldEnd(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	id := warmAgent(t, d, c, t.TempDir())
	m := appClient(t, d, id)
	m.post("initialize", map[string]any{}, 1)
	if text, _ := m.tool(2, "wait_for_event", map[string]any{"events": backgroundEndedEvent, "until_minutes": 5}); !strings.Contains(text, "starts your session again itself") {
		t.Fatal(text)
	}
	asNotWakingItself(t)
	if text, _ := m.tool(3, "wait_for_event", map[string]any{"events": backgroundEndedEvent, "until_minutes": 5}); !strings.Contains(text, "Nothing you started runs in the background now") {
		t.Fatal(text)
	}
	if waitOf(d.Store.Agent(id)) != nil {
		t.Fatal("a refused wait waits")
	}
}

func TestBriefSaysToWaitOnlyWhereTheRuntimeDoesNotWakeItself(t *testing.T) {
	if strings.Contains(eventsBriefFor("claude"), backgroundEndedEvent) {
		t.Fatal("Claude wakes itself")
	}
	if !strings.Contains(eventsBriefFor("codex"), backgroundEndedEvent) {
		t.Fatal(eventsBriefFor("codex"))
	}
}

// sleeper is a process in a group of its own, as a runtime's background command is.
func sleeper(t *testing.T) *exec.Cmd {
	t.Helper()
	s := exec.Command("sleep", "300")
	s.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := s.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Process.Kill(); _ = s.Wait() })
	return s
}

func writeHandover(t *testing.T, d *Daemon, h backgroundHandover) {
	t.Helper()
	b, err := diskjson.Marshal(h)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(d.backgroundPath(), b, 0o600); err != nil {
		t.Fatal(err)
	}
}

// Over a restart, a background process the runtime left is adopted; when it ends, the
// session gets the event, and a Claude session with no wait a prompt, as Claude would
// have started itself.
func TestAdoptedBackgroundEndsAfterARestart(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	id := warmAgent(t, d, c, t.TempDir())
	s := sleeper(t)
	writeHandover(t, d, backgroundHandover{Agents: map[wire.UUID][]adoptedProcess{
		id:            {{Pid: s.Process.Pid, Line: "make build", Started: startedAt(s.Process.Pid)}},
		"no-such-one": {{Pid: s.Process.Pid, Line: "x", Started: startedAt(s.Process.Pid)}},
	}})
	d.adoptBackground()
	if _, err := os.Stat(d.backgroundPath()); !os.IsNotExist(err) {
		t.Fatal("background.json is still there")
	}
	d.adoptedMu.Lock()
	n := len(d.adopted)
	d.adoptedMu.Unlock()
	if n != 1 {
		t.Fatalf("adopted %d sessions, want 1", n)
	}
	// Adopted, so the wait is not refused on Claude.
	if words := d.backgroundWaitWords(d.Store.Agent(id)); words != "" {
		t.Fatal(words)
	}
	d.adoptedPass()
	if len(backgroundEvents(d, id)) != 0 {
		t.Fatal("raised while it runs")
	}
	_ = s.Process.Kill()
	_ = s.Wait()
	d.adoptedPass()
	es := backgroundEvents(d, id)
	if len(es) != 1 || es[0].Details["after_restart"] != "true" || es[0].Details["commands"] != "`make build`" {
		t.Fatalf("%+v", es)
	}
	waitFor(t, "the prompt's turn", func() bool {
		for _, u := range userMessages(d, id) {
			if strings.HasPrefix(u, "Your background commands ended while Agent Loops restarted") {
				return d.Store.Agent(id).State == wire.AgentStateFinished
			}
		}
		return false
	})
}

// A process that is not the one handed over (its pid used again, or ended in the gap) is
// not adopted, and its end is raised at the first look.
func TestAdoptionChecksTheStartTime(t *testing.T) {
	fakeRuntimes(t)
	asNotWakingItself(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	id := warmAgent(t, d, c, t.TempDir())
	s := sleeper(t)
	writeHandover(t, d, backgroundHandover{Agents: map[wire.UUID][]adoptedProcess{
		id: {{Pid: s.Process.Pid, Line: "vite", Started: startedAt(s.Process.Pid) - 5000}},
	}})
	d.adoptBackground()
	d.adoptedPass()
	if es := backgroundEvents(d, id); len(es) != 1 {
		t.Fatalf("%+v", es)
	}
	if q := d.Store.Agent(id).QueuedPrompts; len(q) != 0 {
		t.Fatalf("a runtime that does not wake itself was sent %v", q)
	}
}

// A clean stop with nothing in the background leaves no background.json behind.
func TestHandoverWithNothingWritesNothing(t *testing.T) {
	d, _ := start(t, t.TempDir())
	_ = os.WriteFile(d.backgroundPath(), []byte("{}"), 0o600)
	d.Shutdown()
	if _, err := os.Stat(d.backgroundPath()); !os.IsNotExist(err) {
		t.Fatal("background.json is still there")
	}
}
