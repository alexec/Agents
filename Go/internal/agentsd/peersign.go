package agentsd

import (
	"encoding/json"
	"log"
	"os"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/machinelock"
	"github.com/alexec/agents/Go/wire"
)

// A machine's calls to another of its person's machines (#3492, specs/3399-machine-lock D7).
// An agent here that starts a session on another machine, calls the session it started,
// says one ended, or sends or brings back a folder, goes through the control plane
// (machine/machines). The other machine takes it only when a machine of the same lock signed
// it, so this machine writes what that machine is to get, in its own words, and signs it
// (MachineWorkspaceCall.deliver); the control plane delivers it as it is. With no lock here,
// nothing is signed and the control plane delivers its own words, as before.

// signedDelivery is the delivery for an agent's call, signed with this machine's key; nil
// for a call that goes to no other machine, or with no lock.
func (d *Daemon) signedDelivery(agent wire.UUID, method string, params any) *wire.LockDelivery {
	if _, pinned := d.heldLock(); !pinned {
		return nil
	}
	name, who := d.ownName(), d.agentWho(agent)
	var deliver string
	var out any
	switch p := params.(type) {
	case wire.MachineSessionStart:
		if method != sessionOnMachine {
			return nil
		}
		start := p.Start
		var asker wire.UUID
		if start.StartedFrom != nil {
			asker = start.StartedFrom.Agent
		}
		start.StartedFrom = &wire.StartedFrom{Machine: name, Agent: asker, Who: who}
		deliver, out = wire.CallAgentsStart.Name, start
	case wire.MachineSessionCall:
		call := p.Call
		call.From = wire.StartedFrom{Machine: name, Agent: call.From.Agent, Who: who}
		deliver, out = "agents/fromStarter", call
	case wire.SessionEnded:
		p.Machine = name
		deliver, out = "agents/endedElsewhere", p
	case wire.MachineFolderSend:
		switch {
		case p.State != nil:
			deliver, out = "folders/receiveState", p.State
		case p.Upload != nil:
			deliver, out = "folders/receiveUpload", p.Upload
		case p.Receive != nil:
			deliver, out = "folders/receive", p.Receive
		case p.Facts != nil:
			deliver, out = "folders/sendFacts", p.Facts
		case p.Pack != nil:
			deliver, out = "folders/sendPack", p.Pack
		case p.Read != nil:
			deliver, out = "folders/sendRead", p.Read
		case p.MoveIn != nil:
			in := *p.MoveIn
			in.From.Machine, in.From.Who = name, who
			deliver, out = wire.CallAgentsMoveIn.Name, in
		default:
			return nil
		}
	default:
		return nil
	}
	signer, err := d.machineSigner()
	if err != nil {
		log.Printf("lock: %s goes unsigned: %v", method, err)
		return nil
	}
	b, err := json.Marshal(out)
	if err != nil {
		return nil
	}
	sig, err := machinelock.SignRequest(signer, "", deliver, b, time.Now())
	if err != nil {
		return nil
	}
	return &wire.LockDelivery{Method: deliver, Params: string(b), Lock: sig}
}

// ownName is this machine's name as the person gave it in its join code, else its host name.
func (d *Daemon) ownName() string {
	if m, err := controllink.LoadMembership(d.Store.Loc.Root); err == nil && m.Name != "" {
		return m.Name
	}
	name, _ := os.Hostname()
	return name
}
