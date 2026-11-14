package controlplane

import (
	"encoding/json"
	"strings"

	"github.com/agentloops-dev/agents/Go/internal/controlplane/records"
	"github.com/agentloops-dev/agents/Go/wire"
)

// Connect to Another… from a client of the control plane on this Mac (#4257). The switch
// stops this control plane and changes this Mac's launch agents, which only the window on
// this Mac does (#4228, HostModel.joinElsewhere). So the control plane tells the person's
// Mac windows control/connectWanted, and the one whose Mac runs it does it and reports each
// step with control/connectReport, which the person's clients hear as control/connectReported.
func (m *Methods) connectAnotherMethod(method string, params json.RawMessage, from Caller) (any, error) {
	person := m.callerPerson(from)
	switch method {
	case "control/connectAnother":
		request, err := require[wire.ConnectAnotherRequest](params, "ConnectAnotherRequest")
		if err != nil {
			return nil, err
		}
		if !m.s.isAdmin(person) {
			return nil, fail(notPermitted, "Only an admin can connect this Mac to another control plane.")
		}
		// Only a control plane that Agents on a Mac started reads its host's join file.
		if m.s.cfg.HostJoinFile == "" {
			return nil, fail(notSupported, "This control plane isn’t run by Agent Loops on a Mac, so there is nothing here to connect.")
		}
		hosted := request.Hosted != nil && *request.Hosted
		code := ""
		if request.Code != nil {
			code = strings.TrimSpace(*request.Code)
		}
		if hosted == (code != "") {
			return nil, fail(invalidParams, "Ask with a client code or for agentloops.dev, not both.")
		}
		want := wire.ConnectAnotherRequest{}
		if hosted {
			want.Hosted = &hosted
		} else {
			want.Code = &code
		}
		if m.router.TellPersonClients(person, wire.NotifyControlConnectWanted.Name, want, m.isMacWindow) == 0 {
			return nil, fail(hostOffline, "Agent Loops isn’t open on this Mac. Open it, then try again.")
		}
		return wire.Empty{}, nil
	case "control/connectReport":
		report, err := require[wire.ConnectReport](params, "ConnectReport")
		if err != nil {
			return nil, err
		}
		if !m.isMacWindow(from.Client) {
			return nil, fail(notPermitted, "Only Agent Loops on a Mac reports a connect.")
		}
		m.router.TellPerson(person, wire.NotifyControlConnectReported.Name, report)
		return wire.Empty{}, nil
	}
	return nil, notFound(method)
}

// isMacWindow says whether a client is a Mac's window, not a browser or a device.
func (m *Methods) isMacWindow(client string) bool {
	c := m.records.Client(client)
	return c != nil && c.Kind == records.KindMac
}
