package providers

import (
	"encoding/json"
	"fmt"
	"strings"
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

// sessionCall is machines/sessionCall (#2927): an agent on fromName reads, messages, stops
// or archives a session it started on another machine, or asks how it stands. It goes as
// that machine's agents/fromStarter, which answers only the agent that started it; from
// says which, in the control plane's words.
func (p *Providers) sessionCall(fromName, agent string, params json.RawMessage, caller Caller) (any, error) {
	var request wire.MachineSessionCall
	if err := requireParams(params, &request, "MachineSessionCall", "host", "call"); err != nil {
		return nil, err
	}
	host, name := request.Host, request.Host
	if h := p.records.Host(host); h != nil {
		name = h.Name
	}
	call := request.Call
	call.From = wire.StartedFrom{Machine: fromName, Agent: call.From.Agent, Who: agent}
	if !p.router.Online(host) {
		return nil, fail(CodeHostOffline, "%s is offline.", name)
	}
	reply := p.router.DeliverKept(MethodAgentsFromStarter, rawOf(call), caller.Client, caller.Kind, host, time.Minute)
	if reply == nil {
		return nil, fail(CodeHostOffline, "%s did not answer.", name)
	}
	if reply.Error != nil {
		return nil, reply.Error
	}
	var out wire.SessionCallReply
	if json.Unmarshal(reply.Result, &out) != nil {
		return nil, fail(CodeHostOffline, "%s's answer could not be read.", name)
	}
	return out, nil
}

// sessionEnded is machines/sessionEnded (#2927): a session on fromName that an agent on
// another machine started has ended. That machine is told with agents/endedElsewhere,
// naming fromName as the session's machine; one offline is not, and finds out when its
// agent next asks.
func (p *Providers) sessionEnded(fromName string, params json.RawMessage, caller Caller) (any, error) {
	var ended wire.SessionEnded
	if err := requireParams(params, &ended, "SessionEnded", "machine", "session", "starter", "how"); err != nil {
		return nil, err
	}
	host := ""
	for _, h := range p.records.Hosts() {
		if h.ID == ended.Machine || strings.EqualFold(h.Name, ended.Machine) {
			host = h.ID
			break
		}
	}
	// Another user's machine is not there for this one (FR-038).
	if host == "" || p.hooks.OwnerOf(host) != caller.Person {
		return nil, fail(CodeNoSuchHost, "No machine is called %s.", ended.Machine)
	}
	ended.Machine = fromName
	if p.router.Online(host) {
		p.router.DeliverKept(MethodAgentsEndedThere, rawOf(ended), caller.Client, caller.Kind, host, time.Minute)
	}
	return map[string]any{}, nil
}

// sendFolder is machines/sendFolder: one step of an agent's start_session with send
// (#2929), which sends the branch it is on to another machine first, as the window's Send
// to ‹machine›… does: that machine's folders/receiveState, a part of a file with
// folders/receiveUpload, or folders/receive, which makes the copy. Or one step of its
// bring_back (#2947), the reverse, as Bring Back from ‹machine›… does: that machine's
// folders/sendFacts, folders/sendPack, which makes the bundle, or a part of it with
// folders/sendRead. Only an online machine takes it; nothing of a send is kept.
func (p *Providers) sendFolder(fromName, agent string, params json.RawMessage, caller Caller) (any, error) {
	var request wire.MachineFolderSend
	if err := requireParams(params, &request, "MachineFolderSend", "host"); err != nil {
		return nil, err
	}
	host, name := request.Host, request.Host
	if h := p.records.Host(host); h != nil {
		name = h.Name
	}
	var out wire.MachineFolderSent
	// Each step, and where its answer goes; an upload's answer is nothing.
	method, step, answer, patience := "", any(nil), any(nil), time.Minute
	steps := 0
	if request.State != nil {
		out.State = &wire.ReceiveState{}
		method, step, answer, steps = MethodReceiveState, request.State, out.State, steps+1
	}
	if request.Upload != nil {
		method, step, steps = MethodReceiveUpload, request.Upload, steps+1
	}
	if request.Receive != nil {
		// Fetching the bundle and checking out take a while on a large repository: as long
		// as the asking host waits (controllink's askWait).
		out.Folder = &wire.FolderSummary{}
		method, step, answer, steps, patience = MethodReceive, request.Receive, out.Folder, steps+1, 2*time.Minute
		p.log(fmt.Sprintf("workspace: agent %s on %s sends %s to %s", agent, fromName, request.Receive.Folder, name))
	}
	if request.Facts != nil {
		out.Facts = &wire.SendFacts{}
		method, step, answer, steps = MethodSendFacts, request.Facts, out.Facts, steps+1
	}
	if request.Pack != nil {
		// Making the bundle takes a while on a large repository, as a receive does.
		out.Pack = &wire.SendPack{}
		method, step, answer, steps, patience = MethodSendPack, request.Pack, out.Pack, steps+1, 2*time.Minute
		p.log(fmt.Sprintf("workspace: agent %s on %s brings back %s from %s", agent, fromName, request.Pack.Folder, name))
	}
	if request.Read != nil {
		out.Read = &wire.SendRead{}
		method, step, answer, steps = MethodSendRead, request.Read, out.Read, steps+1
	}
	if steps != 1 {
		return nil, invalid("Give exactly one of state, upload, receive, facts, pack and read.")
	}
	if !p.router.Online(host) {
		return nil, fail(CodeHostOffline, "%s is offline.", name)
	}
	reply := p.router.DeliverKept(method, rawOf(step), caller.Client, caller.Kind, host, patience)
	if reply == nil {
		return nil, fail(CodeHostOffline, "%s did not answer.", name)
	}
	if reply.Error != nil {
		return nil, reply.Error
	}
	if answer != nil && json.Unmarshal(reply.Result, answer) != nil {
		return nil, fail(CodeHostOffline, "%s's answer could not be read.", name)
	}
	return out, nil
}
