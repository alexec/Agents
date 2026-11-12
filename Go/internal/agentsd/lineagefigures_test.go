package agentsd

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/wire"
)

// #4427: a release's figures are its rollup's cost and sessions, the runtimes and how many
// run now, and its lead time. A milestone's are refused since #3878, as an issue's are.
func TestLineageFiguresOfARelease(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	folder := t.TempDir()
	repo := forgeRepo{"github", "alexec/agents"}
	d.repos = map[string]forgeRepo{folder: repo}
	session := func(runtime string, state wire.AgentState, labels ...string) wire.Agent {
		a := seeded(t, d, folder, func(a *wire.Agent) {
			a.RuntimeID, a.State = runtime, state
			for _, l := range labels {
				a.Labels = append(a.Labels, wire.SessionLabel{Value: l, Owner: wire.SessionLabelOwnerAgent})
			}
		})
		d.noteLineage(nil, a)
		return a
	}
	a := session("claude", wire.AgentStateRunning, "#12", "P#40")
	b := session("codex", wire.AgentStateFinished, "#13", "P#41")
	other := session("claude", wire.AgentStateRunning, "#99")
	v41, v42 := repo.release("v0.41.0"), repo.release("v0.42.0")
	tagged := time.Now().Add(time.Hour)
	d.lineageDo(func() {
		d.link(repo.pr(40), repo.issue(12), lineage.RelFixes, lineage.SourcePRBody)
		d.link(repo.pr(41), repo.issue(13), lineage.RelFixes, lineage.SourcePRBody)
		d.linkAt(repo.pr(40), v41, lineage.RelPartOf, lineage.SourceForge, tagged)
		d.linkAt(repo.pr(41), v42, lineage.RelPartOf, lineage.SourceForge, tagged)
		d.linkAt(repo.pr(40), v42, lineage.RelPartOf, lineage.SourceForge, tagged)
	})
	d.lineageSettle(2 * time.Second)
	d.bankSessionCost(a.ID, wire.Cost{Amount: 1, Currency: "USD"})
	d.bankSessionCost(b.ID, wire.Cost{Amount: 2, Currency: "USD"})
	d.bankSessionCost(other.ID, wire.Cost{Amount: 5, Currency: "USD"})

	figures := func(id int, n wire.LineageNode) wire.LineageFigures {
		var got wire.LineageFigures
		if err := json.Unmarshal(c.call(t, id, "lineage/figures", wire.LineageNodeRequest{Node: n}), &got); err != nil {
			t.Fatal(err)
		}
		return got
	}
	r := figures(1, v42)
	if usd(r.Cost) != 3 || r.Sessions != 2 || r.Running != 1 {
		t.Fatalf("v0.42.0 %+v", r)
	}
	if len(r.Runtimes) != 2 || r.Runtimes[0] != (wire.LineageRuntimeCount{RuntimeID: "claude", Sessions: 1}) ||
		r.Runtimes[1] != (wire.LineageRuntimeCount{RuntimeID: "codex", Sessions: 1}) {
		t.Fatalf("runtimes %+v", r.Runtimes)
	}
	if r.LeadTimeSeconds == nil || *r.LeadTimeSeconds < 3000 || *r.LeadTimeSeconds > 3700 {
		t.Fatalf("lead time %v", r.LeadTimeSeconds)
	}
	if r := figures(2, v41); usd(r.Cost) != 1 || r.Sessions != 1 {
		t.Fatalf("v0.41.0 %+v", r)
	}
	milestone := wire.LineageNode{Kind: "milestone", Ref: "github:milestone:alexec/agents#3"}
	if e := c.callError(t, 3, "lineage/figures", wire.LineageNodeRequest{Node: milestone}); e == nil {
		t.Fatal("a milestone's figures were not refused")
	}
	if e := c.callError(t, 4, "lineage/figures", wire.LineageNodeRequest{Node: repo.issue(12)}); e == nil {
		t.Fatal("an issue's figures were not refused")
	}
}
