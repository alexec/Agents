package gitlabmcp

import (
	"strconv"
	"testing"
)

// deploy.started, deploy.succeeded and deploy.failed over the fake GitLab (#5244).

func deploymentObj(id int, status, env, tier string, started, finished, updated int) obj {
	d := obj{"id": id, "iid": id - 800, "status": status, "ref": "main", "sha": "sha" + strconv.Itoa(id),
		"created_at": at(0), "updated_at": at(updated),
		"environment": obj{"id": id, "name": env, "tier": tier},
		"deployable":  obj{"name": "deploy", "web_url": "https://gitlab.test/group/app/-/jobs/" + strconv.Itoa(id), "started_at": at(started)}}
	if finished >= 0 {
		d["finished_at"] = at(finished)
	}
	return d
}

func TestDeployEventsOncePerChangeOfState(t *testing.T) {
	f := newFake(t)
	started := newPoller(t, f, "deploy.started", nil)
	succeeded := newPoller(t, f, "deploy.succeeded", nil)
	failed := newPoller(t, f, "deploy.failed", nil)
	production := newPoller(t, f, "deploy.started", map[string]any{"tier": "production"})
	staging := newPoller(t, f, "deploy.started", map[string]any{"environment": "staging"})
	elsewhere := newPoller(t, f, "deploy.started", map[string]any{"component": "other/app"})
	all := []*poller{started, succeeded, failed, production, staging, elsewhere}
	for _, q := range all {
		q.poll()
	}
	f.set(func() {
		f.deploys = []obj{
			deploymentObj(801, "running", "production", "production", 1, -1, 1),
			deploymentObj(802, "success", "staging", "", 1, 2, 2),
			deploymentObj(803, "canceled", "review/fix", "", 1, 3, 3),
			// Waiting for an approval, not started yet, and never run: none is a deploy.* event.
			deploymentObj(804, "blocked", "production", "production", -1, -1, 1),
			deploymentObj(805, "created", "production", "production", -1, -1, 1),
			deploymentObj(806, "skipped", "production", "production", -1, -1, 1),
		}
		f.deploys[1]["ref"] = "v1.2.0"
		for _, d := range f.deploys[3:] {
			delete(d["deployable"].(obj), "started_at")
		}
	})
	ref := func(id int, event string) string { return "gitlab:deploy:group/app#" + strconv.Itoa(id) + "@" + event }
	ids, _ := started.poll()
	same(t, ids, []string{ref(801, "deploy.started"), ref(802, "deploy.started"), ref(803, "deploy.started")})
	ids, result := succeeded.poll()
	same(t, ids, []string{ref(802, "deploy.succeeded")})
	d := data(t, result, 0)
	dep := d["deploy"].(map[string]any)
	version := dep["version"].(map[string]any)
	env := dep["target"].(map[string]any)["environment"].(map[string]any)
	if d["component"] != "group/app" || d["environment"] != "staging" || d["tier"] != "staging" || d["outcome"] != nil ||
		dep["system"] != "gitlab" || dep["id"] != "802" || dep["state"] != "succeeded" || dep["rawState"] != "success" ||
		dep["url"] != "https://gitlab.test/group/app/-/jobs/802" || dep["started"] == nil || dep["finished"] == nil ||
		version["name"] != "v1.2.0" || version["ref"] != "gitlab:release:group/app#v1.2.0" || env["system"] != "gitlab" {
		t.Fatalf("data %v", d)
	}
	if a := version["artifacts"].([]any)[0].(map[string]any); a["kind"] != "commit" || a["id"] != "sha802" || a["ref"] != "gitlab:artifact:group/app#sha802" {
		t.Fatalf("artifact %v", a)
	}
	// GitLab's canceled is deploy.failed, cancelled; a name that says no tier is other.
	ids, result = failed.poll()
	same(t, ids, []string{ref(803, "deploy.failed")})
	if d := data(t, result, 0); d["outcome"] != "cancelled" || d["tier"] != "other" || d["deploy"].(map[string]any)["state"] != "cancelled" ||
		d["deploy"].(map[string]any)["rawState"] != "canceled" {
		t.Fatalf("data %v", d)
	}
	ids, _ = production.poll()
	same(t, ids, []string{ref(801, "deploy.started")})
	ids, _ = staging.poll()
	same(t, ids, []string{ref(802, "deploy.started")})
	ids, _ = elsewhere.poll()
	same(t, ids, nil)

	// 801 ends: deploy.succeeded once, and no second start; one that started and ended between
	// two polls raises both.
	f.set(func() {
		f.deploys[0]["status"], f.deploys[0]["finished_at"], f.deploys[0]["updated_at"] = "success", at(5), at(5)
		f.deploys = append(f.deploys, deploymentObj(807, "failed", "production", "production", 4, 5, 5))
	})
	ids, _ = started.poll()
	same(t, ids, []string{ref(807, "deploy.started")})
	ids, _ = succeeded.poll()
	same(t, ids, []string{ref(801, "deploy.succeeded")})
	ids, result = failed.poll()
	same(t, ids, []string{ref(807, "deploy.failed")})
	if d := data(t, result, 0); d["outcome"] != "failed" || d["tier"] != "production" {
		t.Fatalf("data %v", d)
	}
	ids, _ = production.poll()
	same(t, ids, []string{ref(807, "deploy.started")})
	for _, q := range all {
		if ids, _ := q.poll(); len(ids) != 0 {
			t.Fatalf("%s again: %v", q.name, ids)
		}
	}
}
