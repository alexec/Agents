package agentsd

import (
	"context"
	"encoding/json"
	"strconv"
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

// #4552: a merged PR's files and the PR it reverts are asked of the forge, and a repo's
// figures carry its delivery figures.
func TestLineageFiguresOfARepo(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	folder := t.TempDir()
	repo := forgeRepo{"github", "alexec/agents"}
	d.repos = map[string]forgeRepo{folder: repo}
	// A session in the folder makes it one of the daemon's, signed in to the repo.
	seeded(t, d, folder, func(*wire.Agent) {})
	d.workMu.Lock()
	d.prFactsLookup = func(_ context.Context, in string, r forgeRepo, n int) (prFacts, error) {
		if in != folder || r != repo {
			t.Errorf("asked in %s of %v", in, r)
		}
		if n == 41 {
			return prFacts{files: []string{"a.go"}, body: "Reverts alexec/agents#40"}, nil
		}
		return prFacts{files: []string{"a.go", "b.go"}}, nil
	}
	d.workMu.Unlock()
	merged := func(n int, title string) {
		d.lineageEvent(wire.Event{Name: "pr.merged", Details: map[string]string{"payload": `{"pr":{"number":` + strconv.Itoa(n) +
			`,"title":` + strconv.Quote(title) + `,"url":"https://github.com/alexec/Agents/pull/` + strconv.Itoa(n) + `"}}`}})
	}
	merged(40, "Add x")
	merged(41, `Revert "Add x"`)
	node := func(n int) wire.LineageCostNode {
		d.workMu.Lock()
		defer d.workMu.Unlock()
		return d.costLedgerLocked().Nodes[costKey(repo.pr(n))]
	}
	waitFor(t, "the merged PRs' files", func() bool { return len(node(40).Files) == 2 && len(node(41).Files) == 1 })
	if r := node(41).Reverts; r == nil || *r != repo.pr(40).Ref {
		t.Fatalf("reverts %v", r)
	}
	d.lineageDo(func() {
		d.linkAt(repo.pr(40), repo.release("v0.41.0"), lineage.RelPartOf, lineage.SourceForge, time.Now().Add(-time.Hour))
	})
	d.lineageSettle(2 * time.Second)

	var got wire.LineageFigures
	of := lineage.RepoNode(wire.Ref{Provider: "github", Topic: "alexec/agents"})
	if err := json.Unmarshal(c.call(t, 1, "lineage/figures", wire.LineageNodeRequest{Node: of}), &got); err != nil {
		t.Fatal(err)
	}
	f := got.Delivery
	if f == nil || f.WindowDays != 28 || f.DeploymentFrequency.Count != 1 {
		t.Fatalf("delivery %+v", f)
	}
	// Two merged, one a revert; the revert recovers, and changes a.go, which #40 changed.
	if f.ChangeFailureRate.Count != 2 || f.ChangeFailureRate.Value == nil || *f.ChangeFailureRate.Value != 0.5 {
		t.Errorf("change failure rate %+v", f.ChangeFailureRate)
	}
	if f.RecoveryTime.Count != 1 || f.ReworkRate.Count != 2 || f.ReworkRate.Value == nil || *f.ReworkRate.Value != 0.5 {
		t.Errorf("recovery %+v, rework %+v", f.RecoveryTime, f.ReworkRate)
	}
	if got.LeadTimeSeconds != nil {
		t.Errorf("a repo's lead time is in delivery, not %v", *got.LeadTimeSeconds)
	}
}

// #4552: GitHub's and GitLab's answers for a merged PR's files and description.
func TestPRFactsOf(t *testing.T) {
	gh, err := githubPRFactsOf([]byte(`{"body":"Reverts o/r#3","files":[{"path":"a.go","additions":1},{"path":"b/c.go"}]}`))
	if err != nil || gh.body != "Reverts o/r#3" || len(gh.files) != 2 || gh.files[1] != "b/c.go" {
		t.Errorf("github %+v %v", gh, err)
	}
	gl, err := gitlabPRFactsOf([]byte(`{"description":"x","changes":[{"old_path":"a.go","new_path":"a.go"},{"old_path":"old.go","new_path":"new.go"}]}`))
	if err != nil || len(gl.files) != 3 || gl.files[1] != "new.go" || gl.files[2] != "old.go" {
		t.Errorf("gitlab %+v %v", gl, err)
	}
	if _, err := githubPRFactsOf([]byte("not json")); err == nil {
		t.Error("not json: want an error")
	}
}

// #4552: a PR's files are kept while the rework rate can count them, not as long as its node.
func TestPruneCostDropsOldFiles(t *testing.T) {
	now := time.Now()
	at := func(ago time.Duration) *wire.Date { d := wire.DateOf(now.Add(-ago)); return &d }
	f := &costLedgerFile{Nodes: map[string]wire.LineageCostNode{
		"old": {Files: []string{"a.go"}, EndedAt: at(lineage.FilesKeep + time.Hour), LastAt: *at(0)},
		"new": {Files: []string{"a.go"}, EndedAt: at(time.Hour), LastAt: *at(0)},
	}, Unsent: map[string]int64{}}
	pruneCost(f, now)
	if f.Nodes["old"].Files != nil || len(f.Nodes["new"].Files) != 1 {
		t.Fatalf("%+v", f.Nodes)
	}
}
