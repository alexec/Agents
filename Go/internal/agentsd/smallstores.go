package agentsd

import (
	"encoding/json"
	"errors"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// Small stores that grew and never shrank (#3652): each is pruned by the hourly sweep.
// A workflow's state goes 30 days after its file went; the approvals and the review files
// let go of a folder that is gone; a device not seen for 90 days is forgotten.

const (
	workflowStateKeptGone = 30 * 24 * time.Hour
	deviceKeptUnseen      = 90 * 24 * time.Hour
)

func (d *Daemon) sweepSmallStores(now time.Time) {
	d.sweepGoneWorkflowStates(now)
	gone := d.goneFolderTest()
	d.sweepMCPApprovals(gone)
	d.sweepPluginApprovals(gone)
	d.sweepReviewFolders(gone)
	d.sweepUnseenDevices(now)
}

// goneFolderTest says whether a folder is gone: no folder of this host, and not on disk. A
// folder on a drive not plugged in now is still a folder of this host, so it is kept.
func (d *Daemon) goneFolderTest() func(folder string) bool {
	known := map[string]bool{}
	for _, f := range d.folderPaths() {
		known[filepath.Clean(f)] = true
	}
	if home := d.personalHome(); home != "" {
		known[filepath.Clean(home)] = true
	}
	return func(folder string) bool {
		if !filepath.IsAbs(folder) || known[filepath.Clean(folder)] {
			return false
		}
		_, err := os.Stat(folder)
		return errors.Is(err, os.ErrNotExist)
	}
}

// sweepGoneWorkflowStates marks each state whose workflow file is not there now with the
// time it went, clears that when the file is back, and drops a state gone for 30 days.
// Saving drops the copies no state names any more.
func (d *Daemon) sweepGoneWorkflowStates(now time.Time) {
	d.workflowMu.Lock()
	defer d.workflowMu.Unlock()
	// Before the first scan nothing is known to be gone.
	if d.workflowFiles == nil {
		return
	}
	r := d.recordsLocked()
	if d.workflowRecsBad {
		return
	}
	changed := false
	kept := r.States[:0]
	for _, st := range r.States {
		there := d.workflowFiles[store.FolderPath(st.Folder)][st.WorkflowID] != nil
		switch {
		case there && st.GoneSince != nil:
			st.GoneSince, changed = nil, true
		case !there && st.GoneSince == nil:
			t := wire.DateOf(now)
			st.GoneSince, changed = &t, true
		case !there && now.Sub(st.GoneSince.Time()) >= workflowStateKeptGone:
			log.Printf("workflows: let go of %s in %s: its file went 30 days ago", st.WorkflowID, st.Folder)
			changed = true
			continue
		}
		kept = append(kept, st)
	}
	r.States = kept
	if changed {
		d.saveRecordsLocked(false)
	}
}

// approvalKeyFolder is the folder a key of the approvals files begins with: the part before
// the first "|". A scope that is not a path (the user's) is never a folder that is gone.
func approvalKeyFolder(key string) string {
	folder, _, _ := strings.Cut(key, "|")
	return folder
}

// sweepMCPApprovals drops the approved servers and views of folders that are gone. A file
// not there, or one that could not be read, is left as it is.
func (d *Daemon) sweepMCPApprovals(gone func(string) bool) {
	if _, err := os.Stat(d.mcpApprovalsPath()); err != nil {
		return
	}
	d.mcpMu.Lock()
	defer d.mcpMu.Unlock()
	d.mcpApprovalsLocked()
	if d.mcpApprovals == nil {
		return
	}
	changed := false
	for _, part := range []string{"approved", "views"} {
		raw := d.mcpApprovals[part]
		if raw == nil {
			continue
		}
		m := map[string]string{}
		if json.Unmarshal(raw, &m) != nil {
			continue
		}
		n := len(m)
		for k := range m {
			if gone(approvalKeyFolder(k)) {
				delete(m, k)
			}
		}
		if len(m) != n {
			d.mcpApprovals[part], _ = json.Marshal(m)
			changed = true
		}
	}
	if changed {
		if err := d.saveMCPApprovalsLocked(false); err != nil {
			log.Printf("mcp-approvals.json: could not save: %v", err)
		}
	}
}

// sweepPluginApprovals drops the approvals and denials of plugins whose folder is gone. A
// plugin's key is its folder, <folder>/.agents/plugins/<name>.
func (d *Daemon) sweepPluginApprovals(gone func(string) bool) {
	if _, err := os.Stat(d.pluginApprovalsPath()); err != nil {
		return
	}
	pluginMu.Lock()
	defer pluginMu.Unlock()
	records, unreadable := d.loadPluginApprovals()
	if unreadable {
		return
	}
	n := len(records.Approved) + len(records.Denied)
	for _, m := range []map[string]string{records.Approved, records.Denied} {
		for k := range m {
			if folder, _, ok := strings.Cut(k, "/.agents/plugins/"); ok && gone(folder) {
				delete(m, k)
			}
		}
	}
	if len(records.Approved)+len(records.Denied) != n {
		if err := d.savePluginApprovals(records); err != nil {
			log.Printf("plugin-approvals.json: could not save: %v", err)
		}
	}
}

// sweepReviewFolders drops the dismissed and opened pull requests of folders that are gone.
func (d *Daemon) sweepReviewFolders(gone func(string) bool) {
	d.reviewMu.Lock()
	defer d.reviewMu.Unlock()
	for _, s := range []struct {
		path string
		m    map[string][]string
	}{{d.reviewDismissalsPath(), d.dismissedLocked()}, {d.reviewOpenedPath(), d.openedLocked()}} {
		n := len(s.m)
		for folder := range s.m {
			if gone(folder) {
				delete(s.m, folder)
			}
		}
		if len(s.m) != n {
			if err := writeStore(s.path, s.m); err != nil {
				log.Printf("%s: could not save: %v", filepath.Base(s.path), err)
			}
		}
	}
}

// sweepUnseenDevices forgets each device not seen for 90 days, as devices/forget does: it
// pairs again to come back.
func (d *Daemon) sweepUnseenDevices(now time.Time) {
	d.devMu.Lock()
	defer d.devMu.Unlock()
	d.loadDevices()
	var gone []wire.UUID
	kept := d.devRecords[:0]
	for _, r := range d.devRecords {
		seen := r.AnnouncedAt
		if r.LastSeenAt != nil {
			seen = *r.LastSeenAt
		}
		if now.Sub(seen.Time()) >= deviceKeptUnseen {
			gone = append(gone, r.ID)
			continue
		}
		kept = append(kept, r)
	}
	if len(gone) == 0 {
		return
	}
	d.devRecords = kept
	if err := d.writeDevices(); err != nil {
		log.Printf("devices.json: could not save: %v", err)
		return
	}
	for _, id := range gone {
		log.Printf("devices: forgot %s: not seen for 90 days", id)
		d.afterDeviceForgottenLocked(id)
	}
}
