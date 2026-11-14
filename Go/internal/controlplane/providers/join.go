package providers

import (
	"time"

	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// StartToJoin starts a stopped workspace that no host is linked to, before machines/install
// joins it (#4978): a click on a machine that never joined, in a client's Machines group. Its
// provider starts it, and the install waits until the provider lists it running, at most half
// of GiveUp. Nothing is done for a workspace that is not listed stopped, that person may not
// link, or a codespace whose provider a machine carries: `gh codespace ssh` on that machine
// starts it (#3497). The step is said to clients as control/installProgress "start".
func (p *Providers) StartToJoin(request wire.MachineInstall, person string) error {
	if request.Provider == nil || request.Workspace == nil {
		return nil
	}
	link := WorkspaceLink{Provider: string(*request.Provider), Workspace: *request.Workspace}
	w := p.workspace(link)
	if w == nil || w.State != "stopped" || p.carriedCodespace(link, request.Destination) != nil ||
		!p.mayLink(person, link.Provider, link.Workspace) {
		return nil
	}
	name := trimSpaces(deref(request.Name))
	if name == "" {
		name = w.Name
	}
	p.router.BroadcastControl("control/installProgress", wire.ControlInstallProgress{Name: name, Step: "start"})
	if _, err := p.providerCall(link.Provider, func(c Provider) (any, error) { return c.Start(link.Workspace) }); err != nil {
		return err
	}
	patience := p.timing.GiveUp / 2
	every := 5 * p.timing.LookEvery
	for waited := time.Duration(0); ; waited += every {
		p.Refresh(link.Provider)
		if now := p.workspace(link); now == nil || now.State == "running" {
			return nil
		}
		if waited >= patience {
			return fail(CodeProviderFailed, "%s started %s, but it wasn’t running after %s.", p.providerName(link.Provider),
				name, durationWords(patience))
		}
		if !p.sleep(every) {
			return nil
		}
	}
}

// providerName is a provider's name, or its id once it is gone.
func (p *Providers) providerName(id string) string {
	p.mu.Lock()
	defer p.mu.Unlock()
	if held, ok := p.providers[id]; ok && held.record.Name != "" {
		return held.record.Name
	}
	return id
}
