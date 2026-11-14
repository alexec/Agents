package controlplane

import (
	"encoding/json"

	"github.com/agentloops-dev/agents/Go/wire"
)

// Move to Another Machine… and Run It Here Again… from any client of the person (#4255).
// The move runs `agents-control handover` with the control plane's key, which only the
// window on the Mac that holds it has, and it changes that Mac's launch agents. So this
// control plane holds no key for it and does no step itself (direction.md, principle 6): it
// tells the person's Mac windows control/planeMoveWanted, the window whose Mac it concerns
// does the step, and says how it stands with control/planeMoveReport, which the person's
// clients hear as control/planeMoveReported. After the move the copy elsewhere carries it on,
// so Run It Here Again… is asked of it in the same way.
func (m *Methods) planeMoveMethod(method string, params json.RawMessage, from Caller) (any, error) {
	person := m.callerPerson(from)
	switch method {
	case "control/planeMove":
		ask, err := require[wire.PlaneMoveAsk](params, "PlaneMoveAsk")
		if err != nil {
			return nil, err
		}
		if !m.s.isAdmin(person) {
			return nil, fail(notPermitted, "Only an admin can move the control plane.")
		}
		if m.router.TellPersonClients(person, wire.NotifyControlPlaneMoveWanted.Name, ask, m.isMacWindow) == 0 {
			return nil, fail(hostOffline, "Agents isn’t open on the Mac that moves the control plane. Open it, then try again.")
		}
		return wire.Empty{}, nil
	case "control/planeMoveReport":
		report, err := require[wire.PlaneMoveReport](params, "PlaneMoveReport")
		if err != nil {
			return nil, err
		}
		if !m.isMacWindow(from.Client) {
			return nil, fail(notPermitted, "Only Agents on a Mac reports a move of the control plane.")
		}
		m.router.TellPerson(person, wire.NotifyControlPlaneMoveReported.Name, report)
		return wire.Empty{}, nil
	}
	return nil, notFound(method)
}
