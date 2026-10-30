package providers

import (
	"encoding/json"
	"fmt"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// MachineSessionStart is DaemonAPI.MachineSessionStart: machines/startSession (#2887).
type MachineSessionStart = wire.MachineSessionStart

// startSessionOn is machines/startSession (#2887): an agent on fromName asked, with
// start_session, for a session on another of its person's machines, which AgentCall has
// found by name and checked is theirs. It goes as that machine's own agents/start, and its
// chat names the agent and machine in the control plane's words, not the asking host's. A
// stopped workspace is kept for and started, as a client's start would be.
func (p *Providers) startSessionOn(fromName, agent string, params json.RawMessage, caller Caller) (any, error) {
	var request MachineSessionStart
	if err := requireParams(params, &request, "MachineSessionStart", "host", "start"); err != nil {
		return nil, err
	}
	host, name := request.Host, request.Host
	if h := p.records.Host(host); h != nil {
		name = h.Name
	}
	start := request.Start
	var asker wire.UUID
	if start.StartedFrom != nil {
		asker = start.StartedFrom.Agent
	}
	start.StartedFrom = &wire.StartedFrom{Machine: fromName, Agent: asker, Who: agent}
	p.log(fmt.Sprintf("workspace: agent %s on %s starts a session on %s", agent, fromName, name))
	if p.router.Online(host) {
		reply := p.router.DeliverKept(MethodAgentsStart, rawOf(start), caller.Client, caller.Kind, host, time.Minute)
		if reply == nil {
			return nil, fail(CodeHostOffline, "%s did not answer.", name)
		}
		if reply.Error != nil {
			return nil, reply.Error
		}
		var id wire.UUID
		if json.Unmarshal(reply.Result, &id) != nil || id == "" {
			return nil, fail(CodeHostOffline, "%s did not say which session it started.", name)
		}
		return id, nil
	}
	if kept := p.Kept(); kept != nil {
		if f := kept.Keep(host, MethodAgentsStart, rawOf(start), caller); f != nil {
			return nil, f
		}
	}
	return nil, fail(CodeHostOffline, "%s is offline.", name)
}
