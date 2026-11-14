package agentsd

import (
	"encoding/json"
	"fmt"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/lineage"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// deployEvent is a deploy.* event of the github server (#5240) for Deployment id of
// alexec/Agents to env, at sha, named by tag when it is set, in run's job.
func deployEvent(t *testing.T, name string, id int, env, sha, tag string, run int, state wire.DeployState,
	started, finished time.Time, notices ...string) wire.Event {
	t.Helper()
	ref := fmt.Sprintf("github:deploy:alexec/Agents#%d", id)
	artifact := "github:artifact:alexec/Agents#" + sha
	dep := wire.Deploy{System: "github", ID: fmt.Sprint(id), Ref: &ref, State: state, RawState: string(state),
		Target: wire.DeployTarget{Component: wire.DeployComponent{System: "github", ID: "alexec/Agents"},
			Environment: wire.DeployEnvironment{System: "github", Name: env, Tier: wire.EnvironmentTierOther}},
		Version: wire.DeployVersion{Artifacts: []wire.DeployArtifact{{Kind: "commit", System: "github", ID: sha, Ref: &artifact}}},
		URL:     new(fmt.Sprintf("https://github.com/alexec/Agents/actions/runs/%d/job/9", run))}
	if tag != "" {
		dep.Version.Name = &tag
	}
	if !started.IsZero() {
		dep.Started = new(wire.DateOf(started))
	}
	if !finished.IsZero() {
		dep.Finished = new(wire.DateOf(finished))
	}
	payload := map[string]any{"deploy": dep, "component": "alexec/Agents", "environment": env, "tier": "other"}
	if len(notices) > 0 {
		payload["notices"] = notices
	}
	b, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	return wire.Event{Name: name, Details: map[string]string{"payload": string(b)}}
}

// #5241: a deploy.* event makes a deploy node, one try: it deploys its release (or its commit
// with no tag), it is part-of its environment, and its run builds it. The job's notice names
// the environment once it ends, so the deploy leaves the forge environment for it; a started
// polled late takes back nothing.
func TestLineageDeployNodesFromDeployEvents(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	t0 := time.Date(2026, 11, 13, 10, 0, 0, 0, time.UTC)
	deploy := wire.LineageNode{Kind: lineage.KindDeploy, Ref: "github:deploy:alexec/agents#7"}
	release := "github:release:alexec/agents#v0.18.0"

	d.lineageEvent(deployEvent(t, "deploy.started", 7, "release", "aaa", "v0.18.0", 500, wire.DeployStateRunning, t0, time.Time{}))
	wantLinks(t, active(d, deploy),
		deploy.Ref+" deploys "+release+" (forge)",
		deploy.Ref+" part-of github:environment:alexec/agents#release (forge)",
		"github:run:alexec/agents#500 builds "+deploy.Ref+" (forge)")

	d.lineageEvent(deployEvent(t, "deploy.succeeded", 7, "release", "aaa", "v0.18.0", 500, wire.DeployStateSucceeded,
		t0, t0.Add(time.Minute), "testflight=testflight:com.alexecollins.agents.remote/812", "not a notice"))
	wantLinks(t, active(d, deploy),
		deploy.Ref+" deploys "+release+" (forge)",
		deploy.Ref+" part-of github:environment:alexec/agents#testflight (forge)",
		"github:run:alexec/agents#500 builds "+deploy.Ref+" (forge)")

	d.lineageEvent(deployEvent(t, "deploy.started", 7, "release", "aaa", "v0.18.0", 500, wire.DeployStateRunning, t0, time.Time{}))
	wantLinks(t, active(d, deploy),
		deploy.Ref+" deploys "+release+" (forge)",
		deploy.Ref+" part-of github:environment:alexec/agents#testflight (forge)",
		"github:run:alexec/agents#500 builds "+deploy.Ref+" (forge)")

	g := d.deployGraph(d.lineage().Walk(deploy, 1))
	r := g.Resolved[deploy.Ref]
	if r.Title != "v0.18.0 to testflight" || r.State == nil || *r.State != "succeeded" || r.CreatedAt == nil || *r.CreatedAt != wire.DateOf(t0) {
		t.Fatalf("resolved %+v", r)
	}
	// #5243: the deploy itself, for the Work pages' rows: its environment, times and job.
	if r.Deploy == nil || r.Deploy.Target.Environment.Name != "release" || r.Deploy.Finished == nil ||
		*r.Deploy.Finished != wire.DateOf(t0.Add(time.Minute)) || r.Deploy.URL == nil {
		t.Fatalf("resolved deploy %+v", r.Deploy)
	}
	d.deployBookMu.Lock()
	arts := d.deploysFileLocked().Deploys[deploy.Ref].Deploy.Version.Artifacts
	d.deployBookMu.Unlock()
	if len(arts) != 2 || arts[1].Ref == nil || *arts[1].Ref != "testflight:artifact:com.alexecollins.agents.remote#812" {
		t.Fatalf("artifacts %+v: want the commit and the notice's build", arts)
	}

	// No tag: the deploy deploys its commit. The old notice form names the target's kind.
	pages := wire.LineageNode{Kind: lineage.KindDeploy, Ref: "github:deploy:alexec/agents#8"}
	d.lineageEvent(deployEvent(t, "deploy.succeeded", 8, "app-store", "bbb", "", 501, wire.DeployStateSucceeded,
		t0, t0.Add(time.Minute), "appstore:com.alexecollins.agents.remote/0.18.0"))
	wantLinks(t, active(d, pages),
		pages.Ref+" deploys github:commit:alexec/agents#bbb (forge)",
		pages.Ref+" part-of github:environment:alexec/agents#appstore (forge)",
		"github:run:alexec/agents#501 builds "+pages.Ref+" (forge)")

	// A ref that is not a deploy's links nothing.
	bad := deployEvent(t, "deploy.started", 9, "release", "ccc", "", 502, wire.DeployStateRunning, t0, time.Time{})
	bad.Details["payload"] = `{"deploy":{"ref":"github:issue:alexec/Agents#9"}}`
	d.lineageEvent(bad)
	wantLinks(t, active(d, wire.LineageNode{Kind: lineage.KindDeploy, Ref: "github:deploy:alexec/agents#9"}))
}

// #5241: a succeeded deploy is replaced once a newer one succeeds in its environment; one of an
// older release than the one it replaced is a rollback; and what a deploy brings is the PRs
// between the deploy before it and it, worked out in the background, never stored.
func TestLineageDeployReplacedRollbackAndBrings(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	c.call(t, 1, "folders/add", map[string]any{"folder": "file://" + gitFolder(t, "git@github.com:alexec/agents.git")})
	forge := &fakeReleases{
		compares: map[string][]compareCommit{
			"aaa..bbb": {{SHA: "s1", Message: "Deploys: lineage nodes (#5241)"}, {SHA: "s2", Message: "No number"}},
		},
		commitPRs: map[string]int{"s2": 5240},
		asked:     map[string]int{},
	}
	d.releaseCompare, d.releaseCommitPR = forge.compare, forge.commitPR
	t0 := time.Date(2026, 11, 13, 10, 0, 0, 0, time.UTC)
	first := wire.LineageNode{Kind: lineage.KindDeploy, Ref: "github:deploy:alexec/agents#1"}
	second := wire.LineageNode{Kind: lineage.KindDeploy, Ref: "github:deploy:alexec/agents#2"}
	third := wire.LineageNode{Kind: lineage.KindDeploy, Ref: "github:deploy:alexec/agents#3"}
	d.lineageEvent(deployEvent(t, "deploy.succeeded", 1, "production", "aaa", "v0.18.0", 10, wire.DeployStateSucceeded, t0, t0.Add(time.Minute)))
	d.lineageEvent(deployEvent(t, "deploy.succeeded", 2, "production", "bbb", "v0.19.0", 11, wire.DeployStateSucceeded, t0.Add(time.Hour), t0.Add(61*time.Minute)))
	d.lineageSettle(5 * time.Second)

	g := d.deployGraph(d.lineage().Walk(first, 1))
	if s := g.Resolved[first.Ref].State; s == nil || *s != "replaced" {
		t.Fatalf("first: %+v, want replaced", g.Resolved[first.Ref])
	}

	g = d.deployGraph(d.lineage().Walk(second, 1))
	if s := g.Resolved[second.Ref].State; s == nil || *s != "succeeded" {
		t.Fatalf("second: %+v, want succeeded", g.Resolved[second.Ref])
	}
	if g.Resolving == nil || !*g.Resolving {
		t.Fatal("what the second brings is not asked yet: the answer says resolving")
	}
	d.deploySettle(5 * time.Second)
	g = d.deployGraph(d.lineage().Walk(second, 1))
	brings := map[string]bool{}
	for _, l := range g.Links {
		if l.Rel == lineage.RelBrings {
			brings[l.From.Ref+" brings "+l.To.Ref+" ("+l.Source+")"] = true
		}
	}
	wantLinks(t, brings,
		second.Ref+" brings github:pr:alexec/agents#5241 (computed)",
		second.Ref+" brings github:pr:alexec/agents#5240 (computed)")
	wantLinks(t, active(d, second),
		second.Ref+" deploys github:release:alexec/agents#v0.19.0 (forge)",
		second.Ref+" part-of github:environment:alexec/agents#production (forge)",
		"github:run:alexec/agents#11 builds "+second.Ref+" (forge)")
	asked := forge.asked["compare"]
	d.deployGraph(d.lineage().Walk(second, 1))
	d.deploySettle(5 * time.Second)
	if forge.asked["compare"] != asked {
		t.Fatal("a cached brings is asked again before resolveRecheck")
	}

	// Back to v0.18.0: a rollback, and it replaces the second.
	d.lineageEvent(deployEvent(t, "deploy.succeeded", 3, "production", "aaa", "v0.18.0", 12, wire.DeployStateSucceeded, t0.Add(2*time.Hour), t0.Add(121*time.Minute)))
	d.lineageSettle(5 * time.Second)
	g = d.deployGraph(d.lineage().Walk(third, 1))
	if l := g.Resolved[third.Ref].Labels; len(l) != 1 || l[0] != "rollback" {
		t.Fatalf("third: %+v, want a rollback", g.Resolved[third.Ref])
	}
	g = d.deployGraph(d.lineage().Walk(second, 1))
	if s := g.Resolved[second.Ref].State; s == nil || *s != "replaced" {
		t.Fatalf("second: %+v, want replaced", g.Resolved[second.Ref])
	}
}

func TestDeployNotice(t *testing.T) {
	for notice, want := range map[string]string{
		"testflight=testflight:com.example.app/42": "testflight testflight:artifact:com.example.app#42",
		"testflight:com.example.app/42":            "testflight testflight:artifact:com.example.app#42",
		"app-store=appstore:com.example.app/1.2.0": "app-store appstore:artifact:com.example.app#1.2.0",
		"cloudrun:project/service/rev-00042":       "cloudrun cloudrun:artifact:project/service#rev-00042",
		"=testflight:com.example.app/42":           "",
		"testflight:com.example.app/":              "",
		"testflight:com.example.app":               "",
		"com.example.app/42":                       "",
		"testflight:a b/42":                        "",
	} {
		env, a, ok := deployNotice(notice)
		got := ""
		if ok {
			got = env + " " + *a.Ref
		}
		if got != want {
			t.Errorf("deployNotice(%q) = %q, want %q", notice, got, want)
		}
	}
}

// #5246: an environment's live and next versions, as GitOps Promoter's active and proposed,
// computed from its deploys: a walk from the environment gives them as live and next links.
// A canary is live beside the version it splits with, each at its share; a redeploy of the live
// version keeps its since; a waiting deploy older than the live one is not next; and the next
// deploy brings the PRs since the live version.
func TestLineageDeployLiveAndNext(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	c.call(t, 1, "folders/add", map[string]any{"folder": "file://" + gitFolder(t, "git@github.com:alexec/agents.git")})
	forge := &fakeReleases{
		compares:  map[string][]compareCommit{"bbb..ccc": {{SHA: "s1", Message: "Deploys: live and next (#5246)"}}},
		commitPRs: map[string]int{},
		asked:     map[string]int{},
	}
	d.releaseCompare, d.releaseCommitPR = forge.compare, forge.commitPR
	t0 := time.Date(2026, 11, 13, 10, 0, 0, 0, time.UTC)
	env := wire.LineageNode{Kind: lineage.KindEnvironment, Ref: "github:environment:alexec/agents#production"}
	walk := func() (map[string]bool, wire.LineageGraph) {
		t.Helper()
		g := d.deployGraph(d.lineage().Walk(env, 1))
		got := map[string]bool{}
		for _, l := range g.Links {
			if l.From == env && (l.Rel == lineage.RelLive || l.Rel == lineage.RelNext) {
				got[l.Rel+" "+l.To.Ref+" "+l.At.Time().Format("15:04")] = true
			}
		}
		return got, g
	}
	at := func(m int) time.Time { return t0.Add(time.Duration(m) * time.Minute) }

	// A deploy that waits from before v0.18.0 went out is never approved: it is not next.
	d.lineageEvent(deployEvent(t, "deploy.waiting", 1, "production", "zzz", "v0.17.0", 9, wire.DeployStateWaiting, at(0), time.Time{}))
	d.lineageEvent(deployEvent(t, "deploy.succeeded", 2, "production", "aaa", "v0.18.0", 10, wire.DeployStateSucceeded, at(10), at(11)))
	d.lineageEvent(deployEvent(t, "deploy.succeeded", 3, "production", "aaa", "v0.18.0", 11, wire.DeployStateSucceeded, at(20), at(21)))
	d.lineageSettle(5 * time.Second)
	got, _ := walk()
	wantLinks(t, got, "live github:deploy:alexec/agents#3 10:11")

	// v0.19.0 goes out as a canary at 10 %: both are live.
	canary := deployEvent(t, "deploy.succeeded", 4, "production", "bbb", "v0.19.0", 12, wire.DeployStateSucceeded, at(30), at(31))
	canary.Details["payload"] = strings.Replace(canary.Details["payload"], `"state":`, `"share":10,"state":`, 1)
	d.lineageEvent(canary)
	// v0.20.0 waits for its approval: next.
	d.lineageEvent(deployEvent(t, "deploy.waiting", 5, "production", "ccc", "v0.20.0", 13, wire.DeployStateWaiting, at(40), time.Time{}))
	d.lineageSettle(5 * time.Second)
	got, g := walk()
	wantLinks(t, got,
		"live github:deploy:alexec/agents#4 10:31",
		"live github:deploy:alexec/agents#3 10:11",
		"next github:deploy:alexec/agents#5 10:40")
	if l := g.Resolved["github:deploy:alexec/agents#4"].Labels; !slices.Equal(l, []string{"share:10"}) {
		t.Fatalf("canary labels %v, want share:10", l)
	}
	if l := g.Resolved["github:deploy:alexec/agents#3"].Labels; !slices.Equal(l, []string{"share:90"}) {
		t.Fatalf("stable labels %v, want share:90", l)
	}
	if s := g.Resolved["github:deploy:alexec/agents#3"].State; s == nil || *s != "succeeded" {
		t.Fatalf("stable state %v: live at 90 %% is not replaced", s)
	}

	// What the next version brings: the PRs since the live version before it.
	d.deploySettle(5 * time.Second)
	_, g = walk()
	brings := map[string]bool{}
	for _, l := range g.Links {
		if l.Rel == lineage.RelBrings && l.From.Ref == "github:deploy:alexec/agents#5" {
			brings[l.To.Ref] = true
		}
	}
	wantLinks(t, brings, "github:pr:alexec/agents#5246")

	// v0.20.0 goes out at 100 %: it alone is live, nothing is next, and the others are replaced.
	d.lineageEvent(deployEvent(t, "deploy.succeeded", 5, "production", "ccc", "v0.20.0", 13, wire.DeployStateSucceeded, at(40), at(45)))
	d.lineageSettle(5 * time.Second)
	got, g = walk()
	wantLinks(t, got, "live github:deploy:alexec/agents#5 10:45")
	for _, ref := range []string{"github:deploy:alexec/agents#3", "github:deploy:alexec/agents#4"} {
		if s := g.Resolved[ref].State; s != nil && *s != "replaced" {
			t.Fatalf("%s state %s, want replaced", ref, *s)
		}
	}

	// Another target of the same environment node, told apart by its labels, has its own live
	// version.
	eu := deployEvent(t, "deploy.succeeded", 6, "production", "bbb", "v0.19.0", 14, wire.DeployStateSucceeded, at(50), at(51))
	eu.Details["payload"] = strings.Replace(eu.Details["payload"], `"environment":{`, `"labels":{"region":"eu"},"environment":{`, 1)
	d.lineageEvent(eu)
	d.lineageSettle(5 * time.Second)
	got, _ = walk()
	wantLinks(t, got,
		"live github:deploy:alexec/agents#5 10:45",
		"live github:deploy:alexec/agents#6 10:51")
}

// #5270: deploys/targets says every target, in the environment its job's notice names, with
// its live versions (the most traffic first), since when, its next deploys, and the release.
func TestDeployTargets(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	t0 := time.Date(2026, 11, 13, 10, 0, 0, 0, time.UTC)
	at := func(m int) time.Time { return t0.Add(time.Duration(m) * time.Minute) }
	d.lineageEvent(deployEvent(t, "deploy.succeeded", 1, "release", "aaa", "v0.18.0", 10, wire.DeployStateSucceeded, at(0), at(1),
		"testflight=testflight:com.example.remote/812"))
	d.lineageEvent(deployEvent(t, "deploy.succeeded", 2, "production", "aaa", "v0.18.0", 11, wire.DeployStateSucceeded, at(10), at(11)))
	canary := deployEvent(t, "deploy.succeeded", 3, "production", "bbb", "v0.19.0", 12, wire.DeployStateSucceeded, at(20), at(21))
	canary.Details["payload"] = strings.Replace(canary.Details["payload"], `"state":`, `"share":10,"state":`, 1)
	d.lineageEvent(canary)
	d.lineageEvent(deployEvent(t, "deploy.waiting", 4, "production", "ccc", "v0.20.0", 13, wire.DeployStateWaiting, at(30), time.Time{}))
	d.lineageSettle(5 * time.Second)

	got := d.deployTargets()
	var lines []string
	for _, tn := range got.Targets {
		line := tn.Target.Environment.Name + " " + string(tn.Target.Environment.Tier) + ":"
		for _, l := range tn.Live {
			line += fmt.Sprintf(" live %s %v%% since %s release %s", *l.Deploy.Version.Name, *l.Share, l.Since.Time().Format("15:04"), *l.Release)
		}
		for _, n := range tn.Next {
			line += " next " + *n.Deploy.Version.Name + " " + string(n.Deploy.State)
		}
		lines = append(lines, line)
	}
	want := []string{
		"production other: live v0.18.0 90% since 10:11 release github:release:alexec/agents#v0.18.0" +
			" live v0.19.0 10% since 10:21 release github:release:alexec/agents#v0.19.0 next v0.20.0 waiting",
		"testflight other: live v0.18.0 100% since 10:01 release github:release:alexec/agents#v0.18.0",
	}
	if !slices.Equal(lines, want) {
		t.Fatalf("targets\n%s\nwant\n%s", strings.Join(lines, "\n"), strings.Join(want, "\n"))
	}
}
