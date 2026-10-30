package agentsd

import (
	"encoding/json"
	"path/filepath"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// What the agents did, for Reports ▸ Outcomes, Time, Runtimes, Adoption and Workflows (#2019): counted into the same UTC
// hours as their cost, by folder and runtime, from this host's own event log and time
// ledger. Only numbers go to the control plane, never a conversation's words.
//
// A pull or merge request counts on the host whose agent made it: one from a branch that
// an agent here works in. Thus two hosts that hear the same repository count it once, and a
// person's own pull requests do not count as the agents'. A host hears pr.opened and
// pr.merged only while a workflow or a wait is subscribed to them.

// waitBounds are the upper ends of ReportCounts.waitBuckets but the last, in minutes.
var waitBounds = []time.Duration{time.Minute, 5 * time.Minute, 15 * time.Minute, time.Hour, 4 * time.Hour}

func blankCounts() *wire.ReportCounts {
	return &wire.ReportCounts{WaitBuckets: make([]int64, len(waitBounds)+1)}
}

func addCounts(r *wire.ReportCounts, o wire.ReportCounts) {
	r.Sessions += o.Sessions
	r.FailedSessions += o.FailedSessions
	r.WorkflowRuns += o.WorkflowRuns
	r.WorkflowFailures += o.WorkflowFailures
	r.PrsOpened += o.PrsOpened
	r.PrsMerged += o.PrsMerged
	r.PrsReverted += o.PrsReverted
	r.MergeSeconds += o.MergeSeconds
	r.Waits += o.Waits
	for len(r.WaitBuckets) < len(o.WaitBuckets) {
		r.WaitBuckets = append(r.WaitBuckets, 0)
	}
	for i, n := range o.WaitBuckets {
		r.WaitBuckets[i] += n
	}
}

// waitCounts is one wait for the person, in its bucket.
func waitCounts(length time.Duration) *wire.ReportCounts {
	c := blankCounts()
	c.Waits = 1
	i := 0
	for i < len(waitBounds) && length >= waitBounds[i] {
		i++
	}
	c.WaitBuckets[i] = 1
	return c
}

// prPayload is what the GitHub and GitLab servers say of a pull or merge request.
type prPayload struct {
	PR struct {
		Title  string `json:"title"`
		Branch string `json:"branch"`
	} `json:"pr"`
	OpenedAt string `json:"openedAt"`
	MergedAt string `json:"mergedAt"`
}

// eventFolder is an event's folder as the reports name it: its folder's name.
func eventFolder(e wire.Event) string {
	if e.Scope.Folder == nil {
		return ""
	}
	f := store.FolderPath(e.Scope.Folder.Value)
	if f == "" || f == "/" {
		return ""
	}
	return filepath.Base(f)
}

// countReportEvents adds the events logged since the last count to their hours.
func (d *Daemon) countReportEvents() {
	d.reportMu.Lock()
	seen := d.reportLocked().EventsSeen
	d.reportMu.Unlock()
	d.eventMu.Lock()
	// A log that starts again (its state lost) gives out its positions again.
	if n := len(d.eventList); n > 0 && d.eventList[n-1].Position < seen {
		seen = 0
	}
	var list []wire.Event
	for _, e := range d.eventList {
		if e.Position > seen {
			list = append(list, e)
		}
	}
	d.eventMu.Unlock()
	if len(list) == 0 {
		return
	}
	type add struct {
		folder, runtime, workflow, hour string
		counts                           *wire.ReportCounts
	}
	var adds []add
	var branches map[string]*wire.Agent
	for _, e := range list {
		switch e.Name {
		case "agent.started", "agent.failed":
			c := blankCounts()
			workflow := ""
			if a := d.Store.Agent(wire.UUID(e.Details["agent"])); a != nil {
				workflow = reportWorkflow(a)
			}
			if e.Name == "agent.started" {
				c.Sessions = 1
			} else {
				c.FailedSessions = 1
				if workflow != "" {
					c.WorkflowFailures = 1
				}
			}
			adds = append(adds, add{eventFolder(e), e.Details["runtime"], workflow, utcHour(e.At.Time()), c})
		case "workflow.ran":
			c := blankCounts()
			c.WorkflowRuns = 1
			runtime := ""
			if a := d.Store.Agent(wire.UUID(e.Details["agent"])); a != nil {
				runtime = a.RuntimeID
			}
			adds = append(adds, add{eventFolder(e), runtime, e.Details["workflow"], utcHour(e.At.Time()), c})
		case "pr.opened", "pr.merged":
			var p prPayload
			if json.Unmarshal([]byte(e.Details["payload"]), &p) != nil || p.PR.Branch == "" {
				continue
			}
			if branches == nil {
				branches = d.agentBranches()
			}
			a := branches[p.PR.Branch]
			if a == nil {
				continue
			}
			at := e.At.Time()
			stamp := p.OpenedAt
			if e.Name == "pr.merged" {
				stamp = p.MergedAt
			}
			if t, err := time.Parse(time.RFC3339, stamp); err == nil {
				at = t
			}
			c := blankCounts()
			if e.Name == "pr.opened" {
				c.PrsOpened = 1
			} else {
				c.PrsMerged = 1
				if strings.HasPrefix(p.PR.Title, "Revert") {
					c.PrsReverted = 1
				}
				if took := at.Sub(a.CreatedAt.Time()); took > 0 {
					c.MergeSeconds = took.Seconds()
				}
			}
			adds = append(adds, add{reportFolder(a), a.RuntimeID, reportWorkflow(a), utcHour(at), c})
		}
	}
	last := list[len(list)-1].Position
	d.reportMu.Lock()
	defer d.reportMu.Unlock()
	oldest := utcHour(time.Now().Add(-reportHoursKept * time.Hour))
	for _, a := range adds {
		if a.hour >= oldest {
			// What the agents did is counted by folder, not by route.
			d.addReportLocked(a.folder, a.runtime, a.workflow, "", a.hour, wire.UsageRollupRow{Counts: a.counts})
		}
	}
	d.reportLocked().EventsSeen = last
	d.reportChangedLocked()
}

// agentBranches is each branch an agent here works in, the newest agent's.
func (d *Daemon) agentBranches() map[string]*wire.Agent {
	out := map[string]*wire.Agent{}
	for _, a := range d.Store.Agents() {
		if a.Worktree == nil || a.Worktree.Branch == nil || *a.Worktree.Branch == "" {
			continue
		}
		if had := out[*a.Worktree.Branch]; had == nil || a.CreatedAt > had.CreatedAt {
			a := a
			out[*a.Worktree.Branch] = &a
		}
	}
	return out
}
