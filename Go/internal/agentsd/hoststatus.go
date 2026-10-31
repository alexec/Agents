package agentsd

import (
	"bytes"
	"encoding/json"
	"sort"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// host/status (#691 US4, #1387), as DaemonCore+MachineStatus: whether this host is idle, what
// runs, and its next scheduled workflow, said on channel 0 when it changes (on the
// 15-second tick, and again when the uplink comes back), so a machine provider can stop
// an idle host and wake it for its next schedule.

const hostStatusTick = 15 * time.Second

type hostStatusBook struct {
	statusMu   sync.Mutex
	toldStatus []byte // what host/status last said, as sent; nil to say it again
	statusTick sync.Once
}

// hostStatus is idle as a workspace's stop when idle counts it: no turn in flight, no agent
// waiting on a person, no permission asked and no terminal or folder shell open.
func (d *Daemon) hostStatus() wire.MachineStatus {
	running := []string{}
	for _, a := range d.Store.Agents() {
		if a.State != wire.AgentStateStarting && a.State != wire.AgentStateRunning && a.State != wire.AgentStateWaitingOnUser {
			continue
		}
		name := a.RuntimeID
		if r := runtimeByID(a.RuntimeID); r != nil {
			name = r.Name
		}
		if a.Title != nil {
			name += " (" + *a.Title + ")"
		}
		running = append(running, name)
	}
	sort.Strings(running)
	d.mu.Lock()
	shells := len(d.shells)
	d.mu.Unlock()
	idle := len(running) == 0 && len(d.pendingPermissions()) == 0 && shells == 0
	schedule := d.nextScheduled()
	return wire.MachineStatus{Idle: idle, Running: running, Schedule: &schedule}
}

// nextScheduled is this host's next scheduled workflow, for the control plane's wake-up
// call (#1004): the soonest due of the ones that run here and could fire, as their pages say.
func (d *Daemon) nextScheduled() wire.MachineSchedule {
	var best *wire.WorkflowSummary
	for _, s := range d.workflowSummaries("") {
		if s.NextFireAt == nil || s.IsArchived || !s.IsEnabled || s.AwaitingApproval != nil || s.DeniedHere != nil || s.OverLimit != nil {
			continue
		}
		if best == nil || *s.NextFireAt < *best.NextFireAt || *s.NextFireAt == *best.NextFireAt && s.Workflow.Name < best.Workflow.Name {
			s := s
			best = &s
		}
	}
	if best == nil {
		return wire.MachineSchedule{}
	}
	name := best.Workflow.Name
	return wire.MachineSchedule{At: best.NextFireAt, Workflow: &name}
}

// reviseHostStatus says host/status when it has changed, to a control plane this host has.
func (d *Daemon) reviseHostStatus() {
	tell := d.tellControl.Load()
	if tell == nil {
		return
	}
	status := d.hostStatus()
	b, err := json.Marshal(status)
	if err != nil {
		return
	}
	d.statusMu.Lock()
	same := d.toldStatus != nil && bytes.Equal(d.toldStatus, b)
	if !same {
		d.toldStatus = b
	}
	d.statusMu.Unlock()
	if !same {
		(*tell)(wire.NewMethodName(wire.CallHostStatus.Name), status)
	}
}

// startHostStatus says it now, then on the tick for the host's life.
func (d *Daemon) startHostStatus() {
	d.statusMu.Lock()
	d.toldStatus = nil
	d.statusMu.Unlock()
	d.reviseHostStatus()
	d.statusTick.Do(func() {
		safe.Go("host status", func() {
			tick := time.NewTicker(hostStatusTick)
			defer tick.Stop()
			for {
				select {
				case <-d.ctx.Done():
					return
				case <-tick.C:
					d.reviseHostStatus()
				}
			}
		})
	})
}
