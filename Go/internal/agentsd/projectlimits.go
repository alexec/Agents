package agentsd

import (
	"encoding/json"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// The helper limits count across the project (#3281, specs/3273-project-unit "Lane limits
// per project"). Helpers running, not archived and queued count in every folder of the
// project: this machine's own folders of it, from the store, and the person's other
// machines, through the control plane (machines/projectSessions). A machine that cannot
// reach the control plane counts this machine's folders alone, and says so. A lead does
// not count; its lanes do. A folder in no project counts on its own, as before.

const (
	// projectCountFresh is how long the other machines' count is used before it is asked
	// again (projectSessionsAsk bounds one ask).
	projectCountFresh = 15 * time.Second
	// projectQueueEvery is how often a queue in a project looks again for a place another
	// machine freed.
	projectQueueEvery = 30 * time.Second
)

// projectCount is the helpers of a project on the person's other machines, as last heard.
type projectCount struct {
	at time.Time
	// helpers are those started by an agent, not archived and not a lead; queued are those
	// waiting for a place. Each title says its machine.
	helpers, queued []wire.Agent
	// counted is false when the control plane did not answer: this machine counts alone.
	// unreached is the machines it did not hear from, whose helpers are not in it.
	counted   bool
	unreached []string
}

type projectCounts struct {
	mu     sync.Mutex
	asking map[string]*sync.Mutex
	last   map[string]projectCount
}

// isLead says a is a lead (#3265), which counts in no limit.
func isLead(a *wire.Agent) bool {
	return slices.ContainsFunc(a.Labels, func(l wire.SessionLabel) bool { return l.Value == "lead" })
}

// limitScope is what folder's helper limits count in: its project, or the folder alone.
func limitScope(folder string) string {
	if p := projectOfFolder(folder); p != "" {
		return "project:" + p
	}
	return folder
}

// inLimitScope says a counts in folder's limits: in folder, or in another folder here of
// folder's project. projects keeps each folder read once.
func inLimitScope(folder, project string, projects projectsOfFolders, a *wire.Agent) bool {
	if f := folderPath(a); f == folder {
		return true
	}
	return project != "" && projects.of(a) == project
}

// scopeTitle is "This project" for a folder in one, else "This folder".
func scopeTitle(folder string) string {
	w := scopeWords(folder)
	return strings.ToUpper(w[:1]) + w[1:]
}

// projectCountOf is the other machines' helpers of folder's project, as last heard; ok is
// false for a folder in no project, or a machine on no control plane. It never asks.
func (d *Daemon) projectCountOf(folder string) (c projectCount, ok bool) {
	project := projectOfFolder(folder)
	if project == "" || d.askControl.Load() == nil {
		return projectCount{}, false
	}
	d.projectCounts.mu.Lock()
	defer d.projectCounts.mu.Unlock()
	c, heard := d.projectCounts.last[project]
	return c, heard
}

// countProject asks the control plane for the other machines' helpers of folder's project
// when the last count is older than projectCountFresh. Call it before counting, never with
// queueMu held: it can wait up to projectSessionsAsk.
func (d *Daemon) countProject(folder string) {
	project := projectOfFolder(folder)
	if project == "" || d.askControl.Load() == nil {
		return
	}
	d.projectCounts.mu.Lock()
	if d.projectCounts.asking == nil {
		d.projectCounts.asking, d.projectCounts.last = map[string]*sync.Mutex{}, map[string]projectCount{}
	}
	one := d.projectCounts.asking[project]
	if one == nil {
		one = &sync.Mutex{}
		d.projectCounts.asking[project] = one
	}
	d.projectCounts.mu.Unlock()
	// One ask at a time for a project; those behind it take its answer.
	one.Lock()
	defer one.Unlock()
	d.projectCounts.mu.Lock()
	last, heard := d.projectCounts.last[project]
	d.projectCounts.mu.Unlock()
	if heard && time.Since(last.at) < projectCountFresh {
		return
	}
	c := projectCount{at: time.Now()}
	if sessions, unreached, err := d.projectSessionsElsewhere("", project, false); err == nil {
		c.counted = true
		for _, m := range unreached {
			c.unreached = append(c.unreached, m.MachineName)
		}
		for _, s := range sessions {
			a := s.Session
			if a.StartedByAgent == nil || a.State == wire.AgentStateArchived || isLead(&a) {
				continue
			}
			title := "Untitled"
			if a.Title != nil {
				title = *a.Title
			}
			title += " (on " + s.MachineName + ")"
			a.Title = &title
			if a.State == wire.AgentStateQueued {
				c.queued = append(c.queued, a)
			} else {
				c.helpers = append(c.helpers, a)
			}
		}
	}
	d.projectCounts.mu.Lock()
	d.projectCounts.last[project] = c
	d.projectCounts.mu.Unlock()
}

// projectSessionsElsewhere is machines/projectSessions for project, without this machine's
// own sessions, which its store lists.
func (d *Daemon) projectSessionsElsewhere(caller wire.UUID, project string, includeArchived bool) (sessions []wire.ProjectSession, unreached []wire.ProjectMachine, err error) {
	out, err := d.askWorkspacesPatient(caller, projectSessionsMethod,
		wire.ProjectSessionsRequest{Project: project, IncludeArchived: &includeArchived}, projectSessionsAsk)
	if err != nil {
		return nil, nil, err
	}
	var listed wire.ProjectSessions
	if json.Unmarshal(out, &listed) != nil {
		return nil, nil, &Error{Code: wire.FailureNotSupported, Message: "the control plane's answer could not be read"}
	}
	here := d.controlMachine()
	for _, s := range listed.Sessions {
		if !strings.EqualFold(string(s.Machine), here) {
			sessions = append(sessions, s)
		}
	}
	for _, m := range listed.Unreached {
		if !strings.EqualFold(string(m.Machine), here) {
			unreached = append(unreached, m)
		}
	}
	return sessions, unreached, nil
}

// countedHereWords is what helperPlaces adds when folder's project could not be counted on
// the other machines: the count is this machine's alone.
func (d *Daemon) countedHereWords(folder string) string {
	c, ok := d.projectCountOf(folder)
	switch {
	case !ok:
		return ""
	case !c.counted:
		return " (counted on this machine only: the control plane did not answer, so the project's other machines are not in it)"
	case len(c.unreached) > 0:
		return " (" + strings.Join(c.unreached, ", ") + " did not answer, so its helpers are not in it)"
	}
	return ""
}

// checkProjectQueues looks again, every projectQueueEvery, at each queue of a folder in a
// project, for a place another machine freed: this machine hears of no end there.
func (d *Daemon) checkProjectQueues() {
	safe.Go("project queues", func() {
		tick := time.NewTicker(projectQueueEvery)
		defer tick.Stop()
		for {
			select {
			case <-d.ctx.Done():
				return
			case <-tick.C:
				if d.askControl.Load() == nil {
					continue
				}
				seen := map[string]bool{}
				for _, a := range d.Store.Agents() {
					if f := folderPath(&a); a.State == wire.AgentStateQueued && !seen[f] && projectOfFolder(f) != "" {
						seen[f] = true
						d.checkQueueSoon(f)
					}
				}
			}
		}
	})
}
