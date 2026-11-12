package controlplane

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// #4276: the control plane answers lineage reads from the merged copy, over every machine in
// the scope, also one that sent and then went to sleep; a member sees only their own
// machines; a sync tells the machine's person and the admins what changed.
func TestLineageReadsMergeEveryMachine(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	owner := p.host("OWNERS-MAC")
	_, admin := p.client("Owner's window")
	bea := p.invite(admin, "Bea", wire.UserRoleMember)
	beas := p.machine(bea, "BEAS-MAC")

	now := time.Now()
	epic := wire.LineageNode{Kind: "issue", Ref: "github:issue:o/r#1"}
	child := wire.LineageNode{Kind: "issue", Ref: "github:issue:o/r#2"}
	pr := wire.LineageNode{Kind: "pr", Ref: "github:o/r!3"}
	lead := wire.LineageNode{Kind: "session", Ref: "agents:session:#lead"}
	lane := wire.LineageNode{Kind: "session", Ref: "agents:session:#lane"}
	at := func(ago time.Duration) wire.Date { return wire.DateOf(now.Add(-ago)) }
	link := func(from, to wire.LineageNode, rel string, ago time.Duration) wire.LineageLink {
		return wire.LineageLink{From: from, To: to, Rel: rel, Source: "start", At: at(ago)}
	}
	partOf := link(child, epic, "part-of", 5*time.Hour)
	send := func(host string, sync wire.LineageSync) {
		t.Helper()
		params, _ := json.Marshal(sync)
		if _, err := p.s.methods.HostSaid(host, "lineage/sync", params); err != nil {
			t.Fatal(err)
		}
	}
	yes := true
	// The owner's machine leads the epic; Bea's works on the child, opens a PR, and sleeps.
	send(owner.member.Host, wire.LineageSync{Reset: &yes, Links: []wire.LineageLink{partOf, link(lead, epic, "works-on", 4*time.Hour)},
		States: []wire.LineageStateChange{{Node: lead, State: wire.LineageSessionStateNameWaiting, At: at(time.Hour)}}})
	waitNote(t, admin, "control/lineageChanged")
	send(beas.member.Host, wire.LineageSync{Reset: &yes, Links: []wire.LineageLink{partOf,
		link(lane, child, "works-on", 3*time.Hour), link(lane, pr, "opens", 2*time.Hour)},
		States: []wire.LineageStateChange{
			{Node: lane, State: wire.LineageSessionStateNameStopped, At: at(3 * time.Hour)},
			{Node: lane, State: wire.LineageSessionStateNameWorking, At: at(time.Minute)},
		}})
	// Bea's machine's change reaches Bea and the admin.
	note := waitNote(t, bea.window, "control/lineageChanged")
	var change wire.LineageChanged
	if err := json.Unmarshal(note.Params, &change); err != nil || change.Host != beas.member.Host || len(change.States) != 2 ||
		change.Links == nil || !*change.Links {
		t.Fatalf("%s %v", note.Params, err)
	}
	waitNote(t, admin, "control/lineageChanged")

	sessions := func(s *controllink.Session, scope *wire.ReportScope, nodes ...wire.LineageNode) wire.LineageSessionsOn {
		t.Helper()
		var got wire.LineageSessionsOn
		if err := json.Unmarshal(call(t, s, "", "lineage/sessionsOn", wire.LineageSessionsOnRequest{Nodes: nodes, Scope: scope}), &got); err != nil {
			t.Fatal(err)
		}
		return got
	}
	org := &wire.ReportScope{Kind: wire.ReportScopeKindOrg}
	got := sessions(admin, org, epic, child)
	if len(got.Sessions) != 2 {
		t.Fatalf("%+v", got)
	}
	first, second := got.Sessions[0], got.Sessions[1]
	if first.Node != lead || first.Host != owner.member.Host || len(first.On) != 1 || first.On[0] != epic ||
		first.At != at(4*time.Hour) || first.State == nil || first.State.State != wire.LineageSessionStateNameWaiting {
		t.Fatalf("%+v", first)
	}
	// The PR is not asked for: the lane is on the child only, and working now.
	if second.Node != lane || second.Host != beas.member.Host || len(second.On) != 1 || second.On[0] != child ||
		second.State == nil || second.State.State != wire.LineageSessionStateNameWorking {
		t.Fatalf("%+v", second)
	}

	// The walk goes over both machines: the epic, its child (once, though both sent it), both
	// sessions and the PR, with the states now.
	var g wire.LineageGraph
	depth := int64(3)
	if err := json.Unmarshal(call(t, admin, "", "lineage/walkAll", wire.LineageWalkAllRequest{Node: epic, Depth: &depth, Scope: org}), &g); err != nil {
		t.Fatal(err)
	}
	if len(g.Nodes) != 5 || len(g.Links) != 4 || g.States[lane.Ref].State != wire.LineageSessionStateNameWorking ||
		g.States[lead.Ref].State != wire.LineageSessionStateNameWaiting {
		t.Fatalf("%+v", g)
	}

	// Bea sees only her own machine, and not the organisation.
	if mine := sessions(bea.window, nil, epic, child); len(mine.Sessions) != 1 || mine.Sessions[0].Node != lane {
		t.Fatalf("%+v", mine)
	}
	if e := callError(t, bea.window, "", "lineage/sessionsOn", wire.LineageSessionsOnRequest{Nodes: []wire.LineageNode{epic}, Scope: org}); e == "" {
		t.Fatal("a member read the organisation")
	}
	if e := callError(t, admin, "", "lineage/sessionsOn", wire.LineageSessionsOnRequest{Nodes: []wire.LineageNode{{Kind: "Issue", Ref: "x"}}}); e == "" {
		t.Fatal("a bad node was read")
	}
}
