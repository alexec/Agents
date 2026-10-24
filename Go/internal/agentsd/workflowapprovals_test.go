package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// A workflow waiting for an OK is in the folder's guarded changes, its approvals and
// Needs You, as on the Swift host (#1322); Approve, Deny and Undo settle it from there.
func TestAWaitingWorkflowIsInTheFoldersApprovals(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	folder := store.FolderURL(dir)
	os.MkdirAll(workflowsFolder(dir), 0o755)
	write := func(id, text string) {
		os.WriteFile(filepath.Join(workflowsFolder(dir), id+".md"), []byte(text), 0o644)
		d.rescanWorkflows(dir)
	}
	write("greet", "---\nname: Greet\non: agent.finished\n---\nSay hello.\n")
	s, _ := d.summaryFor(dir)
	if len(s.GuardedChanges) != 1 || s.GuardedChanges[0].Path != ".agents/workflows/greet.md" || s.GuardedChanges[0].Digest == nil {
		t.Fatalf("%+v", s.GuardedChanges)
	}
	if len(s.Approvals) != 1 || s.Approvals[0].Kind != wire.ApprovalKindWorkflow || s.Approvals[0].Key != "greet" ||
		s.Approvals[0].Title != "Greet" || s.Approvals[0].Line != "New" || len(s.Approvals[0].Actions) != 2 {
		t.Fatalf("%+v", s.Approvals)
	}
	if n := d.attentionPending().Needs; len(n) != 1 || n[0].Kind != wire.NeedKindGuardedChange ||
		n[0].ID.GuardedChange == nil || n[0].ID.GuardedChange.Path != ".agents/workflows/greet.md" {
		t.Fatalf("%+v", n)
	}
	var reading wire.GuardedChangeReading
	json.Unmarshal(c.call(t, 2, "approvals/read", map[string]any{"folder": folder, "kind": "workflow", "key": "greet"}), &reading)
	if reading.Current == nil || reading.Approved != nil || *reading.Digest != *s.Approvals[0].Digest || len(reading.Lines) == 0 {
		t.Fatalf("%+v", reading)
	}
	if e := c.callError(t, 3, "approvals/answer", map[string]any{"folder": folder, "kind": "workflow", "key": "greet", "digest": "stale", "action": "approve"}); e.Code != wire.FailureNotChanged {
		t.Fatalf("%+v", e)
	}
	// Approve from Needs You: it runs, and leaves the list.
	c.call(t, 4, "approvals/answer", map[string]any{"folder": folder, "kind": "workflow", "key": "greet", "digest": *reading.Digest, "action": "approve"})
	if s, _ := d.summaryFor(dir); len(s.GuardedChanges) != 0 || len(s.Approvals) != 0 || len(d.attentionPending().Needs) != 0 {
		t.Fatalf("%+v %+v", s.GuardedChanges, s.Approvals)
	}
	// Changed: it waits again, as a change; Undo puts back the approved copy.
	write("greet", "---\nname: Greet\non: agent.finished\n---\nSay goodbye.\n")
	s, _ = d.summaryFor(dir)
	if len(s.Approvals) != 1 || s.Approvals[0].Line != "Changed since you approved it" {
		t.Fatalf("%+v", s.Approvals)
	}
	c.call(t, 5, "folders/undoGuardedChange", map[string]any{"folder": folder, "path": ".agents/workflows/greet.md", "digest": *s.Approvals[0].Digest})
	if b, _ := os.ReadFile(filepath.Join(workflowsFolder(dir), "greet.md")); string(b) != "---\nname: Greet\non: agent.finished\n---\nSay hello.\n" {
		t.Fatalf("%s", b)
	}
	if s, _ := d.summaryFor(dir); len(s.Approvals) != 0 {
		t.Fatalf("%+v", s.Approvals)
	}
	// Deny from Needs You: denied here, and out of the list until it changes.
	write("other", "---\nname: Other\non: agent.finished\n---\nHi.\n")
	s, _ = d.summaryFor(dir)
	if len(s.Approvals) != 1 {
		t.Fatalf("%+v", s.Approvals)
	}
	c.call(t, 6, "approvals/answer", map[string]any{"folder": folder, "kind": "workflow", "key": "other", "digest": *s.Approvals[0].Digest, "action": "deny"})
	if s, _ := d.summaryFor(dir); len(s.Approvals) != 0 {
		t.Fatalf("%+v", s.Approvals)
	}
	var list []wire.WorkflowSummary
	json.Unmarshal(c.call(t, 7, "workflows/list", map[string]any{"folder": folder}), &list)
	for _, w := range list {
		if w.Workflow.WorkflowID == "other" && w.DeniedHere == nil {
			t.Fatalf("%+v", w)
		}
	}
}
