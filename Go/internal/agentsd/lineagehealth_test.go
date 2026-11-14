package agentsd

import (
	"fmt"
	"path/filepath"
	"testing"
	"time"

	"github.com/agentloops-dev/agents/Go/internal/lineage"
	"github.com/agentloops-dev/agents/Go/wire"
)

func healthEvent(name, folder, release string) wire.Event {
	at := "firstSeen"
	if name == "health.issue_regressed" {
		at = "regressedAt"
	}
	e := wire.Event{Name: name, Details: map[string]string{"payload": fmt.Sprintf(
		`{"org":"scratch","project":"agents","release":%q,"%s":"2026-11-05T09:00:00Z",`+
			`"issue":{"id":"42","shortId":"AGENTS-1","title":"TypeError","level":"error","url":"https://scratch.sentry.io/issues/42/"}}`,
		release, at)}}
	if folder != "" {
		e.Scope = folderScope(folder)
	}
	return e
}

func realTempDir(t *testing.T) string {
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return dir
}

// #3585: a new Sentry issue is a health node seen-in the release of its version, at the time
// Sentry first saw it, so a walk from it reaches the release, its PRs and the issues they fix.
func TestLineageHealthSeenInItsRelease(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	folder := realTempDir(t)
	d.repos = map[string]forgeRepo{folder: {"github", "alexec/agents"}}
	repo := d.repos[folder]
	release, pr, issue := repo.release("v1.2.0"), repo.pr(40), repo.issue(12)
	d.lineageDo(func() {
		d.link(pr, release, lineage.RelPartOf, lineage.SourceForge)
		d.link(pr, issue, lineage.RelFixes, lineage.SourcePRBody)
	})
	d.lineageEvent(healthEvent("health.issue_new", folder, "agents@1.2.0"))
	health := wire.LineageNode{Kind: "health", Ref: "sentry:issue:scratch#42"}
	wantLinks(t, active(d, health), health.Ref+" seen-in "+release.Ref+" (health)")
	if l := d.lineage().Links(health).Links[0]; !l.At.Time().Equal(time.Date(2026, 11, 5, 9, 0, 0, 0, time.UTC)) {
		t.Fatalf("linked at %v, want when Sentry first saw it", l.At.Time())
	}
	got := map[string]bool{}
	for _, l := range d.lineage().Walk(health, 3).Links {
		got[l.From.Ref+" "+l.Rel+" "+l.To.Ref] = true
	}
	for _, w := range []string{health.Ref + " seen-in " + release.Ref, pr.Ref + " part-of " + release.Ref, pr.Ref + " fixes " + issue.Ref} {
		if !got[w] {
			t.Fatalf("walk from %s: got %v, want %s", health.Ref, got, w)
		}
	}

	// A regression in a later release is seen-in that one too.
	d.lineageEvent(healthEvent("health.issue_regressed", folder, "agents@1.3.0"))
	wantLinks(t, active(d, health),
		health.Ref+" seen-in "+release.Ref+" (health)",
		health.Ref+" seen-in "+repo.release("v1.3.0").Ref+" (health)")
}

// #3585: an event with no folder links only a release the graph knows, in one repo; a
// version that is not x.y.z links nothing.
func TestLineageHealthWithNoFolder(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	one, two := realTempDir(t), realTempDir(t)
	seeded(t, d, one, nil)
	seeded(t, d, two, nil)
	d.repos = map[string]forgeRepo{one: {"github", "alexec/agents"}, two: {"github", "alexec/other"}}
	agents, other := d.repos[one], d.repos[two]
	d.lineageDo(func() { d.link(agents.pr(40), agents.release("v1.2.0"), lineage.RelPartOf, lineage.SourceForge) })
	health := wire.LineageNode{Kind: "health", Ref: "sentry:issue:scratch#42"}

	d.lineageEvent(healthEvent("health.issue_new", "", "9.9.9"))
	d.lineageEvent(healthEvent("health.issue_new", "", "agents@main"))
	if got := active(d, health); len(got) != 0 {
		t.Fatalf("an unknown release or no version: %v", got)
	}
	d.lineageEvent(healthEvent("health.issue_new", "", "v1.2.0"))
	wantLinks(t, active(d, health), health.Ref+" seen-in "+agents.release("v1.2.0").Ref+" (health)")

	// Both repos know v2.0.0: the one named as the Sentry project.
	d.lineageDo(func() {
		d.link(agents.pr(41), agents.release("v2.0.0"), lineage.RelPartOf, lineage.SourceForge)
		d.link(other.pr(7), other.release("v2.0.0"), lineage.RelPartOf, lineage.SourceForge)
	})
	d.lineageEvent(healthEvent("health.issue_regressed", "", "2.0.0"))
	wantLinks(t, active(d, health),
		health.Ref+" seen-in "+agents.release("v1.2.0").Ref+" (health)",
		health.Ref+" seen-in "+agents.release("v2.0.0").Ref+" (health)")
}

// #3585: an Apple app's version names its build, and the health node is seen-in that
// TestFlight deploy when the graph knows it (#3584).
func TestLineageHealthSeenInItsDeploy(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	folder := realTempDir(t)
	d.repos = map[string]forgeRepo{folder: {"github", "alexec/agents"}}
	release := d.repos[folder].release("v0.16.0")
	deploy := wire.LineageNode{Kind: "deploy", Ref: "testflight:deploy:com.example.app#812"}
	d.lineageDo(func() { d.link(release, deploy, "deployed-as", lineage.SourceForge) })
	d.lineageEvent(healthEvent("health.issue_new", folder, "com.example.app@0.16.0+812"))
	health := wire.LineageNode{Kind: "health", Ref: "sentry:issue:scratch#42"}
	wantLinks(t, active(d, health),
		health.Ref+" seen-in "+release.Ref+" (health)",
		health.Ref+" seen-in "+deploy.Ref+" (health)")

	// A build the graph does not know links only the release.
	d.lineageEvent(wire.Event{Name: "health.issue_new", Scope: folderScope(folder), Details: map[string]string{"payload": `{"org":"scratch","release":"com.example.app@0.16.0+813","issue":{"id":"43"}}`}})
	wantLinks(t, active(d, wire.LineageNode{Kind: "health", Ref: "sentry:issue:scratch#43"}),
		"sentry:issue:scratch#43 seen-in "+release.Ref+" (health)")
}

func TestSentryVersion(t *testing.T) {
	for release, want := range map[string]string{
		"1.2.0":                       "v1.2.0  ",
		"v1.2.0":                      "v1.2.0  ",
		"web@1.2.0":                   "v1.2.0 web ",
		"@scope/web@1.2.0":            "v1.2.0 @scope/web ",
		"com.example.app@1.2.0+42":    "v1.2.0 com.example.app 42",
		"com.example.app@1.2.0-beta1": "",
		"abc123def":                   "",
		"":                            "",
	} {
		tag, pkg, build, ok := sentryVersion(release)
		got := ""
		if ok {
			got = tag + " " + pkg + " " + build
		}
		if got != want {
			t.Errorf("%q: got %q, want %q", release, got, want)
		}
	}
}

// #3586: health back into work. The session that a health.* event's run started is started
// by the health signal, and the bug it labels itself with reports it, so a walk from the bug
// reaches the release and its PRs.
func TestLineageABugReportsTheHealthThatStartedIt(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	folder := realTempDir(t)
	d.repos = map[string]forgeRepo{folder: {"github", "alexec/agents"}}
	repo := d.repos[folder]
	release, pr, bug := repo.release("v1.2.0"), repo.pr(40), repo.issue(77)
	d.lineageDo(func() { d.link(pr, release, lineage.RelPartOf, lineage.SourceForge) })
	e := healthEvent("health.issue_new", folder, "agents@1.2.0")
	d.lineageEvent(e)
	a := seeded(t, d, folder, nil)
	other := seeded(t, d, folder, nil)
	d.lineageHealthStarted(e, a.ID)
	d.lineageHealthStarted(wire.Event{Name: "checks.failed", Details: e.Details}, other.ID)
	for _, id := range []wire.UUID{a.ID, other.ID} {
		d.change(id, func(a *wire.Agent) {
			a.Labels = []wire.SessionLabel{{Value: "#77", Owner: wire.SessionLabelOwnerAgent}}
		})
	}
	health := wire.LineageNode{Kind: "health", Ref: "sentry:issue:scratch#42"}
	s := sessionNode(a.ID)
	wantLinks(t, active(d, bug),
		bug.Ref+" reports "+health.Ref+" (agent)",
		s.Ref+" works-on "+bug.Ref+" (agent)",
		sessionNode(other.ID).Ref+" works-on "+bug.Ref+" (agent)")
	wantLinks(t, active(d, health),
		health.Ref+" seen-in "+release.Ref+" (health)",
		health.Ref+" started "+s.Ref+" (helper)",
		bug.Ref+" reports "+health.Ref+" (agent)")
	got := map[string]bool{}
	for _, l := range d.lineage().Walk(bug, 3).Links {
		got[l.From.Ref+" "+l.Rel+" "+l.To.Ref] = true
	}
	if !got[pr.Ref+" part-of "+release.Ref] {
		t.Fatalf("walk from %s: got %v, want its release's PR", bug.Ref, got)
	}
}

func incidentEvent(name, folder, startedAt string) wire.Event {
	e := wire.Event{Name: name, Details: map[string]string{"payload": fmt.Sprintf(
		`{"team":"Scratch","startedAt":%q,"incident":{"id":"77","name":"web","cause":"Status 503","url":"https://app.example.com","monitor":"7"}}`,
		startedAt)}}
	if folder != "" {
		e.Scope = folderScope(folder)
	}
	return e
}

// #3655: a Better Stack incident is a health node seen-in the release that was out when it
// started: not a later one, and nothing with no folder.
func TestLineageIncidentSeenInTheReleaseOut(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	folder := realTempDir(t)
	d.repos = map[string]forgeRepo{folder: {"github", "alexec/agents"}}
	repo := d.repos[folder]
	day := func(n int) time.Time { return time.Date(2026, 11, n, 9, 0, 0, 0, time.UTC) }
	for i, tag := range []string{"v1.2.0", "v1.10.0", "v1.11.0"} {
		d.markReleaseTagDone(repo, tag)
		pr := repo.pr(40 + i)
		d.lineageDo(func() { d.linkAt(pr, repo.release(tag), lineage.RelPartOf, lineage.SourceForge, day(1+2*i)) })
	}
	health := wire.LineageNode{Kind: "health", Ref: "betterstack:incident:#77"}

	d.lineageEvent(incidentEvent("health.incident_started", "", "2026-11-04T10:00:00Z"))
	d.lineageEvent(incidentEvent("health.incident_resolved", folder, "2026-11-04T10:00:00Z"))
	if links := d.lineage().Links(health).Links; len(links) != 0 {
		t.Fatalf("no folder, or resolved, linked %v", links)
	}
	// v1.10.0 was out on the 3rd; v1.11.0 only on the 5th.
	d.lineageEvent(incidentEvent("health.incident_started", folder, "2026-11-04T10:00:00Z"))
	wantLinks(t, active(d, health), health.Ref+" seen-in "+repo.release("v1.10.0").Ref+" (health)")
	if l := d.lineage().Links(health).Links[0]; !l.At.Time().Equal(time.Date(2026, 11, 4, 10, 0, 0, 0, time.UTC)) {
		t.Fatalf("linked at %v, want when the incident started", l.At.Time())
	}

	// A workflow run it started links health started session, as a Sentry issue's does.
	e := incidentEvent("health.incident_started", folder, "2026-11-04T10:00:00Z")
	if n, ok := healthNode(e); !ok || n != health {
		t.Fatalf("%v %v", n, ok)
	}
}
