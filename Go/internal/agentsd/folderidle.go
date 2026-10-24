package agentsd

import (
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// folder.idle (#360, #1368), as DaemonCore+FolderIdle: every agent in a folder has
// stopped working. A busy period starts when an agent there starts a turn, and ends once
// none is starting or running and none has for folderIdleSettle, so a lead that ends one
// helper and starts the next does not raise it in between. It is raised once a busy
// period, on the way from working to quiet.
//
// An agent asking for permission is not running: it is counted under waiting_on_you. A
// run started by folder.idle (or folder.*) is the clean-up itself, and its agents and
// their helpers do not count as work, or the job's own finish would make the folder idle
// again for ever. Memory only: a host restarted mid-period counts from the next agent.

// folderIdleSettle is how long a folder stays quiet before it is idle; a test's own.
var folderIdleSettle = time.Minute

type busyPeriod struct {
	since      time.Time
	worked     []wire.UUID
	settling   *time.Timer
	generation int
}

type idleBook struct {
	idleMu sync.Mutex
	busy   map[string]*busyPeriod
}

// watchForIdle is called whenever an agent's state moves, off the change's own lock.
func (d *Daemon) watchForIdle(folder string) {
	// Read under the lock, so two calls racing apply what was so in their order.
	d.idleMu.Lock()
	defer d.idleMu.Unlock()
	working := d.workingIn(folder)
	if d.busy == nil {
		d.busy = map[string]*busyPeriod{}
	}
	period := d.busy[folder]
	if len(working) > 0 {
		if period == nil {
			period = &busyPeriod{since: nowFunc()}
			d.busy[folder] = period
		}
		for _, id := range working {
			if !containsID(period.worked, id) {
				period.worked = append(period.worked, id)
			}
		}
		if period.settling != nil {
			period.settling.Stop()
			period.settling = nil
		}
		period.generation++
		return
	}
	if period == nil || period.settling != nil || len(period.worked) == 0 {
		return
	}
	generation := period.generation
	period.settling = time.AfterFunc(folderIdleSettle, func() {
		safe.Go("folder idle", func() { d.idleSettled(folder, generation) })
	})
}

// workingIn is the agents starting or running in a folder, less the clean-up's own.
func (d *Daemon) workingIn(folder string) []wire.UUID {
	var out []wire.UUID
	for _, a := range d.agentsOf(folder) {
		if (a.State == wire.AgentStateStarting || a.State == wire.AgentStateRunning) && !d.isIdleJob(&a) {
			out = append(out, a.ID)
		}
	}
	return out
}

// idleSettled is the settle run out: said, if nothing has worked since.
func (d *Daemon) idleSettled(folder string, generation int) {
	if d.ctx.Err() != nil {
		return
	}
	d.idleMu.Lock()
	stillWorking := len(d.workingIn(folder)) > 0
	period := d.busy[folder]
	if period == nil || period.generation != generation || stillWorking {
		if period != nil && period.generation == generation {
			period.settling = nil
		}
		d.idleMu.Unlock()
		return
	}
	delete(d.busy, folder)
	d.idleMu.Unlock()
	d.raiseFolderIdle(folder, period)
}

func (d *Daemon) raiseFolderIdle(folder string, period *busyPeriod) {
	keys := []string{"finished", "waiting", "waiting_on_you", "stopped", "failed"}
	counts := map[string]int{}
	for _, id := range period.worked {
		if a := d.Store.Agent(id); a != nil {
			counts[d.idleStanding(a)]++
		}
	}
	details := map[string]string{}
	var tally []string
	for _, k := range keys {
		details[k] = fmt.Sprint(counts[k])
		if counts[k] > 0 {
			tally = append(tally, fmt.Sprintf("%d %s", counts[k], strings.ReplaceAll(k, "_", " ")))
		}
	}
	ids := make([]string, len(period.worked))
	for i, id := range period.worked {
		ids[i] = string(id)
	}
	n := len(period.worked)
	details["agents"] = fmt.Sprint(n)
	details["since"] = period.since.UTC().Format(time.RFC3339)
	details["ids"] = strings.Join(ids, ",")
	d.raise(wire.EventDraft{Name: "folder.idle", At: now(), Scope: folderScope(folder),
		Sentence: fmt.Sprintf("Every agent here has stopped: %d worked (%s).", n, strings.Join(tally, ", ")),
		Details:  details})
}

// idleStanding is how an agent that worked stands now, as the event counts it.
func (d *Daemon) idleStanding(a *wire.Agent) string {
	switch a.State {
	case wire.AgentStateWaitingOnUser:
		return "waiting_on_you"
	case wire.AgentStateStopped:
		if r := a.EndedReason; r == nil || *r == wire.EndedReasonCancelled || *r == wire.EndedReasonCostLimit || *r == wire.EndedReasonStoppedByAdmin {
			return "stopped"
		}
		return "failed"
	}
	if d.waitStatus(a) != nil {
		return "waiting"
	}
	if a.Report != nil {
		switch a.Report.Outcome {
		case wire.WorkOutcomeNeedsAnswer:
			return "waiting_on_you"
		case wire.WorkOutcomeWaiting:
			return "waiting"
		}
	}
	return "finished"
}

// isIdleJob is whether an agent does a folder.idle workflow's work, or is a helper of one
// that does, however far up (#940).
func (d *Daemon) isIdleJob(a *wire.Agent) bool {
	chain := []*wire.Agent{a}
	for _, id := range d.starters(a) {
		if s := d.Store.Agent(id); s != nil {
			chain = append(chain, s)
		}
	}
	d.workflowMu.Lock()
	defer d.workflowMu.Unlock()
	for _, x := range chain {
		if d.doesIdleWorkLocked(x) {
			return true
		}
	}
	return false
}

func (d *Daemon) doesIdleWorkLocked(a *wire.Agent) bool {
	for _, r := range d.recordsLocked().Runs {
		if r.AgentID != nil && *r.AgentID == a.ID && answersIdle(r.Trigger) {
			return true
		}
	}
	if a.StartedByWorkflow == nil {
		return false
	}
	if d.workflowFiles == nil {
		d.scanLocked()
	}
	f := d.workflowFiles[folderPath(a)][*a.StartedByWorkflow]
	if f == nil || f.wf.Mode == wire.WorkflowModeTriggering {
		return false
	}
	for _, t := range f.wf.Triggers {
		if answersIdle(t) {
			return true
		}
	}
	return false
}

func answersIdle(t wire.WorkflowTrigger) bool {
	p, ok := triggerPattern(t)
	return ok && (p.name == "folder.idle" || p.name == "folder.*")
}

func containsID(ids []wire.UUID, id wire.UUID) bool {
	for _, x := range ids {
		if x == id {
			return true
		}
	}
	return false
}

// stopIdleTimers lets every settle go, as the host stops.
func (d *Daemon) stopIdleTimers() {
	d.idleMu.Lock()
	defer d.idleMu.Unlock()
	for _, p := range d.busy {
		if p.settling != nil {
			p.settling.Stop()
		}
	}
	d.busy = nil
}
