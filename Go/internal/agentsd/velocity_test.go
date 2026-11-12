package agentsd

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/wire"
)

// #4596: two merged PRs and a merged revert on two days, in two repositories, go in their
// hours and days; a PR no session worked on, one still open, one closed without a merge and
// one older than the 90 days count nothing.
func TestVelocityHistoryCountsTheLandedPRs(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	now := time.Now()
	yesterday := now.Add(-24 * time.Hour)
	str := func(s string) *string { return &s }
	pr := func(ref, repo string, outcome *string, at time.Time, sessions ...string) wire.LineageCostNode {
		end := wire.DateOf(at)
		return wire.LineageCostNode{Node: wire.LineageNode{Kind: lineage.KindPR, Ref: ref}, Repo: str(repo),
			Banked: wire.LineageCost{Cost: map[string]float64{}}, Outcome: outcome, EndedAt: &end, Sessions: sessions}
	}
	merged, reverted, closed := str(lineage.OutcomeMerged), str(lineage.OutcomeReverted), str(lineage.OutcomeClosed)
	d.workMu.Lock()
	f := d.costLedgerLocked()
	var nodes []wire.LineageCostNode
	for _, n := range []wire.LineageCostNode{
		pr("github:alexec/agents#1", "github:alexec/agents", merged, yesterday, "s1"),
		pr("github:alexec/agents#2", "github:alexec/agents", merged, now, "s2"),
		pr("github:alexec/agents#3", "github:alexec/agents", reverted, now, "s3"),
		pr("github:alexec/other#4", "github:alexec/other", merged, now, "s4"),
		pr("github:alexec/agents#5", "github:alexec/agents", merged, now),                           // no session
		pr("github:alexec/agents#6", "github:alexec/agents", nil, now, "s6"),                        // still open
		pr("github:alexec/agents#7", "github:alexec/agents", closed, now, "s7"),                     // closed
		pr("github:alexec/agents#8", "github:alexec/agents", merged, now.AddDate(0, 0, -120), "s8"), // too old
	} {
		f.Nodes[costKey(n.Node)] = n
		nodes = append(nodes, n)
	}
	// As noteMergeLocked keeps it when each PR's outcome changes: the sessions are its
	// lineage links, which a refresh would read again and this test has none of.
	d.multiplierMerges = lineage.Merges(nodes, lineage.AllMerges)
	d.workMu.Unlock()

	var h wire.VelocityHistory
	if err := json.Unmarshal(c.call(t, 1, "velocity/history", map[string]any{}), &h); err != nil {
		t.Fatal(err)
	}
	if h.Now != hourStamp(now) || h.TimeZone == nil {
		t.Fatalf("now %q, zone %v", h.Now, h.TimeZone)
	}
	agents, other := "github:alexec/agents", "github:alexec/other"
	today := map[string]wire.VelocityBucket{agents: {Merged: 2, Reverted: 1}, other: {Merged: 1}}
	if dayStamp(yesterday) == dayStamp(now) {
		t.Skip("yesterday is today")
	}
	if got := h.Days[dayStamp(now)]; len(got) != 2 || got[agents] != today[agents] || got[other] != today[other] {
		t.Fatalf("today: %+v", got)
	}
	if got := h.Days[dayStamp(yesterday)]; len(got) != 1 || got[agents] != (wire.VelocityBucket{Merged: 1}) {
		t.Fatalf("yesterday: %+v", got)
	}
	if len(h.Days) != 2 {
		t.Fatalf("days: %+v", h.Days)
	}
	if got := h.Hours[hourStamp(now)]; got[agents] != today[agents] || got[other] != today[other] {
		t.Fatalf("this hour: %+v", got)
	}
	if got := h.Hours[hourStamp(yesterday)]; got[agents] != (wire.VelocityBucket{Merged: 1}) {
		t.Fatalf("yesterday's hour: %+v", got)
	}
}
