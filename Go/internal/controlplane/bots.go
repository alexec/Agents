package controlplane

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/alexec/agents/Go/internal/controlplane/providers"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// Bots (#1761, spec 736 US6, FR-030–FR-035): a user with no clients and no sign-in, in a
// group, with machines an admin enrols for it (hosts/startEnroll with as). No client starts,
// messages or answers an agent on a bot's machine; an admin may stop a run (bots/stopRun).
// A workflow whose runs-on: names the bot runs once per trigger across its machines
// (workflows/claimRun). At its own or its group's daily spend cap it starts no work.

const (
	// runsPrefix keeps a claim per trigger, by the UTC day it was claimed, swept after a week.
	runsPrefix = "v1/runs/"
	runsKept   = 7 * 24 * time.Hour
	// mostBotName bounds a bot's name, as a person's.
	mostBotName = 80
)

// botsMethod answers bots/make, bots/setCaps and bots/stopRun: an admin's only.
func (m *Methods) botsMethod(ctx context.Context, method string, params json.RawMessage, from Caller) (any, error) {
	if !m.s.isAdmin(m.callerPerson(from)) {
		return nil, fail(notPermitted, "Only an admin can make or change a bot.")
	}
	switch method {
	case "bots/make":
		request, err := require[wire.BotMake](params, "BotMake")
		if err != nil {
			return nil, err
		}
		return m.makeBot(ctx, request)
	case "bots/setCaps":
		request, err := require[wire.BotCaps](params, "BotCaps")
		if err != nil {
			return nil, err
		}
		return wire.Empty{}, m.setBotCaps(ctx, request)
	case "bots/stopRun":
		request, err := require[wire.BotStopRun](params, "BotStopRun")
		if err != nil {
			return nil, err
		}
		return wire.Empty{}, m.stopBotRun(request, from)
	}
	return nil, notFound(method)
}

func (m *Methods) makeBot(ctx context.Context, request wire.BotMake) (wire.BotMade, error) {
	name := strings.TrimSpace(request.Name)
	if name == "" || utf8.RuneCountInString(name) > mostBotName || strings.ContainsAny(name, " \t\n,") {
		return wire.BotMade{}, fail(invalidParams, "Give the bot a name of 1 to %d characters with no spaces, such as review-bot: runs-on: names it.", mostBotName)
	}
	if m.records.Group(request.Group) == nil {
		return wire.BotMade{}, fail(invalidParams, "There is no such group.")
	}
	if err := refuseBadCap(request.Caps); err != nil {
		return wire.BotMade{}, err
	}
	id := records.NewPersonID()
	err := m.records.ChangePeople(ctx, func(all map[string]records.Person) ([]records.Person, error) {
		for _, p := range all {
			if !p.IsRemoved() && strings.EqualFold(p.Name, name) {
				return nil, fail(invalidParams, "There is already someone called %s.", p.Name)
			}
		}
		return []records.Person{{ID: id, Name: name, Kind: records.KindBot, Role: records.RoleMember, Group: request.Group,
			Caps: capsOf(request.Caps)}}, nil
	})
	if err != nil {
		return wire.BotMade{}, err
	}
	m.s.peopleChanged(id, false)
	m.s.log("bot " + id + " (" + name + ") made in group " + request.Group)
	return wire.BotMade{User: id}, nil
}

func (m *Methods) setBotCaps(ctx context.Context, request wire.BotCaps) error {
	group := deref(request.Group)
	if group != "" && m.records.Group(group) == nil {
		return fail(invalidParams, "There is no such group.")
	}
	if err := refuseBadCap(&request.Caps); err != nil {
		return err
	}
	err := m.records.ChangePeople(ctx, func(all map[string]records.Person) ([]records.Person, error) {
		p, ok := all[request.User]
		if !ok || p.IsRemoved() || !p.IsBot() {
			return nil, fail(invalidParams, "There is no such bot.")
		}
		p.Caps = capsOf(&request.Caps)
		if group != "" {
			p.Group = group
		}
		return []records.Person{p}, nil
	})
	if err != nil {
		return err
	}
	m.s.peopleChanged(request.User, false)
	go m.s.checkCaps(request.User)
	return nil
}

// stopBotRun is bots/stopRun: agents/stop on the bot's machine, on a channel of the admin's.
func (m *Methods) stopBotRun(request wire.BotStopRun, from Caller) error {
	host := string(request.Host)
	owner := m.records.Person(m.s.ownerOf(host))
	if m.records.Host(host) == nil || owner == nil || !owner.IsBot() {
		return fail(noSuchHost, "No bot's machine is called %s.", host)
	}
	if err := m.stopAgentOn(host, request.Agent, from); err != nil {
		return err
	}
	m.s.log("an admin stopped " + string(request.Agent) + " on " + owner.Name + "'s " + host)
	return nil
}

// stopAgentOn stops one agent on a machine for an admin (bots/stopRun, console/stopAgent):
// the machine's own agents/stop, kept for it for 10 seconds.
func (m *Methods) stopAgentOn(host string, agent wire.UUID, from Caller) error {
	answer := m.router.DeliverKept(wire.CallAgentsStop.Name, wire.AgentStopRequest{AgentID: agent, ByAdmin: new(true)}, from.Client, from.Kind, host,
		10*time.Second)
	if answer == nil {
		return fail(hostOffline, "%s is not online.", m.records.Host(host).Name)
	}
	if len(answer.Error) > 0 {
		var refused RPCError
		if json.Unmarshal(answer.Error, &refused) == nil && refused.Message != "" {
			return &refused
		}
		return fail(invalidParams, "%s did not stop it.", m.records.Host(host).Name)
	}
	return nil
}

// refuseBadCap refuses a daily cap that is not more than $0 (#2066): no cap is a cap left out, never a
// number that is quietly dropped.
func refuseBadCap(c *wire.SpendCaps) error {
	if c != nil && c.DailyUSD != nil && !(*c.DailyUSD > 0) {
		return fail(invalidParams, "A daily cap is more than $0. Leave it out for no cap.")
	}
	return nil
}

func capsOf(c *wire.SpendCaps) *records.Caps {
	if c == nil || c.DailyUSD == nil || *c.DailyUSD <= 0 {
		return nil
	}
	return &records.Caps{DailyUSD: c.DailyUSD}
}

func capsOnWire(c *records.Caps) *wire.SpendCaps {
	if c == nil {
		return nil
	}
	return &wire.SpendCaps{DailyUSD: c.DailyUSD}
}

// isBot says a user is a bot.
func (s *Service) isBot(user string) bool {
	p := s.records.Person(user)
	return p != nil && !p.IsRemoved() && p.IsBot()
}

// BotMachineFor is botOwners: a bot's machine, asked of by an admin, who is told it is a
// bot's rather than not found.
func (s *Service) BotMachineFor(person, host string) bool {
	owner := s.ownerOf(host)
	return owner != person && s.isBot(owner) && s.isAdmin(person)
}

// MARK: host/user

// sendHostUser tells a machine its user, their kind and labels, and a bot's cap.
func (s *Service) sendHostUser(host string) {
	h := s.records.Host(host)
	if h == nil {
		return
	}
	user := s.ownerOf(host)
	u := wire.MachineUser{User: user, Kind: records.KindPerson, Name: s.personName(user), Labels: []string{}}
	if u.Name == "" && user == s.localOwner() {
		u.Name = localOwnerName
	}
	if p := s.records.Person(user); p != nil && p.IsBot() {
		u.Kind = records.KindBot
		if until, capped := s.caps.until(user); capped {
			at := wire.DateOf(until)
			u.CapReachedUntil = &at
		}
	}
	if link := providers.LinkOf(h); link != nil {
		u.Labels = append(u.Labels, link.Provider)
	}
	if u.Kind == records.KindPerson {
		u.Bots = s.botsOfGroups(user)
	}
	s.router.Tell(host, wire.NotifyHostUser.Name, u)
}

// botsOfGroups is the names of the bots in a person's groups, sorted (#2027): a runs-on:
// workflow that names one is heard on the person's machines, once approved there, and its
// matches are sent here, as workflows/trigger takes them from the bot's group.
func (s *Service) botsOfGroups(user string) []string {
	names := []string{}
	for _, p := range s.records.People() {
		if p.IsBot() && !p.IsRemoved() && p.Name != "" && s.inGroup(user, p.Group) {
			names = append(names, p.Name)
		}
	}
	sort.Strings(names)
	return names
}

// tellPeoplesMachines sends host/user again to each person's machine held here: a bot or a
// group changed, and so which bots' workflows each hears (#2027).
func (s *Service) tellPeoplesMachines() {
	for _, host := range s.router.HostsHeldHere() {
		if !s.isBot(s.ownerOf(host)) {
			s.sendHostUser(host)
		}
	}
}

// tellUsersMachines sends host/user again to each machine of a user held here.
func (s *Service) tellUsersMachines(user string) {
	for _, host := range s.router.HostsHeldHere() {
		if s.ownerOf(host) == user {
			s.sendHostUser(host)
		}
	}
}

// MARK: workflows/claimRun

// claimRun is workflows/claimRun (FR-034): the first machine of a user to claim a trigger
// runs it. A claim is kept by the UTC day it was made; yesterday's counts too, so a trigger
// heard either side of midnight is run once.
func (s *Service) claimRun(ctx context.Context, host string, claim wire.WorkflowClaim, now time.Time) (wire.WorkflowClaimed, error) {
	return s.claimAs(ctx, s.ownerOf(host), host, claim, now)
}

// claimAs claims a trigger of a user's workflow for host: a machine of theirs, or, for a
// trigger sent to the control plane (workflows/trigger), the machine that sent it. The key
// is the same either way, so a machine that still claims and one that sends run it once.
func (s *Service) claimAs(ctx context.Context, owner, host string, claim wire.WorkflowClaim, now time.Time) (wire.WorkflowClaimed, error) {
	if strings.TrimSpace(claim.Workflow) == "" || strings.TrimSpace(claim.Trigger) == "" {
		return wire.WorkflowClaimed{}, fail(invalidParams, "Say the workflow and the trigger.")
	}
	name := claimName(owner, claim)
	today, yesterday := now.UTC().Format(usageDayLayout), now.UTC().Add(-24*time.Hour).Format(usageDayLayout)
	if before, err := s.cfg.Store.Get(ctx, runsPrefix+yesterday+"/"+name); err != nil {
		return wire.WorkflowClaimed{}, err
	} else if before != nil {
		return wire.WorkflowClaimed{Won: false}, nil
	}
	data, err := records.Encode(map[string]any{"machine": host, "workflow": claim.Workflow, "trigger": claim.Trigger,
		"claimedAt": records.At(now)})
	if err != nil {
		return wire.WorkflowClaimed{}, err
	}
	if _, err := s.cfg.Store.Put(ctx, runsPrefix+today+"/"+name, data, store.Absent); err != nil {
		if store.IsConflict(err) {
			return wire.WorkflowClaimed{Won: false}, nil
		}
		return wire.WorkflowClaimed{}, err
	}
	s.log(fmt.Sprintf("%s runs %s for %s", host, claim.Workflow, claim.Trigger))
	return wire.WorkflowClaimed{Won: true}, nil
}

// unclaimAs takes back a claim claimAs made: a trigger sent to the control plane that no
// machine took and none waits for. Yesterday's is taken back too, for a claim made either
// side of midnight.
func (s *Service) unclaimAs(ctx context.Context, owner string, claim wire.WorkflowClaim, now time.Time) {
	name := claimName(owner, claim)
	for _, day := range []time.Time{now, now.Add(-24 * time.Hour)} {
		if err := s.cfg.Store.Delete(ctx, runsPrefix+day.UTC().Format(usageDayLayout)+"/"+name); err != nil {
			s.log(fmt.Sprintf("the claim of %s for %s could not be taken back: %v", claim.Workflow, claim.Trigger, err))
		}
	}
}

// claimName is a claim's file: the same for the same owner, workflow and trigger.
func claimName(owner string, claim wire.WorkflowClaim) string {
	sum := sha256.Sum256([]byte(owner + "\x00" + claim.Workflow + "\x00" + claim.Trigger))
	return hex.EncodeToString(sum[:16]) + ".json"
}

// sweepRuns deletes claims of days older than a week, at most most.
func sweepRuns(ctx context.Context, st store.Store, now time.Time, most int) (int, error) {
	oldest := now.Add(-runsKept).UTC().Format(usageDayLayout)
	keys, err := st.List(ctx, runsPrefix)
	if err != nil {
		return 0, err
	}
	n := 0
	for _, k := range keys {
		if n >= most {
			break
		}
		day, _, _ := strings.Cut(strings.TrimPrefix(k.Key, runsPrefix), "/")
		if day >= oldest {
			continue
		}
		if err := st.Delete(ctx, k.Key); err != nil {
			return n, err
		}
		n++
	}
	return n, nil
}

// MARK: Spend caps

// botCaps is which bots are at a cap, until the end of the UTC day, and to whom it was said.
type botCaps struct {
	mu     sync.Mutex
	capped map[string]time.Time
}

func (c *botCaps) until(user string) (time.Time, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	until, ok := c.capped[user]
	return until, ok && time.Now().Before(until)
}

// mark notes a cap reached; false when it was already noted for that day.
func (c *botCaps) mark(user string, until time.Time) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.capped == nil {
		c.capped = map[string]time.Time{}
	}
	if was, ok := c.capped[user]; ok && !was.Before(until) {
		return false
	}
	c.capped[user] = until
	return true
}

func (c *botCaps) clear(user string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	_, was := c.capped[user]
	delete(c.capped, user)
	return was
}

// spentToday is what a user's machines said they spent today, UTC, in US dollars.
func (s *Service) spentToday(ctx context.Context, user string, now time.Time) float64 {
	day := now.UTC().Format(usageDayLayout)
	prefix := usageDaysPrefix + day + "/"
	listed, err := s.cfg.Store.List(ctx, prefix)
	if err != nil {
		return 0
	}
	mine := map[string]bool{}
	for _, h := range s.records.Hosts() {
		if s.ownerOf(h.ID) == user {
			mine[usageKey(usageDaysPrefix, day, h.ID)] = true
		}
	}
	var read []store.Key
	for _, k := range listed {
		if mine[k.Key] {
			read = append(read, k)
		}
	}
	objects, err := s.storeReads.read(ctx, s.cfg.Store, prefix, listed, read)
	if err != nil {
		return 0
	}
	total := 0.0
	for _, data := range objects {
		if data == nil {
			continue
		}
		var kept storedUsage
		if json.Unmarshal(data, &kept) != nil {
			continue
		}
		for _, row := range kept.Rows {
			total += row.Cost["USD"]
		}
	}
	return total
}

// checkCaps weighs a bot's spend today against its own cap and its group's (the group's
// bots together). At one, its machines start no more work until the end of the day, and
// the admins are told once (FR-033).
func (s *Service) checkCaps(user string) {
	p := s.records.Person(user)
	if p == nil || !p.IsBot() {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), userDeliveryTimeout)
	defer cancel()
	now := time.Now()
	spent := s.spentToday(ctx, user, now)
	reached := wire.CapReached{User: user, Name: p.Name}
	at := false
	if p.Caps != nil && p.Caps.DailyUSD != nil && spent >= *p.Caps.DailyUSD {
		reached.SpentUSD, reached.CapUSD, at = spent, *p.Caps.DailyUSD, true
	}
	if g := s.records.Group(p.Group); !at && g != nil && g.Caps != nil && g.Caps.DailyUSD != nil {
		groupSpent := 0.0
		for _, other := range s.records.People() {
			if other.IsBot() && other.Group == g.ID {
				groupSpent += s.spentToday(ctx, other.ID, now)
			}
		}
		if groupSpent >= *g.Caps.DailyUSD {
			reached.SpentUSD, reached.CapUSD, at = groupSpent, *g.Caps.DailyUSD, true
			reached.Group = &g.Name
		}
	}
	if !at {
		if s.caps.clear(user) {
			s.tellUsersMachines(user)
		}
		return
	}
	until := now.UTC().Truncate(24 * time.Hour).Add(24 * time.Hour)
	reached.Until = wire.DateOf(until)
	if !s.caps.mark(user, until) {
		return
	}
	s.tellUsersMachines(user)
	s.log(fmt.Sprintf("bot %s is at its cap: $%.2f of $%.2f today", p.Name, reached.SpentUSD, reached.CapUSD))
	for _, admin := range s.records.People() {
		if admin.IsAdmin() {
			s.router.TellPerson(admin.ID, wire.NotifyControlCapReached.Name, reached)
		}
	}
	if s.records.Person(s.localOwner()) == nil {
		s.router.TellPerson(s.localOwner(), wire.NotifyControlCapReached.Name, reached)
	}
}
