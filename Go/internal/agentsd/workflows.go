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
	"github.com/alexec/agents/Go/wire"
)

// Workflows, as DaemonCore+Workflows and WorkflowStore keep them on the Swift host: each a
// file in its project; what the host remembers of each (whether the person approved it as
// it stands, who turned it off, when it last ran and how) in <root>/workflows.json, the
// approved bytes in <root>/workflow-copies/<sha256>. A workflow that is new or changed
// since it was approved runs nothing until the person approves it here; at most 3 wait
// in a project, and at most 10 (workflow-limit.json) are on across every project.

const (
	workflowsWaitingPerProject = 3
	workflowsTotalDefault      = 10
	approvalsBeganNote         = "Approval began here; see #205.\n"
)

// workflowState is WorkflowState in workflows.json, in its order.
type workflowState struct {
	Folder           wire.URL              `json:"folder"`
	WorkflowID       string                `json:"workflowID"`
	OffBy            *string               `json:"offBy,omitempty"`
	OffDigest        *string               `json:"offDigest,omitempty"`
	StandingAgentID  *wire.UUID            `json:"standingAgentID,omitempty"`
	LastFiredAt      *wire.Date            `json:"lastFiredAt,omitempty"`
	LastFiredBy      *wire.WorkflowCause   `json:"lastFiredBy,omitempty"`
	LastOutcome      *wire.WorkflowOutcome `json:"lastOutcome,omitempty"`
	LastCausingEvent *int64                `json:"lastCausingEvent,omitempty"`
	ApprovedDigest   *string               `json:"approvedDigest,omitempty"`
	ApprovedCopy     *string               `json:"approvedCopy,omitempty"`
	DeniedDigest     *string               `json:"deniedDigest,omitempty"`
	HeldFire         *heldFire             `json:"heldFire,omitempty"`
	QueuedFires      []heldFire            `json:"queuedFires,omitempty"`
	GoneSince        *wire.Date            `json:"goneSince,omitempty"`
}

type heldFire struct {
	Trigger           wire.WorkflowTrigger `json:"trigger"`
	TriggeringAgentID *wire.UUID           `json:"triggeringAgentID,omitempty"`
	Depth             int64                `json:"depth"`
	CausingEvent      *int64               `json:"causingEvent,omitempty"`
	HeldAt            wire.Date            `json:"heldAt"`
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
}

// workflowFile is one workflow as read now.
type workflowFile struct {
	wf     wire.Workflow
	digest string
	text   string
}

type workflowBook struct {
	workflowMu      sync.Mutex
	workflowRecs    *workflowRecords
	workflowRecsBad bool
	workflowFiles   map[string]map[string]*workflowFile // folder → id → file
	machineIDOnce   sync.Once
	machineValue    string
}

func (d *Daemon) workflowsPath() string  { return filepath.Join(d.Store.Loc.Root, "workflows.json") }
func (d *Daemon) workflowCopies() string { return filepath.Join(d.Store.Loc.Root, "workflow-copies") }
func (d *Daemon) workflowBegan() string {
	return filepath.Join(d.Store.Loc.Root, ".workflows.json.began")
}

// machineID is MachineID.current.
func (d *Daemon) machineID() string {
	d.machineIDOnce.Do(func() {
		if v := strings.TrimSpace(os.Getenv("AGENTS_MACHINE_ID")); v != "" {
			d.machineValue = v
			return
		}
		for _, p := range []string{"/etc/machine-id", "/var/lib/dbus/machine-id"} {
			if b, err := os.ReadFile(p); err == nil && strings.TrimSpace(string(b)) != "" {
				d.machineValue = strings.TrimSpace(string(b))
				return
			}
		}
		d.machineValue, _ = os.Hostname()
	})
	return d.machineValue
}

func (d *Daemon) runsHere(w wire.Workflow) bool {
	if len(w.Hosts) == 0 {
		return true
	}
	for _, h := range w.Hosts {
		if h == d.machineID() {
			return true
		}
	}
	return false
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

// keepCopyLocked writes the approved bytes where approvedCopy names them.
func (d *Daemon) keepCopyLocked(st *workflowState, f *workflowFile) {
	sum := sha256.Sum256([]byte(f.text))
	name := hex.EncodeToString(sum[:])
	os.MkdirAll(d.workflowCopies(), 0o755)
	if err := store.WriteAtomically(filepath.Join(d.workflowCopies(), name), []byte(f.text), 0o644); err == nil {
		st.ApprovedCopy = &name
	}
	digest := f.digest
	st.ApprovedDigest = &digest
}

// scanLocked reads every project's workflows afresh, and on the first start approves
// every file as it stands.
func (d *Daemon) scanLocked() {
	files := map[string]map[string]*workflowFile{}
	for _, p := range d.projects(false) {
		if p.Project.ArchivedAt != nil {
			continue
		}
		folder := store.FolderPath(p.Project.Folder)
		for _, id := range workflowIDs(folder) {
			path, _ := workflowPath(folder, id)
			text, digest, why := readWorkflowFile(path)
			var wf wire.Workflow
			if why != "" {
				wf = parseWorkflow("", id, folder)
				wf.Problem = &wire.WorkflowProblem{Unreadable: &wire.WorkflowProblemUnreadable{Value: why}}
			} else {
				wf = parseWorkflow(text, id, folder)
			}
			if files[folder] == nil {
				files[folder] = map[string]*workflowFile{}
			}
			files[folder][id] = &workflowFile{wf: wf, digest: digest, text: text}
		}
	}
	d.workflowFiles = files
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
	st := d.stateLocked(folder, id, false)
	if d.workflowRecsBad {
		note := "workflows.json could not be read, so nothing is approved until you approve it again."
		return &wire.WorkflowApproval{Digest: f.digest, IsNew: st == nil || st.ApprovedDigest == nil, Note: &note}, nil
	}
	if f.digest == "" {
		return nil, nil
	}
	if st != nil && st.DeniedDigest != nil && *st.DeniedDigest == f.digest {
		return nil, &wire.WorkflowApproval{Digest: f.digest, IsNew: st.ApprovedDigest == nil}
	}
	if st != nil && st.ApprovedDigest != nil && *st.ApprovedDigest == f.digest {
		return nil, nil
	}
	return &wire.WorkflowApproval{Digest: f.digest, IsNew: st == nil || st.ApprovedDigest == nil}, nil
}

func (d *Daemon) workflowTotal() int64 {
	var l struct {
		Total int64 `json:"total"`
	}
	if b, err := os.ReadFile(filepath.Join(d.SettingsDir, "workflow-limit.json")); err == nil && diskjson.Unmarshal(b, &l) == nil && l.Total >= 1 && l.Total <= 50 {
		return l.Total
	}
	return workflowsTotalDefault
}

// ceilingsLocked is which workflows are over a ceiling: past the 3 waiting in a project,
// or past the total on across every project.
func (d *Daemon) ceilingsLocked() map[string]wire.WorkflowLimit {
	over := map[string]wire.WorkflowLimit{}
	total := d.workflowTotal()
	var folders []string
	for f := range d.workflowFiles {
		folders = append(folders, f)
	}
	sort.Strings(folders)
	approved := 0
	for _, folder := range folders {
		var ids []string
		for id := range d.workflowFiles[folder] {
			ids = append(ids, id)
		}
		sort.Strings(ids)
		waiting := 0
		for _, id := range ids {
			f := d.workflowFiles[folder][id]
			if isArchived(f.wf) || !d.runsHere(f.wf) {
				continue
			}
			awaiting, denied := d.approvalOf(folder, id, f)
			switch {
			case denied != nil:
			case awaiting != nil:
				waiting++
				if waiting > workflowsWaitingPerProject {
					over[folder+"/"+id] = wire.WorkflowLimitProject
				}
			case !isOff(f.wf):
				approved++
				if int64(approved) > total {
					over[folder+"/"+id] = wire.WorkflowLimitTotal
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
	s := wire.WorkflowSummary{Workflow: f.wf, NextFireAtByTrigger: []*wire.Date{}}
	s.IsArchived = isArchived(f.wf)
	s.IsEnabled = !isOff(f.wf)
	if l, ok := over[folder+"/"+id]; ok {
		s.OverLimit = &l
		if l == wire.WorkflowLimitTotal {
			t := d.workflowTotal()
			s.TotalLimit = &t
		}
	}
	s.AwaitingApproval, s.DeniedHere = d.approvalOf(folder, id, f)
	s.IsRunning = d.runningLocked(folder, id)
	st := d.stateLocked(folder, id, false)
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
			if d.runsHere(wf.wf) {
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
	return &Error{Code: wire.FailureNoSuchWorkflow, Message: "There is no workflow called " + id + " in this project."}
}

// editWorkflowLocked rewrites a workflow's file with an edit, carrying a person's approval
// across to the new bytes.
func (d *Daemon) editWorkflowLocked(folder, id string, byPerson bool, edit func(string) (string, error)) error {
	f := d.fileLocked(folder, id)
	if f == nil {
		return noSuchWorkflow(id)
	}
	path, _ := workflowPath(folder, id)
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
	sum := sha256.Sum256([]byte(changed))
	newDigest := hex.EncodeToString(sum[:])
	st := d.stateLocked(folder, id, true)
	if byPerson && st.ApprovedDigest != nil && *st.ApprovedDigest == digest {
		d.keepCopyLocked(st, &workflowFile{text: changed, digest: newDigest})
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
		return
	}
	s := d.summaryLocked(folder, id, d.ceilingsLocked())
	d.workflowMu.Unlock()
	Broadcast(d, wire.NotifyWorkflowChanged, s)
}

// tellEveryWorkflow says each again: a ceiling or an approval moves them all.
func (d *Daemon) tellEveryWorkflow() {
	for _, s := range d.workflowSummaries("") {
		Broadcast(d, wire.NotifyWorkflowChanged, s)
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
			for fo, ws := range d.workflowFiles {
				for id, g := range ws {
					if a, dd := d.approvalOf(fo, id, g); a == nil && dd == nil && !isOff(g.wf) && !isArchived(g.wf) && d.runsHere(g.wf) {
						approved++
					}
				}
			}
			if total := d.workflowTotal(); int64(approved) >= total {
				d.workflowMu.Unlock()
				return wire.WorkflowSummary{}, &Error{Code: wire.FailureWorkflowLimitReached, Message: fmt.Sprintf(
					"%d workflows are already running, across every project, so %s was left off. Turn one off or archive one, in any project, to let it run.", total, r.WorkflowID)}
			}
		}
	}
	err := d.editWorkflowLocked(folder, r.WorkflowID, by == "person", func(text string) (string, error) {
		if r.Enabled {
			return setFrontMatter("enabled", nil, text)
		}
		return setFrontMatter("enabled", strPtr("false"), text)
	})
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
	err := d.editWorkflowLocked(folder, r.WorkflowID, byPerson, func(text string) (string, error) {
		if r.Archived {
			return setFrontMatter("archived", strPtr("true"), text)
		}
		return setFrontMatter("archived", nil, text)
	})
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
	if d.fileLocked(folder, r.WorkflowID) == nil {
		d.workflowMu.Unlock()
		return noSuchWorkflow(r.WorkflowID)
	}
	path, _ := workflowPath(folder, r.WorkflowID)
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
		if r.Hosts != nil {
			if text, err = setFrontMatterList("hosts", r.Hosts, text); err != nil {
				if text2, err2 := setFrontMatter("hosts", nil, text); err2 == nil {
					text, err = setFrontMatterList("hosts", r.Hosts, text2)
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
		if over := d.ceilingsLocked()[folder+"/"+r.WorkflowID]; over == wire.WorkflowLimitProject {
			d.workflowMu.Unlock()
			return wire.WorkflowSummary{}, &Error{Code: wire.FailureWorkflowLimitReached, Message: fmt.Sprintf(
				"This project already has %d workflows waiting for approval. Approve or remove one of the %d workflows waiting for approval first.",
				workflowsWaitingPerProject, workflowsWaitingPerProject)}
		}
		if d.recordsLocked().ApprovalsBegan == nil {
			t := now()
			d.workflowRecs.ApprovalsBegan = &t
		}
		d.keepCopyLocked(st, f)
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
	On(d, wire.CallWorkflowsList, func(ctx context.Context, c *Client, r wire.WorkflowsListRequest) ([]wire.WorkflowSummary, error) {
		folder := ""
		if r.Folder != nil {
			folder = store.FolderPath(*r.Folder)
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
	On(d, wire.CallWorkflowsSettings, func(ctx context.Context, c *Client, r wire.WorkflowSettingsRequest) (wire.WorkflowSummary, error) {
		return d.workflowSettingsChange(r, d.byPerson(c))
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

// unpinWorkflow takes a workflow out of its project's pins (unpinArchived).
func (d *Daemon) unpinWorkflow(project, id string) {
	f := d.readPins(project)
	for i, w := range f.workflows {
		if w.Workflow == id {
			f.workflows = append(f.workflows[:i], f.workflows[i+1:]...)
			d.writePins(f, project)
			return
		}
	}
}
