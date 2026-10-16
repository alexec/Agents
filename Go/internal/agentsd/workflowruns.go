package agentsd

import (
	"fmt"
	"log"
	"sort"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// Running workflows, as DaemonCore+Workflows fires them on the Swift host: on the clock
// (every 15 seconds, a schedule due since the last tick), on an event that matches a
// trigger, or by hand with Run now. Each fire is weighed first (archived, off, unreadable,
// waiting for approval, a cooldown, a run still going, a chain too deep) and either starts
// a run or is recorded as a refusal, with workflow.ran or workflow.refused on the log and
// what came of it on the event that caused it. A run ends with its agent's turn.

const (
	workflowTick       = 15 * time.Second
	workflowAway       = 120 * time.Second
	workflowChainLimit = 3
	workflowQueueLimit = 10
	workflowRunsKept   = 7 * 24 * time.Hour
)

type fireRequest struct {
	folder, id      string
	trigger         wire.WorkflowTrigger
	byHand          bool
	triggeringAgent *wire.UUID
	depth           int64
	causingEvent    *int64
	fromQueue       bool
}

// refusalWords is WorkflowRefusal.message.
func refusalWords(r wire.WorkflowRefusal) string {
	switch {
	case r.ChainTooDeep != nil:
		return fmt.Sprintf("this chain is already %d deep", r.ChainTooDeep.Depth)
	case r.RunInFlight != nil:
		return "a run is still going"
	case r.Queued != nil:
		return "a run is still going, and it runs when that ends"
	case r.QueueFull != nil:
		return fmt.Sprintf("%d triggers are already queued for it", r.QueueFull.Limit)
	case r.Archived != nil:
		return "it is archived"
	case r.Disabled != nil:
		return "it is turned off"
	case r.OverLimit != nil:
		n := int64(0)
		if r.OverLimit.Allowed != nil {
			n = *r.OverLimit.Allowed
		}
		if r.OverLimit.Value == wire.WorkflowLimitProject {
			return fmt.Sprintf("this project already has %d workflows waiting for approval", n)
		}
		return fmt.Sprintf("%d workflows are already running, across every project", n)
	case r.Unreadable != nil:
		return r.Unreadable.Value
	case r.TriggerNotSupported != nil:
		return "\"" + r.TriggerNotSupported.Name + "\" is not something this version can watch for"
	case r.AgentUnavailable != nil:
		return "the agent it would have resumed is gone"
	case r.NoTriggeringAgent != nil:
		return "nothing triggered it, so there was no agent to resume"
	case r.MissedWhileClosed != nil:
		return "the app was closed"
	case r.FolderGone != nil:
		return "the project folder is not there"
	case r.DayLimitReached != nil:
		return "the day's spending limit has been reached"
	case r.SettingRefused != nil:
		return r.SettingRefused.Detail
	case r.AwaitingApproval != nil:
		return "it is waiting for your OK"
	case r.DeniedHere != nil:
		return "it is denied on this host"
	case r.CoolingDown != nil:
		if r.CoolingDown.Until != nil {
			return "it is cooling down until " + clock(*r.CoolingDown.Until) + ", and runs once then"
		}
		return "a run is still going, and it runs once more when that ends"
	}
	return ""
}

// refusalCode is WorkflowRefusal.code, the reason workflow.refused carries.
func refusalCode(r wire.WorkflowRefusal) string {
	for code, set := range map[string]bool{"chain_too_deep": r.ChainTooDeep != nil, "run_in_flight": r.RunInFlight != nil,
		"queued": r.Queued != nil, "queue_full": r.QueueFull != nil, "archived": r.Archived != nil, "disabled": r.Disabled != nil,
		"over_limit": r.OverLimit != nil, "unreadable": r.Unreadable != nil, "trigger_not_supported": r.TriggerNotSupported != nil,
		"agent_unavailable": r.AgentUnavailable != nil, "no_triggering_agent": r.NoTriggeringAgent != nil,
		"missed_while_closed": r.MissedWhileClosed != nil, "folder_gone": r.FolderGone != nil, "day_limit_reached": r.DayLimitReached != nil,
		"setting_refused": r.SettingRefused != nil, "awaiting_approval": r.AwaitingApproval != nil, "denied_here": r.DeniedHere != nil,
		"cooling_down": r.CoolingDown != nil} {
		if set {
			return code
		}
	}
	return "unreadable"
}

func sameReason(a, b wire.WorkflowRefusal) bool {
	if refusalCode(a) != refusalCode(b) {
		return false
	}
	switch {
	case a.OverLimit != nil:
		return a.OverLimit.Value == b.OverLimit.Value
	case a.SettingRefused != nil:
		return a.SettingRefused.Setting == b.SettingRefused.Setting
	}
	return true
}

func workflowKey(folder, id string) string { return folder + "/" + id }

// fireWorkflows is fireWorkflows(for:): every workflow with a trigger this event matches,
// never on news of itself or of its own agents.
func (d *Daemon) fireWorkflows(e wire.Event) {
	if d.ctx.Err() != nil {
		return
	}
	var fires []fireRequest
	d.workflowMu.Lock()
	if d.workflowFiles == nil {
		d.scanLocked()
	}
	var folders []string
	if e.Scope.Project != nil {
		folders = []string{store.FolderPath(e.Scope.Project.Value)}
	} else {
		for f := range d.workflowFiles {
			folders = append(folders, f)
		}
		sort.Strings(folders)
	}
	var triggering *wire.UUID
	if a := e.Details["agent"]; a != "" {
		id := wire.UUID(a)
		triggering = &id
	}
	for _, folder := range folders {
		var ids []string
		for id := range d.workflowFiles[folder] {
			ids = append(ids, id)
		}
		sort.Strings(ids)
		for _, id := range ids {
			f := d.workflowFiles[folder][id]
			w := f.wf
			if !d.runsHere(w) || w.Problem != nil || isArchived(w) {
				continue
			}
			if strings.HasPrefix(e.Name, "workflow.") && e.Details["workflow"] == id {
				continue
			}
			if strings.HasPrefix(e.Name, "agent.") && triggering != nil && d.isOwnAgentLocked(*triggering, folder, w) {
				continue
			}
			for _, t := range w.Triggers {
				if p, ok := triggerPattern(t); ok && p.matches(e) {
					pos := e.Position
					fires = append(fires, fireRequest{folder: folder, id: id, trigger: t, triggeringAgent: triggering, depth: e.ChainDepth, causingEvent: &pos})
					break
				}
			}
		}
	}
	d.workflowMu.Unlock()
	for _, f := range fires {
		f := f
		safe.Go("workflow fire", func() { d.fire(f) })
	}
}

// isOwnAgentLocked is isOwnAgent: the agent a run of this workflow started, or one that
// agent started.
func (d *Daemon) isOwnAgentLocked(agent wire.UUID, folder string, w wire.Workflow) bool {
	for _, r := range d.recordsLocked().Runs {
		if store.FolderPath(r.Folder) == folder && r.WorkflowID == w.WorkflowID && r.AgentID != nil && *r.AgentID == agent {
			return true
		}
	}
	a := d.Store.Agent(agent)
	for seen := map[wire.UUID]bool{}; a != nil && !seen[a.ID]; {
		seen[a.ID] = true
		if a.StartedByWorkflow != nil && *a.StartedByWorkflow == w.WorkflowID && projectFolder(a) == folder && w.Mode != wire.WorkflowModeTriggering {
			return true
		}
		if a.StartedByAgent == nil {
			return false
		}
		a = d.Store.Agent(*a.StartedByAgent)
	}
	return false
}

// refusalLocked is refusalIfBlocked, in its order.
func (d *Daemon) refusalLocked(fr fireRequest, f *workflowFile) *wire.WorkflowRefusal {
	w := f.wf
	st := d.stateLocked(fr.folder, fr.id, false)
	running := d.runningLocked(fr.folder, fr.id)
	queued := 0
	if st != nil {
		queued = len(st.QueuedFires)
	}
	r := func(set func(*wire.WorkflowRefusal)) *wire.WorkflowRefusal {
		var x wire.WorkflowRefusal
		set(&x)
		return &x
	}
	exempt := isArchived(w) || (!fr.byHand && isOff(w))
	if !exempt {
		awaiting, denied := d.approvalOf(fr.folder, fr.id, f)
		if awaiting != nil {
			return r(func(x *wire.WorkflowRefusal) { x.AwaitingApproval = &struct{}{} })
		}
		if denied != nil {
			return r(func(x *wire.WorkflowRefusal) { x.DeniedHere = &struct{}{} })
		}
	}
	switch {
	case isArchived(w):
		return r(func(x *wire.WorkflowRefusal) { x.Archived = &struct{}{} })
	case !fr.byHand && isOff(w):
		return r(func(x *wire.WorkflowRefusal) { x.Disabled = &struct{}{} })
	case w.Problem != nil && w.Problem.Unreadable != nil:
		v := w.Problem.Unreadable.Value
		return r(func(x *wire.WorkflowRefusal) { x.Unreadable = &wire.WorkflowRefusalUnreadable{Value: v} })
	case !isDir(fr.folder):
		return r(func(x *wire.WorkflowRefusal) { x.FolderGone = &struct{}{} })
	}
	if l, ok := d.ceilingsLocked()[workflowKey(fr.folder, fr.id)]; ok {
		n := int64(workflowsWaitingPerProject)
		if l == wire.WorkflowLimitTotal {
			n = d.workflowTotal()
		}
		return r(func(x *wire.WorkflowRefusal) { x.OverLimit = &wire.WorkflowRefusalOverLimit{Value: l, Allowed: &n} })
	}
	if w.Cooldown != nil && !fr.byHand {
		if fr.depth > workflowChainLimit {
			return r(func(x *wire.WorkflowRefusal) {
				x.ChainTooDeep = &wire.WorkflowRefusalChainTooDeep{Depth: workflowChainLimit}
			})
		}
		if st != nil && st.LastFiredAt != nil {
			if until := st.LastFiredAt.Time().Add(time.Duration(*w.Cooldown * float64(time.Second))); until.After(time.Now()) {
				u := wire.DateOf(until)
				return r(func(x *wire.WorkflowRefusal) { x.CoolingDown = &wire.WorkflowRefusalCoolingDown{Until: &u} })
			}
		}
		if running {
			return r(func(x *wire.WorkflowRefusal) { x.CoolingDown = &wire.WorkflowRefusalCoolingDown{} })
		}
	}
	if running || (queued > 0 && !fr.byHand && !fr.fromQueue) {
		switch {
		case fr.byHand:
			return r(func(x *wire.WorkflowRefusal) { x.RunInFlight = &struct{}{} })
		case fr.depth > workflowChainLimit:
			return r(func(x *wire.WorkflowRefusal) {
				x.ChainTooDeep = &wire.WorkflowRefusalChainTooDeep{Depth: workflowChainLimit}
			})
		case queued >= workflowQueueLimit:
			return r(func(x *wire.WorkflowRefusal) { x.QueueFull = &wire.WorkflowRefusalQueueFull{Limit: workflowQueueLimit} })
		}
		return r(func(x *wire.WorkflowRefusal) { x.Queued = &struct{}{} })
	}
	if fr.depth > workflowChainLimit {
		return r(func(x *wire.WorkflowRefusal) {
			x.ChainTooDeep = &wire.WorkflowRefusalChainTooDeep{Depth: workflowChainLimit}
		})
	}
	if w.Problem != nil {
		name := triggerName(fr.trigger)
		if w.Problem.TriggerNotSupported != nil {
			name = w.Problem.TriggerNotSupported.Value
		} else if w.Problem.UnsupportedMode != nil {
			name = w.Problem.UnsupportedMode.Value
		}
		return r(func(x *wire.WorkflowRefusal) {
			x.TriggerNotSupported = &wire.WorkflowRefusalTriggerNotSupported{Name: name}
		})
	}
	if w.Mode == wire.WorkflowModeTriggering {
		if fr.triggeringAgent == nil {
			return r(func(x *wire.WorkflowRefusal) { x.NoTriggeringAgent = &struct{}{} })
		}
		if a := d.Store.Agent(*fr.triggeringAgent); a == nil || a.State == wire.AgentStateArchived {
			return r(func(x *wire.WorkflowRefusal) { x.AgentUnavailable = &struct{}{} })
		}
	}
	return nil
}

// fire is DaemonCore.fire: weighed, then a run or a refusal recorded.
func (d *Daemon) fire(fr fireRequest) {
	d.workflowMu.Lock()
	f := d.fileLocked(fr.folder, fr.id)
	if f == nil || !d.runsHere(f.wf) {
		d.workflowMu.Unlock()
		return
	}
	if refused := d.refusalLocked(fr, f); refused != nil {
		st := d.stateLocked(fr.folder, fr.id, true)
		hf := heldFire{Trigger: fr.trigger, TriggeringAgentID: fr.triggeringAgent, Depth: fr.depth, CausingEvent: fr.causingEvent, HeldAt: now()}
		switch {
		case refused.Queued != nil:
			st.QueuedFires = append(st.QueuedFires, hf)
		case refused.CoolingDown != nil:
			st.HeldFire = &hf
		}
		d.saveRecordsLocked(false)
		name := f.wf.Name
		d.workflowMu.Unlock()
		d.recordOutcome(fr, name, wire.WorkflowOutcome{Refused: &wire.WorkflowOutcomeRefused{Value: *refused, At: now()}}, nil)
		return
	}
	run := workflowRun{ID: store.NewUUID(), WorkflowID: fr.id, Folder: store.FolderURL(fr.folder), Trigger: fr.trigger,
		TriggeringAgentID: fr.triggeringAgent, Depth: fr.depth, StartedAt: now()}
	rec := d.recordsLocked()
	rec.Runs = append(rec.Runs, run)
	d.saveRecordsLocked(false)
	w := f.wf
	d.workflowMu.Unlock()
	d.tellWorkflow(fr.folder, fr.id)

	agent, refusedSetting := d.runAgent(w, run, fr)
	if refusedSetting != nil {
		d.releaseRun(run.ID)
		d.recordOutcome(fr, w.Name, wire.WorkflowOutcome{Refused: &wire.WorkflowOutcomeRefused{Value: *refusedSetting, At: now()}}, nil)
		return
	}
	d.workflowMu.Lock()
	for i := range d.recordsLocked().Runs {
		if d.workflowRecs.Runs[i].ID == run.ID {
			d.workflowRecs.Runs[i].AgentID = &agent
		}
	}
	d.saveRecordsLocked(false)
	d.workflowMu.Unlock()
	d.recordOutcome(fr, w.Name, wire.WorkflowOutcome{Ran: &wire.WorkflowOutcomeRan{AgentID: agent, At: now()}}, &agent)
}

// runAgent starts or prompts the run's agent, as the workflow's mode says.
func (d *Daemon) runAgent(w wire.Workflow, run workflowRun, fr fireRequest) (wire.UUID, *wire.WorkflowRefusal) {
	prompt := d.runPrompt(w, fr)
	settingRefused := func(setting, detail string) *wire.WorkflowRefusal {
		return &wire.WorkflowRefusal{SettingRefused: &wire.WorkflowRefusalSettingRefused{Setting: setting, Detail: detail}}
	}
	if w.Mode == wire.WorkflowModeTriggering {
		if fr.triggeringAgent == nil {
			return "", &wire.WorkflowRefusal{Unreadable: &wire.WorkflowRefusalUnreadable{Value: "Nothing triggered it, so there was no agent to resume."}}
		}
		if err := d.promptFromApp(*fr.triggeringAgent, prompt); err != nil {
			_, msg := errMessage(err)
			return "", &wire.WorkflowRefusal{Unreadable: &wire.WorkflowRefusalUnreadable{Value: msg}}
		}
		return *fr.triggeringAgent, nil
	}
	if w.Mode == wire.WorkflowModeStanding {
		d.workflowMu.Lock()
		st := d.stateLocked(fr.folder, fr.id, true)
		standing := st.StandingAgentID
		d.workflowMu.Unlock()
		if standing != nil {
			if a := d.Store.Agent(*standing); a != nil && a.State != wire.AgentStateArchived {
				if err := d.promptFromApp(a.ID, prompt); err == nil {
					return a.ID, nil
				}
			}
		}
	}
	runtimeID := defaultRuntimeID
	if w.Settings.RuntimeID != nil {
		runtimeID = *w.Settings.RuntimeID
	}
	if runtimeByID(runtimeID) == nil {
		return "", settingRefused("runtime", "There is no runtime called \""+runtimeID+"\" — this version knows "+knownRuntimes())
	}
	model := ""
	if w.Settings.Model != nil {
		model = *w.Settings.Model
	}
	r := helperRequest(runtimeID, fr.folder, prompt, model, w.Settings.PermissionMode, nil, w.Settings.Labels)
	for id, v := range w.Settings.Options {
		b := []byte(`"` + strings.ReplaceAll(v, `"`, `\"`) + `"`)
		r.StartOptions.Values[id] = b
	}
	id, err := d.startFor(r, startedBy{owner: wire.SessionLabelOwnerAgent})
	if err != nil {
		_, msg := errMessage(err)
		return "", &wire.WorkflowRefusal{Unreadable: &wire.WorkflowRefusalUnreadable{Value: msg}}
	}
	depth := run.Depth + 1
	wid, rid, name := w.WorkflowID, run.ID, w.Name
	d.change(id, func(a *wire.Agent) {
		a.StartedByWorkflow, a.StartedByRun, a.ChainDepth, a.Title = &wid, &rid, &depth, &name
	})
	if w.Mode == wire.WorkflowModeStanding {
		d.workflowMu.Lock()
		d.stateLocked(fr.folder, fr.id, true).StandingAgentID = &id
		d.saveRecordsLocked(false)
		d.workflowMu.Unlock()
	}
	return id, nil
}

// runPrompt is the file's prompt, and what started it.
func (d *Daemon) runPrompt(w wire.Workflow, fr fireRequest) string {
	text := w.Prompt
	if fr.triggeringAgent != nil {
		title := "an untitled agent"
		if a := d.Store.Agent(*fr.triggeringAgent); a != nil && a.Title != nil {
			title = "“" + *a.Title + "”"
		}
		what := "triggered this"
		if fr.causingEvent != nil {
			if e := d.event(*fr.causingEvent); e != nil {
				switch e.Name {
				case "agent.finished":
					what = "has just finished its work"
				case "agent.asked_permission":
					what = "is waiting for permission"
				case "agent.asked_form":
					what = "is waiting on a form"
				case "agent.stopped", "agent.failed":
					what = "stopped without finishing"
				}
			}
		}
		text += "\n\n(You were started by the workflow \"" + w.Name + "\" because " + title + " " + what + ".)"
	} else if fr.causingEvent != nil {
		if e := d.event(*fr.causingEvent); e != nil {
			details := ""
			if len(e.Details) > 0 {
				var keys []string
				for k := range e.Details {
					keys = append(keys, k)
				}
				sort.Strings(keys)
				var parts []string
				for _, k := range keys {
					parts = append(parts, k+": "+e.Details[k])
				}
				details = " Its details are " + strings.Join(parts, "; ") + "."
			}
			text += "\n\n(You were started by the workflow \"" + w.Name + "\" because of the event " + e.Name + ": " + e.Sentence + details + ")"
		}
	}
	return text
}

// recordOutcome is record(): the outcome kept, said on the log and on its causing event.
func (d *Daemon) recordOutcome(fr fireRequest, name string, o wire.WorkflowOutcome, agent *wire.UUID) {
	d.workflowMu.Lock()
	st := d.stateLocked(fr.folder, fr.id, true)
	if o.Refused != nil {
		o.Refused.Repeats = 1
		if st.LastOutcome != nil && st.LastOutcome.Refused != nil && sameReason(st.LastOutcome.Refused.Value, o.Refused.Value) {
			o.Refused.Repeats = st.LastOutcome.Refused.Repeats + 1
		}
	}
	st.LastOutcome, st.LastCausingEvent = &o, fr.causingEvent
	if o.Ran != nil {
		t := now()
		st.LastFiredAt = &t
		cause := wire.WorkflowCause{Trigger: &wire.WorkflowCauseTrigger{Value: fr.trigger}}
		if fr.byHand {
			cause = wire.WorkflowCause{ByHand: &struct{}{}}
		}
		st.LastFiredBy = &cause
	}
	d.saveRecordsLocked(false)
	d.workflowMu.Unlock()
	scope := projectScope(fr.folder)
	if o.Ran != nil {
		title := "Untitled"
		var t *string
		if a := d.Store.Agent(*agent); a != nil && a.Title != nil {
			title, t = *a.Title, a.Title
		}
		d.raise(wire.EventDraft{Name: "workflow.ran", At: now(), Scope: scope, Sentence: "Workflow " + name + " started " + agentName(t) + ".",
			Details: map[string]string{"workflow": fr.id, "agent": string(*agent), "agent_title": title}, ChainDepth: fr.depth + 1})
		if fr.causingEvent != nil {
			d.addConsequence(wire.Consequence{Fired: &wire.ConsequenceFired{WorkflowID: fr.id, Folder: store.FolderURL(fr.folder), AgentID: agent}}, *fr.causingEvent)
		}
	} else {
		r := o.Refused.Value
		if r.Disabled == nil && r.CoolingDown == nil && r.Queued == nil {
			d.raise(wire.EventDraft{Name: "workflow.refused", At: now(), Scope: scope, Sentence: "Workflow " + name + " did not run: " + refusalWords(r) + ".",
				Details: map[string]string{"workflow": fr.id, "reason": refusalCode(r)}, ChainDepth: fr.depth + 1})
		}
		if fr.causingEvent != nil {
			d.addConsequence(wire.Consequence{Refused: &wire.ConsequenceRefused{WorkflowID: fr.id, Folder: store.FolderURL(fr.folder), Reason: r}}, *fr.causingEvent)
		}
	}
	d.tellWorkflow(fr.folder, fr.id)
}

func (d *Daemon) releaseRun(id wire.UUID) *workflowRun {
	d.workflowMu.Lock()
	defer d.workflowMu.Unlock()
	rec := d.recordsLocked()
	for i, r := range rec.Runs {
		if r.ID == id {
			rec.Runs = append(rec.Runs[:i], rec.Runs[i+1:]...)
			d.saveRecordsLocked(false)
			return &r
		}
	}
	return nil
}

// workflowRunFinished is called as an agent's turn ends: its run is over, said with
// workflow.completed, and what was queued behind it goes, oldest first.
func (d *Daemon) workflowRunFinished(agent wire.UUID) {
	d.workflowMu.Lock()
	var run *workflowRun
	for _, r := range d.recordsLocked().Runs {
		if r.AgentID != nil && *r.AgentID == agent {
			r := r
			run = &r
		}
	}
	d.workflowMu.Unlock()
	if run == nil {
		return
	}
	d.releaseRun(run.ID)
	folder := store.FolderPath(run.Folder)
	d.workflowMu.Lock()
	name := run.WorkflowID
	var whenDone *wire.WorkflowWhenDone
	var mode wire.WorkflowMode
	if f := d.fileLocked(folder, run.WorkflowID); f != nil {
		name, whenDone, mode = f.wf.Name, f.wf.WhenDone, f.wf.Mode
	}
	d.workflowMu.Unlock()
	details := map[string]string{"workflow": run.WorkflowID, "agent": string(agent)}
	a := d.Store.Agent(agent)
	if a != nil {
		details["agent_title"] = "Untitled"
		if a.Title != nil {
			details["agent_title"] = *a.Title
		}
		if a.Report != nil {
			details["outcome"] = string(a.Report.Outcome)
		}
	}
	d.raise(wire.EventDraft{Name: "workflow.completed", At: now(), Scope: projectScope(folder), Sentence: "Workflow " + name + " finished.",
		Details: details, ChainDepth: run.Depth + 1})
	// when-done: a run its workflow lets archive itself, ended done or with nothing to do.
	if a != nil && whenDone != nil && mode != wire.WorkflowModeTriggering && a.StartedByWorkflow != nil && *a.StartedByWorkflow == run.WorkflowID &&
		a.State == wire.AgentStateFinished && a.EndedReason != nil && *a.EndedReason == wire.EndedReasonEndTurn && len(a.QueuedPrompts) == 0 &&
		a.Report != nil && goesWithArchive(a.Report.Outcome) {
		asked := a.ArchiveRequest != nil && a.ArchiveRequest.Requested != nil
		if *whenDone == wire.WorkflowWhenDoneArchive || *whenDone == wire.WorkflowWhenDoneArchiveAllowed && asked {
			d.record(agent, runtimeNote("Archived when its run was done, as the workflow “"+name+"” allows."))
			d.archiveBy(agent, wire.AgentArchivedReasonByAgent)
		}
	}
	d.releaseQueued(folder, run.WorkflowID)
}

// releaseQueued is the queue behind a run: one, oldest first, or the whole of it dropped
// when the workflow has gone, been archived or turned off.
func (d *Daemon) releaseQueued(folder, id string) {
	d.workflowMu.Lock()
	st := d.stateLocked(folder, id, false)
	if st == nil || len(st.QueuedFires) == 0 && st.HeldFire == nil {
		d.workflowMu.Unlock()
		return
	}
	f := d.fileLocked(folder, id)
	var drop *wire.WorkflowRefusal
	switch {
	case f == nil:
		drop = &wire.WorkflowRefusal{Unreadable: &wire.WorkflowRefusalUnreadable{Value: "the workflow's file is gone"}}
	case isArchived(f.wf):
		drop = &wire.WorkflowRefusal{Archived: &struct{}{}}
	case isOff(f.wf):
		drop = &wire.WorkflowRefusal{Disabled: &struct{}{}}
	}
	if drop != nil {
		for _, q := range st.QueuedFires {
			if q.CausingEvent != nil {
				d.addConsequence(wire.Consequence{Refused: &wire.ConsequenceRefused{WorkflowID: id, Folder: store.FolderURL(folder), Reason: *drop}}, *q.CausingEvent)
			}
		}
		st.QueuedFires, st.HeldFire = nil, nil
		d.saveRecordsLocked(false)
		d.workflowMu.Unlock()
		return
	}
	var next *heldFire
	fromQueue := false
	if len(st.QueuedFires) > 0 {
		q := st.QueuedFires[0]
		st.QueuedFires = st.QueuedFires[1:]
		next, fromQueue = &q, true
	} else if st.HeldFire != nil {
		cooled := f.wf.Cooldown == nil || st.LastFiredAt == nil ||
			!st.LastFiredAt.Time().Add(time.Duration(*f.wf.Cooldown*float64(time.Second))).After(time.Now())
		if cooled {
			next, st.HeldFire = st.HeldFire, nil
		}
	}
	d.saveRecordsLocked(false)
	d.workflowMu.Unlock()
	if next != nil {
		fr := fireRequest{folder: folder, id: id, trigger: next.Trigger, triggeringAgent: next.TriggeringAgentID, depth: next.Depth,
			causingEvent: next.CausingEvent, fromQueue: fromQueue}
		safe.Go("workflow queue", func() { d.fire(fr) })
	}
}

// runWorkflow is workflows/run: Run now, refused only if it is pinned elsewhere.
func (d *Daemon) runWorkflow(r wire.WorkflowRequest) (wire.WorkflowSummary, error) {
	folder := store.FolderPath(r.Folder)
	d.workflowMu.Lock()
	d.scanLocked()
	f := d.fileLocked(folder, r.WorkflowID)
	if f == nil {
		d.workflowMu.Unlock()
		return wire.WorkflowSummary{}, noSuchWorkflow(r.WorkflowID)
	}
	if !d.runsHere(f.wf) {
		d.workflowMu.Unlock()
		return wire.WorkflowSummary{}, &Error{Code: wire.FailureNoSuchWorkflow, Message: f.wf.Name + " runs on another computer."}
	}
	d.workflowMu.Unlock()
	d.fire(fireRequest{folder: folder, id: r.WorkflowID, byHand: true,
		trigger: wire.WorkflowTrigger{Schedule: &wire.WorkflowTriggerStoredSchedule{Value: wire.WorkflowSchedule{Minutes: []int64{0},
			Hours: [2]int64{0, 23}, EndMinute: 30, Days: []wire.Weekday{"sun", "mon", "tue", "wed", "thu", "fri", "sat"}}}}})
	return d.oneWorkflow(folder, r.WorkflowID)
}

// workflowClock ticks every 15 seconds: a schedule due since the last tick fires, or is
// missed when the host was away longer than two minutes.
func (d *Daemon) workflowClock() {
	t := time.NewTicker(workflowTick)
	defer t.Stop()
	for {
		select {
		case <-d.ctx.Done():
			return
		case <-t.C:
			d.workflowTickOnce(time.Now())
		}
	}
}

func (d *Daemon) workflowTickOnce(at time.Time) {
	d.noteDay()
	d.workflowMu.Lock()
	rec := d.recordsLocked()
	var since *time.Time
	if rec.LastTickAt != nil {
		s := rec.LastTickAt.Time()
		since = &s
	}
	n := wire.DateOf(at)
	rec.LastTickAt = &n
	// Written at most every 30 seconds: a restart reads how long it was away from it.
	if since == nil || !since.Add(30*time.Second).After(at) {
		d.saveRecordsLocked(false)
	}
	d.scanLocked()
	var fires []fireRequest
	var missed []fireRequest
	held := map[string]bool{}
	if since != nil && since.Before(at) {
		away := at.Sub(*since) > workflowAway
		for folder, ws := range d.workflowFiles {
			for id, f := range ws {
				if st := d.stateLocked(folder, id, false); st != nil && st.HeldFire != nil {
					held[workflowKey(folder, id)] = true
				}
				w := f.wf
				if !d.runsHere(w) || w.Problem != nil || isArchived(w) {
					continue
				}
				for _, t := range w.Triggers {
					if t.Schedule == nil {
						continue
					}
					if due, ok := nextDue(t.Schedule.Value, *since); ok && !due.After(at) {
						fr := fireRequest{folder: folder, id: id, trigger: t}
						if away {
							missed = append(missed, fr)
						} else {
							fires = append(fires, fr)
						}
						break
					}
				}
			}
		}
	}
	d.workflowMu.Unlock()
	for k := range held {
		folder, id := k[:strings.LastIndex(k, "/")], k[strings.LastIndex(k, "/")+1:]
		if !d.runningOf(folder, id) {
			d.releaseQueued(folder, id)
		}
	}
	for _, fr := range missed {
		d.workflowMu.Lock()
		name := d.fileLocked(fr.folder, fr.id).wf.Name
		d.workflowMu.Unlock()
		d.recordOutcome(fr, name, wire.WorkflowOutcome{Refused: &wire.WorkflowOutcomeRefused{
			Value: wire.WorkflowRefusal{MissedWhileClosed: &struct{}{}}, At: now()}}, nil)
	}
	for _, fr := range fires {
		fr := fr
		safe.Go("workflow schedule", func() { d.fire(fr) })
	}
}

func (d *Daemon) runningOf(folder, id string) bool {
	d.workflowMu.Lock()
	defer d.workflowMu.Unlock()
	return d.runningLocked(folder, id)
}

// restoreRuns lets go of runs a restart cannot carry on: older than a week, their workflow
// or agent gone, or their agent ended and not about to be picked up.
func (d *Daemon) restoreRuns() {
	d.workflowMu.Lock()
	defer d.workflowMu.Unlock()
	// The host's first look, at start-up as the Swift host's is: what is there now is
	// approved if approval has not begun, and a file that comes after waits for the person.
	d.scanLocked()
	rec := d.recordsLocked()
	kept := rec.Runs[:0]
	for _, r := range rec.Runs {
		why := ""
		switch a := (*wire.Agent)(nil); {
		case time.Since(r.StartedAt.Time()) > workflowRunsKept:
			why = "it is over a week old"
		case r.AgentID == nil:
			why = "it never started an agent"
		default:
			a = d.Store.Agent(*r.AgentID)
			if a == nil || a.State == wire.AgentStateArchived {
				why = "its agent is gone"
			} else if !inFlight(a.State) && a.RestartPickUps == nil {
				why = "its agent had already ended"
			}
		}
		if why != "" {
			log.Printf("let go of the %s run from before the restart: %s", r.WorkflowID, why)
			continue
		}
		kept = append(kept, r)
	}
	if len(kept) != len(rec.Runs) {
		rec.Runs = kept
		d.saveRecordsLocked(false)
	}
}
