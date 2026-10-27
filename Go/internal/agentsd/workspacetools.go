package agentsd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/wire"
)

// The app's workspace tools for agents (#691 US6, #1444), as DaemonCore+WorkspaceTools: list,
// start, stop, make and delete, relayed to this host's control plane on channel 0 as
// host/machines, which answers them as a client's request would be. Making and deleting
// ask the person first, on the agent's question card, and do nothing without a yes (FR-051).

// What an agent may ask of the control plane through host/machines.
const (
	machinesForAgent   = "machines/forAgent"
	hostsStart         = "hosts/start"
	hostsStop          = "hosts/stop"
	providersCreate    = "providers/create"
	hostsDeleteMachine = "hosts/deleteMachine"
)

// askControl is a request of the control plane on channel 0, and its answer.
type askControl = func(ctx context.Context, method string, params any) (json.RawMessage, error)

// SetControlAsk is how this host asks its control plane something (host/machines): the
// uplink's Ask. Not set off a control plane.
func (d *Daemon) SetControlAsk(ask askControl) {
	if ask == nil {
		d.askControl.Store(nil)
		return
	}
	d.askControl.Store(&ask)
}

// askWorkspaces is one host/machines call for an agent, named for the control plane's log.
func (d *Daemon) askWorkspaces(agent wire.UUID, method string, params any) (json.RawMessage, error) {
	ask := d.askControl.Load()
	if ask == nil {
		return nil, &Error{Code: wire.FailureNotSupported, Message: "This machine isn’t on a control plane, so it has no machines."}
	}
	p, _ := json.Marshal(params)
	out, err := (*ask)(d.ctx, "host/machines", wire.MachineWorkspaceCall{Agent: d.agentWho(agent), Method: method, Params: json.RawMessage(p)})
	var refused *controllink.AskError
	if errors.As(err, &refused) {
		return nil, &Error{Code: refused.Code, Message: refused.Message}
	}
	if err != nil {
		return nil, &Error{Code: wire.FailureNotSupported, Message: "Nothing was done: " + err.Error() + "."}
	}
	return out, nil
}

func (d *Daemon) agentWorkspaces(agent wire.UUID) (wire.AgentMachines, error) {
	var listed wire.AgentMachines
	out, err := d.askWorkspaces(agent, machinesForAgent, map[string]any{})
	if err != nil {
		return listed, err
	}
	if err := json.Unmarshal(out, &listed); err != nil {
		return listed, &Error{Code: wire.FailureNotSupported, Message: "Nothing was done: the control plane's answer could not be read."}
	}
	return listed, nil
}

func named(args map[string]json.RawMessage, key, what string) (string, error) {
	if v := strings.TrimSpace(argString(args, key)); v != "" {
		return v, nil
	}
	return "", Invalid("Nothing was done: say which %s.", what)
}

// listMachines is list_machines.
func (d *Daemon) listMachines(agent wire.UUID, _ map[string]json.RawMessage) (string, error) {
	listed, err := d.agentWorkspaces(agent)
	if err != nil {
		return "", err
	}
	return workspacesNote(listed), nil
}

// startMachine is start_machine.
func (d *Daemon) startMachine(agent wire.UUID, args map[string]json.RawMessage) (string, error) {
	host, err := named(args, "host", "host")
	if err != nil {
		return "", err
	}
	out, err := d.askWorkspaces(agent, hostsStart, map[string]any{"host": host})
	if err != nil {
		return "", err
	}
	var row struct {
		State string `json:"state"`
	}
	if json.Unmarshal(out, &row) == nil && row.State == "online" {
		return host + " is running already.", nil
	}
	d.earnNow(firstCloudHost)
	return "Starting " + host + ". It is up when it connects: wait for the server.online event " +
		"(with wait_for_event) before you start anything there.", nil
}

// stopMachine is stop_machine.
func (d *Daemon) stopMachine(agent wire.UUID, args map[string]json.RawMessage) (string, error) {
	host, err := named(args, "host", "host")
	if err != nil {
		return "", err
	}
	params := map[string]any{"host": host}
	var confirm bool
	if json.Unmarshal(args["confirm_running"], &confirm) == nil && confirm {
		params["confirmRunning"] = true
	}
	if _, err := d.askWorkspaces(agent, hostsStop, params); err != nil {
		return "", err
	}
	return "Stopping " + host + ".", nil
}

// makeMachine is make_machine.
func (d *Daemon) makeMachine(agent wire.UUID, args map[string]json.RawMessage) (string, error) {
	given, err := named(args, "provider", "provider")
	if err != nil {
		return "", err
	}
	name, err := named(args, "name", "name for the new machine")
	if err != nil {
		return "", err
	}
	// Checked before the card: the person is never asked about what can't be done (#855).
	listed, err := d.agentWorkspaces(agent)
	if err != nil {
		return "", err
	}
	found := workspaceProvider(given, listed)
	if found == nil {
		return "", Invalid("Nothing was made: %s", noProvider(given, listed))
	}
	if !found.CanMake {
		return "", Invalid("Nothing was made: %s can’t make machines.", found.Name)
	}
	for _, w := range found.Workspaces {
		if strings.EqualFold(w.Name, name) {
			return "", Invalid("Nothing was made: %s has a machine called %s already.", found.Name, name)
		}
	}
	var options map[string]json.RawMessage
	json.Unmarshal(args["options"], &options)
	keys := make([]string, 0, len(options))
	for k := range options {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var choices []string
	for _, k := range keys {
		var s string
		if json.Unmarshal(options[k], &s) != nil {
			s = string(options[k])
		}
		choices = append(choices, k+" "+s)
	}
	question := "Make a new machine, " + name + ", at " + found.Name
	if len(choices) > 0 {
		question += " (" + strings.Join(choices, ", ") + ")"
	}
	yes, err := d.personSaysYes(agent, d.agentWho(agent)+" wants to make a machine", question+"?", "Make it")
	if err != nil {
		return "", err
	}
	if !yes {
		return "Nothing was made: the person said no, or didn’t answer.", nil
	}
	params := map[string]any{"id": found.ID, "name": name}
	if len(args["options"]) > 0 && string(args["options"]) != "null" {
		params["options"] = args["options"]
	}
	out, err := d.askWorkspaces(agent, providersCreate, params)
	if err != nil {
		return "", err
	}
	var made wire.ProviderCreated
	json.Unmarshal(out, &made)
	if made.Joining {
		return "Made " + made.Workspace.Name + ". It joins as the host " + made.Workspace.Name + " on its first boot: wait for server.online.", nil
	}
	return "Made " + made.Workspace.Name + ". It can’t install Agents on its first boot, so the person adds it from " +
		"Settings ▸ Machine Providers with Add as Machine….", nil
}

// deleteMachine is delete_machine.
func (d *Daemon) deleteMachine(agent wire.UUID, args map[string]json.RawMessage) (string, error) {
	given, err := named(args, "host", "host")
	if err != nil {
		return "", err
	}
	listed, err := d.agentWorkspaces(agent)
	if err != nil {
		return "", err
	}
	var provider *wire.AgentMachinesProvider
	host := ""
	for i := range listed.Providers {
		for _, w := range listed.Providers[i].Workspaces {
			if provider == nil && w.Host != nil && strings.EqualFold(*w.Host, given) {
				provider, host = &listed.Providers[i], *w.Host
			}
		}
	}
	if provider == nil {
		return "", &Error{Code: wire.FailureNoSuchHost,
			Message: "Nothing was deleted: no machine provider has a machine called " + given + ". list_machines names the ones that do."}
	}
	if !provider.CanDelete {
		return "", Invalid("Nothing was deleted: %s runs on %s, which can’t delete machines.", host, provider.Name)
	}
	yes, err := d.personSaysYes(agent, d.agentWho(agent)+" wants to delete a machine",
		"Delete the machine "+host+" runs on, with everything on its disk, and remove the machine "+host+" with its agents?", "Delete it")
	if err != nil {
		return "", err
	}
	if !yes {
		return "Nothing was deleted: the person said no, or didn’t answer.", nil
	}
	if _, err := d.askWorkspaces(agent, hostsDeleteMachine, map[string]any{"host": host}); err != nil {
		return "", err
	}
	return "Deleted the machine " + host + " ran on, and removed the machine.", nil
}

// agentWho is an agent as the control plane's log and the card name it: "Claude (fix-login)".
func (d *Daemon) agentWho(agent wire.UUID) string {
	a := d.Store.Agent(agent)
	if a == nil {
		return "An agent"
	}
	who := a.RuntimeID
	if r := runtimeByID(a.RuntimeID); r != nil {
		who = r.Name
	}
	if a.Title != nil && *a.Title != "" {
		who += " (" + *a.Title + ")"
	}
	return who
}

// personSaysYes is one yes-or-no question on the agent's card; true only for the yes.
func (d *Daemon) personSaysYes(agent wire.UUID, title, question, yes string) (bool, error) {
	q, _ := json.Marshal([]map[string]any{{"id": "go", "prompt": question,
		"options": []map[string]string{{"id": "yes", "label": yes}, {"id": "no", "label": "Don’t"}}}})
	t, _ := json.Marshal(title)
	note, err := d.askQuestion(agent, map[string]json.RawMessage{"title": t, "questions": q})
	if err != nil {
		return false, err
	}
	return strings.Contains(note, ": "+yes), nil
}

// workspaceProvider is the provider an agent named, by id or by name.
func workspaceProvider(given string, listed wire.AgentMachines) *wire.AgentMachinesProvider {
	for i := range listed.Providers {
		if string(listed.Providers[i].ID) == given {
			return &listed.Providers[i]
		}
	}
	for i := range listed.Providers {
		if strings.EqualFold(listed.Providers[i].Name, given) {
			return &listed.Providers[i]
		}
	}
	return nil
}

func noProvider(given string, listed wire.AgentMachines) string {
	if len(listed.Providers) == 0 {
		return "this control plane has no machine providers. The person adds them in Settings ▸ Machine Providers."
	}
	var names []string
	for _, p := range listed.Providers {
		names = append(names, p.Name)
	}
	return "no provider is called " + given + ". There are " + strings.Join(names, ", ") + "."
}

// workspacesNote is list_machines for an agent to read: each provider, its workspaces and
// their hosts, and what a new one takes.
func workspacesNote(listed wire.AgentMachines) string {
	if len(listed.Providers) == 0 {
		return "This control plane has no machine providers. The person adds them in Settings ▸ Machine Providers."
	}
	var lines []string
	for _, p := range listed.Providers {
		var can []string
		if p.CanMake {
			can = append(can, "can make machines (make_machine)")
		}
		if p.CanDelete {
			can = append(can, "can delete them")
		}
		line := fmt.Sprintf("%s (provider %s)", p.Name, p.ID)
		if len(can) > 0 {
			line += ": " + strings.Join(can, ", ")
		}
		lines = append(lines, line)
		if len(p.Workspaces) == 0 {
			lines = append(lines, "  no machines")
		}
		for _, w := range p.Workspaces {
			host := " — not a host"
			if w.Host != nil {
				state := "unknown"
				if w.HostState != nil {
					state = *w.HostState
				}
				host = " — host " + *w.Host + ", " + state
			}
			cost := ""
			if w.Cost != nil {
				cost = ", " + *w.Cost
			}
			lines = append(lines, "  - "+w.Name+": "+w.State+host+cost)
		}
		if p.CanMake && p.Options != nil {
			if b, err := json.Marshal(p.Options); err == nil && string(b) != "null" {
				lines = append(lines, "  New machine options (JSON Schema): "+string(b))
			}
		}
	}
	lines = append(lines, "Start or stop one by its host's name. Making and deleting ask the person first.")
	return strings.Join(lines, "\n")
}
