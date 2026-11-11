package controlplane

import (
	"context"
	"encoding/json"
	"errors"
	"sort"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/wire"
)

// The merged copy of lineage (#4273, #4275): each machine sends its links and its sessions'
// changes of state (lineage/sync) a few seconds after they change, and the control plane
// keeps them per machine, under v1/lineage-graph/<host>/links.json and states.json. Only
// that machine writes its objects, so nothing locks; a read merges them (#4276). Only refs,
// states and times: no titles or text (principle 7).
//
//   - Links are bounded as the machine bounds its own file (lineage.Bound): an ended link
//     90 days after its end, at most lineage.MostLinks a machine.
//   - States are each change with its time, bounded as the machine bounds its own (#4274):
//     the last 90 days and each session's latest whatever its age, at most
//     lineage.MostStates a machine, those that are not a session's latest going first.
//   - The hourly sweep applies both bounds to a machine that stopped sending, and deletes
//     a removed machine's objects.

const (
	lineageGraphPrefix = "v1/lineage-graph/"
	// mostSyncLinks and mostSyncStates bound one send.
	mostSyncLinks  = 2_000
	mostSyncStates = 1_000
)

// storedLinks is one machine's links as the store keeps them, oldest start first.
type storedLinks struct {
	Links []wire.LineageLink `json:"links"`
	At    records.Stamp      `json:"at"`
}

// storedStates is one machine's state changes, oldest first.
type storedStates struct {
	States []wire.LineageStateChange `json:"states"`
	At     records.Stamp             `json:"at"`
}

func lineageLinksKey(host string) string {
	return lineageGraphPrefix + strings.ToLower(host) + "/links.json"
}

func lineageStatesKey(host string) string {
	return lineageGraphPrefix + strings.ToLower(host) + "/states.json"
}

var sessionStates = map[wire.LineageSessionStateName]bool{
	wire.LineageSessionStateNameWorking: true, wire.LineageSessionStateNameWaiting: true, wire.LineageSessionStateNameNeedsYou: true,
	wire.LineageSessionStateNameStopped: true, wire.LineageSessionStateNameArchived: true, wire.LineageSessionStateNameDeleted: true,
}

// keepLineageSync is lineage/sync: the links over this machine's copies of them, and the
// state changes after its own. Full says the control plane has no copy of its links.
func (s *Service) keepLineageSync(ctx context.Context, host string, sync wire.LineageSync, now time.Time) (wire.LineageSyncAnswer, error) {
	if s.records.Host(host) == nil {
		return wire.LineageSyncAnswer{}, fail(noSuchHost, "No machine is called %s.", host)
	}
	if len(sync.Links) > mostSyncLinks || len(sync.States) > mostSyncStates {
		return wire.LineageSyncAnswer{}, fail(invalidParams, "Send at most %d links and %d states at a time.", mostSyncLinks, mostSyncStates)
	}
	for _, l := range sync.Links {
		if err := checkSyncLink(l); err != nil {
			return wire.LineageSyncAnswer{}, fail(invalidParams, "A lineage link: %v.", err)
		}
	}
	for _, c := range sync.States {
		if c.Node.Kind != lineage.KindSession || lineage.CheckNode(c.Node) != nil {
			return wire.LineageSyncAnswer{}, fail(invalidParams, "A state is a session node's, not %s %s.", c.Node.Kind, c.Node.Ref)
		}
		if !sessionStates[c.State] {
			return wire.LineageSyncAnswer{}, fail(invalidParams, "%q is not a session's state.", c.State)
		}
	}
	reset := sync.Reset != nil && *sync.Reset
	full, err := s.keepSyncLinks(ctx, host, sync.Links, reset, now)
	if err != nil {
		return wire.LineageSyncAnswer{}, err
	}
	if err := s.keepSyncStates(ctx, host, sync.States, now); err != nil {
		return wire.LineageSyncAnswer{}, err
	}
	if len(sync.Links) > 0 && !full || len(sync.States) > 0 {
		kept := sync
		if full {
			kept.Links = nil
		}
		s.lineageChanged(host, kept)
	}
	if full {
		t := true
		return wire.LineageSyncAnswer{Full: &t}, nil
	}
	return wire.LineageSyncAnswer{}, nil
}

func checkSyncLink(l wire.LineageLink) error {
	if err := lineage.CheckNode(l.From); err != nil {
		return err
	}
	if err := lineage.CheckNode(l.To); err != nil {
		return err
	}
	if err := lineage.CheckWord("rel", l.Rel); err != nil {
		return err
	}
	return lineage.CheckWord("source", l.Source)
}

// syncLinkKey is a link apart from its end: the same from, to and rel can start again
// after it ended.
type syncLinkKey struct {
	from, to wire.LineageNode
	rel      string
	at       wire.Date
}

// keepSyncLinks puts links over the machine's copies of them, or in place of them all with
// reset. It says full when there is no copy to put them over.
func (s *Service) keepSyncLinks(ctx context.Context, host string, links []wire.LineageLink, reset bool, now time.Time) (bool, error) {
	var kept storedLinks
	if !reset {
		object, err := s.cfg.Store.Get(ctx, lineageLinksKey(host))
		if err != nil {
			return false, err
		}
		if object == nil || json.Unmarshal(object.Data, &kept) != nil {
			// Nothing to put a change over: the machine sends all it has, the first with
			// reset. What it sent now comes again with it.
			return true, nil
		}
		if len(links) == 0 {
			return false, nil
		}
	}
	at := map[syncLinkKey]int{}
	for i, l := range kept.Links {
		at[syncLinkKey{l.From, l.To, l.Rel, l.At}] = i
	}
	for _, l := range links {
		k := syncLinkKey{l.From, l.To, l.Rel, l.At}
		if i, ok := at[k]; ok {
			kept.Links[i] = l
			continue
		}
		at[k] = len(kept.Links)
		kept.Links = append(kept.Links, l)
	}
	sort.SliceStable(kept.Links, func(i, j int) bool { return kept.Links[i].At < kept.Links[j].At })
	kept.Links = lineage.Bound(kept.Links, now)
	if kept.Links == nil {
		kept.Links = []wire.LineageLink{}
	}
	kept.At = records.At(now)
	data, err := records.Encode(kept)
	if err != nil {
		return false, err
	}
	_, err = s.cfg.Store.Put(ctx, lineageLinksKey(host), data, store.Always)
	return false, err
}

// keepSyncStates adds the changes to the machine's, each once.
func (s *Service) keepSyncStates(ctx context.Context, host string, changes []wire.LineageStateChange, now time.Time) error {
	if len(changes) == 0 {
		return nil
	}
	var kept storedStates
	object, err := s.cfg.Store.Get(ctx, lineageStatesKey(host))
	if err != nil {
		return err
	}
	if object != nil {
		// What cannot be read starts again from what was sent.
		_ = json.Unmarshal(object.Data, &kept)
	}
	kept.States = boundStates(append(kept.States, changes...), now)
	kept.At = records.At(now)
	data, err := records.Encode(kept)
	if err != nil {
		return err
	}
	_, err = s.cfg.Store.Put(ctx, lineageStatesKey(host), data, store.Always)
	return err
}

// boundStates is the changes oldest first, each once, within the bounds at now, as the
// machine bounds its own (lineage.Files.pruneStates): the last lineage.KeepEnded, and each
// session's latest whatever its age; past lineage.MostStates, the oldest that are not a
// session's latest go first, then the oldest.
func boundStates(changes []wire.LineageStateChange, now time.Time) []wire.LineageStateChange {
	sort.SliceStable(changes, func(i, j int) bool { return changes[i].At < changes[j].At })
	seen := map[wire.LineageStateChange]bool{}
	once := changes[:0:0]
	for _, c := range changes {
		if !seen[c] {
			seen[c] = true
			once = append(once, c)
		}
	}
	latest := map[wire.LineageNode]int{}
	for i, c := range once {
		latest[c.Node] = i
	}
	oldest := wire.DateOf(now.Add(-lineage.KeepEnded))
	gone := map[int]bool{}
	for i, c := range once {
		if c.At < oldest && latest[c.Node] != i {
			gone[i] = true
		}
	}
	over := len(once) - len(gone) - lineage.MostStates
	for i := 0; i < len(once) && over > 0; i++ {
		if !gone[i] && latest[once[i].Node] != i {
			gone[i] = true
			over--
		}
	}
	for i := 0; i < len(once) && over > 0; i++ {
		if !gone[i] {
			gone[i] = true
			over--
		}
	}
	kept := make([]wire.LineageStateChange, 0, len(once)-len(gone))
	for i, c := range once {
		if !gone[i] {
			kept = append(kept, c)
		}
	}
	return kept
}

// sweepLineageGraph deletes the objects of machines removed since, and bounds the rest
// again, so a machine that stopped sending loses its old links and states too; at most most
// deletions and writes. A write is only over the object it read: a machine that wrote since
// keeps what it wrote.
func sweepLineageGraph(ctx context.Context, st store.Store, rs *records.Records, now time.Time, most int) (int, error) {
	keys, err := st.List(ctx, lineageGraphPrefix)
	if err != nil {
		return 0, err
	}
	known := map[string]bool{}
	for _, h := range rs.Hosts() {
		known[strings.ToLower(h.ID)] = true
	}
	n := 0
	for _, k := range keys {
		if n >= most {
			break
		}
		host, name, ok := strings.Cut(strings.TrimPrefix(k.Key, lineageGraphPrefix), "/")
		if !ok {
			continue
		}
		object, err := st.Get(ctx, k.Key)
		if err != nil {
			return n, err
		}
		if object == nil {
			continue
		}
		var stamp struct {
			At records.Stamp `json:"at"`
		}
		readable := json.Unmarshal(object.Data, &stamp) == nil
		if !known[host] {
			// A machine another copy has just added is not in these records yet: only an
			// object a day old goes.
			if readable && stamp.At.After(now.Add(-24*time.Hour)) {
				continue
			}
			if err := st.Delete(ctx, k.Key); err != nil {
				return n, err
			}
			n++
			continue
		}
		var data []byte
		switch name {
		case "links.json":
			var kept storedLinks
			if json.Unmarshal(object.Data, &kept) != nil {
				continue
			}
			bounded := lineage.Bound(kept.Links, now)
			if len(bounded) == len(kept.Links) {
				continue
			}
			kept.Links = bounded
			if kept.Links == nil {
				kept.Links = []wire.LineageLink{}
			}
			data, err = records.Encode(kept)
		case "states.json":
			var kept storedStates
			if json.Unmarshal(object.Data, &kept) != nil {
				continue
			}
			before := len(kept.States)
			kept.States = boundStates(kept.States, now)
			if len(kept.States) == before {
				continue
			}
			data, err = records.Encode(kept)
		default:
			continue
		}
		if err != nil {
			return n, err
		}
		if _, err := st.Put(ctx, k.Key, data, store.Matching(object.ETag)); err != nil {
			var conflict *store.ConflictError
			if errors.As(err, &conflict) {
				continue
			}
			return n, err
		}
		n++
	}
	return n, nil
}
