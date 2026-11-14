package agentsd

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/agentsd/acp"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

var warmT0 = time.Date(2026, 11, 7, 12, 0, 0, 0, time.UTC)

func released(rs []warmRelease) []string {
	var out []string
	for _, r := range rs {
		out = append(out, string(r.id))
	}
	slices.Sort(out)
	return out
}

func idleFor(id string, ago time.Duration) warmEntry {
	return warmEntry{id: wire.UUID(id), lastUsed: warmT0.Add(-ago)}
}

// At the cap, the least recently used goes first.
func TestWarmPoolReleasesTheLeastRecentlyUsedAtTheCap(t *testing.T) {
	es := []warmEntry{idleFor("a", 4*time.Minute), idleFor("b", 1*time.Minute), idleFor("c", 3*time.Minute), idleFor("d", 2*time.Minute)}
	if got := released(warmDecide(es, warmT0, 3, 4, warmIdle)); !slices.Equal(got, []string{"a"}) {
		t.Fatalf("released %v, want a", got)
	}
	if got := released(warmDecide(es, warmT0, 2, 4, warmIdle)); !slices.Equal(got, []string{"a", "c"}) {
		t.Fatalf("released %v, want a and c", got)
	}
}

// A finished runtime goes after 10 minutes idle, under the cap too.
func TestWarmPoolReleasesAfterTenMinutesIdle(t *testing.T) {
	es := []warmEntry{idleFor("old", warmIdle), idleFor("new", warmIdle-time.Second)}
	got := warmDecide(es, warmT0, 3, 4, warmIdle)
	if len(got) != 1 || got[0].id != "old" || got[0].background || got[0].why != "10 min idle" {
		t.Fatalf("released %+v", got)
	}
}

// Prewarms under way count against the cap, and are never released for it.
func TestWarmPoolCapHoldsWithPrewarmsUnderWay(t *testing.T) {
	es := []warmEntry{{id: "p1", prewarming: true}, {id: "p2", prewarming: true}, idleFor("idle", time.Minute)}
	if got := released(warmDecide(es, warmT0, 2, 4, warmIdle)); !slices.Equal(got, []string{"idle"}) {
		t.Fatalf("released %v, want idle", got)
	}
	if got := released(warmDecide(es, warmT0, 3, 4, warmIdle)); len(got) != 0 {
		t.Fatalf("released %v under the cap", got)
	}
}

// A runtime with a live background process does not count against the cap and is kept past
// 10 minutes; at backgroundHours it goes, with its processes.
func TestWarmPoolKeepsABackgroundRuntimeUntilItsHours(t *testing.T) {
	bg := warmEntry{id: "bg", lastUsed: warmT0.Add(-3 * time.Hour), background: true}
	es := []warmEntry{bg, idleFor("a", time.Minute)}
	if got := warmDecide(es, warmT0, 1, 4, warmIdle); len(got) != 0 {
		t.Fatalf("released %+v at 3 h with a cap of 1", got)
	}
	got := warmDecide(es, warmT0.Add(time.Hour), 1, 4, warmIdle)
	if len(got) != 2 || got[0].id != "bg" || !got[0].background || got[0].why != "4 h idle" {
		t.Fatalf("released %+v at 4 h", got)
	}
}

// Once its last process ends, the 10 minutes start then.
func TestWarmPoolReleasesTenMinutesAfterTheLastProcessEnds(t *testing.T) {
	e := warmEntry{id: "bg", lastUsed: warmT0.Add(-2 * time.Hour), quietSince: warmT0}
	if got := warmDecide([]warmEntry{e}, warmT0.Add(warmIdle-time.Second), 3, 4, warmIdle); len(got) != 0 {
		t.Fatalf("released %+v before 10 minutes", got)
	}
	if got := warmDecide([]warmEntry{e}, warmT0.Add(warmIdle), 3, 4, warmIdle); len(got) != 1 || got[0].background {
		t.Fatalf("released %+v at 10 minutes", got)
	}
}

// A cap of 0 turns the pool off: every idle runtime goes, one with background processes stays.
func TestWarmPoolCapOfZero(t *testing.T) {
	es := []warmEntry{idleFor("a", 0), idleFor("b", time.Second), {id: "bg", lastUsed: warmT0, background: true}}
	if got := released(warmDecide(es, warmT0, 0, 4, warmIdle)); !slices.Equal(got, []string{"a", "b"}) {
		t.Fatalf("released %v", got)
	}
}

// backgroundHours is 1 to 24, 4 when missing, and a client that does not send it keeps it.
func TestBackgroundHoursClamped(t *testing.T) {
	for _, c := range []struct {
		in   *int64
		want int64
	}{{nil, 4}, {new(int64(0)), 1}, {new(int64(-3)), 1}, {new(int64(30)), 24}, {new(int64(9)), 9}} {
		got := clampWake(wire.WakeSettings{BackgroundHours: c.in})
		if *got.BackgroundHours != c.want {
			t.Fatalf("%v: %d, want %d", c.in, *got.BackgroundHours, c.want)
		}
	}
	w := &waker{file: filepath.Join(t.TempDir(), "wake.json"), hold: func() (func(), error) { return func() {}, nil }, tell: func(wire.WakeState) {}}
	w.settings = new(defaultWake())
	if got := w.Set(wire.WakeSettings{KeepsAwake: true, WarmRuntimes: 3, BackgroundHours: new(int64(12))}); *got.BackgroundHours != 12 {
		t.Fatalf("set %d", *got.BackgroundHours)
	}
	if got := w.Set(wire.WakeSettings{KeepsAwake: true, WarmRuntimes: 2}); *got.BackgroundHours != 12 || got.WarmRuntimes != 2 {
		t.Fatalf("a client without the hours set them to %d", *got.BackgroundHours)
	}
	if s := readWakeSettings(w.file); *s.BackgroundHours != 12 {
		t.Fatalf("read back %d", *s.BackgroundHours)
	}
}

// Background processes: under the runtime in a group of their own and not there as it
// started, or orphans of such a group; never the runtime's own helpers in its group.
func TestBackgroundProcessesOfARuntime(t *testing.T) {
	table := map[int32]procInfo{
		100: {parent: 1, name: "npm"},      // the runtime
		101: {parent: 100, name: "node"},   // its own, in its group
		102: {parent: 101, name: "claude"}, // its own
		103: {parent: 102, name: "mcp"},    // an MCP server started later, in its group
		110: {parent: 102, name: "zsh"},    // a command's shell, its own group
		111: {parent: 110, name: "vite"},   // under it: not listed apart
		120: {parent: 1, name: "next"},     // "cmd &" whose shell ended, group 130
		121: {parent: 1, name: "other"},    // another app's, group 121
		130: {parent: 102, name: "zsh"},    // seen earlier: its group recorded
	}
	pgid := map[int32]int{100: 100, 101: 100, 102: 100, 103: 100, 110: 110, 111: 110, 120: 130, 121: 121, 130: 130}
	own := map[int32]bool{101: true, 102: true, 130: true}
	groups := map[int]bool{}
	got := backgroundIn(table, 100, own, groups, func(p int32) int { return pgid[p] })
	if !slices.Equal(got, []int32{110, 120}) {
		t.Fatalf("background %v, want [110 120]", got)
	}
	if !groups[110] || !groups[130] || groups[100] {
		t.Fatalf("groups %v", groups)
	}
	// Gone: none.
	if got := backgroundIn(table, 999, own, groups, func(p int32) int { return pgid[p] }); got != nil {
		t.Fatalf("%v for a runtime that is gone", got)
	}
}

func TestBackgroundNoteNamesTheProcesses(t *testing.T) {
	got := backgroundNote(4, []acp.Command{{Line: "npm run dev"}, {Line: "gh run watch"}})
	if want := "Released after 4 h idle; ended its background processes: `npm run dev`, `gh run watch`"; got != want {
		t.Fatalf("%q", got)
	}
	many := backgroundNote(4, []acp.Command{{Line: "a"}, {Line: "b"}, {Line: "c"}, {Line: "d"}, {Line: "e"}, {Line: "f"}})
	if !strings.HasSuffix(many, "`d`, and 2 more") {
		t.Fatalf("%q", many)
	}
}

// A release ends the background processes it is given.
func TestReleaseEndsBackgroundProcesses(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	id := warmAgent(t, d, c, t.TempDir())
	sleep := exec.Command("sleep", "300")
	sleep.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := sleep.Start(); err != nil {
		t.Fatal(err)
	}
	ended := make(chan struct{})
	go func() { sleep.Wait(); close(ended) }()
	if !d.releaseWarm(d.live(id), "test", []acp.Command{{Pid: sleep.Process.Pid, Line: "sleep 300"}}, false) {
		t.Fatal("not released")
	}
	select {
	case <-ended:
	case <-time.After(10 * time.Second):
		sleep.Process.Kill()
		t.Fatal("the background process was not ended")
	}
	if l := d.live(id); l.session != nil {
		t.Fatal("the runtime is still live")
	}
}

// warmAgent starts an agent whose first turn has finished, its runtime still live.
func warmAgent(t *testing.T, d *Daemon, c *conn, work string) wire.UUID {
	t.Helper()
	var id wire.UUID
	json.Unmarshal(c.call(t, 1, "agents/start", map[string]any{"runtimeID": "claude", "cwd": "file://" + work, "prompt": "hello"}), &id)
	waitFor(t, "the first turn's end", func() bool {
		a := d.Store.Agent(id)
		l := d.live(id)
		l.mu.Lock()
		defer l.mu.Unlock()
		return a.State == wire.AgentStateFinished && l.session != nil && !l.running
	})
	return id
}

func startsIn(file string) int {
	b, _ := os.ReadFile(file)
	return strings.Count(string(b), "\n")
}

// A warm runtime takes the next turn when nothing changed; a changed start starts a new one.
func TestWarmRuntimeReusedOnlyWhenNothingChanged(t *testing.T) {
	fakeRuntimes(t)
	t.Setenv("AGENTS_PERSONAL_HOME", t.TempDir())
	starts := filepath.Join(t.TempDir(), "starts")
	t.Setenv("AGENTS_FAKE_STARTS", starts)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	id := warmAgent(t, d, c, t.TempDir())
	turn := func(n int, text string) {
		t.Helper()
		c.call(t, n, "agents/prompt", map[string]any{"agentID": id, "text": text, "from": "person"})
		waitFor(t, "turn "+text, func() bool {
			a := d.Store.Agent(id)
			return a.State == wire.AgentStateFinished && len(a.QueuedPrompts) == 0 && strings.Contains(strings.Join(kinds(d, id), " "), "userMessage")
		})
		waitFor(t, "the turn's end", func() bool {
			l := d.live(id)
			l.mu.Lock()
			defer l.mu.Unlock()
			return !l.running
		})
	}
	turn(2, "again")
	if n := startsIn(starts); n != 1 {
		t.Fatalf("%d starts for two turns on the same start", n)
	}
	if err := d.setSessionSecret(id, "SOME_TOKEN", "x", "", false); err != nil {
		t.Fatal(err)
	}
	turn(3, "with a secret")
	if n := startsIn(starts); n != 2 {
		t.Fatalf("%d starts after the start changed, want 2", n)
	}
}

// agents/prewarm starts a finished session's runtime with no word in its chat, and the
// next turn takes it; with the pool off it starts nothing.
func TestPrewarmStartsTheRuntimeQuietly(t *testing.T) {
	fakeRuntimes(t)
	starts := filepath.Join(t.TempDir(), "starts")
	t.Setenv("AGENTS_FAKE_STARTS", starts)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	id := warmAgent(t, d, c, t.TempDir())
	if !d.releaseWarm(d.live(id), "test", nil, false) {
		t.Fatal("not released")
	}
	before := len(kinds(d, id))
	activity := d.Store.Agent(id).LastActivityAt
	c.call(t, 2, "agents/prewarm", map[string]any{"agentID": id, "why": "opened"})
	waitFor(t, "the prewarm", func() bool {
		l := d.live(id)
		l.mu.Lock()
		defer l.mu.Unlock()
		return l.session != nil && !l.running && !l.pool.prewarming
	})
	if n := startsIn(starts); n != 2 {
		t.Fatalf("%d starts after a prewarm, want 2", n)
	}
	if after := kinds(d, id); len(after) != before {
		t.Fatalf("the prewarm wrote in the chat: %v", after[before:])
	}
	if a := d.Store.Agent(id); a.State != wire.AgentStateFinished || a.LastActivityAt != activity {
		t.Fatalf("the prewarm moved the session: %s %v", a.State, a.LastActivityAt)
	}
	// Asked again: already warm, nothing more.
	c.call(t, 3, "agents/prewarm", map[string]any{"agentID": id, "why": "typing"})
	c.call(t, 4, "agents/prompt", map[string]any{"agentID": id, "text": "after the prewarm", "from": "person"})
	waitFor(t, "the turn", func() bool {
		a := d.Store.Agent(id)
		return a.State == wire.AgentStateFinished && len(a.QueuedPrompts) == 0 && len(kinds(d, id)) > before
	})
	if n := startsIn(starts); n != 2 {
		t.Fatalf("%d starts: the turn did not take the prewarmed runtime", n)
	}

	// The pool off: a prewarm starts nothing.
	off := func() wire.WakeSettings { s := defaultWake(); s.WarmRuntimes = 0; return s }
	d.wakeSettings.Store(&off)
	waitFor(t, "the turn's end", func() bool {
		l := d.live(id)
		l.mu.Lock()
		defer l.mu.Unlock()
		return !l.running
	})
	d.releaseWarm(d.live(id), "test", nil, false)
	l := d.live(id)
	l.mu.Lock()
	l.pool.asked = nil
	l.mu.Unlock()
	c.call(t, 5, "agents/prewarm", map[string]any{"agentID": id, "why": "opened"})
	time.Sleep(300 * time.Millisecond)
	if n := startsIn(starts); n != 2 {
		t.Fatalf("%d starts with the pool off", n)
	}
}

// releaseAfterMinutes is how long an idle runtime stays (#4513): 0 releases none for being
// idle, and the cap still holds; a kept runtime neither counts against the cap nor goes.
func TestWarmPoolReleaseAfterMinutes(t *testing.T) {
	es := []warmEntry{idleFor("a", 30*time.Minute), idleFor("b", 5*time.Minute), idleFor("c", time.Minute)}
	if got := released(warmDecide(es, warmT0, 3, 4, 20*time.Minute)); !slices.Equal(got, []string{"a"}) {
		t.Fatalf("released %v at 20 minutes", got)
	}
	if got := released(warmDecide(es, warmT0, 3, 4, 0)); len(got) != 0 {
		t.Fatalf("released %v with the release off", got)
	}
	if got := released(warmDecide(es, warmT0, 2, 4, 0)); !slices.Equal(got, []string{"a"}) {
		t.Fatalf("released %v over the cap with the release off", got)
	}
	kept := warmEntry{id: "kept", lastUsed: warmT0.Add(-2 * time.Hour), kept: true}
	if got := released(warmDecide(append(es, kept), warmT0, 1, 4, warmIdle)); !slices.Equal(got, []string{"a", "b"}) {
		t.Fatalf("released %v with a kept runtime", got)
	}
}

// The minutes are 0 to 1440, 10 when missing, and a client that does not send them (no
// client shows them) keeps them; 0 is kept as 0.
func TestReleaseAfterMinutesClamped(t *testing.T) {
	for _, c := range []struct {
		in   *int64
		want int64
	}{{nil, 10}, {new(int64(0)), 0}, {new(int64(-5)), 0}, {new(int64(30)), 30}, {new(int64(9999)), 1440}} {
		got := clampWake(wire.WakeSettings{ReleaseAfterMinutes: c.in})
		if *got.ReleaseAfterMinutes != c.want {
			t.Fatalf("%v: %d, want %d", c.in, *got.ReleaseAfterMinutes, c.want)
		}
	}
	w := &waker{file: filepath.Join(t.TempDir(), "wake.json"), hold: func() (func(), error) { return func() {}, nil }, tell: func(wire.WakeState) {}}
	w.settings = new(defaultWake())
	if got := w.Set(wire.WakeSettings{KeepsAwake: true, WarmRuntimes: 3, ReleaseAfterMinutes: new(int64(0))}); *got.ReleaseAfterMinutes != 0 {
		t.Fatalf("set %d", *got.ReleaseAfterMinutes)
	}
	if got := w.Set(wire.WakeSettings{KeepsAwake: true, WarmRuntimes: 2}); *got.ReleaseAfterMinutes != 0 {
		t.Fatalf("a client without the minutes set them to %d", *got.ReleaseAfterMinutes)
	}
	if s := readWakeSettings(w.file); *s.ReleaseAfterMinutes != 0 {
		t.Fatalf("read back %d", *s.ReleaseAfterMinutes)
	}
	if got := releaseAfterOf(wire.WakeSettings{}); got != warmIdle {
		t.Fatalf("missing is %s", got)
	}
}

// waitIdle has a warm agent wait on branch.moved, its wait_for_event call over, and the pool's
// clock moved past the release.
func waitIdle(t *testing.T, d *Daemon, id wire.UUID) {
	t.Helper()
	was := eventHoldLimit
	eventHoldLimit = 200 * time.Millisecond
	t.Cleanup(func() { eventHoldLimit = was })
	m := appClient(t, d, id)
	m.post("initialize", map[string]any{}, 1)
	if text, _ := m.tool(2, "wait_for_event", map[string]any{"events": "branch.moved", "where": map[string]any{"branch": []string{"cd"}}, "until_minutes": 60}); !strings.HasPrefix(text, "Still waiting for ") {
		t.Fatal(text)
	}
	later := time.Now().Add(warmIdle + time.Minute)
	warmNow = func() time.Time { return later }
	t.Cleanup(func() { warmNow = time.Now })
}

// An agent that waits past releaseAfterMinutes has no runtime; its ACP session id is kept,
// and the event's turn starts one that continues the same conversation with session/load
// (#4513).
func TestAWaitingAgentsRuntimeIsReleasedAndTheEventContinuesIt(t *testing.T) {
	fakeRuntimes(t)
	t.Setenv("AGENTS_FAKE_CONTINUE", "load")
	starts := filepath.Join(t.TempDir(), "starts")
	t.Setenv("AGENTS_FAKE_STARTS", starts)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := t.TempDir()
	id := warmAgent(t, d, c, dir)
	l := d.live(id)
	l.mu.Lock()
	pid := l.session.Pid()
	l.mu.Unlock()
	waitIdle(t, d, id)

	d.warmPass()
	l.mu.Lock()
	gone := l.session == nil
	l.mu.Unlock()
	if !gone {
		t.Fatal("the waiting agent's runtime was kept")
	}
	waitFor(t, "the runtime's process to end", func() bool { return syscall.Kill(pid, 0) != nil })
	a := d.Store.Agent(id)
	if a.RuntimeSessionID == nil || *a.RuntimeSessionID != "fake-session" || waitOf(a) == nil {
		t.Fatalf("session %v, wait %+v", a.RuntimeSessionID, a.EventWait)
	}

	d.raise(wire.EventDraft{Name: "branch.moved", At: now(), Scope: folderScope(dir), Sentence: "cd moved.", Details: map[string]string{"branch": "cd"}})
	waitFor(t, "the wake's turn", func() bool {
		a := d.Store.Agent(id)
		woke := false
		for _, u := range userMessages(d, id) {
			woke = woke || strings.HasPrefix(u, "The event you were waiting for happened.")
		}
		return woke && a.State == wire.AgentStateFinished && len(a.QueuedPrompts) == 0
	})
	if n := startsIn(starts); n != 2 {
		t.Fatalf("%d starts, want 2", n)
	}
	notes := strings.Join(runtimeNotes(d, id), " | ")
	if !strings.HasSuffix(notes, "Picked the conversation back up.") || strings.Contains(notes, "no longer has this conversation") {
		t.Fatal(notes)
	}
	if a := d.Store.Agent(id); *a.RuntimeSessionID != "fake-session" {
		t.Fatalf("a new session %s", *a.RuntimeSessionID)
	}
}

// A waiting agent whose runtime can neither load nor resume keeps it: a release would lose
// the conversation. Without the wait it goes as before.
func TestAWaitingAgentWhoseRuntimeCannotContinueIsKept(t *testing.T) {
	fakeRuntimes(t)
	t.Setenv("AGENTS_FAKE_CONTINUE", "none")
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := t.TempDir()
	id := warmAgent(t, d, c, dir)
	waitIdle(t, d, id)
	d.warmPass()
	l := d.live(id)
	l.mu.Lock()
	kept, logged := l.session != nil, l.pool.keptWaiting
	l.mu.Unlock()
	if !kept || !logged {
		t.Fatalf("kept %v, logged %v", kept, logged)
	}
	d.endWait(id, "agent", true)
	d.warmPass()
	l.mu.Lock()
	gone := l.session == nil
	l.mu.Unlock()
	if !gone {
		t.Fatal("kept once it no longer waits")
	}
}
