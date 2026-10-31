package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// failedWorkflows is the folder's failed-workflow rows in its approvals.
func failedWorkflows(d *Daemon, dir string) []wire.Approval {
	s, _ := d.summaryFor(dir)
	var out []wire.Approval
	for _, a := range s.Approvals {
		if a.Kind == wire.ApprovalKindWorkflowFailed {
			out = append(out, a)
		}
	}
	return out
}

// Ports WorkflowFiringTests.aFailedRunIsListedUntilDismissed (#989, #1983): a run whose agent
// got stuck is in the folder's approvals with Dismiss only; Dismiss takes it out, on the
// workflow's record, until it fails again.
func TestAFailedRunIsListedUntilDismissed(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	folder := store.FolderURL(dir)
	os.MkdirAll(workflowsFolder(dir), 0o755)
	os.WriteFile(filepath.Join(workflowsFolder(dir), "nightly.md"), []byte("---\nname: Nightly\non: lease.granted\n---\nCheck the build.\n"), 0o644)
	approveAll(t, c, folder)
	run := func(id int) wire.UUID {
		var s wire.WorkflowSummary
		json.Unmarshal(c.call(t, id, "workflows/run", map[string]any{"folder": folder, "workflowID": "nightly"}), &s)
		if s.LastOutcome == nil || s.LastOutcome.Ran == nil {
			t.Fatalf("%+v", s)
		}
		agent := s.LastOutcome.Ran.AgentID
		waitFor(t, "the run over", func() bool {
			d.workflowMu.Lock()
			defer d.workflowMu.Unlock()
			return len(d.recordsLocked().Runs) == 0
		})
		if len(failedWorkflows(d, dir)) != 0 {
			t.Fatalf("a run that finished well is no failure: %+v", failedWorkflows(d, dir))
		}
		a := d.Store.Agent(agent)
		// A run that stopped short (#1916: a finished run is never a failure).
		a.State, a.EndedReason = wire.AgentStateStopped, reason(wire.EndedReasonRuntimeError)
		d.Store.Save(*a)
		return agent
	}
	agent := run(2)
	got := failedWorkflows(d, dir)
	if len(got) != 1 {
		t.Fatalf("%+v", got)
	}
	item := got[0]
	if item.Key != "nightly" || item.Title != "Nightly" || item.Line != "Run failed — The runtime reported an error" ||
		item.AgentID == nil || *item.AgentID != agent || item.Digest == nil ||
		len(item.Actions) != 1 || item.Actions[0] != wire.ApprovalActionDismiss {
		t.Fatalf("%+v", item)
	}
	answer := func(action, digest string) map[string]any {
		return map[string]any{"folder": folder, "kind": "workflowFailed", "key": "nightly", "digest": digest, "action": action}
	}
	if e := c.callError(t, 3, "approvals/answer", answer("approve", *item.Digest)); !strings.Contains(e.Message, "only be dismissed") {
		t.Fatalf("a failed workflow takes Dismiss only: %+v", e)
	}
	if e := c.callError(t, 4, "approvals/answer", map[string]any{"folder": folder, "kind": "archive", "key": "x", "action": "dismiss"}); !strings.Contains(e.Message, "Only a failed workflow") {
		t.Fatalf("nothing else takes Dismiss: %+v", e)
	}
	if e := c.callError(t, 5, "approvals/answer", answer("dismiss", "stale")); e.Code != wire.FailureNotChanged {
		t.Fatalf("a failure not shown is not dismissed: %+v", e)
	}
	var s wire.FolderSummary
	json.Unmarshal(c.call(t, 6, "approvals/answer", answer("dismiss", *item.Digest)), &s)
	for _, a := range s.Approvals {
		if a.Kind == wire.ApprovalKindWorkflowFailed {
			t.Fatalf("dismissed, it leaves Needs You: %+v", s.Approvals)
		}
	}
	d.workflowMu.Lock()
	kept := d.stateLocked(dir, "nightly", false).DismissedFailure
	d.workflowMu.Unlock()
	if kept == nil || *kept != *item.Digest {
		t.Fatalf("kept on the workflow's record, for every client and a restart: %v", kept)
	}
	// It fails again: listed again.
	again := run(7)
	if got := failedWorkflows(d, dir); len(got) != 1 || *got[0].AgentID != again {
		t.Fatalf("%+v", got)
	}
}
