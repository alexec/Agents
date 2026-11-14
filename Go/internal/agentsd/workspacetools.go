package agentsd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"sort"
	"strings"
	"time"

	"github.com/agentloops-dev/agents/Go/internal/controllink"
	"github.com/agentloops-dev/agents/Go/internal/safe"
	"github.com/agentloops-dev/agents/Go/wire"
)

// The app's workspace tools for agents (#691 US6, #1444), as DaemonCore+WorkspaceTools: list,
// start, stop, make and delete, relayed to this host's control plane on channel 0 as
// machine/machines, which answers them as a client's request would be. Making and deleting
// ask the person first, on the agent's question card, and do nothing without a yes (FR-051).

// What an agent may ask of the control plane through machine/machines.
const (
	machinesForAgent   = "machines/forAgent"
	hostsStart         = "machines/start"
	hostsStop          = "machines/stop"
	providersCreate    = "providers/create"
	hostsDeleteMachine = "machines/deleteMachine"
)

// askControl is a request of the control plane on channel 0, and its answer.
type askControl = func(ctx context.Context, method string, params any) (json.RawMessage, error)

// SetControlAsk is how this host asks its control plane something (machine/machines): the
// uplink's Ask. Not set off a control plane.
func (d *Daemon) SetControlAsk(ask askControl) {
	if ask == nil {
		d.askControl.Store(nil)
		return
	}
	d.askControl.Store(&ask)
	// What ended on other machines while this one was away (#2927).
	safe.Go("ask how sessions elsewhere stand", d.askThereWaits)
}

// SetControlCapabilities is how this host reads what its control plane said it can do
// (#4100): the uplink's ControlCapabilities.
func (d *Daemon) SetControlCapabilities(list func() []string) {
	d.controlCapabilities.Store(&list)
}

// controlHas says whether the control plane said capability when this link came up, so a
// host asks an older one nothing it would refuse (#4100).
func (d *Daemon) controlHas(capability string) bool {
	list := d.controlCapabilities.Load()
	return list != nil && wire.Has((*list)(), capability)
}

// askWorkspaces is one machine/machines call for an agent, named for the control plane's log.
func (d *Daemon) askWorkspaces(agent wire.UUID, method string, params any) (json.RawMessage, error) {
	return d.askWorkspacesCtx(d.ctx, agent, method, params)
}

// askWorkspacesPatient is askWorkspaces that gives up after patience rather than waiting on
// d.ctx's own lifetime (P20261030-1): a status probe that must not keep list_sessions, or
// askThereWaits, waiting on one slow machine as long as the control plane itself would.
func (d *Daemon) askWorkspacesPatient(agent wire.UUID, method string, params any, patience time.Duration) (json.RawMessage, error) {
	ctx, cancel := context.WithTimeout(d.ctx, patience)
	defer cancel()
	return d.askWorkspacesCtx(ctx, agent, method, params)
}

func (d *Daemon) askWorkspacesCtx(ctx context.Context, agent wire.UUID, method string, params any) (json.RawMessage, error) {
	ask := d.askControl.Load()
	if ask == nil {
		return nil, &Error{Code: wire.FailureNotSupported, Message: "This machine isn’t on a control plane, so it has no machines."}
	}
	p, _ := json.Marshal(params)
	call := wire.MachineWorkspaceCall{Agent: d.agentWho(agent), Method: method, Params: json.RawMessage(p),
		Deliver: d.signedDelivery(agent, method, params)}
	out, err := (*ask)(ctx, "machine/machines", call)
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
	return d.agentWorkspacesWithin(agent, 0)
}

// cardCheckPatience is how long make_machine and delete_machine wait for the list they check
// before the card (#4986): the control plane asks every provider for its options, and a slow
// one (GitHub Codespaces) left the card no time inside the tool's limit.
var cardCheckPatience = 25 * time.Second

// agentWorkspacesWithin is agentWorkspaces that gives up after patience, or waits on d.ctx
// when it is 0.
func (d *Daemon) agentWorkspacesWithin(agent wire.UUID, patience time.Duration) (wire.AgentMachines, error) {
	var listed wire.AgentMachines
	var out json.RawMessage
	var err error
	if patience > 0 {
		out, err = d.askWorkspacesPatient(agent, machinesForAgent, map[string]any{}, patience)
	} else {
		out, err = d.askWorkspaces(agent, machinesForAgent, map[string]any{})
	}
	if err != nil {
		var refused *Error
		if patience > 0 && errors.As(err, &refused) && strings.Contains(refused.Message, context.DeadlineExceeded.Error()) {
			return listed, &Error{Code: wire.FailureNotSupported, Message: "Nothing was done, and the person was not asked: " +
				"the control plane did not list the machines within " + patience.String() + ". Call it again."}
		}
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
	note := workspacesNote(listed)
	// A make that waits for the person's yes is no machine yet, but it is on its way (#4986).
	for _, card := range d.cardsOpen(makeCardTitle) {
		note += "\nWaiting for the person's yes, on " + card.who + "'s card: " + card.question + " Do not ask again."
	}
	return note, nil
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
	since := time.Now()
	given, err := named(args, "provider", "provider")
	if err != nil {
		return "", err
	}
	// With no name, the control plane takes the person's next machine-N (#3972).
	name := strings.TrimSpace(argString(args, "name"))
	// Checked before the card: the person is never asked about what can't be done (#855).
	listed, err := d.agentWorkspacesWithin(agent, cardCheckPatience)
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
		if name != "" && strings.EqualFold(w.Name, name) {
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
	question := "Make a new machine at " + found.Name
	if name != "" {
		question = "Make a new machine, " + name + ", at " + found.Name
	}
	if len(choices) > 0 {
		question += " (" + strings.Join(choices, ", ") + ")"
	}
	return d.personSaysYesSince(since, agent, d.agentWho(agent)+makeCardTitle, question+"?", "Make it", func(yes bool) (string, error) {
		if !yes {
			return "Nothing was made: the person said no, or didn’t answer.", nil
		}
		params := map[string]any{"id": found.ID}
		if name != "" {
			params["name"] = name
		}
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
		return "Made " + made.Workspace.Name + ". It can’t install Agent Loops on its first boot, so the person adds it from " +
			"Settings ▸ Machine Providers with Add as Machine….", nil
	})
}

// deleteMachine is delete_machine.
func (d *Daemon) deleteMachine(agent wire.UUID, args map[string]json.RawMessage) (string, error) {
	since := time.Now()
	given, err := named(args, "host", "host")
	if err != nil {
		return "", err
	}
	listed, err := d.agentWorkspacesWithin(agent, cardCheckPatience)
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
	return d.personSaysYesSince(since, agent, d.agentWho(agent)+" wants to delete a machine",
		"Delete the machine "+host+" runs on, with everything on its disk, and remove the machine "+host+" with its agents?", "Delete it",
		func(yes bool) (string, error) {
			if !yes {
				return "Nothing was deleted: the person said no, or didn’t answer.", nil
			}
			if _, err := d.askWorkspaces(agent, hostsDeleteMachine, map[string]any{"host": host}); err != nil {
				return "", err
			}
			return "Deleted the machine " + host + " ran on, and removed the machine.", nil
		})
}

// agentWho is an agent as the control plane's log and the card name it: "Claude (fix-login)".
func (d *Daemon) agentWho(agent wire.UUID) string {
	if agent == "" {
		// The person, in a client: Send to ‹machine›… (#4613).
		return "You"
	}
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

// personSaysYes is one yes-or-no question on the agent's card: then does what the answer
// says, with true only for the yes, and its words are the call's. A card still open after
// formHoldLimit keeps then (#4261): the call says so, and when the person answers, then
// runs and its words come to the agent as a prompt. A no, or no answer, never says yes.
func (d *Daemon) personSaysYes(agent wire.UUID, title, question, yes string, then func(yes bool) (string, error)) (string, error) {
	return d.personSaysYesSince(time.Now(), agent, title, question, yes, then)
}

// personSaysYesSince is personSaysYes for a call that began at since (#4986): the card is held
// only for what is left of formHoldLimit, so the checks before it and the hold end together
// inside the tool's time limit. The same card open already is not asked again: the call says
// it is still open, and the one answer does what it says once.
func (d *Daemon) personSaysYesSince(since time.Time, agent wire.UUID, title, question, yes string, then func(yes bool) (string, error)) (string, error) {
	for _, card := range d.cardsOpen(title) {
		if card.agent == agent && card.question == question {
			return yesStillOpen, nil
		}
	}
	q, _ := json.Marshal([]map[string]any{{"id": "go", "prompt": question,
		"options": []map[string]string{{"id": "yes", "label": yes}, {"id": "no", "label": "Don’t"}}}})
	t, _ := json.Marshal(title)
	said := func(note string) bool { return strings.Contains(note, ": "+yes) }
	late := func(note string) {
		words, err := then(said(note))
		if err != nil {
			_, msg := errMessage(err)
			words = msg
		}
		if err := d.promptFromApp(agent, "The person answered your card \""+title+"\". "+words); err != nil {
			log.Printf("agent %s: card answer: %v", agent, err)
		}
	}
	note, answered, err := d.askForm(agent, map[string]json.RawMessage{"title": t, "questions": q}, late, formHoldLimit-time.Since(since))
	if err != nil {
		return "", err
	}
	if !answered {
		return yesStillOpen, nil
	}
	return then(said(note))
}

// yesStillOpen is what a call that asks with personSaysYes says when the card is not answered
// within formHoldLimit (#4261).
const yesStillOpen = "The card is still open: nothing is done until the person answers it. When they say yes, it is done then, " +
	"and you are started again with the result. End your turn (or go on with other work). Do not ask again."

// makeCardTitle ends the title of make_machine's card, after the agent's name.
const makeCardTitle = " wants to make a machine"

// openCard is a question card open on this machine: its agent, the agent as the card names
// it, and its one question.
type openCard struct {
	agent         wire.UUID
	who, question string
}

// cardsOpen is every card open on this machine whose title ends with title (#4986), held or
// left open, the oldest first.
func (d *Daemon) cardsOpen(title string) []openCard {
	type asked struct {
		card openCard
		at   wire.Date
	}
	var found []asked
	for _, l := range d.everyLive() {
		l.mu.Lock()
		for _, pe := range l.elicitations {
			m, form := pe.req.Message, pe.req.Mode.Form
			if m == nil || form == nil || !strings.HasSuffix(*m, title) || len(form.Value.Properties) != 1 {
				continue
			}
			question := deref(form.Value.Properties[0].Title)
			found = append(found, asked{openCard{agent: l.id, who: strings.TrimSuffix(*m, title), question: question}, pe.req.AskedAt})
		}
		l.mu.Unlock()
	}
	sort.Slice(found, func(i, j int) bool { return found[i].at < found[j].at })
	cards := make([]openCard, len(found))
	for i, f := range found {
		cards[i] = f.card
	}
	return cards
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
	var lines []string
	if len(listed.Providers) == 0 {
		lines = append(lines, "This control plane has no machine providers. The person adds them in Settings ▸ Machine Providers.")
	}
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
			// A make that failed says why (#4706), not that it is no host.
			if w.Reason != nil && *w.Reason != "" {
				host = " — " + *w.Reason
			}
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
	if len(listed.Providers) > 0 {
		lines = append(lines, "Start or stop one by its host's name. Making and deleting ask the person first.")
	}
	// Every machine of the person's, for start_session's machine (#2887).
	if len(listed.Hosts) > 0 {
		lines = append(lines, "The person's machines, where start_session with machine starts a session, in this project's folder there or in folder, once the person says yes:")
		for _, h := range listed.Hosts {
			lines = append(lines, "  - "+h.Name+": "+h.State)
		}
	}
	return strings.Join(lines, "\n")
}
