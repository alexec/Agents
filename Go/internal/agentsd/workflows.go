package agentsd

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/diskjson"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/machine"
	"github.com/alexec/agents/Go/wire"
)

// Workflows, as DaemonCore+Workflows and WorkflowStore keep them on the Swift host: each a
// file in its folder; what the host remembers of each (whether the person approved it as
// it stands, who turned it off, when it last ran and how) in <root>/workflows.json, the
// approved bytes in <root>/workflow-copies/<sha256>. A workflow that is new or changed
// since it was approved runs nothing until the person approves it here; at most 20
// (workflow-limit.json) are on in each folder.

const (
	workflowsTotalDefault = 20
	workflowsTotalMax     = 100
	approvalsBeganNote    = "Approval began here; see #205.\n"
)

// workflowState is WorkflowState in workflows.json, in its order.
type workflowState struct {
	Folder           wire.URL              `json:"folder"`
	WorkflowID       string                `json:"workflowID"`
	OffBy            *string               `json:"offBy,omitempty"`
	OffDigest        *string               `json:"offDigest,omitempty"`
	UserEnabled      *bool                 `json:"userEnabled,omitempty"`
	UserArchived     bool                  `json:"userArchived,omitempty"`
	StandingAgentID  *wire.UUID            `json:"standingAgentID,omitempty"`
	LastFiredAt      *wire.Date            `json:"lastFiredAt,omitempty"`
	LastFiredBy      *wire.WorkflowCause   `json:"lastFiredBy,omitempty"`
	LastOutcome      *wire.WorkflowOutcome `json:"lastOutcome,omitempty"`
	LastCausingEvent *int64                `json:"lastCausingEvent,omitempty"`
	ApprovedDigest   *string               `json:"approvedDigest,omitempty"`
	ApprovedCopy     *string               `json:"approvedCopy,omitempty"`
	ApprovedSkills   map[string]string     `json:"approvedSkills,omitempty"`
	DeniedDigest     *string               `json:"deniedDigest,omitempty"`
	// HeardDigest is the file a person approved to be heard here for a bot (#2027). It is
	// apart from ApprovedDigest, which every file gets at the first start: hearing a bot's
	// workflow with this machine's servers waits for the person, always.
	HeardDigest *string    `json:"heardDigest,omitempty"`
	HeldFire    *heldFire  `json:"heldFire,omitempty"`
	QueuedFires []heldFire `json:"queuedFires,omitempty"`
	GoneSince   *wire.Date `json:"goneSince,omitempty"`
	// DismissedFailure is the failure the person dismissed from Needs You (#989): its key.
	// A new failure has a new key, and an outcome that is not the same refusal again clears it.
	DismissedFailure *string `json:"dismissedFailure,omitempty"`
}

type heldFire struct {
	Trigger           wire.WorkflowTrigger `json:"trigger"`
	TriggeringAgentID *wire.UUID           `json:"triggeringAgentID,omitempty"`
	Depth             int64                `json:"depth"`
	CausingEvent      *int64               `json:"causingEvent,omitempty"`
	HeldAt            wire.Date            `json:"heldAt"`
	DueAt             *wire.Date           `json:"dueAt,omitempty"`
}

type workflowRun struct {
	ID                wire.UUID            `json:"id"`
	WorkflowID        string               `json:"workflowID"`
	Folder            wire.URL             `json:"folder"`
	Trigger           wire.WorkflowTrigger `json:"trigger"`
	TriggeringAgentID *wire.UUID           `json:"triggeringAgentID,omitempty"`
	Depth             int64                `json:"depth"`
	AgentID           *wire.UUID           `json:"agentID,omitempty"`
	StartedAt         wire.Date            `json:"startedAt"`
}

type workflowRecords struct {
	States         []workflowState `json:"states"`
	LastTickAt     *wire.Date      `json:"lastTickAt,omitempty"`
	Runs           []workflowRun   `json:"runs"`
	ApprovalsBegan *wire.Date      `json:"approvalsBegan,omitempty"`
	// RanBy is, for a session a workflow started on manage_workflows run, the session that
	// ran it: that one may stop and archive it as one it started (#1730).
	RanBy map[wire.UUID]wire.UUID `json:"ranBy,omitempty"`
}

// workflowFile is one workflow as read now.
type workflowFile struct {
	wf wire.Workflow
	// sourceFolder is where the file and its named skills live. A user workflow shown in
	// a folder has a folder on wf, so its run and state stay folder-scoped.
	sourceFolder string
	scope        string
	digest       string
	text         string
	// skills is the skills it names, which digest covers (S20261019-2).
	skills []workflowSkill
}

type workflowBook struct {
	workflowMu       sync.Mutex
	workflowRecs     *workflowRecords
	workflowStarting map[wire.UUID]bool // runs whose agent has not returned from startFor
	workflowRecsBad  bool
	workflowFiles    map[string]map[string]*workflowFile // folder → id → file
	machineIDOnce    sync.Once
	machineValue     string
	// clockStop ends the workflow clock, and clockRunning waits for a tick still going:
	// Shutdown stops it, as a host on a context nobody cancels would keep ticking (#2823).
	clockStop     chan struct{}
	clockStopOnce sync.Once
	clockRunning  sync.WaitGroup
}

func (d *Daemon) workflowsPath() string  { return filepath.Join(d.Store.Loc.Root, "workflows.json") }
func (d *Daemon) workflowCopies() string { return filepath.Join(d.Store.Loc.Root, "workflow-copies") }
func (d *Daemon) workflowBegan() string {
	return filepath.Join(d.Store.Loc.Root, ".workflows.json.began")
}

// machineID is machine.ID, read once: the id a workflow's hosts name (#1404).
func (d *Daemon) machineID() string {
	d.machineIDOnce.Do(func() { d.machineValue = machine.ID() })
	return d.machineValue
}

// runsHere says this machine matches the workflow's runs-on: (#1761, #2064): one of its
// machine ids, and every other label. One with none runs on every machine of the person who turned it on, as before.
func (d *Daemon) runsHere(w wire.Workflow) bool {
	return len(w.RunsOn) == 0 || d.runsOnHere(w.RunsOn)
}

// recordsLocked is workflows.json, read once; one that cannot be read approves nothing.
func (d *Daemon) recordsLocked() *workflowRecords {
	if d.workflowRecs != nil {
		return d.workflowRecs
	}
	d.workflowRecs = &workflowRecords{States: []workflowState{}, Runs: []workflowRun{}}
	b, err := os.ReadFile(d.workflowsPath())
	_, beganErr := os.Stat(d.workflowBegan())
	switch {
	case err == nil:
		var r workflowRecords
		if diskjson.Unmarshal(b, &r) == nil {
			if r.States == nil {
				r.States = []workflowState{}
			}
			if r.Runs == nil {
				r.Runs = []workflowRun{}
			}
			d.workflowRecs = &r
		} else {
			d.workflowRecsBad = true
		}
	case !errors.Is(err, os.ErrNotExist):
		d.workflowRecsBad = true
	}
	if beganErr == nil && d.workflowRecs.ApprovalsBegan == nil {
		d.workflowRecsBad = true
	}
	return d.workflowRecs
}

func (d *Daemon) saveRecordsLocked(replacing bool) {
	if d.workflowRecsBad && !replacing {
		return
	}
	if d.workflowRecsBad {
		if b, err := os.ReadFile(d.workflowsPath()); err == nil {
			os.WriteFile(fmt.Sprintf("%s.unreadable-%d", d.workflowsPath(), time.Now().Unix()), b, 0o644)
			store.TrimSetAsides(d.workflowsPath())
		}
		d.workflowRecsBad = false
	}
	r := d.workflowRecs
	sort.SliceStable(r.Runs, func(i, j int) bool {
		if r.Runs[i].StartedAt != r.Runs[j].StartedAt {
			return r.Runs[i].StartedAt < r.Runs[j].StartedAt
		}
		return r.Runs[i].ID < r.Runs[j].ID
	})
	if err := writeStore(d.workflowsPath(), r); err != nil {
		log.Printf("workflows.json: could not save: %v", err)
	} else {
		d.dropUnnamedCopiesLocked()
	}
	if r.ApprovalsBegan != nil {
		if _, err := os.Stat(d.workflowBegan()); err != nil {
			os.WriteFile(d.workflowBegan(), []byte(approvalsBeganNote), 0o644)
		}
	}
}

func (d *Daemon) stateLocked(folder, id string, make bool) *workflowState {
	r := d.recordsLocked()
	for i := range r.States {
		if store.FolderPath(r.States[i].Folder) == folder && r.States[i].WorkflowID == id {
			return &r.States[i]
		}
	}
	if !make {
		return nil
	}
	r.States = append(r.States, workflowState{Folder: store.FolderURL(folder), WorkflowID: id})
	return &r.States[len(r.States)-1]
}

// keepCopyLocked writes the approved bytes where approvedCopy names them, and each skill's
// where approvedSkills does.
func (d *Daemon) keepCopyLocked(st *workflowState, f *workflowFile) {
	os.MkdirAll(d.workflowCopies(), 0o755)
	st.ApprovedCopy = nil
	if name, ok := d.keepBytes(f.text); ok {
		st.ApprovedCopy = &name
	}
	st.ApprovedSkills = nil
	for _, s := range f.skills {
		if name, ok := d.keepBytes(s.text); ok {
			if st.ApprovedSkills == nil {
				st.ApprovedSkills = map[string]string{}
			}
			st.ApprovedSkills[s.name] = name
		}
	}
	digest := f.digest
	st.ApprovedDigest = &digest
}

// dropUnnamedCopiesLocked deletes each copy in workflow-copies that no workflow's record
// names (#2292): one is kept for each approved version, and an edit or a removal leaves
// the last one behind. Called once workflows.json is saved, so a copy goes only after the
// record that named it.
func (d *Daemon) dropUnnamedCopiesLocked() {
	entries, err := os.ReadDir(d.workflowCopies())
	if err != nil {
		return
	}
	named := map[string]bool{}
	for _, st := range d.workflowRecs.States {
		if st.ApprovedCopy != nil {
			named[*st.ApprovedCopy] = true
		}
		for _, name := range st.ApprovedSkills {
			named[name] = true
		}
	}
	for _, e := range entries {
		// Only the copies themselves: a sha256 in hex, not a write in progress.
		if name := e.Name(); len(name) == sha256.Size*2 && !named[name] {
			os.Remove(filepath.Join(d.workflowCopies(), name))
		}
	}
}

// keepBytes writes bytes into workflow-copies by their sha256, and says the name.
func (d *Daemon) keepBytes(text string) (string, bool) {
	sum := sha256.Sum256([]byte(text))
	name := hex.EncodeToString(sum[:])
	return name, store.WriteAtomically(filepath.Join(d.workflowCopies(), name), []byte(text), 0o644) == nil
}

// scanLocked reads every folder's workflows afresh, and on the first start approves
// every file as it stands.
func (d *Daemon) scanLocked() {
	files := map[string]map[string]*workflowFile{}
	d.ensureReadyMadeUserWorkflowsLocked()
	home := d.personalHome()
	if home != "" {
		for _, id := range workflowIDs(home) {
			path, _ := workflowPath(home, id)
			text, digest, why := readWorkflowFile(path)
			f := workflowFileOf(home, id, text, digest, why)
			f.sourceFolder, f.scope = home, "user"
			if files[home] == nil {
				files[home] = map[string]*workflowFile{}
			}
			files[home][id] = f
		}
	}
	for _, folder := range d.folderPaths() {
		if files[folder] == nil {
			files[folder] = map[string]*workflowFile{}
		}
		for _, id := range workflowIDs(folder) {
			path, _ := workflowPath(folder, id)
			text, digest, why := readWorkflowFile(path)
			if files[folder] == nil {
				files[folder] = map[string]*workflowFile{}
			}
			f := workflowFileOf(folder, id, text, digest, why)
			f.sourceFolder, f.scope = folder, "folder"
			files[folder][id] = f
		}
		if home == "" || !pushesToForge(folder) {
			continue
		}
		for _, id := range workflowIDs(home) {
			if files[folder][id] != nil || files[home][id] == nil {
				continue
			}
			user := *files[home][id]
			user.scope = "user"
			user.wf.Folder = store.FolderURL(folder)
			state := d.stateLocked(folder, id, false)
			enabled := state != nil && state.UserEnabled != nil && *state.UserEnabled
			user.wf.Enabled = &enabled
			if state != nil && state.UserArchived {
				archived := true
				user.wf.Archived = &archived
			}
			files[folder][id] = &user
		}
	}
	d.workflowFiles = files
	// A server's event a workflow names, or no longer does (#383).
	d.kickMCPEvents()
	// A folder added, archived or gone since: the watches follow it.
	d.kickFolderWatches()
	// A workflow made here can earn the first workflow (#984).
	defer d.checkMilestonesSoon()
	r := d.recordsLocked()
	if r.ApprovalsBegan == nil && !d.workflowRecsBad {
		t := now()
		r.ApprovalsBegan = &t
		for folder, ws := range files {
			for id, f := range ws {
				if f.digest != "" {
					d.keepCopyLocked(d.stateLocked(folder, id, true), f)
				}
			}
		}
		d.saveRecordsLocked(false)
	}
}

func (d *Daemon) fileLocked(folder, id string) *workflowFile {
	if d.workflowFiles == nil {
		d.scanLocked()
	}
	return d.workflowFiles[folder][id]
}

func isOff(w wire.Workflow) bool      { return w.Enabled != nil && !*w.Enabled }
func isArchived(w wire.Workflow) bool { return w.Archived != nil && *w.Archived }

// approvalOf says whether a workflow waits for the person, or is denied here.
func (d *Daemon) approvalOf(folder, id string, f *workflowFile) (awaiting, denied *wire.WorkflowApproval) {
	// A file in the person's own workflow folder is trusted by its owner. Folders still
	// keep it off by default, and their enabled state stays in their own record.
	if f.scope == "user" {
		return nil, nil
	}
	st := d.stateLocked(folder, id, false)
	if d.workflowRecsBad {
		note := "workflows.json could not be read, so nothing is approved until you approve it again."
		return &wire.WorkflowApproval{Digest: f.digest, IsNew: st == nil || st.ApprovedDigest == nil, Note: &note}, nil
	}
	if f.digest == "" {
		return nil, nil
	}
	approved := func(st *workflowState) *string { return st.ApprovedDigest }
	if d.hearsFor(f.wf) != "" {
		approved = func(st *workflowState) *string { return st.HeardDigest }
	}
	if st != nil && st.DeniedDigest != nil && *st.DeniedDigest == f.digest {
		return nil, &wire.WorkflowApproval{Digest: f.digest, IsNew: approved(st) == nil}
	}
	if st != nil && approved(st) != nil && *approved(st) == f.digest {
		return nil, nil
	}
	return &wire.WorkflowApproval{Digest: f.digest, IsNew: st == nil || approved(st) == nil}, nil
}

func (d *Daemon) workflowTotal() int64 {
	var l struct {
		Total int64 `json:"total"`
	}
	if b, err := os.ReadFile(filepath.Join(d.SettingsDir, "workflow-limit.json")); err == nil && diskjson.Unmarshal(b, &l) == nil && l.Total >= 1 && l.Total <= workflowsTotalMax {
		return l.Total
	}
	return workflowsTotalDefault
}

// workflowLimitSettings is workflows/limit. No total is the default.
func (d *Daemon) workflowLimitSettings() wire.WorkflowLimitSettings {
	var l struct {
		Total *int64 `json:"total"`
	}
	b, err := os.ReadFile(filepath.Join(d.SettingsDir, "workflow-limit.json"))
	if err != nil || diskjson.Unmarshal(b, &l) != nil || l.Total == nil || *l.Total < 1 || *l.Total > workflowsTotalMax {
		return wire.WorkflowLimitSettings{}
	}
	return wire.WorkflowLimitSettings{Total: l.Total}
}

// setWorkflowLimit is workflows/setLimit. A total outside 1 to 100 is refused in the
// words the window already shows.
func (d *Daemon) setWorkflowLimit(s wire.WorkflowLimitSettings) (wire.WorkflowLimitSettings, error) {
	if s.Total != nil && (*s.Total < 1 || *s.Total > workflowsTotalMax) {
		return wire.WorkflowLimitSettings{}, Invalid("Workflows turned on must be between 1 and 100.")
	}
	if err := d.writeSetting("workflow-limit.json", s); err != nil {
		return wire.WorkflowLimitSettings{}, &Error{Code: wire.FailureCouldNotSave, Message: "workflow-limit.json: " + err.Error()}
	}
	return d.workflowLimitSettings(), nil
}

// ceilingsLocked marks approved workflows past the active limit in each folder.
func (d *Daemon) ceilingsLocked() map[string]wire.WorkflowLimit {
	over := map[string]wire.WorkflowLimit{}
	total := d.workflowTotal()
	var folders []string
	for f := range d.workflowFiles {
		folders = append(folders, f)
	}
	sort.Strings(folders)
	for _, folder := range folders {
		if folder == d.personalHome() {
			continue
		}
		var ids []string
		for id := range d.workflowFiles[folder] {
			ids = append(ids, id)
		}
		sort.Strings(ids)
		approved := 0
		for _, id := range ids {
			f := d.workflowFiles[folder][id]
			if isArchived(f.wf) || !d.listedHere(f.wf) {
				continue
			}
			awaiting, denied := d.approvalOf(folder, id, f)
			switch {
			case denied != nil:
			case awaiting != nil:
			case !isOff(f.wf):
				approved++
				if int64(approved) > total {
					over[folder+"/"+id] = wire.WorkflowLimitFolder
				}
			}
		}
	}
	return over
}

func (d *Daemon) runningLocked(folder, id string) bool {
	for _, r := range d.recordsLocked().Runs {
		if store.FolderPath(r.Folder) == folder && r.WorkflowID == id {
			return true
		}
	}
	return false
}

// summaryLocked is WorkflowSummary as the Swift host fills it.
func (d *Daemon) summaryLocked(folder, id string, over map[string]wire.WorkflowLimit) wire.WorkflowSummary {
	f := d.fileLocked(folder, id)
	scope := f.scope
	s := wire.WorkflowSummary{Workflow: f.wf, Scope: &scope, NextFireAtByTrigger: []*wire.Date{}}
	if folder == d.personalHome() {
		content := f.text
		s.Content = &content
	}
	s.IsArchived = isArchived(f.wf)
	s.IsEnabled = !isOff(f.wf)
	if l, ok := over[folder+"/"+id]; ok {
		s.OverLimit = &l
		t := d.workflowTotal()
		s.TotalLimit = &t
	}
	s.AwaitingApproval, s.DeniedHere = d.approvalOf(folder, id, f)
	s.IsRunning = d.runningLocked(folder, id)
	if bot := d.hearsFor(f.wf); bot != "" {
		s.HearsFor = &bot
	}
	s.McpTriggers = d.mcpTriggerStatuses(folder, id)
	st := d.stateLocked(folder, id, false)
	if f.scope == "user" && folder != d.personalHome() {
		s.IsEnabled = st != nil && st.UserEnabled != nil && *st.UserEnabled
		s.IsArchived = st != nil && st.UserArchived
	}
	if st != nil {
		s.LastOutcome, s.LastFiredAt, s.LastFiredBy, s.CausingEvent = st.LastOutcome, st.LastFiredAt, st.LastFiredBy, st.LastCausingEvent
		if s.CausingEvent != nil {
			if e := d.event(*s.CausingEvent); e != nil {
				name := e.Name
				s.CausingEventName = &name
			}
		}
		s.HoldsAFire = st.HeldFire != nil
		s.Queued = int64(len(st.QueuedFires))
		if f.wf.Cooldown != nil && st.LastFiredAt != nil {
			if ends := st.LastFiredAt.Time().Add(time.Duration(*f.wf.Cooldown * float64(time.Second))); ends.After(time.Now()) {
				e := wire.DateOf(ends)
				s.CooldownEndsAt = &e
			}
		}
		if f.wf.Mode == wire.WorkflowModeStanding && st.StandingAgentID != nil {
			if a := d.Store.Agent(*st.StandingAgentID); a != nil && a.State != wire.AgentStateArchived {
				s.StandingAgentID = st.StandingAgentID
			}
		}
	}
	if isOff(f.wf) {
		reason := wire.WorkflowOffReasonFile
		if st != nil && st.OffBy != nil && st.OffDigest != nil && *st.OffDigest == f.digest {
			reason = wire.WorkflowOffReason(*st.OffBy)
		}
		s.OffReason = &reason
	}
	runs := !s.IsArchived && s.IsEnabled && s.OverLimit == nil && s.AwaitingApproval == nil && s.DeniedHere == nil && f.wf.Problem == nil
	if runs {
		var next *wire.Date
		for _, t := range f.wf.Triggers {
			var at *wire.Date
			if t.Schedule != nil {
				if due, ok := nextDue(t.Schedule.Value, time.Now()); ok {
					v := wire.DateOf(due)
					at = &v
					if next == nil || v < *next {
						next = &v
					}
				}
			}
			s.NextFireAtByTrigger = append(s.NextFireAtByTrigger, at)
		}
		s.NextFireAt = next
	} else {
		for range f.wf.Triggers {
			s.NextFireAtByTrigger = append(s.NextFireAtByTrigger, nil)
		}
	}
	return s
}

// nextDue is WorkflowSchedule.nextDue: the first half hour after t that the schedule matches.
func nextDue(s wire.WorkflowSchedule, t time.Time) (time.Time, bool) {
	t = t.Local()
	c := time.Date(t.Year(), t.Month(), t.Day(), t.Hour(), 0, 0, 0, time.Local)
	if t.Minute() < 30 {
		c = c.Add(30 * time.Minute)
	} else {
		c = c.Add(time.Hour)
	}
	days := map[string]bool{}
	for _, d := range s.Days {
		days[string(d)] = true
	}
	names := []string{"sun", "mon", "tue", "wed", "thu", "fri", "sat"}
	for i := 0; i < 8*48; i++ {
		h, m := int64(c.Hour()), int64(c.Minute())
		ok := days[names[c.Weekday()]] && h >= s.Hours[0] && h <= s.Hours[1]
		minuteOK := false
		for _, x := range s.Minutes {
			minuteOK = minuteOK || x == m
		}
		ok = ok && minuteOK && !(h == s.Hours[0] && m < s.StartMinute) && !(h == s.Hours[1] && m > s.EndMinute)
		if ok {
			return c, true
		}
		c = c.Add(30 * time.Minute)
	}
	return time.Time{}, false
}

// summaries is every workflow of a folder (or all) that runs on this host, by name.
func (d *Daemon) workflowSummaries(folder string) []wire.WorkflowSummary {
	d.workflowMu.Lock()
	defer d.workflowMu.Unlock()
	d.scanLocked()
	over := d.ceilingsLocked()
	out := []wire.WorkflowSummary{}
	for f, ws := range d.workflowFiles {
		if folder != "" && f != folder {
			continue
		}
		for id, wf := range ws {
			if f == d.personalHome() || d.listedHere(wf.wf) {
				out = append(out, d.summaryLocked(f, id, over))
			}
		}
	}
	sort.SliceStable(out, func(i, j int) bool {
		a, b := strings.ToLower(out[i].Workflow.Name), strings.ToLower(out[j].Workflow.Name)
		if a != b {
			return a < b
		}
		return out[i].Workflow.WorkflowID < out[j].Workflow.WorkflowID
	})
	return out
}

func noSuchWorkflow(id string) error {
	return &Error{Code: wire.FailureNoSuchWorkflow, Message: "There is no workflow called " + id + " in this folder."}
}

// editWorkflowLocked rewrites a workflow's file with an edit, carrying a person's approval
// across to the new bytes.
func (d *Daemon) editWorkflowLocked(folder, id string, byPerson bool, edit func(string) (string, error)) error {
	f := d.fileLocked(folder, id)
	if f == nil {
		return noSuchWorkflow(id)
	}
	if f.scope == "user" && folder != d.personalHome() {
		return &Error{Code: wire.FailureNotAllowed, Message: "Edit this workflow in Settings ▸ Agent Configuration ▸ Workflows. Its file belongs to your workflows."}
	}
	path, ok := workflowSourcePath(folder, id, f)
	if !ok {
		return notInFolder(id)
	}
	text, digest, why := readWorkflowFile(path)
	if why != "" {
		return &Error{Code: wire.FailureWorkflowUnreadable, Message: id + ".md could not be read."}
	}
	changed, err := edit(text)
	if err != nil {
		return &Error{Code: wire.FailureWorkflowUnreadable, Message: id + ".md was not changed: " + err.Error() + "."}
	}
	if changed == text {
		return nil
	}
	if err := store.WriteAtomically(path, []byte(changed), 0o644); err != nil {
		return &Error{Code: wire.FailureCouldNotSave, Message: id + ".md was not changed: " + err.Error() + "."}
	}
	// The approval, and what turned it off or denied it, are of the workflow with its skills.
	digest = workflowFileOf(folder, id, text, digest, "").digest
	sum := sha256.Sum256([]byte(changed))
	after := workflowFileOf(folder, id, changed, hex.EncodeToString(sum[:]), "")
	newDigest := after.digest
	st := d.stateLocked(folder, id, true)
	if byPerson && st.ApprovedDigest != nil && *st.ApprovedDigest == digest && newDigest != "" {
		d.keepCopyLocked(st, after)
	}
	if st.OffDigest != nil && *st.OffDigest == digest {
		st.OffDigest = &newDigest
	}
	if st.DeniedDigest != nil && *st.DeniedDigest == digest {
		st.DeniedDigest = &newDigest
	}
	d.saveRecordsLocked(false)
	d.scanLocked()
	return nil
}

func (d *Daemon) tellWorkflow(folder, id string) {
	d.workflowMu.Lock()
	f := d.fileLocked(folder, id)
	if f == nil {
		d.workflowMu.Unlock()
		Broadcast(d, wire.NotifyWorkflowRemoved, wire.WorkflowRemovedNotification{Folder: store.FolderURL(folder), WorkflowID: id})
		d.sendFolder(folder)
		return
	}
	s := d.summaryLocked(folder, id, d.ceilingsLocked())
	d.workflowMu.Unlock()
	Broadcast(d, wire.NotifyWorkflowChanged, s)
	// What waits for an OK rides on the folder's summary and in Needs You (#1322).
	d.sendFolder(folder)
}

// tellEveryWorkflow says each again: a ceiling or an approval moves them all.
func (d *Daemon) tellEveryWorkflow() {
	folders := map[string]bool{}
	for _, s := range d.workflowSummaries("") {
		Broadcast(d, wire.NotifyWorkflowChanged, s)
		folders[store.FolderPath(s.Workflow.Folder)] = true
	}
	for f := range folders {
		d.sendFolder(f)
	}
}

func (d *Daemon) oneWorkflow(folder, id string) (wire.WorkflowSummary, error) {
	d.workflowMu.Lock()
	defer d.workflowMu.Unlock()
	if d.fileLocked(folder, id) == nil {
		return wire.WorkflowSummary{}, noSuchWorkflow(id)
	}
	return d.summaryLocked(folder, id, d.ceilingsLocked()), nil
}

// writeUserWorkflow creates or replaces one file in ~/.agents/workflows.
func (d *Daemon) writeUserWorkflow(r wire.WorkflowWriteRequest) (wire.WorkflowSummary, error) {
	home := d.personalHome()
	if home == "" {
		return wire.WorkflowSummary{}, &Error{Code: wire.FailureNotAllowed, Message: "User workflows can only be changed in your own workflow folder."}
	}
	path, ok := workflowPath(home, r.WorkflowID)
	if !ok {
		return wire.WorkflowSummary{}, notInFolder(r.WorkflowID)
	}
	if strings.TrimSpace(r.Content) == "" {
		return wire.WorkflowSummary{}, Invalid("Nothing was written: content must contain the whole workflow file.")
	}
	parsed := parseWorkflow(r.Content, r.WorkflowID, home)
	if p := parsed.Problem; p != nil && p.Unreadable != nil {
		return wire.WorkflowSummary{}, &Error{Code: wire.FailureWorkflowUnreadable, Message: "The workflow file could not be read: " + p.Unreadable.Value + ". Nothing was written."}
	}
	for _, t := range parsed.Triggers {
		if t.Schedule == nil && !triggerSupported(t) && !isServerEventName(triggerName(t)) {
			return wire.WorkflowSummary{}, &Error{Code: wire.FailureWorkflowUnreadable, Message: "\"" + triggerName(t) + "\" is not a trigger. Nothing was written."}
		}
	}
	d.workflowMu.Lock()
	d.scanLocked()
	if existing := d.fileLocked(home, r.WorkflowID); existing != nil {
		if _, _, why := readWorkflowFile(path); why != "" {
			d.workflowMu.Unlock()
			return wire.WorkflowSummary{}, &Error{Code: wire.FailureWorkflowUnreadable, Message: why + ". Nothing was written."}
		}
	}
	if err := os.MkdirAll(workflowsFolder(home), 0o755); err != nil {
		d.workflowMu.Unlock()
		return wire.WorkflowSummary{}, &Error{Code: wire.FailureCouldNotSave, Message: "The workflow folder could not be created: " + err.Error()}
	}
	if err := store.WriteAtomically(path, []byte(r.Content), 0o644); err != nil {
		d.workflowMu.Unlock()
		return wire.WorkflowSummary{}, &Error{Code: wire.FailureCouldNotSave, Message: "The workflow was not saved: " + err.Error()}
	}
	d.scanLocked()
	summary := d.summaryLocked(home, r.WorkflowID, d.ceilingsLocked())
	d.workflowMu.Unlock()
	d.tellEveryWorkflow()
	return summary, nil
}

func strPtr(s string) *string { return &s }

// enableWorkflow is workflows/enable.
func (d *Daemon) enableWorkflow(r wire.WorkflowEnableRequest, by string) (wire.WorkflowSummary, error) {
	folder := store.FolderPath(r.Folder)
	d.workflowMu.Lock()
	d.scanLocked()
	f := d.fileLocked(folder, r.WorkflowID)
	if f == nil {
		d.workflowMu.Unlock()
		return wire.WorkflowSummary{}, noSuchWorkflow(r.WorkflowID)
	}
	if r.Enabled && isOff(f.wf) && !isArchived(f.wf) {
		awaiting, denied := d.approvalOf(folder, r.WorkflowID, f)
		if awaiting == nil && denied == nil {
			approved := 0
			for id, g := range d.workflowFiles[folder] {
				if a, dd := d.approvalOf(folder, id, g); a == nil && dd == nil && !isOff(g.wf) && !isArchived(g.wf) && d.listedHere(g.wf) {
					approved++
				}
			}
			if total := d.workflowTotal(); int64(approved) >= total {
				d.workflowMu.Unlock()
				return wire.WorkflowSummary{}, &Error{Code: wire.FailureWorkflowLimitReached, Message: fmt.Sprintf(
					"%d workflows are already running in this folder, so %s was left off. Turn one off or archive one to let it run.", total, r.WorkflowID)}
			}
		}
	}
	var err error
	if f.scope == "user" && folder != d.personalHome() {
		st := d.stateLocked(folder, r.WorkflowID, true)
		st.UserEnabled = &r.Enabled
		f.wf.Enabled = &r.Enabled
	} else {
		err = d.editWorkflowLocked(folder, r.WorkflowID, by == "person", func(text string) (string, error) {
			if r.Enabled {
				return setFrontMatter("enabled", nil, text)
			}
			return setFrontMatter("enabled", strPtr("false"), text)
		})
	}
	if err == nil {
		st := d.stateLocked(folder, r.WorkflowID, true)
		if r.Enabled {
			st.OffBy, st.OffDigest = nil, nil
		} else {
			f := d.fileLocked(folder, r.WorkflowID)
			st.OffBy, st.OffDigest = strPtr(by), strPtr(f.digest)
			for _, q := range st.QueuedFires {
				if q.CausingEvent != nil {
					d.addConsequence(wire.Consequence{Refused: &wire.ConsequenceRefused{WorkflowID: r.WorkflowID, Folder: store.FolderURL(folder),
						Reason: wire.WorkflowRefusal{Disabled: &struct{}{}}}}, *q.CausingEvent)
				}
			}
			st.HeldFire, st.QueuedFires = nil, nil
			if st.LastOutcome != nil && st.LastOutcome.Refused != nil && st.LastOutcome.Refused.Value.Queued != nil {
				st.LastOutcome = nil
			}
		}
		d.saveRecordsLocked(false)
	}
	d.workflowMu.Unlock()
	if err != nil {
		return wire.WorkflowSummary{}, err
	}
	d.tellEveryWorkflow()
	return d.oneWorkflow(folder, r.WorkflowID)
}

// archiveWorkflow is workflows/archive.
func (d *Daemon) archiveWorkflow(r wire.WorkflowArchiveRequest, byPerson bool) (wire.WorkflowSummary, error) {
	folder := store.FolderPath(r.Folder)
	d.workflowMu.Lock()
	d.scanLocked()
	f := d.fileLocked(folder, r.WorkflowID)
	var err error
	if f == nil {
		err = noSuchWorkflow(r.WorkflowID)
	} else if f.scope == "user" && folder != d.personalHome() {
		st := d.stateLocked(folder, r.WorkflowID, true)
		st.UserArchived = r.Archived
		if r.Archived {
			archived := true
			f.wf.Archived = &archived
		} else {
			f.wf.Archived = nil
		}
	} else {
		err = d.editWorkflowLocked(folder, r.WorkflowID, byPerson, func(text string) (string, error) {
			if r.Archived {
				return setFrontMatter("archived", strPtr("true"), text)
			}
			return setFrontMatter("archived", nil, text)
		})
	}
	if err == nil {
		st := d.stateLocked(folder, r.WorkflowID, true)
		st.LastOutcome, st.HeldFire = nil, nil
		if r.Archived {
			for _, q := range st.QueuedFires {
				if q.CausingEvent != nil {
					d.addConsequence(wire.Consequence{Refused: &wire.ConsequenceRefused{WorkflowID: r.WorkflowID, Folder: store.FolderURL(folder),
						Reason: wire.WorkflowRefusal{Archived: &struct{}{}}}}, *q.CausingEvent)
				}
			}
			st.QueuedFires = nil
		}
		d.saveRecordsLocked(false)
	}
	d.workflowMu.Unlock()
	if err != nil {
		return wire.WorkflowSummary{}, err
	}
	if r.Archived {
		d.unpinWorkflow(folder, r.WorkflowID)
	}
	d.tellEveryWorkflow()
	return d.oneWorkflow(folder, r.WorkflowID)
}

// deleteWorkflow is workflows/delete: the file gone, with what was kept of it.
func (d *Daemon) deleteWorkflow(r wire.WorkflowRequest) error {
	folder := store.FolderPath(r.Folder)
	d.workflowMu.Lock()
	d.scanLocked()
	if f := d.fileLocked(folder, r.WorkflowID); f == nil {
		d.workflowMu.Unlock()
		return noSuchWorkflow(r.WorkflowID)
	} else if f.scope == "user" && folder != d.personalHome() {
		d.workflowMu.Unlock()
		return &Error{Code: wire.FailureDeleteRefused, Message: f.wf.Name + " belongs to your workflows. Delete it in Settings ▸ Agent Configuration ▸ Workflows."}
	}
	f := d.fileLocked(folder, r.WorkflowID)
	path, ok := workflowSourcePath(folder, r.WorkflowID, f)
	if !ok {
		d.workflowMu.Unlock()
		return notInFolder(r.WorkflowID)
	}
	if folder == d.personalHome() {
		if err := markReadyMadeRemoved(folder, r.WorkflowID); err != nil {
			d.workflowMu.Unlock()
			return &Error{Code: wire.FailureDeleteRefused, Message: "Could not save the removed workflow ID: " + err.Error()}
		}
	}
	if err := os.Remove(path); err != nil {
		d.workflowMu.Unlock()
		return &Error{Code: wire.FailureDeleteRefused, Message: "Could not delete workflow file: " + err.Error()}
	}
	rec := d.recordsLocked()
	kept := rec.States[:0]
	for _, s := range rec.States {
		if !(store.FolderPath(s.Folder) == folder && s.WorkflowID == r.WorkflowID) {
			kept = append(kept, s)
		}
	}
	rec.States = kept
	d.saveRecordsLocked(false)
	d.scanLocked()
	d.workflowMu.Unlock()
	d.unpinWorkflow(folder, r.WorkflowID)
	Broadcast(d, wire.NotifyWorkflowRemoved, wire.WorkflowRemovedNotification{Folder: store.FolderURL(folder), WorkflowID: r.WorkflowID})
	d.sendFolder(folder)
	d.tellEveryWorkflow()
	return nil
}

// workflowSettingsChange is workflows/settings: the file's keys set to what the sheet says.
func (d *Daemon) workflowSettingsChange(r wire.WorkflowSettingsRequest, byPerson bool) (wire.WorkflowSummary, error) {
	folder := store.FolderPath(r.Folder)
	d.workflowMu.Lock()
	d.scanLocked()
	f := d.fileLocked(folder, r.WorkflowID)
	if f == nil {
		d.workflowMu.Unlock()
		return wire.WorkflowSummary{}, noSuchWorkflow(r.WorkflowID)
	}
	if p := f.wf.Problem; p != nil && p.Unreadable != nil {
		d.workflowMu.Unlock()
		return wire.WorkflowSummary{}, &Error{Code: wire.FailureWorkflowUnreadable, Message: "Fix the file first: " + p.Unreadable.Value}
	}
	old := f.wf
	err := d.editWorkflowLocked(folder, r.WorkflowID, byPerson, func(text string) (string, error) {
		var err error
		for _, kv := range []struct {
			key string
			v   *string
		}{{"permission-mode", r.Settings.PermissionMode}, {"runtime", r.Settings.RuntimeID}, {"model", r.Settings.Model}, {"effort", r.Settings.Effort}} {
			if text, err = setFrontMatter(kv.key, kv.v, text); err != nil {
				return "", err
			}
		}
		ids := map[string]bool{}
		for id := range r.Settings.Options {
			ids[id] = true
		}
		for id := range old.Settings.Options {
			ids[id] = true
		}
		var sorted []string
		for id := range ids {
			sorted = append(sorted, id)
		}
		sort.Strings(sorted)
		for _, id := range sorted {
			nv, has := r.Settings.Options[id]
			if ov, had := old.Settings.Options[id]; had == has && ov == nv {
				continue
			}
			var v *string
			if has {
				v = &nv
			}
			if text, err = setFrontMatterUnder(id, "options", v, text); err != nil {
				return "", err
			}
		}
		if r.Cooldown != nil {
			c := strings.TrimSpace(*r.Cooldown)
			var v *string
			if c != "" {
				secs, err := parseCooldown(c)
				if err != nil {
					return "", err
				}
				t := cooldownText(secs)
				v = &t
			}
			if text, err = setFrontMatter("cooldown", v, text); err != nil {
				return "", err
			}
		}
		if r.Labels != nil {
			if text, err = setFrontMatterList("labels", r.Labels, text); err != nil {
				return "", err
			}
		}
		if r.RunsOn != nil {
			if text, err = setFrontMatterList("runs-on", r.RunsOn, text); err != nil {
				if text2, err2 := setFrontMatter("runs-on", nil, text); err2 == nil {
					text, err = setFrontMatterList("runs-on", r.RunsOn, text2)
				}
				if err != nil {
					return "", err
				}
			}
		}
		if r.WhenDone != nil {
			var v *string
			if *r.WhenDone != "keep" && *r.WhenDone != "" {
				v = r.WhenDone
			}
			if text, err = setFrontMatter("when-done", v, text); err != nil {
				return "", err
			}
		}
		if r.ContinueWhenBack != nil {
			var v *string
			if *r.ContinueWhenBack {
				t := "true"
				v = &t
			}
			if text, err = setFrontMatter("continue-when-back", v, text); err != nil {
				return "", err
			}
		}
		return text, nil
	})
	d.workflowMu.Unlock()
	if err != nil {
		return wire.WorkflowSummary{}, err
	}
	d.tellWorkflow(folder, r.WorkflowID)
	return d.oneWorkflow(folder, r.WorkflowID)
}

// approveWorkflow is workflows/approve and workflows/deny, for the bytes the person saw.
func (d *Daemon) approveWorkflow(r wire.WorkflowApproveRequest, approve bool) (wire.WorkflowSummary, error) {
	folder := store.FolderPath(r.Folder)
	d.workflowMu.Lock()
	d.scanLocked()
	f := d.fileLocked(folder, r.WorkflowID)
	if f == nil {
		d.workflowMu.Unlock()
		return wire.WorkflowSummary{}, noSuchWorkflow(r.WorkflowID)
	}
	if f.digest != r.Digest {
		verb := "approved"
		if !approve {
			verb = "denied"
		}
		d.workflowMu.Unlock()
		return wire.WorkflowSummary{}, &Error{Code: wire.FailureNotChanged, Message: f.wf.Name + " changed after you looked at it, so it was not " + verb + ". Look again."}
	}
	st := d.stateLocked(folder, r.WorkflowID, true)
	if approve {
		if d.recordsLocked().ApprovalsBegan == nil {
			t := now()
			d.workflowRecs.ApprovalsBegan = &t
		}
		digest := f.digest
		if d.hearsFor(f.wf) != "" {
			// Heard here for a bot (#2027): approved to hear, not to run.
			st.HeardDigest = &digest
		} else {
			d.keepCopyLocked(st, f)
		}
		st.DeniedDigest = nil
		if o := st.LastOutcome; o != nil && o.Refused != nil && (o.Refused.Value.AwaitingApproval != nil || o.Refused.Value.DeniedHere != nil) {
			st.LastOutcome = nil
		}
	} else {
		digest := f.digest
		st.DeniedDigest = &digest
		if st.ApprovedDigest != nil && *st.ApprovedDigest == digest {
			st.ApprovedDigest, st.ApprovedCopy = nil, nil
		}
		if st.HeardDigest != nil && *st.HeardDigest == digest {
			st.HeardDigest = nil
		}
		if o := st.LastOutcome; o != nil && o.Refused != nil && o.Refused.Value.AwaitingApproval != nil {
			st.LastOutcome = nil
		}
	}
	d.saveRecordsLocked(true)
	d.workflowMu.Unlock()
	d.tellEveryWorkflow()
	return d.oneWorkflow(folder, r.WorkflowID)
}

func (d *Daemon) byPerson(c *Client) bool { return true }

func (d *Daemon) registerWorkflows() {
	On(d, wire.CallWorkflowsLimit, func(ctx context.Context, c *Client, _ wire.Empty) (wire.WorkflowLimitSettings, error) {
		return d.workflowLimitSettings(), nil
	})
	On(d, wire.CallWorkflowsSetLimit, func(ctx context.Context, c *Client, s wire.WorkflowLimitSettings) (wire.WorkflowLimitSettings, error) {
		return d.setWorkflowLimit(s)
	})
	On(d, wire.CallWorkflowsList, func(ctx context.Context, c *Client, r wire.WorkflowsListRequest) ([]wire.WorkflowSummary, error) {
		folder := ""
		if r.Scope != nil && *r.Scope == "user" {
			folder = d.personalHome()
		}
		if r.Folder != nil {
			if r.Scope == nil || *r.Scope != "user" {
				folder = store.FolderPath(*r.Folder)
			}
		}
		return d.workflowSummaries(folder), nil
	})
	On(d, wire.CallWorkflowsEnable, func(ctx context.Context, c *Client, r wire.WorkflowEnableRequest) (wire.WorkflowSummary, error) {
		return d.enableWorkflow(r, "person")
	})
	On(d, wire.CallWorkflowsArchive, func(ctx context.Context, c *Client, r wire.WorkflowArchiveRequest) (wire.WorkflowSummary, error) {
		return d.archiveWorkflow(r, d.byPerson(c))
	})
	On(d, wire.CallWorkflowsDelete, func(ctx context.Context, c *Client, r wire.WorkflowRequest) (wire.Empty, error) {
		return wire.Empty{}, d.deleteWorkflow(r)
	})
	On(d, wire.CallWorkflowsSetMuted, func(ctx context.Context, c *Client, r wire.WorkflowMuteRequest) (wire.WorkflowSummary, error) {
		return d.muteWorkflow(r, d.byPerson(c))
	})
	On(d, wire.CallWorkflowsSettings, func(ctx context.Context, c *Client, r wire.WorkflowSettingsRequest) (wire.WorkflowSummary, error) {
		return d.workflowSettingsChange(r, d.byPerson(c))
	})
	On(d, wire.CallWorkflowsWrite, func(ctx context.Context, c *Client, r wire.WorkflowWriteRequest) (wire.WorkflowSummary, error) {
		return d.writeUserWorkflow(r)
	})
	// The page's Clear on an MCP trigger's missed events (#383).
	On(d, wire.CallWorkflowsMcpTriggerClearMissed, func(ctx context.Context, c *Client, r wire.WorkflowMCPClearMissedRequest) (wire.WorkflowSummary, error) {
		return d.clearMCPMissed(r)
	})
	On(d, wire.CallWorkflowsApprove, func(ctx context.Context, c *Client, r wire.WorkflowApproveRequest) (wire.WorkflowSummary, error) {
		return d.approveWorkflow(r, true)
	})
	On(d, wire.CallWorkflowsRun, func(ctx context.Context, c *Client, r wire.WorkflowRequest) (wire.WorkflowSummary, error) {
		return d.runWorkflow(r)
	})
	On(d, wire.CallWorkflowsDeny, func(ctx context.Context, c *Client, r wire.WorkflowApproveRequest) (wire.WorkflowSummary, error) {
		return d.approveWorkflow(r, false)
	})
}

// unpinWorkflow takes a workflow out of its folder's pins (unpinArchived).
func (d *Daemon) unpinWorkflow(folder, id string) {
	f := d.readPins(folder)
	for i, w := range f.workflows {
		if w.Workflow == id {
			f.workflows = append(f.workflows[:i], f.workflows[i+1:]...)
			d.writePins(f, folder)
			return
		}
	}
}
