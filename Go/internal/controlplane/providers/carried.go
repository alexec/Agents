package providers

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/wire"
)

// Carried is a provider's connection through the machine that carries it (#3398): each
// call goes to that machine on its channel 0 as providers/carry, and the machine runs the
// provider's server with the secrets it keeps. The control plane has the record, never a
// secret. Secrets is only a draft's, or the ones an add or an update was given to check
// with: sent with each call, kept by neither side.
type Carried struct {
	Record ProviderRecord
	Router Router
	// Name is the carrying machine's name, for the words a failure is said in.
	Name    func(host string) string
	Secrets map[string]string
	Timing  CallTiming
}

// CarriedCreate is providers/carry's create result.
type CarriedCreate struct {
	Made *MachineInfo `json:"made,omitempty"`
	Runs bool         `json:"runs"`
}

// SSHResult is providers/ssh's result.
type SSHResult = wire.ProviderSSHResult

// carriedPatience is how long a call to the carrying machine is waited for: its own
// timeouts, and a minute more for its server to start.
func (c *Carried) patience() time.Duration {
	long := c.Timing.Long
	if long == 0 {
		long = StandardCalls.Long
	}
	return long + time.Minute
}

func (c *Carried) machine() string { return deref(c.Record.Machine) }

func (c *Carried) machineName() string {
	if c.Name != nil {
		if name := c.Name(c.machine()); name != "" {
			return name
		}
	}
	return "the machine that carries it"
}

// Ask is one ask of a provider's carrying machine: its result, or why it failed.
func Ask(router Router, host, name, method string, params any, patience time.Duration) (json.RawMessage, error) {
	if host == "" {
		return nil, providerFailure("It was added before providers ran on a machine: remove it, and add it again on one of your machines.")
	}
	if !router.Online(host) {
		return nil, providerFailure("%s, which carries it, is offline.", name)
	}
	raw := router.Ask(host, method, params, patience)
	if raw == nil {
		return nil, providerFailure("%s, which carries it, didn’t answer.", name)
	}
	var answer wire.ProviderCarried
	if json.Unmarshal(raw, &answer) != nil {
		return nil, providerFailure("%s, which carries it, answered with something this control plane can’t read.", name)
	}
	if answer.Error != nil {
		return nil, &ProviderFailure{*answer.Error}
	}
	return answer.Result, nil
}

func (c *Carried) call(call string, request wire.ProviderCarry, into any) error {
	record, err := json.Marshal(c.Record)
	if err != nil {
		return err
	}
	request.Provider, request.Record, request.Call = wire.ProviderID(c.Record.ID), record, call
	if len(c.Secrets) > 0 {
		request.Secrets = c.Secrets
	}
	result, err := Ask(c.Router, c.machine(), c.machineName(), wire.CallProvidersCarry.Name, request, c.patience())
	if err != nil || into == nil || len(result) == 0 {
		return err
	}
	if json.Unmarshal(result, into) != nil {
		return providerFailure("%s, which carries it, answered with something this control plane can’t read.", c.machineName())
	}
	return nil
}

func (c *Carried) Check() (Checked, error) {
	var out Checked
	err := c.call("check", wire.ProviderCarry{}, &out)
	return out, err
}

func (c *Carried) List() ([]MachineInfo, error) {
	var out []MachineInfo
	err := c.call("list", wire.ProviderCarry{}, &out)
	return out, err
}

func (c *Carried) Start(id string) (*MachineInfo, error) {
	var out *MachineInfo
	err := c.call("start", wire.ProviderCarry{Workspace: &id}, &out)
	return out, err
}

func (c *Carried) Stop(id string) (*MachineInfo, error) {
	var out *MachineInfo
	err := c.call("stop", wire.ProviderCarry{Workspace: &id}, &out)
	return out, err
}

func (c *Carried) Options() (any, error) {
	var out any
	err := c.call("options", wire.ProviderCarry{}, &out)
	return out, err
}

func (c *Carried) Create(name string, options any, firstBoot *string) (*MachineInfo, bool, error) {
	var out CarriedCreate
	err := c.call("create", wire.ProviderCarry{Name: &name, Options: rawOf(options), FirstBoot: firstBoot}, &out)
	return out.Made, out.Runs, err
}

func (c *Carried) Delete(id string) error {
	return c.call("delete", wire.ProviderCarry{Workspace: &id}, nil)
}

func (c *Carried) Tools() ([]any, error) {
	var out []any
	err := c.call("tools", wire.ProviderCarry{}, &out)
	return out, err
}

// End leaves the server running on its machine: the next call uses it.
func (c *Carried) End() {}

// carrier is the machine that carries the provider an add or an update makes (#3398): the
// one it names, else the one it had, else the caller's first online machine, by name. It
// is the caller's own, online, and new enough to carry one.
func (p *Providers) carrier(request ProviderAdd, before *ProviderRecord, caller Caller) (string, error) {
	machine := string(deref(request.Machine))
	if machine == "" && before != nil {
		machine = deref(before.Machine)
	}
	if machine == "" {
		var mine []records.MachineRecord
		for _, h := range p.records.Hosts() {
			if p.hooks.OwnerOf(h.ID) == caller.Person && p.router.Online(h.ID) &&
				p.router.HostCan(h.ID, wire.CapProvidersCarry1) {
				mine = append(mine, h)
			}
		}
		if len(mine) == 0 {
			return "", invalid("Choose one of your machines to carry it: its server runs there, with its secrets. None of yours is online.")
		}
		sort.Slice(mine, func(i, j int) bool { return mine[i].Name < mine[j].Name })
		machine = mine[0].ID
	}
	h := p.records.Host(machine)
	if h == nil || p.hooks.OwnerOf(machine) != caller.Person {
		return "", invalid("No machine of yours is called %s.", machine)
	}
	if !p.router.Online(machine) {
		return "", invalid("%s is offline: choose a machine that is online to carry it.", h.Name)
	}
	if !p.router.HostCan(machine, wire.CapProvidersCarry1) {
		return "", invalid("%s can’t carry a provider: update Agents on it first.", h.Name)
	}
	return machine, nil
}

// hostName is a host's name, or its id when it has gone.
func (p *Providers) hostName(host string) string {
	if h := p.records.Host(host); h != nil {
		return h.Name
	}
	return host
}

// forget tells a removed or moved provider's machine to end its server and delete its
// secrets. An offline machine keeps them until the provider is added there again or they
// are deleted by hand: said in the log.
func (p *Providers) forget(record ProviderRecord) {
	machine := deref(record.Machine)
	if machine == "" {
		return
	}
	go func() {
		if _, err := Ask(p.router, machine, p.hostName(machine), wire.CallProvidersForget.Name,
			wire.ProviderForget{Provider: wire.ProviderID(record.ID)}, time.Minute); err != nil {
			p.log(fmt.Sprintf("provider: %s's secrets stay on %s: %s", record.ID, p.hostName(machine), errorWords(err)))
		}
	}()
}

// carriedCodespace is the codespaces-api provider a link's workspace is from, when a
// machine carries it and destination is the codespace's (#3347): its token is there, so
// gh runs there.
func (p *Providers) carriedCodespace(link WorkspaceLink, destination string) *ProviderRecord {
	if !strings.HasPrefix(SSHDestination(destination), "cs.") {
		return nil
	}
	p.mu.Lock()
	held, ok := p.providers[link.Provider]
	p.mu.Unlock()
	if !ok || held.record.preset() != "codespaces-api" || deref(held.record.Machine) == "" {
		return nil
	}
	r := held.record
	return &r
}

// sshStart starts a host's agentsd over ssh: from the machine that carries its codespace's
// provider, with the token there, else as the control plane's SSHStart does.
func (p *Providers) sshStart(host records.MachineRecord, link WorkspaceLink, destination string, renew bool) error {
	r := p.carriedCodespace(link, destination)
	if r == nil {
		return p.hooks.SSHStart(host, destination, renew)
	}
	known := ""
	if l := LinkOf(&host); l != nil {
		known = l.KnownHosts
	}
	_, err := Ask(p.router, *r.Machine, p.hostName(*r.Machine), wire.CallProvidersSSH.Name, wire.ProviderSSH{
		Provider: wire.ProviderID(r.ID), Op: "start", Destination: destination, Codespace: &link.Workspace,
		KnownHosts: &known, Name: &host.Name}, p.timing.Calls.Long+time.Minute)
	return err
}

// hostKey is the host key to keep on a link: read from the machine that carries its
// codespace's provider, else as the control plane's HostKey reads it.
func (p *Providers) hostKey(host string, link WorkspaceLink, destination, trust string) (string, string, error) {
	r := p.carriedCodespace(link, destination)
	if r == nil {
		return p.hooks.HostKey(host, SSHDestination(destination), trust)
	}
	raw, err := Ask(p.router, *r.Machine, p.hostName(*r.Machine), wire.CallProvidersSSH.Name, wire.ProviderSSH{
		Provider: wire.ProviderID(r.ID), Op: "hostKey", Destination: destination, Codespace: &link.Workspace,
		Trust: &trust}, time.Minute+p.timing.Calls.Quick)
	if err != nil {
		return "", "", err
	}
	var result SSHResult
	json.Unmarshal(raw, &result)
	return deref(result.KnownHosts), deref(result.NeedsTrust), nil
}
