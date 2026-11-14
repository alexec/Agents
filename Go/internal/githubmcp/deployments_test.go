package githubmcp

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/agentloops-dev/agent-loops/Go/internal/mcpevents"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// #5240: GitHub's Deployments read as the deploy model. One page of the newest made is listed,
// statuses are read only for those updated since, and they come oldest first.
func TestDeploymentsReadsOnlyThoseUpdatedSince(t *testing.T) {
	var asked []string
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		asked = append(asked, r.URL.Path+"?"+r.URL.RawQuery)
		switch {
		case strings.HasSuffix(r.URL.Path, "/o/r/deployments"):
			io.WriteString(w, `[
				{"id":2,"sha":"bbb","ref":"v0.18.0","environment":"release","production_environment":false,"transient_environment":false,
				 "created_at":"2026-11-08T17:54:17Z","updated_at":"2026-11-08T18:51:48Z"},
				{"id":1,"sha":"aaa","ref":"main","environment":"release","created_at":"2026-11-07T10:00:00Z","updated_at":"2026-11-07T10:10:00Z"}]`)
		case strings.HasSuffix(r.URL.Path, "/deployments/2/statuses"):
			io.WriteString(w, `[
				{"id":23,"state":"success","created_at":"2026-11-08T18:20:00Z","target_url":"https://github.com/o/r/actions/runs/9/job/99","environment_url":"https://example.com"},
				{"id":22,"state":"in_progress","created_at":"2026-11-08T18:00:00Z","target_url":"https://github.com/o/r/actions/runs/9/job/99"},
				{"id":21,"state":"waiting","created_at":"2026-11-08T17:54:18Z","target_url":"https://github.com/o/r/actions/runs/9/job/99"}]`)
		case strings.HasSuffix(r.URL.Path, "/actions/jobs/99"):
			io.WriteString(w, `{"conclusion":"cancelled"}`)
		default:
			t.Errorf("asked %s", r.URL.Path)
			io.WriteString(w, `[]`)
		}
	}))
	t.Cleanup(s.Close)
	g := NewRealGitHub(s.URL, func() string { return "t" }, nil)
	deps, err := g.Deployments(context.Background(), "o/r", "release", "2026-11-08T00:00:00.000Z")
	if err != nil || len(deps) != 1 {
		t.Fatalf("deployments: %+v %v", deps, err)
	}
	d := deps[0]
	equal(t, d.ID, int64(2), "id")
	var states []string
	for _, st := range d.Statuses {
		states = append(states, st.State)
	}
	equal(t, states, []string{"waiting", "in_progress", "success"}, "oldest first")
	equal(t, d.Statuses[2].URL, "https://github.com/o/r/actions/runs/9/job/99", "job url")
	equal(t, asked[0], "/repos/o/r/deployments?environment=release&per_page=50", "listed")
	equal(t, len(asked), 2, "no statuses for one not updated since")
	if c, err := g.JobConclusion(context.Background(), "o/r", 99); err != nil || c != "cancelled" {
		t.Fatalf("job: %q %v", c, err)
	}
}

func deployment(id int64, env, ref string, production bool, statuses ...DeploymentStatus) Deployment {
	return Deployment{ID: id, SHA: fmt.Sprintf("sha%d", id), Ref: ref, Environment: env, Production: production,
		Created: statuses[0].At, Updated: statuses[len(statuses)-1].At, Statuses: statuses}
}

func status(id int64, state, at string, job int) DeploymentStatus {
	return DeploymentStatus{ID: id, State: state, At: at,
		URL: fmt.Sprintf("https://github.com/%s/actions/runs/7/job/%d", repo, job)}
}

// #5240: each Deployment raises deploy.started, deploy.succeeded or deploy.failed once, at its
// first status of that state; waiting and inactive raise none; the id is the deploy's ref and the
// event; a cancelled job's failure is outcome cancelled; environment, tier and component narrow.
func TestDeployEventsOncePerStateChange(t *testing.T) {
	h := newHarness(t)
	all := map[string]any{"repo": repo}
	production := map[string]any{"repo": repo, "tier": "production"}
	pages := map[string]any{"repo": repo, "environment": "github-pages"}
	other := map[string]any{"repo": repo, "component": "someone/else"}
	cursors := map[string]any{}
	for _, name := range []string{"deploy.started", "deploy.succeeded", "deploy.failed"} {
		cursors[name] = h.poll(name, all, nil)["cursor"]
	}
	firstProduction := h.poll("deploy.succeeded", production, nil)["cursor"]
	firstPages := h.poll("deploy.failed", pages, nil)["cursor"]
	firstOther := h.poll("deploy.started", other, nil)["cursor"]

	h.fake.mu.Lock()
	h.fake.deployments = []Deployment{
		deployment(7639582616, "app-store", "v0.18.0", true,
			status(1, "waiting", h.at(1), 50), status(2, "queued", h.at(2), 50), status(3, "in_progress", h.at(3), 50),
			status(4, "queued", h.at(4), 50), status(5, "success", h.at(6), 50), status(6, "inactive", h.at(8), 50)),
		deployment(7639582617, "github-pages", "main", false, status(7, "waiting", h.at(2), 51), status(8, "failure", h.at(5), 51)),
	}
	h.fake.jobs = map[int64]string{51: "cancelled"}
	h.fake.jobDeploys = map[int64][]string{50: {"app-store=testflight:com.example.app/812"}}
	h.fake.mu.Unlock()

	store := "github:deploy:" + repo + "#7639582616"
	pagesRef := "github:deploy:" + repo + "#7639582617"
	started := h.poll("deploy.started", all, cursors["deploy.started"])
	equal(t, ids(started), []string{store + "@deploy.started"}, "started once, not again at the second queued")
	succeeded := h.poll("deploy.succeeded", all, cursors["deploy.succeeded"])
	equal(t, ids(succeeded), []string{store + "@deploy.succeeded"}, "succeeded")
	failed := h.poll("deploy.failed", all, cursors["deploy.failed"])
	equal(t, ids(failed), []string{pagesRef + "@deploy.failed"}, "failed")
	equal(t, eventsOf(failed)[0]["subject"], pagesRef, "subject")
	equal(t, eventsOf(failed)[0]["data"].(map[string]any)["outcome"], "cancelled", "a cancelled job")
	equal(t, ids(h.poll("deploy.succeeded", all, succeeded["cursor"])), []string{}, "raised once")

	data := eventsOf(succeeded)[0]["data"].(map[string]any)
	equal(t, data["component"], repo, "component")
	equal(t, data["environment"], "app-store", "environment")
	equal(t, data["tier"], "production", "tier")
	_, hasOutcome := data["outcome"]
	equal(t, hasOutcome, false, "outcome is deploy.failed's")
	equal(t, data["notices"], []any{"app-store=testflight:com.example.app/812"}, "the job's deploy notices (#5241)")
	_, startNotices := eventsOf(started)[0]["data"].(map[string]any)["notices"]
	equal(t, startNotices, false, "a running job's notices are not read")
	_, pagesNotices := eventsOf(failed)[0]["data"].(map[string]any)["notices"]
	equal(t, pagesNotices, false, "a job with no notices says none")
	d := data["deploy"].(map[string]any)
	equal(t, d["system"], "github", "system")
	equal(t, d["id"], "7639582616", "id")
	equal(t, d["ref"], store, "ref")
	equal(t, d["state"], "succeeded", "state")
	equal(t, d["rawState"], "success", "raw state")
	equal(t, d["url"], "https://github.com/"+repo+"/actions/runs/7/job/50", "the job's url")
	startedAt, _ := mcpevents.ParseTime(h.at(2))
	finishedAt, _ := mcpevents.ParseTime(h.at(6))
	equal(t, d["started"], float64(wire.DateOf(startedAt)), "started at the first running status")
	equal(t, d["finished"], float64(wire.DateOf(finishedAt)), "finished")
	version := d["version"].(map[string]any)
	equal(t, version["name"], "v0.18.0", "a tag names the version")
	equal(t, version["ref"], "github:release:"+repo+"#v0.18.0", "the release's ref")
	equal(t, version["artifacts"], []any{map[string]any{"kind": "commit", "system": "github", "id": "sha7639582616",
		"ref": "github:artifact:" + repo + "#sha7639582616"}}, "the sha is the one artifact")
	target := d["target"].(map[string]any)
	equal(t, target["ref"], "github:target:"+repo+"#"+repo+"@app-store", "target ref")
	equal(t, target["component"], map[string]any{"system": "github", "id": repo, "repo": repo}, "the repo is the component")
	equal(t, target["environment"], map[string]any{"system": "github", "name": "app-store", "tier": "production"}, "environment")

	pagesStarted := eventsOf(h.poll("deploy.failed", all, cursors["deploy.failed"]))[0]["data"].(map[string]any)["deploy"].(map[string]any)
	_, hasStarted := pagesStarted["started"]
	equal(t, hasStarted, false, "a deploy that never ran has no start")
	equal(t, pagesStarted["version"].(map[string]any)["ref"], "github:artifact:"+repo+"#sha7639582617", "no tag: the artifact's ref")

	equal(t, ids(h.poll("deploy.succeeded", production, firstProduction)), []string{store + "@deploy.succeeded"}, "by tier")
	equal(t, ids(h.poll("deploy.failed", pages, firstPages)), []string{pagesRef + "@deploy.failed"}, "by environment")
	equal(t, ids(h.poll("deploy.started", other, firstOther)), []string{}, "another component")
}

func TestTierOf(t *testing.T) {
	for name, want := range map[string]wire.EnvironmentTier{"production": "production", "Prod": "production", "staging": "staging",
		"qa": "testing", "dev": "development", "github-pages": "other", "release": "other"} {
		equal(t, tierOf(name, false), want, name)
	}
	equal(t, tierOf("app-store", true), wire.EnvironmentTierProduction, "GitHub's production environment")
}

// #5241: a deploy notice says its artifact, and may say the environment it went to first.
func TestDeployPatternTakesTheEnvironmentForm(t *testing.T) {
	for ref, want := range map[string]bool{
		"testflight:com.example.app/42":             true,
		"testflight=testflight:com.example.app/42":  true,
		"app-store=appstore:com.example.app/0.18.0": true,
		"=testflight:com.example.app/42":            false,
		"a b=testflight:com.example.app/42":         false,
		"testflight=":                               false,
		"not a ref":                                 false,
	} {
		equal(t, deployPattern.MatchString(ref), want, ref)
	}
}

// #5241: a job's deploy notices are its check run's annotations.
func TestJobDeploysAreTheJobsNotices(t *testing.T) {
	api := newFakeAPI(t, map[string]string{
		"repos/" + repo + "/check-runs/50/annotations": `[
			{"annotation_level": "notice", "title": "deploy", "message": "testflight=testflight:com.example.app/42"},
			{"annotation_level": "notice", "title": "other", "message": "testflight:com.example.app/1"}]`,
	})
	got, err := api.github().JobDeploys(context.Background(), repo, 50)
	equal(t, err, error(nil), "no error")
	equal(t, got, []string{"testflight=testflight:com.example.app/42"}, "the deploy notice")
}
