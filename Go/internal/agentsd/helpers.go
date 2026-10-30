package agentsd

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// The sessions an agent started (028, #940), as DaemonCore+Helpers keeps them on the Swift
// host: counted against the folder's helper limits, and stopped or archived only by the
// agents above them.

const (
	defaultHelpersRunning     = 3
	defaultHelpersNotArchived = 5
	defaultHelpersQueued      = 5
)

// helperLimitsIn is the folder's limits as enforced: each the person's, or its default.
func (d *Daemon) helperLimitsIn(folder string) (running, notArchived, queued int64) {
	running, notArchived, queued = defaultHelpersRunning, defaultHelpersNotArchived, defaultHelpersQueued
	if s, ok := d.summaryFor(folder); ok && s.Folder.HelperLimits != nil {
		l := s.Folder.HelperLimits
		if l.Running != nil {
			running = *l.Running
		}
		if l.NotArchived != nil {
			notArchived = *l.NotArchived
		}
		if l.Queued != nil {
			queued = *l.Queued
		}
	}
	// The organisation's caps over the folder's own (#998): the lower number is used.
	running, notArchived, _ = d.helperCaps(running, notArchived)
	return
}

// helpersIn is HelperLimit.helpers: started by an agent, not archived, not queued, oldest first.
// The ones its agents started on other machines count here too (#2927).
func (d *Daemon) helpersIn(folder string) []wire.Agent {
	out := d.thereAgents(folder)
	for _, a := range d.Store.Agents() {
		if a.StartedByAgent != nil && a.State != wire.AgentStateArchived && a.State != wire.AgentStateQueued && folderPath(&a) == folder {
			out = append(out, a)
		}
	}
	return sortedByAge(out)
}

// helperQueue is HelperLimit.queue: the queued, first in first.
func (d *Daemon) helperQueue(folder string) []wire.Agent {
	var out []wire.Agent
	for _, a := range d.Store.Agents() {
		if a.State == wire.AgentStateQueued && folderPath(&a) == folder {
			out = append(out, a)
		}
	}
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].CreatedAt != out[j].CreatedAt {
			return out[i].CreatedAt < out[j].CreatedAt
		}
		return out[i].ID < out[j].ID
	})
	return out
}

// helperRunning is HelperLimit.isRunning: holding a running place.
func helperRunning(a *wire.Agent) bool {
	if a.State == wire.AgentStateArchived || a.ArchiveRequest != nil && a.ArchiveRequest.Requested != nil {
		return false
	}
	if inFlight(a.State) {
		return true
	}
	return a.EventWait != nil && a.EventWait.Ending == nil
}

func (d *Daemon) runningHelpers(folder string) []wire.Agent {
	var out []wire.Agent
	for _, a := range d.helpersIn(folder) {
		if helperRunning(&a) {
			out = append(out, a)
		}
	}
	return out
}

// helperPlaces is "1 of 3 running, 2 of 5 not archived", and the queue once there is one.
func (d *Daemon) helperPlaces(folder string) string {
	running, notArchived, queued := d.helperLimitsIn(folder)
	s := fmt.Sprintf("%d of %d running, %d of %d not archived", len(d.runningHelpers(folder)), running, len(d.helpersIn(folder)), notArchived)
	if q := len(d.helperQueue(folder)); q > 0 {
		s += fmt.Sprintf(", %d of %d queued", q, queued)
	}
	return s
}

// starters is the chain of agents above one: who started it, who started that, and on. A
// session a workflow started on manage_workflows run counts the session that ran it (#1730).
func (d *Daemon) starters(a *wire.Agent) []wire.UUID {
	var chain []wire.UUID
	seen := map[wire.UUID]bool{a.ID: true}
	above := func(a *wire.Agent) *wire.UUID {
		if a.StartedByAgent != nil {
			return a.StartedByAgent
		}
		return d.ranBy(a)
	}
	next := above(a)
	for next != nil && !seen[*next] {
		seen[*next] = true
		chain = append(chain, *next)
		if s := d.Store.Agent(*next); s != nil {
			next = above(s)
		} else {
			next = nil
		}
	}
	return chain
}

// helperTarget is the session an agent may stop or archive: one it, or one below it, started.
func (d *Daemon) helperTarget(caller, target wire.UUID, verb string) (*wire.Agent, error) {
	if d.Store.Agent(caller) == nil {
		return nil, &Error{Code: CodeNoSuchAgent, Message: "That conversation is not open any more, so nothing was changed."}
	}
	t := d.Store.Agent(target)
	if t == nil {
		return nil, &Error{Code: CodeNoSuchAgent, Message: "Nothing changed: there is no agent with that id."}
	}
	if t.ID == caller {
		if verb == "request" {
			return nil, &Error{Code: wire.FailureNotYours, Message: "Nothing changed: to ask to be archived yourself, call archive_session with no id."}
		}
		return nil, &Error{Code: wire.FailureNotYours, Message: "Nothing changed: an agent cannot " + verb + " itself."}
	}
	mine := false
	for _, s := range d.starters(t) {
		mine = mine || s == caller
	}
	if !mine {
		whose := "that is one of the person's own sessions"
		if t.StartedByAgent != nil {
			whose = "another agent started that one"
		} else if t.StartedByWorkflow != nil {
			whose = "a workflow started that one, and you did not run it"
		}
		return nil, &Error{Code: wire.FailureNotYours, Message: "Nothing changed: " + whose +
			". You can only stop or archive sessions you started (also with manage_workflows run) and the sessions they started."}
	}
	if t.State == wire.AgentStateArchived {
		return nil, &Error{Code: wire.FailureNotYours, Message: "Nothing changed: " + quotedTitle(t.Title) + " is already archived."}
	}
	return t, nil
}

func quotedTitle(t *string) string {
	if t == nil {
		return "“Untitled”"
	}
	return "“" + *t + "”"
}

// stopSession is stop_session: a helper stopped, freeing its running place.
func (d *Daemon) stopSession(caller wire.UUID, args map[string]json.RawMessage) (string, error) {
	id := wire.UUID(strings.ToUpper(strings.TrimSpace(argString(args, "id"))))
	if s := d.thereNamed(caller, string(id)); s != nil && d.Store.Agent(id) == nil {
		return d.thereOp(caller, s, "stop")
	}
	t, err := d.helperTarget(caller, id, "stop")
	if err != nil {
		return "", err
	}
	name, folder := quotedTitle(t.Title), folderPath(t)
	if t.State == wire.AgentStateQueued {
		d.change(t.ID, func(a *wire.Agent) {
			a.State, a.EndedReason = wire.AgentStateStopped, reason(wire.EndedReasonCancelled)
		})
		d.record(t.ID, stateChanged(wire.AgentStateStopped, reason(wire.EndedReasonCancelled)))
		d.agentEnded(t.ID)
		return "Took " + name + " off the queue; it will not start. This folder now has " + d.helperPlaces(folder) + ".", nil
	}
	if !d.stopHelper(t) {
		return name + " had already stopped; nothing changed.", nil
	}
	d.checkQueueSoon(folder)
	return "Stopped " + name + ", freeing its running place; it keeps its other place until it is archived. This folder now has " +
		d.helperPlaces(folder) + ".", nil
}

// stopHelper stops a session that is running, and waits a moment for its turn to end;
// false when it had already stopped.
func (d *Daemon) stopHelper(t *wire.Agent) bool {
	l := d.live(t.ID)
	l.mu.Lock()
	busy := l.running || l.inTurn
	l.mu.Unlock()
	if !inFlight(t.State) && !busy && (t.EventWait == nil || t.EventWait.Ending != nil) {
		return false
	}
	l.cancel()
	d.dropLeases(t.ID, "holderStopped")
	d.endWait(t.ID, "stopped", false)
	waitFor := func() bool {
		l.mu.Lock()
		defer l.mu.Unlock()
		return !l.running && !l.inTurn
	}
	for i := 0; i < 100 && !waitFor(); i++ {
		time.Sleep(50 * time.Millisecond)
	}
	return true
}

// requestArchiveHelper is archive_session with a helper's id: archived now when agents may
// archive it and it is not running, else it waits for the person's approval.
func (d *Daemon) requestArchiveHelper(caller, target wire.UUID) (string, error) {
	if s := d.thereNamed(caller, string(target)); s != nil && d.Store.Agent(target) == nil {
		return d.thereOp(caller, s, "archive")
	}
	t, err := d.helperTarget(caller, target, "request")
	if err != nil {
		return "", err
	}
	name, folder := quotedTitle(t.Title), folderPath(t)
	may := d.agentsMayArchive(folder)
	if may && !helperRunning(t) {
		d.archiveBy(t.ID, wire.AgentArchivedReasonByAgent)
		return "Archived " + name + ", freeing its place; the person can unarchive it. This folder now has " + d.helperPlaces(folder) + ".", nil
	}
	if r := t.ArchiveRequest; r != nil && r.Requested != nil {
		return name + " already waits for the person to approve archiving it; nothing changed.", nil
	} else if r != nil && r.WhenTurnEnds != nil {
		return name + " is already set to wait for approval when its turn ends; nothing changed.", nil
	}
	working := inFlight(t.State)
	d.requestArchive(t.ID)
	if working {
		if may {
			return name + " will be archived when its turn ends, if it ends done or with nothing to do; otherwise the person approves it. " +
				"Its running place frees then.", nil
		}
		return name + " will wait for the person to approve archiving it when its turn ends, freeing its running place then.", nil
	}
	return name + " now waits for the person to approve archiving it, which frees its running place; it keeps its other place until it is archived. " +
		"This folder now has " + d.helperPlaces(folder) + ".", nil
}
