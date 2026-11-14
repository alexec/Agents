package providers

import (
	"fmt"
	"time"

	"github.com/agentloops-dev/agents/Go/wire"
)

// MARK: Keep a codespace awake while it works (#4637)

// GitHub stops a codespace after its idle timeout, and counts no background process, such
// as an agent's turn, as use (#4636). While a codespace's machine is not idle and online,
// the machine that carries its provider is asked to hold an ssh session to it that GitHub
// counts as use (providers/ssh keepAwake), and asked again each keepAwakeRenew: it ends the
// session itself when it is not asked again for a while. When the machine goes idle, it is
// let sleep, so Agents' own Stop when idle stops it, or GitHub does after its idle timeout.

// keepAwakeRenew is how often a codespace kept awake is asked for again: well within the
// carrying machine's lease (15 minutes).
var keepAwakeRenew = 5 * time.Minute

// keptAwake is a host whose codespace the carrying machine is asked to keep awake.
type keptAwake struct {
	host, provider, machine, codespace, destination string
	asked                                           time.Time
}

// keepAwake asks, for each host, what keeps its codespace awake or lets it sleep, as
// what it last said (machine/status) and whether it is online say.
func (p *Providers) keepAwake(now time.Time) {
	p.mu.Lock()
	busy := make([]string, 0, len(p.statuses))
	for host, status := range p.statuses {
		if !status.Idle {
			busy = append(busy, host)
		}
	}
	p.mu.Unlock()
	want := map[string]keptAwake{}
	for _, host := range busy {
		if !p.router.Online(host) {
			continue
		}
		link := LinkOf(p.records.Host(host))
		if link == nil {
			continue
		}
		destination := p.sshDestination(*link, host)
		r := p.carriedCodespace(*link, destination)
		// A carrying machine from before providers.carry/2 has no keepAwake.
		if r == nil || !p.router.HostCan(*r.Machine, wire.CapProvidersCarry2) {
			continue
		}
		want[host] = keptAwake{host: host, provider: r.ID, machine: *r.Machine, codespace: link.Workspace,
			destination: destination}
	}
	var keep, sleep []keptAwake
	p.mu.Lock()
	if p.awake == nil {
		p.awake = map[string]keptAwake{}
	}
	for host, was := range p.awake {
		if w, ok := want[host]; !ok || w.provider != was.provider || w.machine != was.machine || w.codespace != was.codespace {
			sleep = append(sleep, was)
			delete(p.awake, host)
		}
	}
	for host, w := range want {
		if was, ok := p.awake[host]; ok && now.Sub(was.asked) < keepAwakeRenew {
			continue
		}
		w.asked = now
		p.awake[host] = w
		keep = append(keep, w)
	}
	p.mu.Unlock()
	for _, w := range sleep {
		go p.askAwake(w, "letSleep")
	}
	for _, w := range keep {
		go p.askAwake(w, "keepAwake")
	}
}

// askAwake asks w's carrying machine for op. A keepAwake it refused is asked again in a
// minute, not at the next renewal.
func (p *Providers) askAwake(w keptAwake, op string) {
	_, err := Ask(p.router, w.machine, p.hostName(w.machine), wire.CallProvidersSSH.Name, wire.ProviderSSH{
		Provider: wire.ProviderID(w.provider), Op: op, Destination: w.destination, Codespace: &w.codespace},
		time.Minute)
	if err == nil {
		return
	}
	p.log(fmt.Sprintf("workspace: %s %s on %s: %s", op, w.codespace, p.hostName(w.machine), errorWords(err)))
	if op != "keepAwake" {
		return
	}
	p.mu.Lock()
	if was, ok := p.awake[w.host]; ok && was == w {
		was.asked = w.asked.Add(time.Minute - keepAwakeRenew)
		p.awake[w.host] = was
	}
	p.mu.Unlock()
}
