package azuredevopsmcp

import (
	"strconv"
	"testing"
)

// deploy.started, deploy.succeeded and deploy.failed over the fake Azure DevOps (#5244).

func deployRecord(id, build int, result string, started, finished int) obj {
	r := obj{"id": id, "planType": "Build", "stageName": "Deploy", "jobName": "deploy", "definition": obj{"name": "Release"},
		"owner": obj{"id": build, "_links": obj{"web": obj{"href": "https://ado.test/build/" + strconv.Itoa(build)}}}}
	if started >= 0 {
		r["startTime"] = at(started)
	}
	if finished >= 0 {
		r["finishTime"], r["result"] = at(finished), result
	}
	return r
}

func TestDeployEventsFromEnvironmentRecords(t *testing.T) {
	f := newFake(t)
	f.environments = []obj{{"id": 1, "name": "production"}, {"id": 2, "name": "staging"}}
	f.builds = []obj{branchBuild(50, "main", "sha50", "Release", "succeeded", 2), branchBuild(51, "main", "sha51", "Release", "failed", 3)}
	f.builds[0]["sourceBranch"] = "refs/tags/v1.2.0"
	// 52 is another repository's build in the same project.
	other := branchBuild(52, "main", "sha52", "Other", "succeeded", 2)
	other["repository"] = obj{"id": "other-guid"}
	f.builds = append(f.builds, other)
	started := newPoller(t, f, "deploy.started", nil)
	succeeded := newPoller(t, f, "deploy.succeeded", nil)
	failed := newPoller(t, f, "deploy.failed", nil)
	production := newPoller(t, f, "deploy.succeeded", map[string]any{"tier": "production"})
	staging := newPoller(t, f, "deploy.started", map[string]any{"environment": "staging"})
	all := []*poller{started, succeeded, failed, production, staging}
	for _, q := range all {
		q.poll()
	}
	f.set(func() {
		f.records = map[int][]obj{
			1: {deployRecord(11, 50, "succeeded", 1, 2), deployRecord(12, 52, "succeeded", 1, 2)},
			2: {deployRecord(21, 51, "canceled", 1, 3), deployRecord(22, 51, "skipped", -1, 3)},
		}
	})
	ref := func(id int, event string) string {
		return "azuredevops:deploy:acme/web app/app#" + strconv.Itoa(id) + "@" + event
	}
	ids, _ := started.poll()
	same(t, ids, []string{ref(11, "deploy.started"), ref(21, "deploy.started")})
	ids, result := succeeded.poll()
	same(t, ids, []string{ref(11, "deploy.succeeded")})
	d := data(t, result, 0)
	dep := d["deploy"].(map[string]any)
	version := dep["version"].(map[string]any)
	labels := dep["target"].(map[string]any)["labels"].(map[string]any)
	if d["component"] != repo || d["environment"] != "production" || d["tier"] != "production" || dep["system"] != "azuredevops" ||
		dep["state"] != "succeeded" || dep["url"] != "https://ado.test/build/50" || version["name"] != "v1.2.0" ||
		labels["pipeline"] != "Release" || labels["stage"] != "Deploy" || dep["started"] == nil || dep["finished"] == nil {
		t.Fatalf("data %v", d)
	}
	if a := version["artifacts"].([]any)[0].(map[string]any); a["id"] != "sha50" {
		t.Fatalf("artifact %v", a)
	}
	ids, result = failed.poll()
	same(t, ids, []string{ref(21, "deploy.failed")})
	if d := data(t, result, 0); d["outcome"] != "cancelled" || d["tier"] != "staging" {
		t.Fatalf("data %v", d)
	}
	ids, _ = production.poll()
	same(t, ids, []string{ref(11, "deploy.succeeded")})
	ids, _ = staging.poll()
	same(t, ids, []string{ref(21, "deploy.started")})
	for _, q := range all {
		if ids, _ := q.poll(); len(ids) != 0 {
			t.Fatalf("%s again: %v", q.name, ids)
		}
	}
}
