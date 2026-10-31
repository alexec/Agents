package controlplane

import (
	"context"
	"encoding/json"
	"sort"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// Cost on the link (#2350): each machine's banked cost per lineage node (an issue, a PR, a
// session), as usage/rollup's work sends it, under v1/lineage/<host>.json. A node sent
// replaces that machine's copy of it, so the latest of each is kept, 90 days after it last
// changed and at most lineageNodesKept a machine. Only that machine writes its object.
// The machines' copies of one node add up, as each banked its own turns; reading them
// (lineage.Rollup) comes with the lineage view (#2351).

const (
	lineagePrefix = "v1/lineage/"
	// lineageNodesKept bounds a machine's object, as the host bounds its own file.
	lineageNodesKept = 5_000
	// mostWorkNodes bounds one send.
	mostWorkNodes   = 1_000
	lineageNodeKept = 90 * 24 * time.Hour
)

// storedLineage is one machine's nodes as the store keeps them.
type storedLineage struct {
	Nodes []wire.LineageCostNode `json:"nodes"`
	At    records.Stamp          `json:"at"`
}

func lineageKey(host string) string { return lineagePrefix + strings.ToLower(host) + ".json" }

// keepWork is usage/rollup's work: the nodes sent, over this machine's copies of them.
func (s *Service) keepWork(ctx context.Context, host string, work []wire.LineageCostNode, now time.Time) error {
	if len(work) == 0 {
		return nil
	}
	if len(work) > mostWorkNodes {
		return fail(invalidParams, "Send at most %d lineage nodes at a time.", mostWorkNodes)
	}
	var kept storedLineage
	object, err := s.cfg.Store.Get(ctx, lineageKey(host))
	if err != nil {
		return err
	}
	if object != nil {
		// What cannot be read starts again from what was sent.
		_ = json.Unmarshal(object.Data, &kept)
	}
	byKey := map[wire.LineageNode]wire.LineageCostNode{}
	for _, n := range kept.Nodes {
		byKey[n.Node] = n
	}
	for _, n := range work {
		if n.Node.Kind == "" || n.Node.Ref == "" {
			return fail(invalidParams, "A lineage node needs a kind and a ref.")
		}
		byKey[n.Node] = n
	}
	oldest := wire.DateOf(now.Add(-lineageNodeKept))
	nodes := make([]wire.LineageCostNode, 0, len(byKey))
	for _, n := range byKey {
		if n.LastAt >= oldest {
			nodes = append(nodes, n)
		}
	}
	// Newest first, so the oldest go past the bound.
	sort.Slice(nodes, func(i, j int) bool {
		if nodes[i].LastAt != nodes[j].LastAt {
			return nodes[i].LastAt > nodes[j].LastAt
		}
		return nodes[i].Node.Ref < nodes[j].Node.Ref
	})
	if len(nodes) > lineageNodesKept {
		nodes = nodes[:lineageNodesKept]
	}
	data, err := records.Encode(storedLineage{Nodes: nodes, At: records.At(now)})
	if err != nil {
		return err
	}
	_, err = s.cfg.Store.Put(ctx, lineageKey(host), data, store.Always)
	return err
}

// sweepLineage deletes the nodes of machines removed since, at most most: no machine
// writes them again, and the rest age out as each machine sends.
func sweepLineage(ctx context.Context, st store.Store, rs *records.Records, now time.Time, most int) (int, error) {
	keys, err := st.List(ctx, lineagePrefix)
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
		if known[strings.TrimSuffix(strings.TrimPrefix(k.Key, lineagePrefix), ".json")] {
			continue
		}
		// A machine another copy has just added is not in these records yet: only an
		// object a day old goes.
		object, err := st.Get(ctx, k.Key)
		if err != nil {
			return n, err
		}
		var kept storedLineage
		if object == nil || json.Unmarshal(object.Data, &kept) == nil && kept.At.After(now.Add(-24*time.Hour)) {
			continue
		}
		if err := st.Delete(ctx, k.Key); err != nil {
			return n, err
		}
		n++
	}
	return n, nil
}
