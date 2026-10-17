package agentsd

import (
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// A workflow waiting for an OK is asked as a changed guarded file is (#569, #1322), as
// DaemonCore+WorkflowQuestions asks it: in the project's guardedChanges by its file's path,
// in its approvals as the workflow kind, and so in Needs You on every client. Keep is
// Approve; Undo writes back the copy last approved, or removes a file never approved.

const workflowChangeFolder = ".agents/workflows/"

// workflowChangePath is the path a workflow's waiting change is asked by.
func workflowChangePath(id string) string { return workflowChangeFolder + id + ".md" }

// workflowIDInPath is the workflow a guarded path names, if it names one.
func workflowIDInPath(path string) (string, bool) {
	if !strings.HasPrefix(path, workflowChangeFolder) || !strings.HasSuffix(path, ".md") {
		return "", false
	}
	id := strings.TrimSuffix(strings.TrimPrefix(path, workflowChangeFolder), ".md")
	return id, id != "" && !strings.Contains(id, "/")
}

// waitingWorkflowChanges is the project's workflows that run here, are not archived and
// wait for an OK, as changes. Since is when the file last changed.
func (d *Daemon) waitingWorkflowChanges(folder string) []wire.GuardedChange {
	d.workflowMu.Lock()
	defer d.workflowMu.Unlock()
	if d.workflowFiles == nil {
		d.scanLocked()
	}
	out := []wire.GuardedChange{}
	for id, f := range d.workflowFiles[folder] {
		if !d.runsHere(f.wf) || isArchived(f.wf) {
			continue
		}
		awaiting, _ := d.approvalOf(folder, id, f)
		if awaiting == nil {
			continue
		}
		digest := awaiting.Digest
		since := now()
		if path, ok := workflowPath(folder, id); ok {
			if fi, err := os.Stat(path); err == nil {
				since = wire.DateOf(fi.ModTime())
			}
		}
		out = append(out, wire.GuardedChange{Path: workflowChangePath(id), Digest: &digest,
			ChangedBy: []string{}, ChangedByIDs: []wire.UUID{}, Since: since})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Path < out[j].Path })
	return out
}

// workflowApproval is a waiting workflow as an approval: titled by its name, New until
// it has been approved once.
func (d *Daemon) workflowApproval(folder string, c wire.GuardedChange) wire.Approval {
	id, _ := workflowIDInPath(c.Path)
	title, isNew := id, true
	d.workflowMu.Lock()
	if f := d.fileLocked(folder, id); f != nil {
		if f.wf.Name != "" {
			title = f.wf.Name
		}
		if awaiting, _ := d.approvalOf(folder, id, f); awaiting != nil {
			isNew = awaiting.IsNew
		}
	}
	d.workflowMu.Unlock()
	line := "Changed since you approved it"
	if isNew {
		line = "New"
	}
	since := c.Since
	return wire.Approval{Kind: wire.ApprovalKindWorkflow, Key: id, Title: title, Digest: c.Digest, Line: line,
		Since: &since, Actions: []wire.ApprovalAction{wire.ApprovalActionApprove, wire.ApprovalActionDeny}}
}

// readWorkflowChange is a waiting workflow's lines against the copy last approved.
func (d *Daemon) readWorkflowChange(folder, id string) (wire.GuardedChangeReading, error) {
	d.workflowMu.Lock()
	d.scanLocked()
	f := d.fileLocked(folder, id)
	if f == nil {
		d.workflowMu.Unlock()
		return wire.GuardedChangeReading{}, noSuchWorkflow(id)
	}
	current, digest := f.text, f.digest
	approved, hasApproved := d.approvedCopyLocked(folder, id)
	d.workflowMu.Unlock()
	out := wire.GuardedChangeReading{Path: workflowChangePath(id), Digest: &digest, Current: &current}
	if hasApproved {
		out.Approved = &approved
	}
	out.Lines = diffLines(approved, current)
	return out, nil
}

// approvedCopyLocked is the text last approved, when a copy of it was kept.
func (d *Daemon) approvedCopyLocked(folder, id string) (string, bool) {
	st := d.stateLocked(folder, id, false)
	if st == nil || st.ApprovedDigest == nil || st.ApprovedCopy == nil {
		return "", false
	}
	b, err := os.ReadFile(filepath.Join(d.workflowCopies(), *st.ApprovedCopy))
	if err != nil {
		return "", false
	}
	return string(b), true
}

// keepOrUndoWorkflow is Keep (Approve) or Undo of a waiting workflow, for the version the
// person was shown.
func (d *Daemon) keepOrUndoWorkflow(folder, id string, digest *string, keep bool) (wire.ProjectSummary, error) {
	if digest == nil {
		return wire.ProjectSummary{}, Invalid("Say which version you were shown.")
	}
	if keep {
		return d.answerWorkflow(folder, id, digest, true)
	}
	d.workflowMu.Lock()
	d.scanLocked()
	f := d.fileLocked(folder, id)
	if f == nil {
		d.workflowMu.Unlock()
		return wire.ProjectSummary{}, noSuchWorkflow(id)
	}
	if f.digest != *digest {
		d.workflowMu.Unlock()
		return wire.ProjectSummary{}, &Error{Code: wire.FailureNotChanged, Message: f.wf.Name + " changed after you looked at it, so it was not undone. Look again."}
	}
	approved, had := d.approvedCopyLocked(folder, id)
	d.workflowMu.Unlock()
	path, ok := workflowPath(folder, id)
	err := errors.New("that is not a workflow's name")
	if ok {
		if had {
			err = store.WriteAtomically(path, []byte(approved), 0o644)
		} else if err = os.Remove(path); errors.Is(err, os.ErrNotExist) {
			err = nil
		}
	}
	if err != nil {
		return wire.ProjectSummary{}, &Error{Code: CodeInternal, Message: workflowChangePath(id) + " could not be put back: " + err.Error()}
	}
	d.rescanWorkflows(folder) // tells the clients, the project's summary with them
	s, _ := d.summaryFor(folder)
	return s, nil
}

// answerWorkflow is Approve or Deny from Needs You: workflows/approve or workflows/deny,
// which tell every client, then the project as it stands.
func (d *Daemon) answerWorkflow(folder, id string, digest *string, approve bool) (wire.ProjectSummary, error) {
	if digest == nil {
		return wire.ProjectSummary{}, Invalid("Say which version you were shown.")
	}
	if _, err := d.approveWorkflow(wire.WorkflowApproveRequest{Folder: store.FolderURL(folder), WorkflowID: id, Digest: *digest}, approve); err != nil {
		return wire.ProjectSummary{}, err
	}
	s, _ := d.summaryFor(folder)
	return s, nil
}
