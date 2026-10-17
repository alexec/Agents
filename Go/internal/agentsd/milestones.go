package agentsd

import (
	"log"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/diskjson"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// The milestones (#984): earned once, when the facts first say so, kept in
// <root>/achievements.json and told to every client. A server host earns those its own
// work shows: the first agent to run a turn, the first workflow, five agents at once and
// the first pull request landed. Pairing a device and answering from one are earned where
// the device connects, and a cloud host where workspaces are started (#1136).

type milestoneBook struct {
	milestoneMu    sync.Mutex
	milestonesHeld *wire.Milestones
	milestoneCheck bool // a check is under way
	milestoneAgain bool // and another is wanted after it
}

const (
	firstAgent    = "firstAgent"
	firstWorkflow = "firstWorkflow"
	firstLandedPR = "firstLandedPR"
	fiveAtOnce    = "fiveAtOnce"
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
	safe.Go("milestones", func() {
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
}

// checkMilestones is DaemonCore.checkMilestones: each one not yet earned, earned at the
// date the facts give for it (never ahead of now).
func (d *Daemon) checkMilestones() {
	d.milestoneMu.Lock()
	held := *d.milestonesLocked()
	d.milestoneMu.Unlock()
	want := func(id string) bool { return !hasMilestone(&held, id) }
	if !want(firstAgent) && !want(firstWorkflow) && !want(firstLandedPR) && !want(fiveAtOnce) {
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

// hasWorkflowHere is whether a project has a workflow that runs on this host.
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

// waitForMilestones lets a check under way finish its write, at most a second, as the
// host goes.
func (d *Daemon) waitForMilestones() {
	for deadline := time.Now().Add(time.Second); time.Now().Before(deadline); time.Sleep(10 * time.Millisecond) {
		d.milestoneMu.Lock()
		busy := d.milestoneCheck
		d.milestoneMu.Unlock()
		if !busy {
			return
		}
	}
}
