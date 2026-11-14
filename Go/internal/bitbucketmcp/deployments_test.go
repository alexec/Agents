package bitbucketmcp

import (
	"strconv"
	"testing"
)

// deploy.started, deploy.succeeded and deploy.failed over the fake Bitbucket (#5244).

func deployRecord(n int, env, state, status string, started, completed int) obj {
	s := obj{"name": state, "url": "https://bitbucket.org/acme/app/pipelines/results/" + strconv.Itoa(n)}
	if started >= 0 {
		s["start_date"] = at(started)
	}
	if completed >= 0 {
		s["completion_date"] = at(completed)
		s["status"] = obj{"name": status}
	}
	return obj{"uuid": "{d" + strconv.Itoa(n) + "}", "environment": obj{"uuid": env}, "state": s,
		"release": obj{"commit": obj{"hash": "sha" + strconv.Itoa(n)}}}
}

func TestDeployEventsFromBitbucketDeployments(t *testing.T) {
	f := newFake(t)
	f.environments = []obj{
		{"uuid": "{p}", "name": "Production", "environment_type": obj{"name": "Production"}},
		{"uuid": "{s}", "name": "Staging", "environment_type": obj{"name": "Staging"}},
		{"uuid": "{t}", "name": "Test", "environment_type": obj{"name": "Test"}},
	}
	started := newPoller(t, f, "deploy.started", nil)
	succeeded := newPoller(t, f, "deploy.succeeded", nil)
	failed := newPoller(t, f, "deploy.failed", nil)
	production := newPoller(t, f, "deploy.started", map[string]any{"tier": "production"})
	staging := newPoller(t, f, "deploy.started", map[string]any{"environment": "staging"})
	all := []*poller{started, succeeded, failed, production, staging}
	for _, q := range all {
		q.poll()
	}
	f.set(func() {
		f.deployments = []obj{
			deployRecord(1, "{p}", "IN_PROGRESS", "", 1, -1),
			deployRecord(2, "{s}", "COMPLETED", "SUCCESSFUL", 1, 2),
			deployRecord(3, "{t}", "COMPLETED", "STOPPED", 1, 3),
			// A step that has not run is none.
			deployRecord(4, "{p}", "UNDEPLOYED", "", -1, -1),
		}
	})
	ref := func(n int, event string) string { return "bitbucket:deploy:acme/app#d" + strconv.Itoa(n) + "@" + event }
	ids, _ := started.poll()
	same(t, ids, []string{ref(1, "deploy.started"), ref(2, "deploy.started"), ref(3, "deploy.started")})
	ids, result := succeeded.poll()
	same(t, ids, []string{ref(2, "deploy.succeeded")})
	d := data(t, result, 0)
	dep := d["deploy"].(map[string]any)
	if d["component"] != "acme/app" || d["environment"] != "Staging" || d["tier"] != "staging" || dep["system"] != "bitbucket" ||
		dep["id"] != "d2" || dep["state"] != "succeeded" || dep["rawState"] != "SUCCESSFUL" || dep["started"] == nil || dep["finished"] == nil ||
		dep["url"] != "https://bitbucket.org/acme/app/pipelines/results/2" {
		t.Fatalf("data %v", d)
	}
	if a := dep["version"].(map[string]any)["artifacts"].([]any)[0].(map[string]any); a["id"] != "sha2" || a["ref"] != "bitbucket:artifact:acme/app#sha2" {
		t.Fatalf("artifact %v", a)
	}
	ids, result = failed.poll()
	same(t, ids, []string{ref(3, "deploy.failed")})
	if d := data(t, result, 0); d["outcome"] != "cancelled" || d["tier"] != "testing" {
		t.Fatalf("data %v", d)
	}
	ids, _ = production.poll()
	same(t, ids, []string{ref(1, "deploy.started")})
	ids, _ = staging.poll()
	same(t, ids, []string{ref(2, "deploy.started")})

	// 1 fails: deploy.failed once, no second start.
	f.set(func() { f.deployments[0] = deployRecord(1, "{p}", "COMPLETED", "FAILED", 1, 5) })
	ids, _ = failed.poll()
	same(t, ids, []string{ref(1, "deploy.failed")})
	for _, q := range all {
		if ids, _ := q.poll(); len(ids) != 0 {
			t.Fatalf("%s again: %v", q.name, ids)
		}
	}
}
