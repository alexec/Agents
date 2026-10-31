package controlplane

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// #2350: usage/rollup's work keeps each machine's latest copy of each node, 90 days, and a
// removed machine's nodes are swept.
func TestRollupKeepsTheCostOnLinks(t *testing.T) {
	t.Parallel()
	mem := store.NewMemory()
	p := startPlane(t, mem, controllink.NewPrivateKey())
	host := p.host("OWNERS-MAC").member.Host
	now := time.Now()
	node := func(ref string, usd float64, at time.Time) wire.LineageCostNode {
		return wire.LineageCostNode{Node: wire.LineageNode{Kind: "issue", Ref: ref},
			Banked: wire.LineageCost{Cost: map[string]float64{"USD": usd}}, LastAt: wire.DateOf(at)}
	}
	send := func(work ...wire.LineageCostNode) {
		t.Helper()
		params, _ := json.Marshal(wire.UsageRollup{Hours: []wire.UsageRollupPeriod{}, Days: []wire.UsageRollupPeriod{}, Work: work})
		if _, err := p.s.methods.HostSaid(host, "usage/rollup", params); err != nil {
			t.Fatal(err)
		}
	}
	send(node("github:o/r#1", 1, now), node("github:o/r#2", 2, now), node("github:o/r#3", 4, now.Add(-91*24*time.Hour)))
	send(node("github:o/r#1", 5, now))
	read := func() map[string]float64 {
		t.Helper()
		object, err := mem.Get(context.Background(), lineageKey(host))
		if err != nil || object == nil {
			t.Fatal(err)
		}
		var kept storedLineage
		if err := json.Unmarshal(object.Data, &kept); err != nil {
			t.Fatal(err)
		}
		out := map[string]float64{}
		for _, n := range kept.Nodes {
			out[n.Node.Ref] = n.Banked.Cost["USD"]
		}
		return out
	}
	if got := read(); len(got) != 2 || got["github:o/r#1"] != 5 || got["github:o/r#2"] != 2 {
		t.Fatalf("%v", got)
	}

	// A machine not in the records: kept a day, in case another copy just added it.
	orphan := lineageKey("GONE-MAC")
	data, _ := json.Marshal(storedLineage{})
	if _, err := mem.Put(context.Background(), orphan, data, store.Always); err != nil {
		t.Fatal(err)
	}
	if n, err := sweepLineage(context.Background(), mem, p.s.records, now, 10); err != nil || n != 1 {
		t.Fatalf("%d %v", n, err)
	}
	if n, _ := sweepLineage(context.Background(), mem, p.s.records, now, 10); n != 0 {
		t.Fatalf("swept a known machine's: %d", n)
	}
}
