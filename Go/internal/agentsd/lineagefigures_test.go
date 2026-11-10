package agentsd

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/wire"
)

// #4427: a milestone's figures are its rollup's cost and sessions, the runtimes and how many
// run now, the releases that took its issues (each in the first one) and, once closed, the
// last of them; a release's are the milestones it finished and its lead time.
func TestLineageFiguresByMilestoneAndByRelease(t *testing.T) {
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
	m3, m4 := repo.milestone(3), repo.milestone(4)
	v41, v42, v43 := repo.release("v0.41.0"), repo.release("v0.42.0"), repo.release("v0.43.0")
	tagged := time.Now().Add(time.Hour)
	d.lineageDo(func() {
		d.link(repo.issue(12), m3, lineage.RelPartOf, lineage.SourceForge)
		d.link(repo.issue(13), m3, lineage.RelPartOf, lineage.SourceForge)
		d.link(repo.pr(40), repo.issue(12), lineage.RelFixes, lineage.SourcePRBody)
		d.link(repo.pr(41), repo.issue(13), lineage.RelFixes, lineage.SourcePRBody)
		d.linkAt(repo.pr(40), v41, lineage.RelPartOf, lineage.SourceForge, tagged)
		// A PR in two releases is taken by the first.
		d.linkAt(repo.pr(41), v43, lineage.RelPartOf, lineage.SourceForge, tagged)
		d.linkAt(repo.pr(41), v42, lineage.RelPartOf, lineage.SourceForge, tagged)
		// Shipped in by its title, though no item of it is.
		d.link(m4, v41, lineage.RelShippedIn, lineage.SourceForge)
	})
	d.lineageSettle(2 * time.Second)
	d.bankSessionCost(a.ID, wire.Cost{Amount: 1, Currency: "USD"})
	d.bankSessionCost(b.ID, wire.Cost{Amount: 2, Currency: "USD"})
	d.bankSessionCost(other.ID, wire.Cost{Amount: 5, Currency: "USD"})
	closed := "closed"
	d.resolveMu.Lock()
	if d.resolveCache == nil {
		d.resolveCache = map[wire.LineageNode]resolvedEntry{}
	}
	d.resolveCache[m3] = resolvedEntry{resolved: wire.LineageResolved{Title: "Projects", State: &closed}, ok: true, at: time.Now()}
	d.resolveMu.Unlock()

	figures := func(id int, n wire.LineageNode) wire.LineageFigures {
		var got wire.LineageFigures
		if err := json.Unmarshal(c.call(t, id, "lineage/figures", wire.LineageNodeRequest{Node: n}), &got); err != nil {
			t.Fatal(err)
		}
		return got
	}
	m := figures(1, m3)
	if usd(m.Cost) != 3 || m.Sessions != 2 || m.Running != 1 {
		t.Fatalf("milestone %+v", m)
	}
	if len(m.Runtimes) != 2 || m.Runtimes[0] != (wire.LineageRuntimeCount{RuntimeID: "claude", Sessions: 1}) ||
		m.Runtimes[1] != (wire.LineageRuntimeCount{RuntimeID: "codex", Sessions: 1}) {
		t.Fatalf("runtimes %+v", m.Runtimes)
	}
	want := []wire.LineageReleaseTook{{Release: v41, Tag: "v0.41.0", Items: 1}, {Release: v42, Tag: "v0.42.0", Items: 1}}
	if len(m.ReleasedIn) != 2 || m.ReleasedIn[0] != want[0] || m.ReleasedIn[1] != want[1] {
		t.Fatalf("released in %+v", m.ReleasedIn)
	}
	if m.FinishedIn == nil || *m.FinishedIn != v42 {
		t.Fatalf("finished in %+v", m.FinishedIn)
	}
	// m4 is open (not resolved): released in by its title, finished in none.
	if m := figures(2, m4); len(m.ReleasedIn) != 1 || m.ReleasedIn[0] != (wire.LineageReleaseTook{Release: v41, Tag: "v0.41.0"}) || m.FinishedIn != nil {
		t.Fatalf("m4 %+v", m)
	}

	r := figures(3, v42)
	if usd(r.Cost) != 2 || r.Sessions != 1 || r.Running != 0 || len(r.MilestonesFinished) != 1 ||
		r.MilestonesFinished[0].Milestone != m3 || r.MilestonesFinished[0].Title == nil || *r.MilestonesFinished[0].Title != "Projects" {
		t.Fatalf("v0.42.0 %+v", r)
	}
	if r.LeadTimeSeconds == nil || *r.LeadTimeSeconds < 3000 || *r.LeadTimeSeconds > 3700 {
		t.Fatalf("lead time %v", r.LeadTimeSeconds)
	}
	// v0.41.0 finished m4 by its title; m3's last release is v0.42.0.
	if r := figures(4, v41); len(r.MilestonesFinished) != 1 || r.MilestonesFinished[0].Milestone != m4 {
		t.Fatalf("v0.41.0 %+v", r.MilestonesFinished)
	}
	if r := figures(5, v43); len(r.MilestonesFinished) != 0 {
		t.Fatalf("v0.43.0 %+v", r.MilestonesFinished)
	}
	if e := c.callError(t, 6, "lineage/figures", wire.LineageNodeRequest{Node: repo.issue(12)}); e == nil {
		t.Fatal("an issue's figures were not refused")
	}
}
