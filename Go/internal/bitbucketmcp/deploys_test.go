package bitbucketmcp

import (
	"fmt"
	"testing"

	"github.com/agentloops-dev/agents/Go/internal/mcpevents"
)

// run.completed and its deploys over the fake Bitbucket (#4217).

func runObj(number int, result, ref string, by obj, extra obj) obj {
	r := obj{"uuid": fmt.Sprintf("{p%d}", number), "build_number": number, "creator": by,
		"target": obj{"type": "pipeline_ref_target", "ref_type": "branch", "ref_name": ref, "commit": obj{"hash": fmt.Sprintf("sha%d", number)},
			"selector": obj{"type": "branches", "pattern": ref}},
		"trigger": obj{"name": "PUSH"}, "state": obj{"name": "COMPLETED", "result": obj{"name": result}},
		"created_on": at(0), "completed_on": at(2)}
	for k, v := range extra {
		r[k] = v
	}
	return r
}

func runID(number, minutes int) string {
	return fmt.Sprintf("run.completed:%s:%d:%s", repo, number, mcpevents.Normalized(at(minutes)))
}

func TestRunCompletedForAPipelinesRunOfAnyTrigger(t *testing.T) {
	f := newFake(t)
	p := newPoller(t, f, "run.completed", nil)
	release := newPoller(t, f, "run.completed", map[string]any{"pipeline": "release"})
	tags := newPoller(t, f, "run.completed", map[string]any{"branch": "v1.2.0"})
	anyone := newPoller(t, f, "run.completed", map[string]any{"anyone": true})
	one := newPoller(t, f, "run.completed", map[string]any{"run": 4})
	for _, q := range []*poller{p, release, tags, anyone, one} {
		q.poll()
	}
	f.set(func() {
		f.pipelines[1] = runObj(1, "SUCCESSFUL", "v1.2.0", dev, obj{
			"target": obj{"type": "pipeline_ref_target", "ref_type": "tag", "ref_name": "v1.2.0", "commit": obj{"hash": "sha1"},
				"selector": obj{"type": "custom", "pattern": "release"}},
			"trigger": obj{"name": "MANUAL"}})
		f.pipelines[2] = runObj(2, "FAILED", "main", alex, obj{"completed_on": at(3)})
		f.pipelines[3] = runObj(3, "SUCCESSFUL", "main", stranger, nil)
		f.pipelines[4] = runObj(4, "", "main", alex, obj{"state": obj{"name": "IN_PROGRESS"}, "completed_on": nil})
		f.pipelines[5] = runObj(5, "SUCCESSFUL", "main", renovate, nil)
		// Created long before since, it finished after it.
		f.pipelines[6] = runObj(6, "STOPPED", "main", alex, obj{"created_on": at(-300)})
		f.pipelines[7] = runObj(7, "SUCCESSFUL", "main", alex, obj{"created_on": at(-300), "completed_on": at(-200)})
		f.environments = []obj{{"uuid": "{e1}", "name": "Production", "slug": "production"}, {"uuid": "{e2}", "name": "Test Env"}}
		f.deployments = []obj{
			{"environment": obj{"uuid": "{e1}"}, "release": obj{"pipeline": obj{"uuid": "{p1}"}},
				"state": obj{"name": "COMPLETED", "status": obj{"name": "SUCCESSFUL"}}},
			{"environment": obj{"uuid": "{e2}"}, "release": obj{"pipeline": obj{"uuid": "{p1}"}},
				"state": obj{"name": "COMPLETED", "status": obj{"name": "SUCCESSFUL"}}},
			{"environment": obj{"uuid": "{e1}"}, "release": obj{"pipeline": obj{"uuid": "{p2}"}},
				"state": obj{"name": "COMPLETED", "status": obj{"name": "FAILED"}}},
		}
	})
	ids, result := p.poll()
	same(t, ids, []string{runID(1, 2), runID(6, 2), runID(2, 3)})
	d := data(t, result, 0)
	r := d["run"].(map[string]any)
	if r["id"] != 1 || r["name"] != "release" || r["event"] != "manual" || r["branch"] != "v1.2.0" || r["conclusion"] != "successful" ||
		r["actor"] != "dev" || r["headSha"] != "sha1" || r["url"] != "https://bitbucket.org/acme/app/pipelines/results/1" ||
		d["completedAt"] != mcpevents.Normalized(at(2)) {
		t.Fatalf("data %v", d)
	}
	// Its successful deployments: the slug, or the name when it has no space.
	same(t, d["deploys"], []string{"bitbucket:acme/app/production/1"})
	same(t, data(t, result, 2)["deploys"], []string{})
	ids, _ = release.poll()
	same(t, ids, []string{runID(1, 2)})
	ids, _ = tags.poll()
	same(t, ids, []string{runID(1, 2)})
	ids, _ = anyone.poll()
	same(t, ids, []string{runID(1, 2), runID(3, 2), runID(5, 2), runID(6, 2), runID(2, 3)})
	ids, _ = one.poll()
	same(t, ids, []string(nil))

	// Run again, it finishes again: a new event; and run 4, by its build number.
	f.set(func() {
		f.pipelines[2]["completed_on"] = at(8)
		f.pipelines[4] = runObj(4, "SUCCESSFUL", "main", alex, obj{"completed_on": at(8)})
	})
	ids, _ = p.poll()
	same(t, ids, []string{runID(2, 8), runID(4, 8)})
	ids, _ = one.poll()
	same(t, ids, []string{runID(4, 8)})
}
