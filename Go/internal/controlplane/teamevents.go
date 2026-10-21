package controlplane

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// Team events (#2011, spec 736 FR-035): a project or control-plane event (a server's, such
// as github or a channel's) or a schedule that a bot's runs-on: workflow matches is sent
// once, by the control plane. Each machine that hears it sends it here (workflows/trigger);
// the first is claimed as workflows/claimRun claims it, and the control plane asks the
// bot's machines held here, one at a time, to run it (workflows/fire) until one takes it.
// Machine events (machine.*, dropbox.*) stay on their machine and never come here.

// fireTimeout is how long a bot's machine has to say whether it takes a trigger.
const fireTimeout = 30 * time.Second

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
	s.log(fmt.Sprintf("no machine of %s here takes %s for %s", s.personName(bot), t.Workflow, t.Trigger))
	return false
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
