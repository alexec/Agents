package agentsd

import (
	"encoding/json"
	"strings"

	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// Archive requests (#584), as the Swift host settles them: archive_session with no id asks
// that this conversation wait for the person to approve archiving it once its turn ends;
// the ask goes only with the ending it was made about, and an ending that wants the person
// for something else takes it away. A helper whose starter may archive it is archived then
// instead, with nobody asked.

// goesWithRequest is AfterTurn.requestArchive.goes(with:).
func goesWithRequest(o wire.WorkOutcome) bool {
	return o == wire.WorkOutcomeDone || o == wire.WorkOutcomeNothingToDo || o == wire.WorkOutcomePartlyDone
}

// goesWithArchive is AfterTurn.archive.goes(with:).
func goesWithArchive(o wire.WorkOutcome) bool {
	return o == wire.WorkOutcomeDone || o == wire.WorkOutcomeNothingToDo
}

// agentsMayArchive is HelperLimits.agentsMayArchive: true unless the person said not.
func (d *Daemon) agentsMayArchive(folder string) bool {
	if s, ok := d.summaryFor(folder); ok && s.Project.HelperLimits != nil && s.Project.HelperLimits.AgentsMayArchive != nil {
		return *s.Project.HelperLimits.AgentsMayArchive
	}
	return true
}

// settleArchiveRequest is DaemonCore.move's archive request, on the record the turn's ending
// is being written to. It says whether a request was made now, and whether the agent is to
// be archived instead.
func (d *Daemon) settleArchiveRequest(a *wire.Agent, next wire.AgentState, why wire.EndedReason) (requested, archiveNow bool) {
	wasRequested := a.ArchiveRequest != nil && a.ArchiveRequest.Requested != nil
	endedAsAsked := next == wire.AgentStateFinished && why == wire.EndedReasonEndTurn && len(a.QueuedPrompts) == 0
	asked := false
	switch {
	case a.ArchiveRequest != nil && a.ArchiveRequest.WhenTurnEnds != nil:
		asked = true
	case a.AfterTurn != nil && *a.AfterTurn == wire.AfterTurnRequestArchive && endedAsAsked:
		asked = a.Report == nil || goesWithRequest(a.Report.Outcome)
	}
	wantsThePerson := a.Report != nil && next == wire.AgentStateFinished && !goesWithRequest(a.Report.Outcome)
	if a.Report == nil {
		wantsThePerson = Group(a) == "needsAttention"
	}
	switch {
	case wantsThePerson || next == wire.AgentStateStopped && Group(a) == "needsAttention":
		a.ArchiveRequest = nil
	case asked:
		if endedAsAsked && a.StartedByAgent != nil && a.Report != nil && goesWithArchive(a.Report.Outcome) &&
			d.agentsMayArchive(projectFolder(a)) {
			a.ArchiveRequest, archiveNow = nil, true
		} else if !wasRequested {
			a.ArchiveRequest = &wire.ArchiveRequest{Requested: &wire.ArchiveRequestRequested{At: now()}}
			requested = true
		}
	case a.ArchiveRequest != nil && a.ArchiveRequest.WhenTurnEnds != nil:
		a.ArchiveRequest = nil
	}
	a.AfterTurn = nil
	return requested, archiveNow
}

// afterArchiveRequest says what settleArchiveRequest did: asking to be put away is not
// waiting to be woken, and is an event; an agent archived on its word goes once its
// runtime is let go.
func (d *Daemon) afterArchiveRequest(id wire.UUID, requested, archiveNow bool) {
	a := d.Store.Agent(id)
	if a == nil {
		return
	}
	outcome := map[string]string{}
	if a.Report != nil {
		outcome["outcome"] = string(a.Report.Outcome)
	}
	if requested {
		d.endWait(id, "archiveRequested", false)
		d.raiseAgentEvent("agent.archive_requested", id, "asked to be archived.", outcome)
		d.reconsider()
	}
	if archiveNow {
		safe.Go("archive when done", func() {
			d.record(id, runtimeNote("Archived when it asked, as the agent that started it may archive it."))
			d.archiveBy(id, wire.AgentArchivedReasonByAgent)
		})
	}
}

// archiveSession is archive_session: with no id (or its own), this conversation asks to be
// archived once its turn ends. A helper's id is the helpers' call.
func (d *Daemon) archiveSession(caller wire.UUID, args map[string]json.RawMessage) (string, error) {
	if id := strings.TrimSpace(argString(args, "id")); id != "" && !strings.EqualFold(id, string(caller)) {
		return d.requestArchiveHelper(caller, wire.UUID(strings.ToUpper(id)))
	}
	a := d.Store.Agent(caller)
	if a == nil {
		return "", &Error{Code: CodeNoSuchAgent, Message: "That conversation is not open any more, so nothing was recorded."}
	}
	if w := a.EventWait; w != nil && w.Ending == nil {
		return "", Invalid("Nothing was recorded: you are waiting for %s, and a conversation asking to be archived is not waiting to be woken. Call cancel_wait first.", waitLabel(w))
	}
	after := wire.AfterTurnRequestArchive
	d.change(caller, func(a *wire.Agent) { a.AfterTurn = &after })
	note := "Once this turn ends, this conversation waits for the person to approve archiving it."
	if a.StartedByAgent != nil && d.agentsMayArchive(projectFolder(a)) {
		note = "Once this turn ends, this conversation will be archived if it ended done or with nothing to do, as nobody needs to approve it; " +
			"otherwise it waits for the person to approve archiving it."
	}
	return note + " Anything the person sends before then drops it.", nil
}

// requestArchive is DaemonCore.requestArchive: when its turn ends if it is working, now if not.
func (d *Daemon) requestArchive(id wire.UUID) {
	a := d.Store.Agent(id)
	if a == nil || a.State == wire.AgentStateArchived {
		return
	}
	working := inFlight(a.State)
	r := a.ArchiveRequest
	if r != nil && (r.Requested != nil || r.WhenTurnEnds != nil && working) {
		return
	}
	requested := false
	d.change(id, func(a *wire.Agent) {
		if working {
			a.ArchiveRequest = &wire.ArchiveRequest{WhenTurnEnds: &wire.ArchiveRequestWhenTurnEnds{Since: now()}}
		} else {
			a.ArchiveRequest = &wire.ArchiveRequest{Requested: &wire.ArchiveRequestRequested{At: now()}}
			requested = true
		}
	})
	d.afterArchiveRequest(id, requested, false)
}
