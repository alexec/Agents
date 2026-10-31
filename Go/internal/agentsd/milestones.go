package agentsd

import (
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/diskjson"
	"github.com/alexec/agents/Go/wire"
)

// The milestones (#984): earned once, when the facts first say so, kept in
// <root>/achievements.json and told to every client. A host earns those its own work
// shows: the first agent to run a turn, the first workflow, five agents at once and the
// first pull request landed (counted with the person's gh, mergedprs.go). A phone or a
// browser is paired when one calls this host at all, through the control plane or the
// bridge, and answering a question from one is answering from away from the Mac (#1987).
// A cloud machine is started when an agent starts one, or when the control plane lists
// one running, asked with the hourly count of merged pull requests.

type milestoneBook struct {
	milestoneMu    sync.Mutex
	milestonesHeld *wire.Milestones
	milestoneCheck bool // a check is under way
	milestoneAgain bool // and another is wanted after it
}

const (
	firstAgent        = "firstAgent"
	firstPairing      = "firstPairing"
	firstRemoteAnswer = "firstRemoteAnswer"
	firstWorkflow     = "firstWorkflow"
	firstCloudHost    = "firstCloudHost"
	firstLandedPR     = "firstLandedPR"
	fiveAtOnce        = "fiveAtOnce"
)

func (d *Daemon) achievementsPath() string {
	return filepath.Join(d.Store.Loc.Root, "achievements.json")
}

// milestonesLocked is what achievements.json says has been earned, read once.
func (d *Daemon) milestonesLocked() *wire.Milestones {
	if d.milestonesHeld == nil {
		var m wire.Milestones
		if b, err := os.ReadFile(d.achievementsPath()); err == nil {
			diskjson.Unmarshal(b, &m)
		}
		if m.Earned == nil {
			m.Earned = []wire.EarnedMilestone{}
		}
		d.milestonesHeld = &m
	}
	return d.milestonesHeld
}

// milestones is milestones/state.
func (d *Daemon) milestones() wire.Milestones {
	d.milestoneMu.Lock()
	defer d.milestoneMu.Unlock()
	m := *d.milestonesLocked()
	m.Earned = append([]wire.EarnedMilestone{}, m.Earned...)
	return m
}

func hasMilestone(m *wire.Milestones, id string) bool {
	for _, e := range m.Earned {
		if e.ID == id {
			return true
		}
	}
	return false
}

// checkMilestonesSoon looks at the facts away from the caller, which may hold the
// agent's or the workflows' locks; a check asked for during one runs again after it.
func (d *Daemon) checkMilestonesSoon() {
	d.milestoneMu.Lock()
	if d.milestoneCheck {
		d.milestoneAgain = true
		d.milestoneMu.Unlock()
		return
	}
	d.milestoneCheck = true
	d.milestoneMu.Unlock()
	started := d.goAfterTurn("milestones", func() {
		for {
			d.checkMilestones()
			d.milestoneMu.Lock()
			if !d.milestoneAgain {
				d.milestoneCheck = false
				d.milestoneMu.Unlock()
				return
			}
			d.milestoneAgain = false
			d.milestoneMu.Unlock()
		}
	})
	if !started {
		d.milestoneMu.Lock()
		d.milestoneCheck, d.milestoneAgain = false, false
		d.milestoneMu.Unlock()
	}
}

// checkMilestones is DaemonCore.checkMilestones: each one not yet earned, earned at the
// date the facts give for it (never ahead of now).
func (d *Daemon) checkMilestones() {
	d.milestoneMu.Lock()
	held := *d.milestonesLocked()
	d.milestoneMu.Unlock()
	want := func(id string) bool { return !hasMilestone(&held, id) }
	if !want(firstAgent) && !want(firstPairing) && !want(firstWorkflow) && !want(firstLandedPR) && !want(fiveAtOnce) {
		return
	}
	at := time.Now()
	found := map[string]time.Time{}
	if want(firstAgent) {
		var first *time.Time
		for _, a := range d.Store.Agents() {
			ran := a.LastActivityAt > a.CreatedAt && a.State != wire.AgentStateQueued &&
				a.State != wire.AgentStateStarting && a.State != wire.AgentStateRunning && a.State != wire.AgentStateWaitingOnUser
			if t := a.CreatedAt.Time(); ran && (first == nil || t.Before(*first)) {
				first = &t
			}
		}
		if first != nil {
			found[firstAgent] = *first
		}
	}
	if want(firstPairing) {
		// The first device paired, read from devices.json as it is, which holds the
		// devices' own table to when one is first asked for.
		var raws []json.RawMessage
		if b, err := os.ReadFile(d.devicesFile()); err == nil && json.Unmarshal(b, &raws) == nil {
			for _, raw := range raws {
				var dev wire.Device
				if json.Unmarshal(raw, &dev) != nil || dev.ID == "" {
					continue
				}
				if t := dev.AnnouncedAt.Time(); found[firstPairing].IsZero() || t.Before(found[firstPairing]) {
					found[firstPairing] = t
				}
			}
		}
	}
	if want(firstWorkflow) && d.hasWorkflowHere() {
		found[firstWorkflow] = at
	}
	if want(firstLandedPR) || want(fiveAtOnce) {
		h := d.timeHistory()
		days := make([]string, 0, len(h.Recap))
		for day := range h.Recap {
			days = append(days, day)
		}
		sort.Strings(days)
		var prDay, fiveDay string
		for _, day := range days {
			r := h.Recap[day]
			if prDay == "" && r.PrsMerged != nil && *r.PrsMerged > 0 {
				prDay = day
			}
			if fiveDay == "" && r.PeakAgents >= 5 {
				fiveDay = day
			}
		}
		// The days kept say when it first happened; the record outlives them.
		if fiveDay == "" && h.Records.MostAgents != nil && h.Records.MostAgents.Value >= 5 {
			fiveDay = h.Records.MostAgents.Day
		}
		for id, day := range map[string]string{firstLandedPR: prDay, fiveAtOnce: fiveDay} {
			if t, err := time.ParseInLocation("2006-01-02", day, time.Local); want(id) && day != "" && err == nil {
				found[id] = t
			}
		}
	}
	d.earnMilestones(found, at)
}

// earnNow earns each of ids, now, when it is not yet.
func (d *Daemon) earnNow(ids ...string) {
	at := time.Now()
	found := map[string]time.Time{}
	for _, id := range ids {
		found[id] = at
	}
	d.earnMilestones(found, at)
}

// earnMilestones earns each found that is not yet, at its date (never ahead of at), keeps
// them and tells every client.
func (d *Daemon) earnMilestones(found map[string]time.Time, at time.Time) {
	if len(found) == 0 {
		return
	}
	d.milestoneMu.Lock()
	m := d.milestonesLocked()
	ids := make([]string, 0, len(found))
	for id := range found {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	earned := false
	for _, id := range ids {
		if hasMilestone(m, id) {
			continue
		}
		t := found[id]
		if t.After(at) {
			t = at
		}
		m.Earned = append(m.Earned, wire.EarnedMilestone{ID: id, At: wire.DateOf(t)})
		earned = true
	}
	if !earned {
		d.milestoneMu.Unlock()
		return
	}
	if err := writeStore(d.achievementsPath(), m); err != nil {
		log.Printf("achievements.json: could not save: %v", err)
	}
	out := *m
	out.Earned = append([]wire.EarnedMilestone{}, m.Earned...)
	d.milestoneMu.Unlock()
	Broadcast(d, wire.NotifyMilestonesChanged, out)
}

// noteMilestones is what a call says once it has been answered: a phone, an iPad or a
// browser is paired when one calls at all, and answering a question from one is answering
// from away from the Mac. A browser on this Mac's own page (pagerelay.go) is the Mac.
func (d *Daemon) noteMilestones(c *Client, method string) {
	answer := method == wire.CallElicitationsAnswer.Name || method == wire.CallPermissionsAnswer.Name ||
		method == wire.CallAgentsAnswerSandbox.Name
	d.milestoneMu.Lock()
	m := d.milestonesLocked()
	wanted := !hasMilestone(m, firstPairing) || answer && !hasMilestone(m, firstRemoteAnswer)
	d.milestoneMu.Unlock()
	if !wanted || !d.fromDevice(c) {
		return
	}
	if answer {
		d.earnNow(firstPairing, firstRemoteAnswer)
	} else {
		d.earnNow(firstPairing)
	}
}

// fromDevice is whether a connection is a device's: a control-plane channel for one, or
// one the bridge bound.
func (d *Daemon) fromDevice(c *Client) bool {
	if c.conn.Device() != "" {
		return true
	}
	d.devMu.Lock()
	defer d.devMu.Unlock()
	b := d.devBound[c]
	return b != nil && b.device != ""
}

// checkCloudHosts earns firstCloudHost when any workspace a cloud provider made is
// running, as the control plane lists them: a machine started from a window, which this
// host is not told of, is found within the hour.
func (d *Daemon) checkCloudHosts() {
	d.milestoneMu.Lock()
	held := hasMilestone(d.milestonesLocked(), firstCloudHost)
	d.milestoneMu.Unlock()
	ask := d.askControl.Load()
	if held || ask == nil {
		return
	}
	out, err := (*ask)(d.ctx, "machine/machines", wire.MachineWorkspaceCall{Agent: "Agents Host", Method: machinesForAgent, Params: json.RawMessage("{}")})
	var listed wire.AgentMachines
	if err != nil || json.Unmarshal(out, &listed) != nil {
		return
	}
	if anyRunning(listed) {
		d.earnNow(firstCloudHost)
	}
}

func anyRunning(listed wire.AgentMachines) bool {
	for _, p := range listed.Providers {
		for _, w := range p.Workspaces {
			if w.State == "running" || w.HostState != nil && *w.HostState == "online" {
				return true
			}
		}
	}
	return false
}

// hasWorkflowHere is whether a folder has a workflow that runs on this host.
func (d *Daemon) hasWorkflowHere() bool {
	d.workflowMu.Lock()
	defer d.workflowMu.Unlock()
	for _, ws := range d.workflowFiles {
		for _, f := range ws {
			if d.runsHere(f.wf) {
				return true
			}
		}
	}
	return false
}
