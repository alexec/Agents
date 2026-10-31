package agentsd

import (
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// Mute Notifications (#2003): the person silences one session, or every run of one
// workflow, and keeps the others. A muted session's need still goes under Needs you and
// counts in the badge (waitingCount), but reconsider delivers it to no surface and offers
// it to no control plane, so it makes no Mac notification, no banner and no push. The mark
// is kept on the session's record, so every client of the person agrees.

// setMuted puts the mark on a session, or takes it off, without moving it up its list. Nil
// when there is no such session.
func (d *Daemon) setMuted(id wire.UUID, muted bool) *wire.Agent {
	return d.changeAgent(id, false, func(a *wire.Agent) {
		if muted {
			a.IsMuted = &muted
		} else {
			a.IsMuted = nil
		}
	})
}

// muteWorkflow is workflows/setMuted: `muted: true` in the workflow's front matter, so its
// next runs start muted, and the same mark on each of its sessions not archived.
func (d *Daemon) muteWorkflow(r wire.WorkflowMuteRequest, byPerson bool) (wire.WorkflowSummary, error) {
	folder := store.FolderPath(r.Folder)
	d.workflowMu.Lock()
	d.scanLocked()
	err := d.editWorkflowLocked(folder, r.WorkflowID, byPerson, func(text string) (string, error) {
		if r.Muted {
			return setFrontMatter("muted", strPtr("true"), text)
		}
		return setFrontMatter("muted", nil, text)
	})
	d.workflowMu.Unlock()
	if err != nil {
		return wire.WorkflowSummary{}, err
	}
	for _, a := range d.Store.Agents() {
		if a.State == wire.AgentStateArchived || a.StartedByWorkflow == nil || *a.StartedByWorkflow != r.WorkflowID || folderPath(&a) != folder {
			continue
		}
		if (a.IsMuted != nil && *a.IsMuted) != r.Muted {
			d.setMuted(a.ID, r.Muted)
		}
	}
	d.tellWorkflow(folder, r.WorkflowID)
	return d.oneWorkflow(folder, r.WorkflowID)
}
