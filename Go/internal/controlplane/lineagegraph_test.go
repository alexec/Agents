package controlplane

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/controllink"
	"github.com/agentloops-dev/agent-loops/Go/internal/controlplane/records"
	"github.com/agentloops-dev/agent-loops/Go/internal/controlplane/store"
	"github.com/agentloops-dev/agent-loops/Go/internal/lineage"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// #4275: lineage/sync keeps each machine's links and its sessions' changes of state, bounded,
// says full when it has no copy of the links, and the sweep bounds them again and deletes a
// removed machine's.
func TestLineageSyncKeepsAMergedCopy(t *testing.T) {
	t.Parallel()
	mem := store.NewMemory()
	p := startPlane(t, mem, controllink.NewPrivateKey())
	host := p.host("OWNERS-MAC").member.Host
	ctx := context.Background()
	now := time.Now()
	session := wire.LineageNode{Kind: "session", Ref: "agents:session:#a1"}
	issue := wire.LineageNode{Kind: "issue", Ref: "github:issue:o/r#1"}
	pr := wire.LineageNode{Kind: "pr", Ref: "github:o/r!2"}
	send := func(sync wire.LineageSync) (wire.LineageSyncAnswer, error) {
		t.Helper()
		params, _ := json.Marshal(sync)
		raw, err := p.s.methods.HostSaid(host, "lineage/sync", params)
		var answer wire.LineageSyncAnswer
		if err == nil {
			b, _ := json.Marshal(raw)
			_ = json.Unmarshal(b, &answer)
		}
		return answer, err
	}
	links := func() []wire.LineageLink {
		t.Helper()
		object, err := mem.Get(ctx, lineageLinksKey(host))
		if err != nil || object == nil {
			t.Fatalf("no links: %v", err)
		}
		var kept storedLinks
		if err := json.Unmarshal(object.Data, &kept); err != nil {
			t.Fatal(err)
		}
		return kept.Links
	}
	states := func() []wire.LineageStateChange {
		t.Helper()
		object, err := mem.Get(ctx, lineageStatesKey(host))
		if err != nil || object == nil {
			t.Fatalf("no states: %v", err)
		}
		var kept storedStates
		if err := json.Unmarshal(object.Data, &kept); err != nil {
			t.Fatal(err)
		}
		return kept.States
	}
	at := wire.DateOf(now.Add(-time.Hour))
	works := wire.LineageLink{From: session, To: issue, Rel: "works-on", Source: "start", At: at}
	working := wire.LineageStateChange{Node: session, State: wire.LineageSessionStateNameWorking, At: wire.DateOf(now)}

	// No copy yet: the states are kept, and the machine is asked for every link.
	answer, err := send(wire.LineageSync{Links: []wire.LineageLink{works}, States: []wire.LineageStateChange{working}})
	if err != nil || answer.Full == nil || !*answer.Full {
		t.Fatalf("want full: %+v %v", answer, err)
	}
	if got := states(); len(got) != 1 || got[0] != working {
		t.Fatalf("states %+v", got)
	}
	if object, _ := mem.Get(ctx, lineageLinksKey(host)); object != nil {
		t.Fatal("links kept without a whole send")
	}

	// The whole send, then a change over it: the link ended, and a new one.
	yes := true
	if answer, err := send(wire.LineageSync{Links: []wire.LineageLink{works}, Reset: &yes}); err != nil || answer.Full != nil {
		t.Fatalf("%+v %v", answer, err)
	}
	ended := works
	endedAt := wire.DateOf(now)
	ended.EndedAt = &endedAt
	opens := wire.LineageLink{From: session, To: pr, Rel: "opens", Source: "agent", At: wire.DateOf(now)}
	stopped := wire.LineageStateChange{Node: session, State: wire.LineageSessionStateNameStopped, At: wire.DateOf(now.Add(time.Second))}
	if answer, err := send(wire.LineageSync{Links: []wire.LineageLink{ended, opens}, States: []wire.LineageStateChange{stopped, working}}); err != nil || answer.Full != nil {
		t.Fatalf("%+v %v", answer, err)
	}
	got := links()
	if len(got) != 2 || got[0].EndedAt == nil || *got[0].EndedAt != endedAt || got[1] != opens {
		t.Fatalf("links %+v", got)
	}
	// A change sent again is kept once.
	if s := states(); len(s) != 2 || s[0] != working || s[1] != stopped {
		t.Fatalf("states %+v", s)
	}

	// A reset starts the links again; the states stay.
	if _, err := send(wire.LineageSync{Links: []wire.LineageLink{opens}, Reset: &yes}); err != nil {
		t.Fatal(err)
	}
	if got := links(); len(got) != 1 || got[0] != opens {
		t.Fatalf("after reset %+v", got)
	}

	// Refused: a state that is not a session's, and a send too big. (A state this build does
	// not know reads as stopped.)
	bad := []wire.LineageSync{
		{States: []wire.LineageStateChange{{Node: issue, State: wire.LineageSessionStateNameWorking, At: working.At}}},
		{Links: make([]wire.LineageLink, mostSyncLinks+1)},
	}
	for _, b := range bad {
		if _, err := send(b); err == nil {
			t.Fatalf("took %+v", b)
		}
	}

	// The sweep, 91 days on: the ended link and the old changes go, but each session's last
	// state. A removed machine's objects go once a day old.
	later := now.Add(91 * 24 * time.Hour)
	old := wire.LineageLink{From: session, To: issue, Rel: "reviews", Source: "agent", At: at, EndedAt: &endedAt}
	if _, err := send(wire.LineageSync{Links: []wire.LineageLink{old}}); err != nil {
		t.Fatal(err)
	}
	other := wire.LineageNode{Kind: "session", Ref: "agents:session:#b2"}
	archived := wire.LineageStateChange{Node: other, State: wire.LineageSessionStateNameArchived, At: wire.DateOf(now)}
	if _, err := send(wire.LineageSync{States: []wire.LineageStateChange{archived}}); err != nil {
		t.Fatal(err)
	}
	gone := lineageGraphPrefix + "gone-mac/links.json"
	data, _ := records.Encode(storedLinks{Links: []wire.LineageLink{}, At: records.At(now)})
	if _, err := mem.Put(ctx, gone, data, store.Always); err != nil {
		t.Fatal(err)
	}
	if n, err := sweepLineageGraph(ctx, mem, p.s.records, later, 10); err != nil || n != 3 {
		t.Fatalf("swept %d %v", n, err)
	}
	if got := links(); len(got) != 1 || got[0] != opens {
		t.Fatalf("links after the sweep %+v", got)
	}
	if s := states(); len(s) != 2 || s[0] != archived || s[1] != stopped {
		t.Fatalf("states after the sweep %+v", s)
	}
	if object, _ := mem.Get(ctx, gone); object != nil {
		t.Fatal("a removed machine's links were kept")
	}
	if n, _ := sweepLineageGraph(ctx, mem, p.s.records, later, 10); n != 0 {
		t.Fatalf("swept again: %d", n)
	}
}

// #4275: the states are bounded by count, the oldest that are not a session's latest first.
func TestLineageStatesAreBounded(t *testing.T) {
	t.Parallel()
	now := time.Now()
	var changes []wire.LineageStateChange
	for i := range lineage.MostStates + 10 {
		changes = append(changes, wire.LineageStateChange{Node: wire.LineageNode{Kind: "session", Ref: "agents:session:#x"},
			State: wire.LineageSessionStateNameWorking, At: wire.DateOf(now.Add(time.Duration(i) * time.Second))})
	}
	kept := boundStates(changes, now)
	if len(kept) != lineage.MostStates || kept[0].At != changes[10].At {
		t.Fatalf("%d, first %v", len(kept), kept[0].At)
	}
}
