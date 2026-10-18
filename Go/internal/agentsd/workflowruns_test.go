package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/machine"
	"github.com/alexec/agents/Go/wire"
)

// Ports WorkflowFireTests and WorkflowQueueTests: Run now starts the workflow's agent and
// its run ends with the agent's turn; an event fires the workflow that waits on it, never
// on news of its own agents; a fire while a run goes queues, and goes when it ends.

// approveAll is the person approving every workflow waiting in a project.
func approveAll(t *testing.T, c *conn, folder wire.URL) {
	t.Helper()
	var list []wire.WorkflowSummary
	json.Unmarshal(c.call(t, 90, "workflows/list", map[string]any{"folder": folder}), &list)
	for i, s := range list {
		if s.AwaitingApproval != nil {
			c.call(t, 91+i, "workflows/approve", map[string]any{"folder": folder, "workflowID": s.Workflow.WorkflowID, "digest": s.AwaitingApproval.Digest})
		}
	}
}

func TestAWorkflowRuns(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := project(t, c, 1)
	folder := store.FolderURL(dir)
	os.MkdirAll(workflowsFolder(dir), 0o755)
	os.WriteFile(filepath.Join(workflowsFolder(dir), "review.md"), []byte("---\nname: Review\non: lease.granted\n---\nReview what changed.\n"), 0o644)
	approveAll(t, c, folder)
	var s wire.WorkflowSummary
	json.Unmarshal(c.call(t, 2, "workflows/run", map[string]any{"folder": folder, "workflowID": "review"}), &s)
	if s.LastOutcome == nil || s.LastOutcome.Ran == nil {
		t.Fatalf("%+v", s)
	}
	agent := s.LastOutcome.Ran.AgentID
	a := d.Store.Agent(agent)
	if a == nil || *a.Title != "Review" || a.StartedByWorkflow == nil || *a.StartedByWorkflow != "review" || *a.ChainDepth != 1 {
		t.Fatalf("%+v", a)
	}
	waitFor(t, "the run over", func() bool {
		n := names(d)
		return strings.Contains(strings.Join(n, " "), "workflow.completed")
	})
	if u := userMessages(d, agent); len(u) != 1 || u[0] != "Review what changed.\n" {
		t.Fatalf("%q", u)
	}
	// An event the workflow waits on fires it, and says so on the event.
	e := d.raise(wire.EventDraft{Name: "lease.granted", At: now(), Scope: macScope(), Sentence: "x was given build.",
		Details: map[string]string{"resource": "build"}})
	waitFor(t, "the event's run", func() bool {
		got := d.event(e.Position)
		return got != nil && len(got.Consequences) == 1 && got.Consequences[0].Fired != nil
	})
	var runs []string
	for _, n := range names(d) {
		if strings.HasPrefix(n, "workflow.") {
			runs = append(runs, n)
		}
	}
	if len(runs) < 3 || runs[0] != "workflow.ran" {
		t.Fatal(runs)
	}
	waitFor(t, "both over", func() bool {
		d.workflowMu.Lock()
		defer d.workflowMu.Unlock()
		return len(d.recordsLocked().Runs) == 0
	})
}

func TestAFireWhileARunGoesQueues(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := project(t, c, 1)
	folder := store.FolderURL(dir)
	os.MkdirAll(workflowsFolder(dir), 0o755)
	os.WriteFile(filepath.Join(workflowsFolder(dir), "slow.md"), []byte("---\non: server.online\n---\nwait for me\n"), 0o644)
	approveAll(t, c, folder)
	var s wire.WorkflowSummary
	json.Unmarshal(c.call(t, 2, "workflows/run", map[string]any{"folder": folder, "workflowID": "slow"}), &s)
	first := s.LastOutcome.Ran.AgentID
	waitFor(t, "it working", func() bool { return d.Store.Agent(first).State == wire.AgentStateRunning })
	e := d.raise(wire.EventDraft{Name: "server.online", At: now(), Scope: macScope(), Sentence: "ci came back.", Details: map[string]string{"server": "ci"}})
	waitFor(t, "the fire queued", func() bool {
		got := d.event(e.Position)
		return got != nil && len(got.Consequences) == 1 && got.Consequences[0].Refused != nil && got.Consequences[0].Refused.Reason.Queued != nil
	})
	// By hand while it runs is refused, and said.
	s = wire.WorkflowSummary{}
	json.Unmarshal(c.call(t, 3, "workflows/run", map[string]any{"folder": folder, "workflowID": "slow"}), &s)
	if s.LastOutcome.Refused == nil || s.LastOutcome.Refused.Value.RunInFlight == nil || s.Queued != 1 {
		t.Fatalf("%+v", s)
	}
	c.call(t, 4, "agents/stop", map[string]any{"agentID": first})
	waitFor(t, "the queued one fired", func() bool {
		got := d.event(e.Position)
		return got != nil && len(got.Consequences) == 1 && got.Consequences[0].Fired != nil
	})
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		d.workflowMu.Lock()
		n := len(d.recordsLocked().Runs)
		var agent *wire.UUID
		if n > 0 {
			agent = d.workflowRecs.Runs[0].AgentID
		}
		d.workflowMu.Unlock()
		if agent != nil {
			c.call(t, 5, "agents/stop", map[string]any{"agentID": *agent})
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	waitFor(t, "no run left", func() bool {
		d.workflowMu.Lock()
		defer d.workflowMu.Unlock()
		return len(d.recordsLocked().Runs) == 0
	})
}

// A workflow pinned to this computer's id is listed and runs; one pinned to another is
// neither (#1404: a Mac's id is its hardware UUID, which the Go host never read).
func TestAWorkflowPinnedHereRuns(t *testing.T) {
	fakeRuntimes(t)
	t.Setenv("AGENTS_MACHINE_ID", "")
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := project(t, c, 1)
	folder := store.FolderURL(dir)
	os.MkdirAll(workflowsFolder(dir), 0o755)
	os.WriteFile(filepath.Join(workflowsFolder(dir), "here.md"), []byte("---\nname: Here\non: lease.granted\nhosts: ["+machine.ID()+"]\n---\nLook.\n"), 0o644)
	os.WriteFile(filepath.Join(workflowsFolder(dir), "there.md"), []byte("---\nname: There\non: lease.granted\nhosts: [another-computer]\n---\nLook.\n"), 0o644)
	approveAll(t, c, folder)
	var list []wire.WorkflowSummary
	json.Unmarshal(c.call(t, 2, "workflows/list", map[string]any{"folder": folder}), &list)
	if len(list) != 1 || list[0].Workflow.WorkflowID != "here" {
		t.Fatalf("%+v", list)
	}
	var s wire.WorkflowSummary
	json.Unmarshal(c.call(t, 3, "workflows/run", map[string]any{"folder": folder, "workflowID": "here"}), &s)
	if s.LastOutcome == nil || s.LastOutcome.Ran == nil {
		t.Fatalf("%+v", s)
	}
	if e := c.callError(t, 4, "workflows/run", map[string]any{"folder": folder, "workflowID": "there"}); e.Code != wire.FailureNoSuchWorkflow {
		t.Fatalf("%+v", e)
	}
	waitFor(t, "the run over", func() bool {
		d.workflowMu.Lock()
		defer d.workflowMu.Unlock()
		return len(d.recordsLocked().Runs) == 0
	})
}
