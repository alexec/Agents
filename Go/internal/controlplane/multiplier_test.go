package controlplane

import (
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
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
		return wire.LineageCostNode{Node: wire.LineageNode{Kind: "pr", Ref: fmt.Sprintf("github:o/r#%d", n)},
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

	if m := count(mac.member.Host); m.PrsMerged != 0 || m.Multiplier != nil || m.Baseline.PrsPerWeek != 1.4 {
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
	if b := count(beas.member.Host); b.PrsMerged != 2 {
		t.Fatalf("Bea's: %+v", b)
	}
}
