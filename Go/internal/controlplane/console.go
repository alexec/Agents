package controlplane

import (
	"context"
	"encoding/json"
	"sort"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/audit"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/wire"
)

// The Console (#1804): the control plane's app for its admins, on the web page beside the
// Workspace and Reports. Its pages read what the control plane keeps already: people,
// machines, and the numbers and events the machines send. Never a conversation.

// consoleMethods are the Console's: an admin's each, naming no machine, so another
// person's machine is never named by one (#994).
var consoleMethods = map[string]bool{"console/fleet": true, "console/teamWorkflows": true}

// consoleMethod answers the Console's own calls. Each is an admin's.
func (m *Methods) consoleMethod(ctx context.Context, method string, params json.RawMessage, from Caller) (any, error) {
	if !m.s.isAdmin(m.callerPerson(from)) {
		return nil, fail(notPermitted, "Only an admin can open the Console.")
	}
	switch method {
	case "console/fleet":
		return m.fleet(ctx), nil
	case "console/teamWorkflows":
		return m.teamWorkflows(ctx, time.Now())
	}
	return nil, fail(methodNotFound, "No method %s.", method)
}

// liveStates are the agent states a machine's list counts as running.
var liveStates = map[string]bool{"starting": true, "running": true, "waitingOnUser": true}

// fleet is console/fleet (M1): every machine, its owner, and how many of its agents were
// running when it last listed them. Offline first, then by owner and name.
func (m *Methods) fleet(ctx context.Context) wire.FleetBoard {
	out := []wire.FleetMachine{}
	for _, h := range m.records.Hosts() {
		owner := m.s.ownerOf(h.ID)
		machine := wire.FleetMachine{Host: m.hostRow(h), OwnerName: m.s.personName(owner), Bot: m.s.isBot(owner)}
		// As the audit names them (actorFor).
		if owner == m.s.localOwner() {
			machine.OwnerName = audit.LocalOwnerName
		}
		if copy := m.s.copies.current(ctx, h.ID); copy != nil && copy.Agents != nil {
			var agents []struct {
				State string `json:"state"`
			}
			if json.Unmarshal(copy.Agents, &agents) == nil {
				var running int64
				for _, a := range agents {
					if liveStates[a.State] {
						running++
					}
				}
				machine.Running = &running
				heard := dateOf(copy.HeardAt.Time)
				machine.HeardAt = &heard
			}
		}
		out = append(out, machine)
	}
	sort.SliceStable(out, func(i, j int) bool {
		a, b := out[i], out[j]
		if (a.Host.State == "offline") != (b.Host.State == "offline") {
			return a.Host.State == "offline"
		}
		if a.OwnerName != b.OwnerName {
			return strings.ToLower(a.OwnerName) < strings.ToLower(b.OwnerName)
		}
		return strings.ToLower(a.Host.Name) < strings.ToLower(b.Host.Name)
	})
	return wire.FleetBoard{Machines: out}
}

// mostRunsRead bounds the claims console/teamWorkflows reads: a week of triggers.
const mostRunsRead = 5000

// teamWorkflows is console/teamWorkflows (M6): each bot, its group, caps and spend today,
// its machines, the workflows it ran in the last 7 days (from the claims of
// workflows/claimRun) and the agents running on its machines, by id, for bots/stopRun.
func (m *Methods) teamWorkflows(ctx context.Context, now time.Time) (wire.TeamWorkflows, error) {
	bots := map[string]*wire.TeamBot{}
	order := []string{}
	for _, p := range m.records.People() {
		if !p.IsBot() || p.IsRemoved() {
			continue
		}
		bot := &wire.TeamBot{User: p.ID, Name: p.Name, Caps: capsOnWire(p.Caps), SpentTodayUSD: m.s.spentToday(ctx, p.ID, now),
			Workflows: []wire.TeamWorkflowRuns{}, Live: []wire.TeamBotRun{}}
		if p.Group != "" {
			group, name := p.Group, m.s.groupName(p.Group)
			bot.Group, bot.GroupName = &group, &name
		}
		_, bot.Capped = m.s.caps.until(p.ID)
		bots[p.ID] = bot
		order = append(order, p.ID)
	}
	for _, h := range m.records.Hosts() {
		bot := bots[m.s.ownerOf(h.ID)]
		if bot == nil {
			continue
		}
		bot.Machines++
		if state, _ := m.router.Described(h.ID)["state"].(string); state == "online" || state == "needsUpdate" {
			bot.Online++
		}
		copy := m.s.copies.current(ctx, h.ID)
		if copy == nil || copy.Agents == nil {
			continue
		}
		var agents []struct {
			ID                string     `json:"id"`
			State             string     `json:"state"`
			StartedByWorkflow string     `json:"startedByWorkflow"`
			CreatedAt         *wire.Date `json:"createdAt"`
		}
		if json.Unmarshal(copy.Agents, &agents) != nil {
			continue
		}
		for _, a := range agents {
			if !liveStates[a.State] {
				continue
			}
			run := wire.TeamBotRun{Host: wire.HostID(h.ID), HostName: h.Name, Agent: wire.UUID(a.ID), Since: a.CreatedAt}
			if a.StartedByWorkflow != "" {
				workflow := a.StartedByWorkflow
				run.Workflow = &workflow
			}
			bot.Live = append(bot.Live, run)
		}
	}
	if len(bots) > 0 {
		if err := m.botRuns(ctx, bots, now); err != nil {
			return wire.TeamWorkflows{}, err
		}
	}
	out := wire.TeamWorkflows{Bots: []wire.TeamBot{}}
	for _, id := range order {
		out.Bots = append(out.Bots, *bots[id])
	}
	sort.SliceStable(out.Bots, func(i, j int) bool { return strings.ToLower(out.Bots[i].Name) < strings.ToLower(out.Bots[j].Name) })
	return out, nil
}

// botRuns adds up the last 7 days' claims by bot and workflow, most runs first.
func (m *Methods) botRuns(ctx context.Context, bots map[string]*wire.TeamBot, now time.Time) error {
	keys, err := m.s.cfg.Store.List(ctx, runsPrefix)
	if err != nil {
		return fail(storeUnavailable, "The runs could not be read: %v", err)
	}
	oldest := now.Add(-runsKept).UTC().Format(usageDayLayout)
	type tally struct {
		runs int64
		last time.Time
	}
	counts := map[string]map[string]*tally{}
	read := 0
	for _, k := range keys {
		day, _, _ := strings.Cut(strings.TrimPrefix(k.Key, runsPrefix), "/")
		if day < oldest {
			continue
		}
		if read >= mostRunsRead {
			break
		}
		read++
		object, err := m.s.cfg.Store.Get(ctx, k.Key)
		if err != nil || object == nil {
			continue
		}
		var claim struct {
			Machine   string        `json:"machine"`
			Workflow  string        `json:"workflow"`
			ClaimedAt records.Stamp `json:"claimedAt"`
		}
		if json.Unmarshal(object.Data, &claim) != nil {
			continue
		}
		owner := m.s.ownerOf(claim.Machine)
		if bots[owner] == nil {
			continue
		}
		if counts[owner] == nil {
			counts[owner] = map[string]*tally{}
		}
		t := counts[owner][claim.Workflow]
		if t == nil {
			t = &tally{}
			counts[owner][claim.Workflow] = t
		}
		t.runs++
		if claim.ClaimedAt.Time.After(t.last) {
			t.last = claim.ClaimedAt.Time
		}
	}
	for owner, workflows := range counts {
		bot := bots[owner]
		for name, t := range workflows {
			last := dateOf(t.last)
			bot.Workflows = append(bot.Workflows, wire.TeamWorkflowRuns{Workflow: name, Runs: t.runs, LastRunAt: &last})
		}
		sort.Slice(bot.Workflows, func(i, j int) bool {
			a, b := bot.Workflows[i], bot.Workflows[j]
			return a.Runs > b.Runs || a.Runs == b.Runs && a.Workflow < b.Workflow
		})
	}
	return nil
}
