package agentsd

import (
	"fmt"
	"log"
	"sort"

	"github.com/alexec/agents/Go/wire"
)

// Needs You lists a workflow that has stopped working (#989), as the Swift host did (#1036):
// its last run's agent stopped short, or a refusal
// repeats until somebody acts. Only Dismiss answers it; that keeps the failure's key on the
// workflow's record (dismissedFailure) until it fails again.

// workflowFailure is WorkflowFailure: which failure (the run or the refusal), what went
// wrong, when, and the run's agent.
type workflowFailure struct {
	key   string
	line  string
	since *wire.Date
	agent *wire.UUID
}

// refusalNeedsAPerson is WorkflowRefusal.needsAPerson, less waiting for an OK, which is
// listed as an approval of its own.
func refusalNeedsAPerson(r wire.WorkflowRefusal) bool {
	return r.ChainTooDeep != nil || r.Unreadable != nil || r.FolderGone != nil || r.OverLimit != nil || r.SettingRefused != nil
}

// failureOf is WorkflowFailure.of: from the workflow, its last outcome and that outcome's
// agent, with no file read. False when nothing is wrong that a person must fix.
func (d *Daemon) failureOf(w wire.Workflow, last *wire.WorkflowOutcome) (workflowFailure, bool) {
	if isArchived(w) {
		return workflowFailure{}, false
	}
	if w.Problem != nil && w.Problem.Unreadable != nil {
		m := problemMessage(*w.Problem)
		return workflowFailure{key: "problem:" + m, line: "Cannot be read — " + m}, true
	}
	switch {
	case last == nil:
	case last.Refused != nil && refusalNeedsAPerson(last.Refused.Value):
		// The file read well again since: a refusal for it is history now.
		if last.Refused.Value.Unreadable != nil && w.Problem == nil {
			return workflowFailure{}, false
		}
		at := last.Refused.At
		return workflowFailure{key: "refused:" + refusalCode(last.Refused.Value), line: outcomeWords(*last), since: &at}, true
	case last.Ran != nil:
		a := d.Store.Agent(last.Ran.AgentID)
		if a == nil {
			return workflowFailure{}, false
		}
		line, ok := runFailure(a)
		if !ok {
			return workflowFailure{}, false
		}
		id, since := a.ID, last.Ran.At
		if a.Report != nil {
			since = a.Report.At
		}
		return workflowFailure{key: fmt.Sprintf("ran:%s:%v", id, float64(last.Ran.At)), line: line, since: &since, agent: &id}, true
	}
	return workflowFailure{}, false
}

// runFailure is WorkflowFailure.runFailure: how a run's agent ended, when it failed. A question is the agent's own row in Needs You, not a failure.
func runFailure(a *wire.Agent) (string, bool) {
	switch a.State {
	case wire.AgentStateStopped:
		if Group(a) != "needsAttention" {
			return "", false
		}
		why := "it stopped"
		if a.EndedReason != nil {
			if s, ok := endedSummary[*a.EndedReason]; ok {
				why = s
			}
		}
		return "Run failed — " + why, true
	}
	// A finished run is never a failure: only a question wants the person (#1916).
	return "", false
}

// workflowFailures is the folder's workflows that have stopped working, less the failure
// each the person dismissed, by id. Waiting for an OK or denied here is not a failure, nor
// over the limit once it no longer is.
func (d *Daemon) workflowFailures(folder string) []wire.Approval {
	d.workflowMu.Lock()
	defer d.workflowMu.Unlock()
	if d.workflowFiles == nil {
		d.scanLocked()
	}
	ws := d.workflowFiles[folder]
	ids := make([]string, 0, len(ws))
	for id := range ws {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	var over map[string]wire.WorkflowLimit
	var out []wire.Approval
	for _, id := range ids {
		f := ws[id]
		if !d.runsHere(f.wf) {
			continue
		}
		st := d.stateLocked(folder, id, false)
		var last *wire.WorkflowOutcome
		if st != nil {
			last = st.LastOutcome
		}
		fail, ok := d.failureOf(f.wf, last)
		if !ok {
			continue
		}
		if awaiting, denied := d.approvalOf(folder, id, f); awaiting != nil || denied != nil {
			continue
		}
		if last != nil && last.Refused != nil && last.Refused.Value.OverLimit != nil {
			if over == nil {
				over = d.ceilingsLocked()
			}
			if _, still := over[workflowKey(folder, id)]; !still {
				continue
			}
		}
		if st != nil && st.DismissedFailure != nil && *st.DismissedFailure == fail.key {
			continue
		}
		title, key := f.wf.Name, fail.key
		if title == "" {
			title = id
		}
		out = append(out, wire.Approval{Kind: wire.ApprovalKindWorkflowFailed, Key: id, Title: title, Digest: &key,
			Line: fail.line, Since: fail.since, Actions: []wire.ApprovalAction{wire.ApprovalActionDismiss}, AgentID: fail.agent})
	}
	return out
}

// dismissWorkflowFailure is Dismiss: out of Needs You until it fails again, kept on the
// workflow's record for every client and a restart. Refused when it has failed anew since
// it was shown, so a dismissal never hides a failure nobody saw.
func (d *Daemon) dismissWorkflowFailure(folder, id string, digest *string) (wire.FolderSummary, error) {
	if digest == nil {
		return wire.FolderSummary{}, Invalid("Say which failure you were shown.")
	}
	shown := false
	for _, a := range d.workflowFailures(folder) {
		if a.Key == id && a.Digest != nil && *a.Digest == *digest {
			shown = true
		}
	}
	if !shown {
		return wire.FolderSummary{}, &Error{Code: wire.FailureNotChanged, Message: "That workflow has failed again since you looked, or it works now. Look again."}
	}
	d.workflowMu.Lock()
	key := *digest
	d.stateLocked(folder, id, true).DismissedFailure = &key
	d.saveRecordsLocked(false)
	d.workflowMu.Unlock()
	log.Printf("workflows: failure of %s in %s dismissed", id, folder)
	return d.sendFolder(folder)
}
