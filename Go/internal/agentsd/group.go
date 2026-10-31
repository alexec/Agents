package agentsd

import "github.com/alexec/agents/Go/wire"

// waitingOnEvents is whether the agent has an open wait on something the app watches: an
// event (wait_for_event), or its place in a lease's line (#2361), which is the same wait.
// A turn that ends while this is open is not done: it is started again when the wait ends,
// so when-done: archive and a plain archive_session request must not archive it (#2911).
func waitingOnEvents(a *wire.Agent) bool {
	return a.EventWait != nil && a.EventWait.Ending == nil
}

// Group is the sidebar heading an agent is under (AgentGroup.init(for:…)), for a
// folder's counts.
func Group(a *wire.Agent) string {
	outcomeAsked := a.OutcomeAsked != nil && *a.OutcomeAsked
	waiting := waitingOnEvents(a)
	// A wait only the connected person can settle (#3051) needs them too, as a question
	// does: review.requested or issue.assigned today, waitForEvent sets ForPerson.
	forPerson := waiting && a.EventWait.ForPerson != nil && *a.EventWait.ForPerson
	wantsAnswer := a.Report != nil && needsAPerson(a.Report.Outcome) || forPerson
	switch a.State {
	case wire.AgentStateStarting:
		return "running"
	case wire.AgentStateWaitingOnUser:
		return "needsAttention"
	case wire.AgentStateRunning:
		if outcomeAsked {
			return settled(wantsAnswer || a.Report == nil, a.Report, waiting)
		}
		return "running"
	case wire.AgentStateFinished:
		return settled(wantsAnswer || (outcomeAsked && a.Report == nil), a.Report, waiting)
	case wire.AgentStateStopped:
		if a.EndedReason != nil {
			switch *a.EndedReason {
			case wire.EndedReasonCancelled, wire.EndedReasonStoppedByAgent, wire.EndedReasonStoppedByAdmin, wire.EndedReasonAllowanceSpent:
				return "stopped"
			}
		}
		return "needsAttention"
	case wire.AgentStateArchived:
		return "archived"
	case wire.AgentStateQueued:
		return "waiting"
	}
	return "stopped"
}

func needsAPerson(o wire.WorkOutcome) bool {
	switch o {
	// Only a question (#1916): the app never assumes an agent needs the person.
	case wire.WorkOutcomeNeedsAnswer:
		return true
	}
	return false
}

func settled(wantsAPerson bool, r *wire.WorkReport, waitingOnEvents bool) string {
	if wantsAPerson {
		return "needsAttention"
	}
	open := r != nil && r.Outcome == wire.WorkOutcomeWaiting && (r.Block == nil || r.Block.ClearedAt == nil)
	if open && r.Block != nil && (len(r.Block.Waits) > 0 || r.Block.CheckAgainAt != nil) || waitingOnEvents {
		return "waiting"
	}
	// A block with nothing the app watches (an old record's) is done, not Needs you (#1916).
	return "finished"
}
