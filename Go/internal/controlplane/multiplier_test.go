package controlplane

import (
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/controllink"
	"github.com/agentloops-dev/agent-loops/Go/internal/controlplane/store"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// multiplier/count (#3903): a person's merged PRs over all their machines, each PR once,
// none of another person's; a new send counts again.
func TestMultiplierCountsThePersonsMachines(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	mac, mini := p.host("OWNERS-MAC"), p.host("OWNERS-MINI")
	_, admin := p.client("Owner's window")
	bea := p.invite(admin, "Bea", wire.UserRoleMember)
	beas := p.machine(bea, "BEAS-MAC")

	ended := wire.DateOf(time.Now().Add(-time.Hour))
	pr := func(n int, outcome string) wire.LineageCostNode {
		return wire.LineageCostNode{Node: wire.LineageNode{Kind: "pr", Ref: fmt.Sprintf("github:pr:o/r#%d", n)},
			Banked: wire.LineageCost{Cost: map[string]float64{}}, LastAt: ended, Outcome: &outcome, EndedAt: &ended,
			Sessions: []string{"s"}}
	}
	send := func(host string, work ...wire.LineageCostNode) {
		t.Helper()
		params, _ := json.Marshal(wire.UsageRollup{Hours: []wire.UsageRollupPeriod{}, Days: []wire.UsageRollupPeriod{}, Work: work})
		if _, err := p.s.methods.HostSaid(host, "usage/rollup", params); err != nil {
			t.Fatal(err)
		}
	}
	count := func(host string) wire.Multiplier {
		t.Helper()
		out, err := p.s.methods.HostSaid(host, "multiplier/count", json.RawMessage(`{}`))
		if err != nil {
			t.Fatal(err)
		}
		data, _ := json.Marshal(out)
		var m wire.Multiplier
		if err := json.Unmarshal(data, &m); err != nil {
			t.Fatal(err)
		}
		return m
	}

	if m := count(mac.member.Host); m.PrsMerged != 0 || m.Multiplier != nil || m.Baseline.PrsPerWeek != 1.4 || m.FirstMergeAt != nil {
		t.Fatalf("nothing merged: %+v", m)
	}
	// Five on the Mac, two more and one both heard on the mini; Bea's are hers.
	send(mac.member.Host, pr(1, "merged"), pr(2, "merged"), pr(3, "merged"), pr(4, "merged"), pr(5, "merged"))
	send(mini.member.Host, pr(5, "merged"), pr(6, "merged"), pr(7, "merged"))
	send(beas.member.Host, pr(8, "merged"), pr(9, "merged"))
	m := count(mac.member.Host)
	if m.PrsMerged != 7 || m.Multiplier == nil || *m.Multiplier != 5 || *m.EngineerHours != 200 {
		t.Fatalf("seven merged: %+v", m)
	}
	if again := count(mini.member.Host); again.PrsMerged != 7 {
		t.Fatalf("the mini: %+v", again)
	}
	// A revert merged since: the figure kept is counted again.
	send(mini.member.Host, pr(10, "reverted"))
	if m := count(mac.member.Host); m.PrsMerged != 6 || m.Reverts != 1 || *m.Multiplier != 4.3 {
		t.Fatalf("one revert: %+v", m)
	}
	// No best week before the first merge is 7 days old (#3988); then the best calendar week.
	if m := count(mac.member.Host); m.BestWeek != nil || m.MostAtOnce != nil {
		t.Fatalf("a best week too soon: %+v", m)
	}
	old := wire.DateOf(time.Now().Add(-21 * 24 * time.Hour))
	first := pr(11, "merged")
	first.EndedAt, first.LastAt = &old, old
	send(mac.member.Host, first)
	if m := count(mac.member.Host); m.BestWeek == nil || *m.BestWeek < 0.7 {
		t.Fatalf("a best week: %+v", m)
	}
	if m := count(mac.member.Host); m.FirstMergeAt == nil || *m.FirstMergeAt != old {
		t.Fatalf("first merge %v, want %v (#4250)", m.FirstMergeAt, old)
	}
	// Cara merged one 30 days ago and none this week: not this week, but not never.
	month := wire.DateOf(time.Now().Add(-30 * 24 * time.Hour))
	cara := p.machine(p.invite(admin, "Cara", wire.UserRoleMember), "CARAS-MAC")
	once := pr(12, "merged")
	once.EndedAt, once.LastAt = &month, month
	send(cara.member.Host, once)
	if c := count(cara.member.Host); c.PrsMerged != 0 || c.Multiplier != nil || c.FirstMergeAt == nil || *c.FirstMergeAt != month {
		t.Fatalf("merged a month ago: %+v", c)
	}
	if b := count(beas.member.Host); b.PrsMerged != 2 {
		t.Fatalf("Bea's: %+v", b)
	}
	// The person's own baseline, sent by the host (#3991): the 6 PRs over 2 a week.
	out, err := p.s.methods.HostSaid(mac.member.Host, "multiplier/count", json.RawMessage(`{"prsPerWeek":2}`))
	if err != nil {
		t.Fatal(err)
	}
	data, _ := json.Marshal(out)
	var own wire.Multiplier
	if err := json.Unmarshal(data, &own); err != nil {
		t.Fatal(err)
	}
	if own.Baseline.PrsPerWeek != 2 || *own.Multiplier != 3 || *own.EngineerHours != 120 {
		t.Fatalf("against 2 a week: %+v", own)
	}
}
