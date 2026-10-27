package controlplane

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// Team events (#2011, spec 736 FR-035): a folder or control-plane event (a server's, such
// as github or a channel's) or a schedule that a bot's runs-on: workflow matches is sent
// once, by the control plane. Each machine that hears it sends it here (workflows/trigger);
// the first is claimed as workflows/claimRun claims it, and the control plane asks the
// bot's machines held here, one at a time, to run it (workflows/fire) until one takes it.
// Machine events (machine.*, dropbox.*) stay on their machine and never come here.

// fireTimeout is how long a bot's machine has to say whether it takes a trigger.
const fireTimeout = 30 * time.Second

// With none of a bot's machines here to take a trigger, the control plane starts one of
// its stopped workspaces, of a provider of the bot's group, and keeps the trigger until it
// joins (#2011, FR-034). It starts one machine per bot at a time, never makes one, keeps at
// most waitingMost triggers, and tries no other start for startPatience: a start that
// fails, or a machine that joins and does not take the trigger, is not a loop.
const (
	waitingMost   = 20
	startPatience = 15 * time.Minute
)

// botStarts is the start under way for each bot, and the triggers waiting for it.
type botStarts struct {
	mu    sync.Mutex
	byBot map[string]*botStart
	// starter and now are the providers and the clock; a test's own when set.
	starter machineStarter
	now     func() time.Time
}

// machineStarter is what a start for a bot needs of the machine providers.
type machineStarter interface {
	MayStartFor(person, host string) bool
	Workspace(host string) *wire.MachineWorkspace
	StartForUse(host, by string)
}

func (s *Service) machineStarter() machineStarter {
	if s.starts.starter != nil {
		return s.starts.starter
	}
	if s.providers == nil {
		return nil
	}
	return s.providers
}

func (b *botStarts) time() time.Time {
	if b.now != nil {
		return b.now()
	}
	return time.Now()
}

type botStart struct {
	host    string // the machine started; "" once it joined, or when none could be
	at      time.Time
	waiting []wire.TeamTrigger
}

// botNamed is the bot whose name a runs-on: list has, if any.
func (s *Service) botNamed(runsOn []string) string {
	for _, label := range runsOn {
		label = strings.ToLower(strings.TrimSpace(label))
		for _, p := range s.records.People() {
			if p.IsBot() && !p.IsRemoved() && strings.ToLower(p.Name) == label {
				return p.ID
			}
		}
	}
	return ""
}

// teamTrigger is workflows/trigger: taken when runs-on: names a bot. Only the bot's own
// machines, its group's people's and admins' may send a bot a trigger.
func (s *Service) teamTrigger(ctx context.Context, host string, t wire.TeamTrigger, now time.Time) (wire.TeamTriggerSent, error) {
	bot := s.botNamed(t.RunsOn)
	if bot == "" {
		return wire.TeamTriggerSent{Taken: false}, nil
	}
	sender := s.ownerOf(host)
	if p := s.records.Person(bot); sender != bot && !s.inGroup(sender, p.Group) && !s.isAdmin(sender) {
		return wire.TeamTriggerSent{}, fail(notPermitted, "Only %s's group may send it a trigger.", p.Name)
	}
	claimed, err := s.claimAs(ctx, bot, host, wire.WorkflowClaim{Workflow: t.Workflow, Trigger: t.Trigger}, now)
	if err != nil {
		return wire.TeamTriggerSent{}, err
	}
	if claimed.Won {
		safe.Go("team trigger", func() { s.sendTrigger(bot, t) })
	}
	return wire.TeamTriggerSent{Taken: true}, nil
}

// sendTrigger asks the bot's online machines held here, in turn, to run a trigger, until
// one takes it. True when one did.
func (s *Service) sendTrigger(bot string, t wire.TeamTrigger) bool {
	for _, host := range s.botMachinesHere(bot) {
		if s.fireOn(host, t) {
			s.log(fmt.Sprintf("%s runs %s for %s", host, t.Workflow, t.Trigger))
			return true
		}
	}
	s.startFor(bot, t, s.starts.time())
	return false
}

// startFor keeps a trigger no machine took and starts one of the bot's machines for it,
// or joins the start under way. One that cannot be kept is said and dropped.
func (s *Service) startFor(bot string, t wire.TeamTrigger, now time.Time) {
	name := s.personName(bot)
	s.starts.mu.Lock()
	if s.starts.byBot == nil {
		s.starts.byBot = map[string]*botStart{}
	}
	under := s.starts.byBot[bot]
	if under != nil && now.Sub(under.at) < startPatience {
		if under.host == "" {
			s.starts.mu.Unlock()
			s.log(fmt.Sprintf("no machine of %s takes %s for %s, and none was started again so soon", name, t.Workflow, t.Trigger))
			return
		}
		if len(under.waiting) >= waitingMost {
			s.starts.mu.Unlock()
			s.log(fmt.Sprintf("%s for %s is dropped: %d triggers already wait for %s's machine", t.Workflow, t.Trigger, waitingMost, name))
			return
		}
		under.waiting = append(under.waiting, t)
		s.starts.mu.Unlock()
		return
	}
	if under != nil && under.host != "" && len(under.waiting) > 0 {
		s.log(fmt.Sprintf("%s's machine did not join in %s: %d triggers are dropped", name, startPatience, len(under.waiting)))
	}
	host := s.stoppedMachineOf(bot)
	start := &botStart{host: host, at: now}
	if host != "" {
		start.waiting = []wire.TeamTrigger{t}
	}
	s.starts.byBot[bot] = start
	s.starts.mu.Unlock()
	if host == "" {
		s.log(fmt.Sprintf("no machine of %s is here to take %s for %s, and none can be started", name, t.Workflow, t.Trigger))
		return
	}
	s.log(fmt.Sprintf("starting %s's %s for %s (%s)", name, host, t.Workflow, t.Trigger))
	s.machineStarter().StartForUse(host, "a trigger for "+name)
}

// stoppedMachineOf is a bot's machine whose workspace may be started for it: one starting
// already first, then the first in order.
func (s *Service) stoppedMachineOf(bot string) string {
	starter := s.machineStarter()
	if starter == nil {
		return ""
	}
	var ok []string
	for _, h := range s.records.Hosts() {
		if s.ownerOf(h.ID) == bot && starter.MayStartFor(bot, h.ID) {
			ok = append(ok, h.ID)
		}
	}
	sort.Strings(ok)
	for _, host := range ok {
		if ws := starter.Workspace(host); ws != nil && ws.HostState != nil && *ws.HostState == "starting" {
			return host
		}
	}
	if len(ok) == 0 {
		return ""
	}
	return ok[0]
}

// botMachineJoined sends what waited for a bot's machine, once it has been told whose it
// is. A trigger it does not take is not started for again (startPatience).
func (s *Service) botMachineJoined(host string) {
	bot := s.ownerOf(host)
	if !s.isBot(bot) {
		return
	}
	s.starts.mu.Lock()
	under := s.starts.byBot[bot]
	var waiting []wire.TeamTrigger
	if under != nil {
		waiting, under.waiting = under.waiting, nil
		under.host = ""
	}
	s.starts.mu.Unlock()
	for _, t := range waiting {
		s.sendTrigger(bot, t)
	}
}

// botMachinesHere is a bot's online machines whose uplink ends here, in a steady order.
func (s *Service) botMachinesHere(bot string) []string {
	var out []string
	for _, host := range s.router.HostsHeldHere() {
		if state, ok := s.router.State(host); ok && state.online() && s.ownerOf(host) == bot {
			out = append(out, host)
		}
	}
	sort.Strings(out)
	return out
}

// fireOn is workflows/fire to one machine: whether it took the trigger.
func (s *Service) fireOn(host string, t wire.TeamTrigger) bool {
	answer := s.router.Ask(host, wire.CallWorkflowsFire.Name, t, fireTimeout)
	if answer == nil || len(answer.Error) > 0 {
		return false
	}
	var fired wire.TeamTriggerFired
	return json.Unmarshal(answer.Result, &fired) == nil && fired.Ran
}
