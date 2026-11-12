package controlplane

import (
	"context"
	"encoding/json"
	"slices"
	"sort"
	"strings"

	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/wire"
)

// Lineage reads over the merged copy (#4276): lineage/walkAll and lineage/sessionsOn read
// every machine's links and states that the scope takes, as reports/value reads their cost,
// so a machine that sleeps is still in the answer. control/lineageChanged tells the machine's
// person and the admins when a machine sent something new, so a client that shows working
// does not poll. Forge data still comes from the machines (principle 6): the copy has only
// refs, states and times.

// mostSessionsOnNodes bounds the nodes one lineage/sessionsOn asks for.
const mostSessionsOnNodes = lineage.MostAnswer

// mergedLineage is the scope's machines' links, each once, with the machine that sent each,
// and each session's latest state.
type mergedLineage struct {
	links  []wire.LineageLink
	hostOf []string
	byNode map[wire.LineageNode][]int
	states map[wire.LineageNode]wire.LineageSessionState
	// names names each node in the full ref form (#4800): a machine on a release before it
	// sends the old form.
	names lineage.Names
}

// linksOf is the indexes in links of a node's links, newest start first.
func (g *mergedLineage) linksOf(n wire.LineageNode) []int {
	idx := g.byNode[n]
	out := make([]int, 0, len(idx))
	for i := len(idx) - 1; i >= 0; i-- {
		out = append(out, idx[i])
	}
	return out
}

func (g *mergedLineage) stateNow(n wire.LineageNode) (wire.LineageSessionState, bool) {
	s, ok := g.states[n]
	return s, ok
}

func (m *Methods) lineageReadMethod(ctx context.Context, method string, params json.RawMessage, from Caller) (any, error) {
	user := m.s.actorFor(from.Client).User
	if method == "lineage/walkAll" {
		request, err := require[wire.LineageWalkAllRequest](params, "LineageWalkAllRequest")
		if err != nil {
			return nil, err
		}
		if err := lineage.CheckNode(request.Node); err != nil {
			return nil, fail(invalidParams, "A lineage node: %v.", err)
		}
		g, err := m.s.scopeLineageGraph(ctx, request.Scope, user)
		if err != nil {
			return nil, err
		}
		depth := 0
		if request.Depth != nil {
			depth = int(*request.Depth)
		}
		return lineage.WalkOver(g.links, g.linksOf, g.stateNow, g.names.Ask(request.Node), depth), nil
	}
	request, err := require[wire.LineageSessionsOnRequest](params, "LineageSessionsOnRequest")
	if err != nil {
		return nil, err
	}
	if len(request.Nodes) > mostSessionsOnNodes {
		return nil, fail(invalidParams, "Ask for at most %d nodes at a time.", mostSessionsOnNodes)
	}
	for _, n := range request.Nodes {
		if err := lineage.CheckNode(n); err != nil {
			return nil, fail(invalidParams, "A lineage node: %v.", err)
		}
	}
	g, err := m.s.scopeLineageGraph(ctx, request.Scope, user)
	if err != nil {
		return nil, err
	}
	return sessionsOn(g, request.Nodes), nil
}

// scopeLineageGraph is the merged copy of the machines whose people the scope takes.
func (s *Service) scopeLineageGraph(ctx context.Context, scope *wire.ReportScope, user string) (*mergedLineage, error) {
	_, keep, _, err := s.reportScope(ctx, scope, user, s.isAdmin(user))
	if err != nil {
		return nil, err
	}
	return s.keptLineageGraph(ctx, keep)
}

// keptLineageGraph is the merged copy of the machines whose people keep says.
func (s *Service) keptLineageGraph(ctx context.Context, keep func(person string) bool) (*mergedLineage, error) {
	keys, err := s.cfg.Store.List(ctx, lineageGraphPrefix)
	if err != nil {
		return nil, fail(storeUnavailable, "Lineage could not be read: %v", err)
	}
	known := map[string]string{}
	for _, h := range s.records.Hosts() {
		known[strings.ToLower(h.ID)] = h.ID
	}
	var read []store.Key
	var hosts []string
	for _, k := range keys {
		host, _, ok := strings.Cut(strings.TrimPrefix(k.Key, lineageGraphPrefix), "/")
		if !ok {
			continue
		}
		// A machine removed since: its person is not known, so only an admin sees it.
		person, id := "", host
		if known[host] != "" {
			id = known[host]
			person = s.ownerOf(id)
		}
		if keep(person) {
			read = append(read, k)
			hosts = append(hosts, id)
		}
	}
	objects, err := s.storeReads.read(ctx, s.cfg.Store, lineageGraphPrefix, keys, read)
	if err != nil {
		return nil, fail(storeUnavailable, "Lineage could not be read: %v", err)
	}
	g := &mergedLineage{byNode: map[wire.LineageNode][]int{}, states: map[wire.LineageNode]wire.LineageSessionState{}}
	seen := map[syncLinkKey]bool{}
	for i, data := range objects {
		if data == nil {
			continue
		}
		if strings.HasSuffix(read[i].Key, "/states.json") {
			var kept storedStates
			if json.Unmarshal(data, &kept) != nil {
				continue
			}
			for _, c := range kept.States {
				c.Node = g.names.Name(c.Node)
				if have, ok := g.states[c.Node]; !ok || c.At >= have.At {
					g.states[c.Node] = wire.LineageSessionState{State: c.State, At: c.At}
				}
			}
			continue
		}
		var kept storedLinks
		if json.Unmarshal(data, &kept) != nil {
			continue
		}
		for _, l := range kept.Links {
			l.From, l.To = g.names.Name(l.From), g.names.Name(l.To)
			// An issue's link is on each machine that knows it only once it is the same link.
			k := syncLinkKey{l.From, l.To, l.Rel, l.At}
			if seen[k] {
				continue
			}
			seen[k] = true
			g.links = append(g.links, l)
			g.hostOf = append(g.hostOf, hosts[i])
		}
	}
	order := make([]int, len(g.links))
	for i := range order {
		order[i] = i
	}
	sort.SliceStable(order, func(a, b int) bool { return g.links[order[a]].At < g.links[order[b]].At })
	links, hostOf := make([]wire.LineageLink, len(order)), make([]string, len(order))
	for i, at := range order {
		links[i], hostOf[i] = g.links[at], g.hostOf[at]
	}
	g.links, g.hostOf = links, hostOf
	for i, l := range g.links {
		g.byNode[l.From] = append(g.byNode[l.From], i)
		if l.To != l.From {
			g.byNode[l.To] = append(g.byNode[l.To], i)
		}
	}
	return g, nil
}

// sessionsOn is the sessions linked to nodes, each once, with the nodes it is on, its first
// link's start and its state now, the earliest first, at most lineage.MostAnswer.
func sessionsOn(g *mergedLineage, nodes []wire.LineageNode) wire.LineageSessionsOn {
	asked := map[wire.LineageNode]bool{}
	nodes = slices.Clone(nodes)
	for i, n := range nodes {
		nodes[i] = g.names.Ask(n)
		asked[nodes[i]] = true
	}
	at := map[wire.LineageNode]int{}
	var out []wire.LineageSessionOn
	for _, n := range nodes {
		for _, i := range g.byNode[n] {
			l := g.links[i]
			session, on := l.From, l.To
			if session.Kind != lineage.KindSession {
				session, on = l.To, l.From
			}
			if session.Kind != lineage.KindSession || !asked[on] {
				continue
			}
			j, ok := at[session]
			if !ok {
				j = len(out)
				at[session] = j
				out = append(out, wire.LineageSessionOn{Node: session, Host: g.hostOf[i], On: []wire.LineageNode{}, At: l.At})
				if s, ok := g.states[session]; ok {
					out[j].State = &s
				}
			}
			if l.At < out[j].At {
				out[j].At = l.At
			}
			if !slices.Contains(out[j].On, on) {
				out[j].On = append(out[j].On, on)
			}
		}
	}
	sort.SliceStable(out, func(a, b int) bool { return out[a].At < out[b].At })
	answer := wire.LineageSessionsOn{Sessions: out}
	if answer.Sessions == nil {
		answer.Sessions = []wire.LineageSessionOn{}
	}
	if len(answer.Sessions) > lineage.MostAnswer {
		answer.Sessions = answer.Sessions[:lineage.MostAnswer]
		t := true
		answer.Limited = &t
	}
	return answer
}

// lineageChanged tells this copy's clients, and every other copy, what a machine's
// lineage/sync brought.
func (s *Service) lineageChanged(host string, sync wire.LineageSync) {
	change := wire.LineageChanged{Host: host, States: sync.States}
	if change.States == nil {
		change.States = []wire.LineageStateChange{}
	}
	if len(sync.Links) > 0 {
		t := true
		change.Links = &t
	}
	s.tellLineageChanged(change)
	if s.mesh != nil {
		// Only on the peer links: a copy that missed it reads the next one, a few seconds on.
		s.mesh.broadcast(encodePeer("lineage", change))
	}
}

// tellLineageChanged tells the machine's person and the admins here, each once.
func (s *Service) tellLineageChanged(change wire.LineageChanged) {
	told := map[string]bool{}
	tell := func(person string) {
		if person != "" && !told[person] {
			told[person] = true
			s.router.TellPerson(person, wire.NotifyControlLineageChanged.Name, change)
		}
	}
	tell(s.ownerOf(change.Host))
	for _, p := range s.records.People() {
		if p.IsAdmin() && !p.IsRemoved() {
			tell(p.ID)
		}
	}
	if s.records.Person(s.localOwner()) == nil {
		tell(s.localOwner())
	}
}
