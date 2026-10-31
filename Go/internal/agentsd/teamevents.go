package agentsd

import (
	"encoding/json"
	"log"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// Scoped events (#2011, spec 736 FR-035). On a bot's machine, a runs-on: workflow's
// trigger is one of three scopes:
//
//   - a machine event (machine.*, dropbox.*) stays on its machine: it runs here, unclaimed;
//   - a folder or control-plane event (a server's, such as github or a channel's) or a
//     schedule is sent to the control plane (workflows/trigger), which sends it once, to one
//     of the bot's machines (workflows/fire);
//   - anything else this machine raised itself (its agents, its workflows, its branches) is
//     claimed, as before (#1761).
//
// A control plane that does not take it (an older one, or runs-on: names no bot) leaves
// the claim to keep the run to one.

type triggerScope int

const (
	scopeClaimed triggerScope = iota
	scopeMachine
	scopeTeam
)

// scopeOf is the scope of the trigger a fire answers.
func scopeOf(fr fireRequest) triggerScope {
	if fr.dueAt != nil {
		return scopeTeam
	}
	if fr.event == nil {
		return scopeClaimed
	}
	noun, _, _ := strings.Cut(fr.event.Name, ".")
	switch {
	case noun == "machine" || noun == "dropbox":
		return scopeMachine
	case fr.event.Details["server"] != "" && isServerEventName(fr.event.Name):
		return scopeTeam
	}
	return scopeClaimed
}

// workflowName is a workflow as every machine names it: by the folder's name, as
// each keeps its own copy of the folder at a path of its own.
func workflowName(folder, id string) string { return filepath.Base(folder) + "/" + id }

// sendTrigger is workflows/trigger. taken is true when the control plane sends it once;
// ok is false when it could not be asked or did not answer.
func (d *Daemon) sendTrigger(fr fireRequest, w wire.Workflow) (taken, ok bool) {
	ask := d.askControl.Load()
	if ask == nil {
		return false, false
	}
	t := wire.TeamTrigger{Workflow: workflowName(fr.folder, fr.id), Trigger: triggerID(fr, fr.event), RunsOn: w.RunsOn, Event: fr.event}
	if fr.dueAt != nil {
		due := wire.DateOf(*fr.dueAt)
		t.DueAt = &due
	}
	out, err := (*ask)(d.ctx, wire.CallWorkflowsTrigger.Name, t)
	if err != nil {
		log.Printf("workflow %s: the control plane did not take %s: %v", fr.id, t.Trigger, err)
		return false, false
	}
	var sent wire.TeamTriggerSent
	if json.Unmarshal(out, &sent) != nil {
		return false, false
	}
	if sent.Taken {
		log.Printf("workflow %s: the control plane sends %s once", fr.id, t.Trigger)
	}
	return sent.Taken, true
}

// Asked answers what the control plane asks on channel 0: workflows/fire, and git/fill
// for a lend a person allowed (#1122). git/fill is not registered as a window method.
func (d *Daemon) Asked(method string, params json.RawMessage) (any, bool) {
	switch method {
	case wire.CallWorkflowsFire.Name:
		var t wire.TeamTrigger
		if err := json.Unmarshal(params, &t); err != nil {
			log.Printf("workflows/fire: %v", err)
			return wire.TeamTriggerFired{Ran: false}, true
		}
		return wire.TeamTriggerFired{Ran: d.fireFromControl(t)}, true
	case wire.CallGitFill.Name:
		return d.fillGit(params), true
	default:
		return nil, false
	}
}

// fireFromControl runs a trigger the control plane took once: true when this machine has
// the workflow, runs it here, and one of its triggers matches. Its refusals (a run still
// going, the cap) are recorded here as for any trigger.
func (d *Daemon) fireFromControl(t wire.TeamTrigger) bool {
	folderName, id, ok := strings.Cut(t.Workflow, "/")
	if !ok || folderName == "" || id == "" {
		return false
	}
	d.workflowMu.Lock()
	if d.workflowFiles == nil {
		d.scanLocked()
	}
	folders := make([]string, 0, len(d.workflowFiles))
	for folder := range d.workflowFiles {
		if filepath.Base(folder) == folderName && d.workflowFiles[folder][id] != nil {
			folders = append(folders, folder)
		}
	}
	sort.Strings(folders)
	var fr *fireRequest
	for _, folder := range folders {
		w := d.workflowFiles[folder][id].wf
		if !d.runsHere(w) || w.Problem != nil || isArchived(w) {
			continue
		}
		if f, matched := matchTeamTrigger(folder, id, w, t, time.Now()); matched {
			fr = &f
			break
		}
	}
	d.workflowMu.Unlock()
	if fr == nil {
		log.Printf("workflows/fire: %s does not run %s here", t.Workflow, t.Trigger)
		return false
	}
	f := *fr
	d.goAfterTurn("workflow fire", func() { d.fire(f) })
	return true
}

// matchTeamTrigger is the fire for a trigger sent by the control plane: a due time of one
// of its schedules, or a server's event one of its server triggers matches, with the event's
// folder made this machine's own folder. Only what a machine may send is run: no app event,
// no time its schedules are not due here, and only the trigger id its event or due time
// names.
func matchTeamTrigger(folder, id string, w wire.Workflow, t wire.TeamTrigger, now time.Time) (fireRequest, bool) {
	fr := fireRequest{folder: folder, id: id, fromControl: true}
	if t.DueAt != nil {
		due := t.DueAt.Time()
		if t.Event != nil || t.Trigger != wire.ScheduleTriggerID(due) || due.After(now.Add(5*time.Minute)) || due.Before(now.Add(-24*time.Hour)) {
			return fr, false
		}
		// Only a time one of its schedules falls due here.
		for _, trig := range w.Triggers {
			if trig.Schedule == nil {
				continue
			}
			if next, ok := nextDue(trig.Schedule.Value, due.Add(-time.Second)); ok && next.Equal(due) {
				fr.trigger, fr.dueAt = trig, &due
				return fr, true
			}
		}
		return fr, false
	}
	if t.Event == nil {
		return fr, false
	}
	e := *t.Event
	if e.Details["server"] == "" || e.Details["event"] != e.Name || !isServerEventName(e.Name) || t.Trigger != triggerID(fireRequest{}, &e) {
		return fr, false
	}
	e.Scope, e.ChainDepth = folderScope(folder), 0
	for _, trig := range w.Triggers {
		if mt, isServer := serverTrigger(trig); isServer && mt.matches(e) {
			fr.trigger, fr.event = trig, &e
			return fr, true
		}
	}
	return fr, false
}

// teamFire decides how a bot's machine runs a runs-on: trigger it heard itself: true to go
// on and run it here.
func (d *Daemon) teamFire(fr fireRequest, w wire.Workflow) bool {
	switch scopeOf(fr) {
	case scopeMachine:
		return true
	case scopeTeam:
		if taken, ok := d.sendTrigger(fr, w); ok && taken {
			return false
		}
	}
	return d.claimRun(fr.folder, fr.id, triggerID(fr, fr.event))
}

// sendOthers sends the control plane a schedule of a runs-on: workflow that does not run
// here (#2011, FR-034): when it names a bot of this machine's user's group, the control
// plane sends it once, starting a machine of the bot's if none is online.
func (d *Daemon) sendOthers(fr fireRequest) {
	d.workflowMu.Lock()
	f := d.fileLocked(fr.folder, fr.id)
	d.workflowMu.Unlock()
	if f == nil || d.askControl.Load() == nil {
		return
	}
	d.sendTrigger(fr, f.wf)
}

// heardForBotLocked is the trigger a server's event makes of a bot's workflow heard here
// (#2027): on, approved here, and one of its server triggers matches. It is only ever sent
// to the control plane.
func (d *Daemon) heardForBotLocked(folder, id string, f *workflowFile, e wire.Event) (fireRequest, bool) {
	w := f.wf
	if isOff(w) || d.hearsFor(w) == "" || e.Details["server"] == "" || !isServerEventName(e.Name) {
		return fireRequest{}, false
	}
	if awaiting, denied := d.approvalOf(folder, id, f); awaiting != nil || denied != nil {
		return fireRequest{}, false
	}
	for _, t := range w.Triggers {
		if mt, ok := serverTrigger(t); ok && mt.matches(e) {
			ev := e
			return fireRequest{folder: folder, id: id, trigger: t, event: &ev, depth: e.ChainDepth}, true
		}
	}
	return fireRequest{}, false
}
