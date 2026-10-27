package controlplane

import (
	"context"
	"encoding/json"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/audit"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// The Console (#1804): the control plane's app for its admins, on the web page beside the
// Workspace and Reports. Its pages read what the control plane keeps already: people,
// machines, and the numbers and events the machines send. Never a conversation.

// consoleMethods are the Console's: an admin's each, naming no machine, so another
// person's machine is never named by one (#994).
var consoleMethods = map[string]bool{"console/fleet": true, "console/live": true, "console/stopAgent": true, "console/teamWorkflows": true}

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
	case "console/live":
		m.refreshLive(ctx, from)
		return m.live(ctx), nil
	case "console/stopAgent":
		request, err := require[wire.ConsoleStopAgent](params, "ConsoleStopAgent")
		if err != nil {
			return nil, err
		}
		if m.records.Host(string(request.Host)) == nil {
			return nil, fail(noSuchHost, "No machine is called %s.", request.Host)
		}
		if err := m.stopAgentOn(string(request.Host), request.Agent, from); err != nil {
			return nil, err
		}
		m.s.log("an admin stopped " + string(request.Agent) + " on " + string(request.Host) + " (Console ▸ Live Now)")
		// So the board that asks next shows it stopped.
		m.listAgain(string(request.Host), from)
		return wire.Empty{}, nil
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

const (
	// liveStale is how old a machine's list may be before console/live asks it again: more
	// than the page's 15 s poll (#2432), so one open tab asks each machine at most every
	// other poll, not at each.
	liveStale = 20 * time.Second
	// mostLiveAsks bounds the machines one console/live asks again, each for at most
	// liveAskPatience, at once.
	mostLiveAsks    = 50
	liveAskPatience = 3 * time.Second
)

// liveCandidate is an online machine and when its list was last heard; zero for never.
type liveCandidate struct {
	host  string
	heard time.Time
}

// liveAsks is which machines console/live asks again (#2432): those whose list is older
// than liveStale, the stalest first, at most mostLiveAsks. Stalest first is a round: the
// machines past the first 50 are asked on the next call, not never.
func liveAsks(candidates []liveCandidate, now time.Time) []string {
	stale := []liveCandidate{}
	for _, c := range candidates {
		if c.heard.IsZero() || now.Sub(c.heard) >= liveStale {
			stale = append(stale, c)
		}
	}
	sort.SliceStable(stale, func(i, j int) bool { return stale[i].heard.Before(stale[j].heard) })
	if len(stale) > mostLiveAsks {
		stale = stale[:mostLiveAsks]
	}
	asks := make([]string, len(stale))
	for i, c := range stale {
		asks[i] = c.host
	}
	return asks
}

// refreshLive asks the online machines liveAsks names for their lists again (agents/list,
// lean): a machine's list is kept only when a window asks for it, and Live Now is about now.
func (m *Methods) refreshLive(ctx context.Context, from Caller) {
	var candidates []liveCandidate
	for _, h := range m.records.Hosts() {
		if state, _ := m.router.Described(h.ID)["state"].(string); state != "online" && state != "needsUpdate" {
			continue
		}
		c := liveCandidate{host: h.ID}
		if copy := m.s.copies.current(ctx, h.ID); copy != nil {
			c.heard = copy.HeardAt.Time
		}
		candidates = append(candidates, c)
	}
	stale := liveAsks(candidates, time.Now())
	var wg sync.WaitGroup
	for _, host := range stale {
		wg.Go(func() { m.listAgain(host, from) })
	}
	wg.Wait()
}

// listAgain asks a machine for its whole agents list, as a window does, and keeps the answer.
func (m *Methods) listAgain(host string, from Caller) {
	answer := m.router.DeliverKept(wire.CallAgentsList.Name, map[string]any{"lean": true}, from.Client, from.Kind, host, liveAskPatience)
	if answer == nil || len(answer.Error) > 0 || len(answer.Result) == 0 {
		return
	}
	reply, err := json.Marshal(map[string]json.RawMessage{"result": answer.Result})
	if err == nil {
		m.s.copies.take(host, wire.CallAgentsList.Name, string(reply))
	}
}

// live is console/live (#2019, M9): every agent running now on every machine, as each
// machine last listed it, with whose machine it is, its runtime, state and cost so far. No
// title and nothing it said. The most costly first (by its first currency), then the oldest.
func (m *Methods) live(ctx context.Context) wire.LiveBoard {
	out := []wire.LiveAgent{}
	for _, h := range m.records.Hosts() {
		copy := m.s.copies.current(ctx, h.ID)
		if copy == nil || copy.Agents == nil {
			continue
		}
		var agents []struct {
			ID                string             `json:"id"`
			RuntimeID         string             `json:"runtimeID"`
			State             string             `json:"state"`
			StartedByWorkflow string             `json:"startedByWorkflow"`
			CreatedAt         *wire.Date         `json:"createdAt"`
			CostToDate        map[string]float64 `json:"costToDate"`
			EventWait         json.RawMessage    `json:"eventWait"`
		}
		if json.Unmarshal(copy.Agents, &agents) != nil {
			continue
		}
		owner := m.s.ownerOf(h.ID)
		ownerName := m.s.personName(owner)
		// As the audit names them (actorFor).
		if owner == m.s.localOwner() {
			ownerName = audit.LocalOwnerName
		}
		heard := dateOf(copy.HeardAt.Time)
		for _, a := range agents {
			if !liveStates[a.State] {
				continue
			}
			row := wire.LiveAgent{Host: wire.MachineRef(h.ID), HostName: h.Name, Owner: owner, OwnerName: ownerName,
				Bot: m.s.isBot(owner), Agent: wire.UUID(a.ID), Runtime: a.RuntimeID, State: wire.AgentState(a.State),
				Since: a.CreatedAt, CostToDate: a.CostToDate, HeardAt: &heard}
			if a.StartedByWorkflow != "" {
				workflow := a.StartedByWorkflow
				row.Workflow = &workflow
			}
			if len(a.EventWait) > 0 && string(a.EventWait) != "null" {
				row.WaitsOnOthers = new(true)
			}
			out = append(out, row)
		}
	}
	sort.SliceStable(out, func(i, j int) bool {
		a, b := firstCost(out[i].CostToDate), firstCost(out[j].CostToDate)
		if a != b {
			return a > b
		}
		return string(out[i].Agent) < string(out[j].Agent)
	})
	return wire.LiveBoard{Agents: out}
}

// firstCost is a cost in US dollars, or else in the first currency by name, for sorting.
func firstCost(cost map[string]float64) float64 {
	if v, ok := cost["USD"]; ok {
		return v
	}
	names := make([]string, 0, len(cost))
	for c := range cost {
		names = append(names, c)
	}
	sort.Strings(names)
	if len(names) == 0 {
		return 0
	}
	return cost[names[0]]
}

// mostRunsRead bounds the claims console/teamWorkflows reads: a week of triggers, the
// newest first. A claim is written once, so each is read from the store once (readCache).
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
			run := wire.TeamBotRun{Host: wire.MachineRef(h.ID), HostName: h.Name, Agent: wire.UUID(a.ID), Since: a.CreatedAt}
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
	// The keys sort by day, oldest first: the newest mostRunsRead of the week.
	var read []store.Key
	for i := len(keys) - 1; i >= 0 && len(read) < mostRunsRead; i-- {
		day, _, _ := strings.Cut(strings.TrimPrefix(keys[i].Key, runsPrefix), "/")
		if day < oldest {
			break
		}
		read = append(read, keys[i])
	}
	objects, err := m.s.storeReads.read(ctx, m.s.cfg.Store, runsPrefix, keys, read)
	if err != nil {
		return fail(storeUnavailable, "The runs could not be read: %v", err)
	}
	for _, data := range objects {
		if data == nil {
			continue
		}
		var claim struct {
			Machine   string        `json:"machine"`
			Workflow  string        `json:"workflow"`
			ClaimedAt records.Stamp `json:"claimedAt"`
		}
		if json.Unmarshal(data, &claim) != nil {
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
