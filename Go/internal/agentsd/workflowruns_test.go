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

// approveAll is the person approving every workflow waiting in a folder.
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
	dir := folder(t, c, 1)
	lastUsed := now() + 1
	seeded(t, d, dir, func(a *wire.Agent) {
		a.RuntimeID = "grok"
		a.LastActivityAt = lastUsed
	})
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
	// A file with no runtime: runs on Auto, not on the newest agent's runtime (#2873).
	if a == nil || a.Auto == nil || *a.Title != "Review" || a.StartedByWorkflow == nil || *a.StartedByWorkflow != "review" || *a.ChainDepth != 1 {
		t.Fatalf("%+v", a)
	}
	waitFor(t, "the run over", func() bool {
		n := names(d)
		return strings.Contains(strings.Join(n, " "), "workflow.completed")
	})
	if u := userMessages(d, agent); len(u) != 1 || u[0] != "(You were started by the workflow \"Review\" because the person ran it by hand, with Run now.)\n\nReview what changed.\n" {
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

// A mode the runtime does not offer stops the run, rather than leaving the agent in the
// runtime's own default; with nothing offered yet, the mode is taken as offered.
func TestAWorkflowModeTheRuntimeDoesNotOffer(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	if id, why := d.offeredMode("grok", "auto"); id != "mode" || why != "" {
		t.Fatal(id, why)
	}
	cat := "mode"
	d.remember("grok\t/x\t", optionEntry{SavedAt: now(), Options: []wire.ConfigOption{{ID: "permission", Name: "Mode", Type: "select", Category: &cat,
		Options: json.RawMessage(`[{"value":"default","name":"Default"},{"value":"read-only","name":"Read only"}]`)}}})
	if id, why := d.offeredMode("grok", "read-only"); id != "permission" || why != "" {
		t.Fatal(id, why)
	}
	if _, why := d.offeredMode("grok", "auto"); !strings.Contains(why, "does not offer the mode auto") || !strings.Contains(why, "default, read-only") {
		t.Fatal(why)
	}
	d.remember("codex\t/x\t", optionEntry{SavedAt: now(), Options: []wire.ConfigOption{{ID: "model", Name: "Model", Type: "select"}}})
	if _, why := d.offeredMode("codex", "auto"); !strings.Contains(why, "offers no modes") {
		t.Fatal(why)
	}
}

func TestAllowanceFailureDoesNotAutoarchiveWorkflowRun(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	const id = "allowance"
	if err := os.MkdirAll(workflowsFolder(dir), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(workflowsFolder(dir), id+".md"), []byte("---\nname: Allowance check\nwhen-done: archive\n---\nCheck usage.\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	d.workflowMu.Lock()
	d.scanLocked()
	d.workflowMu.Unlock()
	workflowID := id
	a := seeded(t, d, dir, func(a *wire.Agent) {
		a.State = wire.AgentStateStopped
		a.EndedReason = reason(wire.EndedReasonAllowanceSpent)
		a.StartedByWorkflow = &workflowID
	})
	d.workflowMu.Lock()
	d.recordsLocked().Runs = append(d.recordsLocked().Runs, workflowRun{
		ID: store.NewUUID(), WorkflowID: id, Folder: store.FolderURL(dir), AgentID: &a.ID, StartedAt: now(),
	})
	d.workflowMu.Unlock()

	d.workflowRunFinished(a.ID)
	if got := d.Store.Agent(a.ID); got == nil || got.State != wire.AgentStateStopped {
		t.Fatalf("allowance failure was archived: %+v", got)
	}
}

func TestRunNowRetriesStoppedWorkflowOnCurrentRuntime(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	folderURL := store.FolderURL(dir)
	path := filepath.Join(workflowsFolder(dir), "retry.md")
	if err := os.MkdirAll(workflowsFolder(dir), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("---\nname: Retry\nruntime: grok\n---\nwait for me\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	approveAll(t, c, folderURL)
	stopped := seeded(t, d, dir, func(a *wire.Agent) {
		a.State = wire.AgentStateStopped
		a.EndedReason = reason(wire.EndedReasonAllowanceSpent)
	})
	d.workflowMu.Lock()
	d.recordsLocked().Runs = append(d.recordsLocked().Runs,
		workflowRun{ID: store.NewUUID(), WorkflowID: "retry", Folder: folderURL, StartedAt: now()},
		workflowRun{ID: store.NewUUID(), WorkflowID: "retry", Folder: folderURL, AgentID: &stopped.ID, StartedAt: now()})
	d.workflowMu.Unlock()
	if err := os.WriteFile(path, []byte("---\nname: Retry\nruntime: codex\n---\nwait for me\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	approveAll(t, c, folderURL)
	var summary wire.WorkflowSummary
	json.Unmarshal(c.call(t, 2, "workflows/run", map[string]any{"folder": folderURL, "workflowID": "retry"}), &summary)
	if summary.LastOutcome == nil || summary.LastOutcome.Ran == nil {
		t.Fatalf("retry did not run: %+v", summary.LastOutcome)
	}
	agent := summary.LastOutcome.Ran.AgentID
	if a := d.Store.Agent(agent); a == nil || a.RuntimeID != "codex" {
		t.Fatalf("retry did not use the current runtime: %+v", a)
	}
	// The new agent is still active, so another Run now remains refused.
	json.Unmarshal(c.call(t, 3, "workflows/run", map[string]any{"folder": folderURL, "workflowID": "retry"}), &summary)
	if summary.LastOutcome.Refused == nil || summary.LastOutcome.Refused.Value.RunInFlight == nil {
		t.Fatalf("active run was not protected: %+v", summary.LastOutcome)
	}
	c.call(t, 4, "agents/stop", map[string]any{"agentID": agent})
}

func TestRunEndingBeforeAgentAttachmentReleasesRun(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	if err := os.MkdirAll(workflowsFolder(dir), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(workflowsFolder(dir), "early.md"), []byte("---\nname: Early\n---\nFinish.\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	d.workflowMu.Lock()
	d.scanLocked()
	w := d.fileLocked(dir, "early").wf
	run := workflowRun{ID: store.NewUUID(), WorkflowID: "early", Folder: store.FolderURL(dir), StartedAt: now()}
	d.recordsLocked().Runs = append(d.recordsLocked().Runs, run)
	d.workflowStarting = map[wire.UUID]bool{run.ID: true}
	d.workflowMu.Unlock()
	agent := seeded(t, d, dir, func(a *wire.Agent) { a.State = wire.AgentStateStopped })
	// This is what the turn ending does before fire has attached its agent ID.
	d.workflowRunFinished(agent.ID)
	if !d.runningOf(dir, "early") {
		t.Fatal("the setup did not leave an unattached run")
	}
	d.attachRunAgent(fireRequest{folder: dir, id: "early", byHand: true}, run, w, agent.ID)
	if d.runningOf(dir, "early") {
		t.Fatal("the completed agent left its run in flight")
	}
	if !strings.Contains(strings.Join(names(d), " "), "workflow.completed") {
		t.Fatal("the completed run was not reported")
	}
}

func TestRunNowUsesExplicitlyChangedRuntimeWhileOldRunIsActive(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	folderURL := store.FolderURL(dir)
	if err := os.MkdirAll(workflowsFolder(dir), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(workflowsFolder(dir), "retry.md"), []byte("---\nname: Retry\nruntime: codex\n---\nwait for me\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	approveAll(t, c, folderURL)
	old := seeded(t, d, dir, func(a *wire.Agent) {
		a.RuntimeID = "grok"
		a.State = wire.AgentStateRunning
	})
	pending := workflowRun{ID: store.NewUUID(), WorkflowID: "retry", Folder: folderURL, StartedAt: now()}
	d.workflowMu.Lock()
	d.recordsLocked().Runs = append(d.recordsLocked().Runs,
		workflowRun{ID: store.NewUUID(), WorkflowID: "retry", Folder: folderURL, AgentID: &old.ID, StartedAt: now()}, pending)
	d.workflowStarting = map[wire.UUID]bool{pending.ID: true}
	d.workflowMu.Unlock()

	var summary wire.WorkflowSummary
	json.Unmarshal(c.call(t, 2, "workflows/run", map[string]any{"folder": folderURL, "workflowID": "retry"}), &summary)
	if summary.LastOutcome == nil || summary.LastOutcome.Refused == nil || summary.LastOutcome.Refused.Value.RunInFlight == nil {
		t.Fatalf("a start without an agent ID did not block Run now: %+v", summary.LastOutcome)
	}
	d.releaseRun(pending.ID)
	json.Unmarshal(c.call(t, 3, "workflows/run", map[string]any{"folder": folderURL, "workflowID": "retry"}), &summary)
	if summary.LastOutcome == nil || summary.LastOutcome.Ran == nil {
		t.Fatalf("Run now did not retry on the selected runtime: %+v", summary.LastOutcome)
	}
	newAgent := summary.LastOutcome.Ran.AgentID
	if a := d.Store.Agent(newAgent); a == nil || a.RuntimeID != "codex" {
		t.Fatalf("retry used the wrong runtime: %+v", a)
	}
	json.Unmarshal(c.call(t, 4, "workflows/run", map[string]any{"folder": folderURL, "workflowID": "retry"}), &summary)
	if summary.LastOutcome.Refused == nil || summary.LastOutcome.Refused.Value.RunInFlight == nil {
		t.Fatalf("a run on the selected runtime did not block Run now: %+v", summary.LastOutcome)
	}
	c.call(t, 5, "agents/stop", map[string]any{"agentID": newAgent})
}

func TestAFireWhileARunGoesQueues(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
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

// A workflow whose runs-on: names this computer's id is listed and runs; one naming another
// is neither (#1761, was hosts:; #1404: a Mac's id is its hardware UUID, which the Go host never read).
func TestAWorkflowPinnedHereRuns(t *testing.T) {
	fakeRuntimes(t)
	t.Setenv("AGENTS_MACHINE_ID", "")
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	folder := store.FolderURL(dir)
	os.MkdirAll(workflowsFolder(dir), 0o755)
	os.WriteFile(filepath.Join(workflowsFolder(dir), "here.md"), []byte("---\nname: Here\non: lease.granted\nruns-on: ["+machine.ID()+"]\n---\nLook.\n"), 0o644)
	os.WriteFile(filepath.Join(workflowsFolder(dir), "there.md"), []byte("---\nname: There\non: lease.granted\nruns-on: [another-computer]\n---\nLook.\n"), 0o644)
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
