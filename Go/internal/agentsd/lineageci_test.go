package agentsd

import (
	"fmt"
	"testing"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/lineage"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

func walkReaches(t *testing.T, d *Daemon, from wire.LineageNode, want ...string) {
	t.Helper()
	d.lineageSettle(5 * time.Second)
	got := map[string]bool{}
	for _, l := range d.lineage().Walk(from, 0).Links {
		got[l.From.Ref+" "+l.Rel+" "+l.To.Ref] = true
	}
	for _, w := range want {
		if !got[w] {
			t.Fatalf("walk from %s: got %v, want %s", from.Ref, got, w)
		}
	}
}

// #3581: checks.passed and checks.failed link the run builds its PR, so a walk from the PR
// reaches its runs; a rerun is the same run.
func TestLineageCIRunsBuildTheirPR(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	checks := func(name, url string, run int) wire.Event {
		return wire.Event{Name: name, Details: map[string]string{"payload": fmt.Sprintf(
			`{"pr":{"number":9,"url":%q},"headSha":"abc","run":{"id":%d,"attempt":1,"name":"CI"}}`, url, run)}}
	}
	d.lineageEvent(checks("checks.failed", "https://github.com/alexec/Agents/pull/9", 100))
	d.lineageEvent(checks("checks.failed", "https://github.com/alexec/Agents/pull/9", 100))
	d.lineageEvent(checks("checks.passed", "https://github.com/alexec/Agents/pull/9", 101))
	d.lineageEvent(checks("checks.failed", "https://gitlab.example.com/group/project/-/merge_requests/4", 7))
	pr := wire.LineageNode{Kind: "pr", Ref: "github:pr:alexec/agents#9"}
	wantLinks(t, active(d, pr),
		"github:run:alexec/agents#100 builds "+pr.Ref+" (forge)",
		"github:run:alexec/agents#101 builds "+pr.Ref+" (forge)")
	walkReaches(t, d, pr, "github:run:alexec/agents#101 builds "+pr.Ref)
	wantLinks(t, active(d, wire.LineageNode{Kind: "pr", Ref: "gitlab:mr:group/project#4"}),
		"gitlab:run:group/project#7 builds gitlab:mr:group/project#4 (forge)")
}

// #3581: a PR keeps its newest ciRunsPerPR runs; the older ones' links end.
func TestLineageCIRunsPerPRAreBounded(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	for run := 1; run <= ciRunsPerPR+3; run++ {
		d.lineageEvent(wire.Event{Name: "checks.passed", Details: map[string]string{"payload": fmt.Sprintf(
			`{"pr":{"number":9,"url":"https://github.com/alexec/Agents/pull/9"},"run":{"id":%d}}`, run)}})
	}
	pr := wire.LineageNode{Kind: "pr", Ref: "github:pr:alexec/agents#9"}
	got := active(d, pr)
	if len(got) != ciRunsPerPR {
		t.Fatalf("got %d active runs, want %d: %v", len(got), ciRunsPerPR, got)
	}
	for run := 1; run <= 3; run++ {
		if got[fmt.Sprintf("github:run:alexec/agents#%d builds %s (forge)", run, pr.Ref)] {
			t.Fatalf("run %d is still active: %v", run, got)
		}
	}
	if !got[fmt.Sprintf("github:run:alexec/agents#%d builds %s (forge)", ciRunsPerPR+3, pr.Ref)] {
		t.Fatalf("the newest run is not active: %v", got)
	}
}

// #3581: run.completed on a version tag links the run builds the tag's release, at the
// run's end, so a walk from the release reaches the run that built it. A branch's run does
// not.
func TestLineageCIRunBuildsItsRelease(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	completed := func(branch string, run int) wire.Event {
		return wire.Event{Name: "run.completed", Details: map[string]string{"payload": fmt.Sprintf(
			`{"run":{"id":%d,"attempt":1,"workflow":"release.yml","event":"push","branch":%q,`+
				`"url":"https://github.com/alexec/Agents/actions/runs/%d","conclusion":"success"},"completedAt":"2026-11-04T10:00:00Z"}`,
			run, branch, run)}}
	}
	d.lineageEvent(completed("v0.16.0", 500))
	d.lineageEvent(completed("main", 501))
	release := wire.LineageNode{Kind: "release", Ref: "github:release:alexec/agents#v0.16.0"}
	wantLinks(t, active(d, release), "github:run:alexec/agents#500 builds "+release.Ref+" (forge)")
	walkReaches(t, d, release, "github:run:alexec/agents#500 builds "+release.Ref)
	if l := d.lineage().Links(release).Links[0]; !l.At.Time().Equal(time.Date(2026, 11, 4, 10, 0, 0, 0, time.UTC)) {
		t.Fatalf("linked at %v, want the run's end", l.At.Time())
	}
	if got := active(d, wire.LineageNode{Kind: "ci-run", Ref: "github:run:alexec/agents#501"}); len(got) != 0 {
		t.Fatalf("a branch's run: %v", got)
	}
}

func TestRepoOfRunURL(t *testing.T) {
	for raw, want := range map[string]string{
		"https://github.com/alexec/Agents/actions/runs/12":            "github:alexec/agents",
		"https://github.com/alexec/Agents/actions/runs/12/attempts/2": "github:alexec/agents",
		"https://github.com/alexec/Agents/pull/12":                    "",
		"https://gitlab.com/g/p/-/pipelines/12":                       "",
	} {
		r, ok := repoOfRunURL(raw)
		got := ""
		if ok {
			got = r.forge + ":" + r.path
		}
		if got != want {
			t.Errorf("%s: got %q, want %q", raw, got, want)
		}
	}
}

// #3584: what run.completed on a version tag says the run deployed is a deploy node: the
// release is deployed-as it, and it is part-of its target, so a walk from an issue reaches the
// TestFlight build that shipped it. A ref that is not <target>:<id>/<version> links nothing.
func TestLineageReleaseDeployedAsATestFlightBuild(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	issue := wire.LineageNode{Kind: "issue", Ref: "github:issue:alexec/agents#3584"}
	pr := wire.LineageNode{Kind: "pr", Ref: "github:pr:alexec/agents#9"}
	release := wire.LineageNode{Kind: "release", Ref: "github:release:alexec/agents#v0.17.0"}
	d.lineageDo(func() {
		d.link(pr, issue, "fixes", "pr-body")
		d.link(pr, release, "part-of", "forge")
	})
	d.lineageEvent(wire.Event{Name: "run.completed", Details: map[string]string{"payload": `{"run":{"id":500,"attempt":1,` +
		`"workflow":"release.yml","event":"push","branch":"v0.17.0","url":"https://github.com/alexec/Agents/actions/runs/500",` +
		`"conclusion":"success"},"completedAt":"2026-11-05T10:00:00Z",` +
		`"deploys":["testflight:com.alexecollins.agents.remote/812","not a deploy","testflight:"]}`}})
	deploy := "testflight:deploy:com.alexecollins.agents.remote#812"
	wantLinks(t, active(d, release),
		"github:run:alexec/agents#500 builds "+release.Ref+" (forge)",
		release.Ref+" deployed-as "+deploy+" (forge)",
		pr.Ref+" part-of "+release.Ref+" (forge)")
	wantLinks(t, active(d, wire.LineageNode{Kind: "deploy", Ref: deploy}),
		release.Ref+" deployed-as "+deploy+" (forge)",
		deploy+" part-of testflight:target:#com.alexecollins.agents.remote (forge)")
	// Issue, PR, release, deploy: 3 links, past the default depth of 2 (#3588 walks further).
	reached := false
	for _, l := range d.lineage().Walk(issue, lineage.MostDepth).Links {
		reached = reached || (l.From == release && l.Rel == lineage.RelDeployedAs && l.To.Ref == deploy)
	}
	if !reached {
		t.Fatalf("a walk from %s does not reach %s", issue.Ref, deploy)
	}
}

func TestLineageTestFlightBuildDeployedAsAnAppStoreVersion(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	issue := wire.LineageNode{Kind: "issue", Ref: "github:issue:alexec/agents#3657"}
	pr := wire.LineageNode{Kind: "pr", Ref: "github:pr:alexec/agents#9"}
	release := wire.LineageNode{Kind: "release", Ref: "github:release:alexec/agents#v0.17.0"}
	d.lineageDo(func() {
		d.link(pr, issue, "fixes", "pr-body")
		d.link(pr, release, "part-of", "forge")
	})
	d.lineageEvent(wire.Event{Name: "run.completed", Details: map[string]string{"payload": `{"run":{"id":501,"attempt":1,` +
		`"workflow":"app-store.yml","event":"push","branch":"v0.17.0","url":"https://github.com/alexec/Agents/actions/runs/501",` +
		`"conclusion":"success"},"completedAt":"2026-11-06T10:00:00Z",` +
		`"deploys":["testflight:com.alexecollins.agents.remote/812","appstore:com.alexecollins.agents.remote/0.17.0",` +
		`"testflight:com.example.other/3"]}`}})
	build, store := "testflight:deploy:com.alexecollins.agents.remote#812", "appstore:deploy:com.alexecollins.agents.remote#0.17.0"
	wantLinks(t, active(d, wire.LineageNode{Kind: "deploy", Ref: store}),
		build+" deployed-as "+store+" (forge)",
		release.Ref+" deployed-as "+store+" (forge)",
		store+" part-of appstore:target:#com.alexecollins.agents.remote (forge)")
	// Issue, PR, release, App Store version: 3 links.
	reached := false
	for _, l := range d.lineage().Walk(issue, lineage.MostDepth).Links {
		reached = reached || (l.From == release && l.To.Ref == store)
	}
	if !reached {
		t.Fatalf("a walk from %s does not reach %s", issue.Ref, store)
	}
}

func TestDeployNodes(t *testing.T) {
	for ref, want := range map[string]string{
		"testflight:com.example.app/42":      "testflight:target:#com.example.app",
		"cloudrun:project/service/rev-00042": "cloudrun:target:#project/service",
		"appstore:com.example.app/1.2.0":     "appstore:target:#com.example.app",
		"testflight:com.example.app/":        "",
		"testflight:com.example.app":         "",
		"com.example.app/42":                 "",
		"testflight:a b/42":                  "",
	} {
		_, target, ok := deployNodes(ref)
		if ok != (want != "") || target.Ref != want {
			t.Errorf("deployNodes(%q) = %q, %v; want %q", ref, target.Ref, ok, want)
		}
	}
}

// #4554: checks.* keep the PR's last head commit's first run and last pass on its cost node; a
// new head commit starts again, and a late event of an older commit changes nothing.
func TestLineageCIKeepsTimeToGreen(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	checks := func(name, sha string, run int, created, completed string) {
		d.lineageEvent(wire.Event{Name: name, Details: map[string]string{"payload": fmt.Sprintf(
			`{"pr":{"number":9,"url":"https://github.com/alexec/Agents/pull/9"},"headSha":%q,`+
				`"run":{"id":%d,"attempt":1,"createdAt":%q},"completedAt":%q}`, sha, run, created, completed)}})
	}
	pr := wire.LineageNode{Kind: "pr", Ref: "github:pr:alexec/agents#9"}
	ci := func() *wire.LineagePRCI {
		d.lineageSettle(5 * time.Second)
		d.workMu.Lock()
		defer d.workMu.Unlock()
		return d.costLedgerLocked().Nodes[costKey(pr)].Ci
	}
	at := func(s string) wire.Date {
		tm, _ := time.Parse(time.RFC3339, s)
		return wire.DateOf(tm)
	}
	checks("checks.passed", "old", 1, "2026-11-10T09:00:00Z", "2026-11-10T09:10:00Z")
	// The new head commit: one workflow fails, a rerun passes, another workflow passes later.
	checks("checks.failed", "new", 2, "2026-11-10T10:00:00Z", "2026-11-10T10:05:00Z")
	checks("checks.passed", "new", 3, "2026-11-10T10:00:30Z", "2026-11-10T10:12:00Z")
	checks("checks.passed", "new", 2, "2026-11-10T10:00:00Z", "2026-11-10T10:20:00Z")
	// A late event of the old commit.
	checks("checks.passed", "old", 1, "2026-11-10T09:00:00Z", "2026-11-10T10:30:00Z")
	got := ci()
	if got == nil || got.HeadSha != "new" || got.PushedAt == nil || *got.PushedAt != at("2026-11-10T10:00:00Z") ||
		got.GreenAt == nil || *got.GreenAt != at("2026-11-10T10:20:00Z") {
		t.Fatalf("ci %+v", got)
	}
	// A push: a failure on it starts again, with no green.
	checks("checks.failed", "newer", 4, "2026-11-10T11:00:00Z", "2026-11-10T11:04:00Z")
	if got := ci(); got == nil || got.HeadSha != "newer" || got.GreenAt != nil || *got.PushedAt != at("2026-11-10T11:00:00Z") {
		t.Fatalf("after a push: %+v", got)
	}
	// No times (as GitLab's): kept as it was.
	d.lineageEvent(wire.Event{Name: "checks.passed", Details: map[string]string{"payload": `{"pr":{"number":9,"url":"https://github.com/alexec/Agents/pull/9"},"run":{"id":5}}`}})
	if got := ci(); got == nil || got.HeadSha != "newer" {
		t.Fatalf("after no times: %+v", got)
	}
}
