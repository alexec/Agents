package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/agentsd/yamlnode"
	"github.com/alexec/agents/Go/wire"
)

// Alarms (#4966): a one-time workflow fires once at its time, inside its grace, and
// archives itself; past its grace it is archived as missed.

func onceFile(at string, extra string) string {
	return "---\non:\n  - once:\n      at: \"" + at + "\"\n      time-zone: UTC\n" + extra + "---\nWake up.\n"
}

func TestOnceIsReadAsATrigger(t *testing.T) {
	w := parseWorkflow(onceFile("2026-11-13T09:15", "      grace: 30m\n"), "alarm", "/tmp/x")
	if w.Problem != nil || len(w.Triggers) != 1 || !triggerSupported(w.Triggers[0]) || !onceOnly(w) {
		t.Fatalf("%+v", w)
	}
	a, ok := alarmOf(w.Triggers[0])
	if !ok || a.grace != 30*time.Minute || a.zone != "UTC" {
		t.Fatalf("%+v", a)
	}
	due, _ := a.due("Europe/London")
	if !due.Equal(time.Date(2026, 11, 13, 9, 15, 0, 0, time.UTC)) {
		t.Fatal(due)
	}
	if s := a.summary(); s != "Once, at 2026-11-13 09:15 (UTC), or up to 30 minutes late" {
		t.Fatal(s)
	}
	// With no zone it is the person's.
	b := alarm{at: "2026-11-13T09:15", grace: onceGrace}
	if due, _ := b.due("America/Los_Angeles"); !due.Equal(time.Date(2026, 11, 13, 17, 15, 0, 0, time.UTC)) {
		t.Fatal(due)
	}
	// An offset names its own instant.
	c := alarm{at: "2026-11-13T09:15:00+01:00", zone: "UTC", grace: onceGrace}
	if due, _ := c.due(""); !due.Equal(time.Date(2026, 11, 13, 8, 15, 0, 0, time.UTC)) {
		t.Fatal(due)
	}
	for _, bad := range []map[string]string{{"at": "tomorrow"}, {}, {"at": "2026-11-13T09:15", "grace": "0m"},
		{"at": "2026-11-13T09:15", "time-zone": "Mars/Base"}, {"at": "2026-11-13T09:15", "every": "1d"}} {
		keys := map[string]yamlnode.Node{}
		for k, v := range bad {
			keys[k] = yamlnode.Node{Scalar: &v}
		}
		if _, err := parseOnce(keys); err == nil {
			t.Fatalf("%v was read", bad)
		}
	}
}

func TestLateWords(t *testing.T) {
	for d, want := range map[time.Duration]string{20 * time.Second: "less than a minute", time.Minute: "1 minute", 12 * time.Minute: "12 minutes",
		time.Hour: "1 hour", 125 * time.Minute: "2 hours 5 minutes", 72 * time.Hour: "3 days"} {
		if got := lateWords(d); got != want {
			t.Fatalf("%v: %q", d, got)
		}
	}
}

func listOne(t *testing.T, c *conn, folder wire.URL) wire.WorkflowSummary {
	t.Helper()
	var list []wire.WorkflowSummary
	json.Unmarshal(c.call(t, 80, "workflows/list", map[string]any{"folder": folder}), &list)
	if len(list) != 1 {
		t.Fatalf("%+v", list)
	}
	return list[0]
}

// Due and approved: it fires once, inside its grace, and is archived with its run kept.
func TestAnAlarmFiresOnceAndArchivesItself(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	folder := store.FolderURL(dir)
	due := time.Now().UTC().Add(-10 * time.Minute)
	os.MkdirAll(workflowsFolder(dir), 0o755)
	os.WriteFile(filepath.Join(workflowsFolder(dir), "alarm.md"), []byte(onceFile(due.Format("2006-01-02T15:04"), "")), 0o644)
	// Waiting for approval, it does not fire.
	d.workflowTickOnce(time.Now())
	if s := listOne(t, c, folder); s.AwaitingApproval == nil || s.LastOutcome != nil {
		t.Fatalf("%+v", s)
	}
	approveAll(t, c, folder)
	d.workflowTickOnce(time.Now())
	waitFor(t, "the alarm ran and archived itself", func() bool {
		s := listOne(t, c, folder)
		return s.IsArchived && s.LastOutcome != nil && s.LastOutcome.Ran != nil
	})
	text, _ := os.ReadFile(filepath.Join(workflowsFolder(dir), "alarm.md"))
	if !strings.Contains(string(text), "archived: true") {
		t.Fatal(string(text))
	}
	agent := d.Store.Agent(listOne(t, c, folder).LastOutcome.Ran.AgentID)
	if agent == nil {
		t.Fatal("no agent")
	}
	// It never runs again.
	d.workflowTickOnce(time.Now().Add(time.Minute))
	runs := 0
	for _, a := range d.Store.Agents() {
		if a.StartedByWorkflow != nil && *a.StartedByWorkflow == "alarm" {
			runs++
		}
	}
	if runs != 1 {
		t.Fatal(runs)
	}
}

// Past its grace, it is archived as missed and starts nothing.
func TestAnAlarmPastItsGraceIsMissed(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	folder := store.FolderURL(dir)
	due := time.Now().UTC().Add(-3 * time.Hour)
	os.MkdirAll(workflowsFolder(dir), 0o755)
	os.WriteFile(filepath.Join(workflowsFolder(dir), "alarm.md"), []byte(onceFile(due.Format("2006-01-02T15:04"), "")), 0o644)
	approveAll(t, c, folder)
	d.workflowTickOnce(time.Now())
	waitFor(t, "the alarm missed and archived", func() bool {
		s := listOne(t, c, folder)
		return s.IsArchived && s.LastOutcome != nil && s.LastOutcome.Refused != nil && s.LastOutcome.Refused.Value.MissedWhileClosed != nil
	})
	for _, a := range d.Store.Agents() {
		if a.StartedByWorkflow != nil {
			t.Fatal("a missed alarm started an agent")
		}
	}
	found := false
	for _, n := range names(d) {
		found = found || n == "workflow.refused"
	}
	if !found {
		t.Fatal(names(d))
	}
}

// An agent's alarm is on once approved; one past its grace is refused when written.
func TestAnAgentSetsAnAlarm(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	a := seeded(t, d, dir, nil)
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	past := time.Now().UTC().Add(-2 * time.Hour).Format("2006-01-02T15:04")
	if text, isErr := m.tool(2, "manage_workflows", map[string]any{"action": "write", "id": "late", "content": onceFile(past, "")}); !isErr ||
		!strings.Contains(text, "past its grace of 1 hour") {
		t.Fatal(text)
	}
	soon := time.Now().UTC().Add(time.Hour).Format("2006-01-02T15:04")
	text, isErr := m.tool(3, "manage_workflows", map[string]any{"action": "write", "id": "soon", "content": onceFile(soon, "")})
	if isErr || !strings.Contains(text, "on as soon as they approve it") || !strings.Contains(text, "Once, at ") {
		t.Fatal(text)
	}
	written, _ := os.ReadFile(filepath.Join(workflowsFolder(dir), "soon.md"))
	if strings.Contains(string(written), "enabled: false") {
		t.Fatal(string(written))
	}
}

// A time wait that came while Agents was off says how late, and past the grace that it
// passed.
func TestALateTimeWaitSaysHowLate(t *testing.T) {
	deadline := wire.DateOf(time.Date(2026, 11, 12, 9, 0, 0, 0, time.Local))
	w := &wire.EventWait{Patterns: []wire.EventPattern{{Name: timeReached}}, Deadline: &deadline}
	if s := timedOutWords(w, wire.DateOf(deadline.Time().Add(10*time.Second))); !strings.HasPrefix(s, "The time you asked for has come (09:00)") {
		t.Fatal(s)
	}
	if s := timedOutWords(w, wire.DateOf(deadline.Time().Add(20*time.Minute))); !strings.Contains(s, "(09:00), 20 minutes late") {
		t.Fatal(s)
	}
	if s := timedOutWords(w, wire.DateOf(deadline.Time().Add(3*time.Hour))); !strings.Contains(s, "passed while Agents was off") || !strings.Contains(s, "3 hours late") {
		t.Fatal(s)
	}
}
