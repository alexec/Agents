package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// Every run says why it started, at the end of its prompt (#1562): an event, the agent
// behind an event, a schedule, Run now, or an agent's manage_workflows run. A queued run
// keeps the cause of the trigger that queued it.
func TestEveryRunSaysWhyItStarted(t *testing.T) {
	dir := t.TempDir()
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	w := wire.Workflow{Name: "Review", Prompt: "Review it."}
	title := "Fix the build"
	a := seeded(t, d, dir, func(a *wire.Agent) { a.Title = &title })
	schedule := wire.WorkflowTrigger{Schedule: &wire.WorkflowTriggerStoredSchedule{}}
	due := time.Date(2026, 10, 19, 9, 0, 0, 0, time.Local)
	finished := d.raise(wire.EventDraft{Name: "agent.finished", At: now(), Scope: macScope(), Sentence: "Fix the build finished.",
		Details: map[string]string{"agent": string(a.ID), "outcome": "done"}})
	lease := d.raise(wire.EventDraft{Name: "lease.granted", At: now(), Scope: macScope(), Sentence: "x was given build.",
		Details: map[string]string{"resource": "build"}})
	for _, c := range []struct {
		name string
		fr   fireRequest
		want string
	}{
		{"an event", fireRequest{causingEvent: &lease.Position},
			`because of the event lease.granted: x was given build. Its details are resource: build.)`},
		{"the agent behind an event", fireRequest{triggeringAgent: &a.ID, causingEvent: &finished.Position},
			`because “Fix the build” has just finished its work. The event was agent.finished: Fix the build finished. Its details are agent: ` +
				string(a.ID) + `; outcome: done.)`},
		{"a schedule", fireRequest{trigger: schedule, dueAt: &due}, `because of its schedule: the 09:00 run.)`},
		{"Run now", fireRequest{byHand: true, trigger: byHandTrigger()}, `because the person ran it by hand, with Run now.)`},
		{"an agent's run", fireRequest{byHand: true, byAgent: &a.ID, trigger: byHandTrigger()},
			`because the agent “Fix the build” (id ` + string(a.ID) + `) ran it.)`},
	} {
		want := "(You were started by the workflow \"Review\" " + c.want + "\n\nReview it."
		if got := d.runPrompt(w, c.fr); got != want {
			t.Errorf("%s:\n got %q\nwant %q", c.name, got, want)
		}
	}
}

// A schedule's fire that queues keeps its time, so the run it becomes says which run it is.
func TestAQueuedRunSaysWhyItStarted(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	folder := store.FolderURL(dir)
	os.MkdirAll(workflowsFolder(dir), 0o755)
	os.WriteFile(filepath.Join(workflowsFolder(dir), "slow.md"), []byte("---\nname: Slow\non: manual\n---\nwait for me\n"), 0o644)
	approveAll(t, c, folder)
	var s wire.WorkflowSummary
	json.Unmarshal(c.call(t, 2, "workflows/run", map[string]any{"folder": folder, "workflowID": "slow"}), &s)
	first := s.LastOutcome.Ran.AgentID
	waitFor(t, "it working", func() bool { return d.Store.Agent(first).State == wire.AgentStateRunning })
	if u := userMessages(d, first); len(u) != 1 || !strings.HasPrefix(u[0], "(You were started by the workflow \"Slow\" because the person ran it by hand, with Run now.)\n\n") {
		t.Fatalf("%q", u)
	}
	due := time.Date(2026, 10, 19, 9, 0, 0, 0, time.Local)
	d.fire(fireRequest{folder: dir, id: "slow", trigger: wire.WorkflowTrigger{Schedule: &wire.WorkflowTriggerStoredSchedule{}}, dueAt: &due})
	d.workflowMu.Lock()
	queued := len(d.stateLocked(dir, "slow", true).QueuedFires)
	d.workflowMu.Unlock()
	if queued != 1 {
		t.Fatal(queued)
	}
	c.call(t, 4, "agents/stop", map[string]any{"agentID": first})
	var second wire.UUID
	waitFor(t, "the queued run", func() bool {
		d.workflowMu.Lock()
		defer d.workflowMu.Unlock()
		for _, r := range d.recordsLocked().Runs {
			if r.AgentID != nil && *r.AgentID != first {
				second = *r.AgentID
				return true
			}
		}
		return false
	})
	waitFor(t, "its prompt", func() bool { return len(userMessages(d, second)) == 1 })
	if u := userMessages(d, second); !strings.HasPrefix(u[0], "(You were started by the workflow \"Slow\" because of its schedule: the 09:00 run.)\n\n") {
		t.Fatalf("%q", u)
	}
	c.call(t, 5, "agents/stop", map[string]any{"agentID": second})
	waitFor(t, "no run left", func() bool {
		d.workflowMu.Lock()
		defer d.workflowMu.Unlock()
		return len(d.recordsLocked().Runs) == 0
	})
}
