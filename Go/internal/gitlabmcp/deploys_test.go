package gitlabmcp

import (
	"context"
	"fmt"
	"strconv"
	"testing"
)

// run.completed, its deploys and deploy.waiting over the fake GitLab (#4217).

func pipeObj(id int, status, ref string, by obj, extra obj) obj {
	p := obj{"id": id, "iid": id - 100, "status": status, "ref": ref, "sha": "sha" + strconv.Itoa(id), "source": "push",
		"web_url": "https://gitlab.test/group/app/-/pipelines/" + strconv.Itoa(id), "user": by,
		"created_at": at(0), "updated_at": at(2), "finished_at": at(2)}
	for k, v := range extra {
		p[k] = v
	}
	return p
}

func deployObj(id, pipeline int, status, env string, by obj, extra obj) obj {
	d := obj{"id": id, "iid": id - 500, "status": status, "created_at": at(1), "finished_at": at(1), "user": by,
		"environment": obj{"id": 1, "name": env},
		"deployable": obj{"name": "deploy", "web_url": "https://gitlab.test/group/app/-/jobs/" + strconv.Itoa(id),
			"pipeline": obj{"id": pipeline, "ref": "v1.2.0", "sha": "sha" + strconv.Itoa(pipeline), "status": "running",
				"web_url": "https://gitlab.test/group/app/-/pipelines/" + strconv.Itoa(pipeline)}}}
	for k, v := range extra {
		d[k] = v
	}
	return d
}

func TestRunCompletedForAPipelineOfAnyTrigger(t *testing.T) {
	f := newFake(t)
	f.addMembers()
	p := newPoller(t, f, "run.completed", nil)
	tags := newPoller(t, f, "run.completed", map[string]any{"branch": "v1.2.0"})
	named := newPoller(t, f, "run.completed", map[string]any{"pipeline": "release", "anyone": true})
	anyone := newPoller(t, f, "run.completed", map[string]any{"anyone": true})
	one := newPoller(t, f, "run.completed", map[string]any{"run": 104})
	for _, q := range []*poller{p, tags, named, anyone, one} {
		q.poll()
	}
	f.set(func() {
		f.pipes = []obj{
			pipeObj(101, "success", "v1.2.0", alex, obj{"name": "release", "source": "push"}),
			pipeObj(102, "failed", "main", dev, obj{"source": "schedule", "updated_at": at(3), "finished_at": at(3)}),
			pipeObj(103, "canceled", "main", stranger, obj{"updated_at": at(3)}),
			pipeObj(104, "running", "main", alex, nil),
			pipeObj(105, "success", "main", tokenBot, nil),
			pipeObj(106, "success", "old", alex, obj{"updated_at": at(-10)}),
		}
		f.deploys = []obj{
			deployObj(601, 101, "success", "production", alex, nil),
			deployObj(602, 101, "success", "review/with space", alex, nil),
			deployObj(603, 101, "failed", "staging", alex, nil),
			deployObj(604, 999, "success", "production", alex, nil),
		}
	})
	ids, result := p.poll()
	same(t, ids, []string{"run.completed:group/app:101:" + at(2), "run.completed:group/app:102:" + at(3)})
	d := data(t, result, 0)
	run := d["run"].(map[string]any)
	if run["id"] != 101 || run["number"] != 1 || run["name"] != "release" || run["event"] != "push" || run["branch"] != "v1.2.0" ||
		run["conclusion"] != "success" || run["actor"] != "alex" || run["headSha"] != "sha101" || d["completedAt"] != at(2) {
		t.Fatalf("data %v", d)
	}
	// Its successful deployments, and never one whose environment's name has a space.
	if fmt.Sprint(d["deploys"]) != "[gitlab:group/app/production/101]" {
		t.Fatalf("deploys %v", d["deploys"])
	}
	if d := data(t, result, 1); d["run"].(map[string]any)["name"] != "Pipeline #102" || len(d["deploys"].([]string)) != 0 {
		t.Fatalf("data %v", d)
	}
	ids, _ = tags.poll()
	same(t, ids, []string{"run.completed:group/app:101:" + at(2)})
	ids, _ = named.poll()
	same(t, ids, []string{"run.completed:group/app:101:" + at(2)})
	// anyone: a stranger's and a bot's too; never one still running.
	ids, _ = anyone.poll()
	same(t, ids, []string{"run.completed:group/app:101:" + at(2), "run.completed:group/app:105:" + at(2),
		"run.completed:group/app:102:" + at(3), "run.completed:group/app:103:" + at(3)})
	ids, _ = one.poll()
	same(t, ids, nil)

	// Retried, it finishes again: a new event. Its own run, by id, once it finishes.
	f.set(func() {
		f.pipes[0]["updated_at"], f.pipes[0]["finished_at"] = at(6), at(6)
		f.pipes[3]["status"], f.pipes[3]["updated_at"] = "success", at(6)
	})
	ids, _ = p.poll()
	same(t, ids, []string{"run.completed:group/app:101:" + at(6), "run.completed:group/app:104:" + at(6)})
	ids, _ = one.poll()
	same(t, ids, []string{"run.completed:group/app:104:" + at(6)})
}

func TestDeployWaitingForAProtectedEnvironment(t *testing.T) {
	f := newFake(t)
	f.addMembers()
	p := newPoller(t, f, "deploy.waiting", nil)
	main := newPoller(t, f, "deploy.waiting", map[string]any{"branch": "main"})
	anyone := newPoller(t, f, "deploy.waiting", map[string]any{"anyone": true})
	for _, q := range []*poller{p, main, anyone} {
		q.poll()
	}
	rules := func(rs ...obj) obj { return obj{"approval_summary": obj{"rules": rs}} }
	f.set(func() {
		f.pipes = []obj{pipeObj(101, "running", "v1.2.0", dev, obj{"name": "release"}), pipeObj(102, "running", "v1.3.0", stranger, nil)}
		f.groupMember[1] = true
		f.deploys = []obj{
			// Newest first, as GitLab lists them.
			deployObj(702, 101, "blocked", "store", dev, rules(obj{"group_id": 9, "access_level_description": "release-managers", "required_approvals": 1})),
			deployObj(701, 101, "blocked", "production", dev, obj{"created_at": at(0)}),
			deployObj(703, 102, "blocked", "production", stranger, nil),
			deployObj(704, 101, "success", "staging", dev, nil),
		}
		f.deploys[1]["approval_summary"] = obj{"rules": []obj{
			{"user_id": 1, "access_level_description": "Alex", "required_approvals": 1},
			{"access_level": 40, "access_level_description": "Maintainers", "required_approvals": 2,
				"deployment_approvals": []obj{{"user": dev, "status": "approved"}}},
			{"user_id": 2, "access_level_description": "Done", "required_approvals": 1,
				"deployment_approvals": []obj{{"user": dev, "status": "approved"}}},
		}}
	})
	ids, result := p.poll()
	same(t, ids, []string{"deploy.waiting:group/app:101:701,702"})
	d := data(t, result, 0)
	envs := d["environments"].([]any)
	if len(envs) != 2 || envs[0].(map[string]any)["name"] != "production" || envs[1].(map[string]any)["id"] != 702 ||
		envs[0].(map[string]any)["url"] != "https://gitlab.test/group/app/-/jobs/701" {
		t.Fatalf("environments %v", envs)
	}
	if fmt.Sprint(d["reviewers"]) != "[Alex Maintainers release-managers]" || d["canApprove"] != true || d["waitingSince"] != at(1) {
		t.Fatalf("data %v", d)
	}
	if run := d["run"].(map[string]any); run["id"] != 101 || run["name"] != "release" || run["actor"] != "dev" || run["branch"] != "v1.2.0" {
		t.Fatalf("run %v", run)
	}
	ids, _ = main.poll()
	same(t, ids, nil)
	ids, _ = anyone.poll()
	same(t, ids, []string{"deploy.waiting:group/app:101:701,702", "deploy.waiting:group/app:102:703"})

	// One answered, the next one it waits on is a new event; the owner no longer in the group
	// may not answer it.
	f.set(func() {
		f.deploys[1]["status"] = "success"
		f.deploys[0]["created_at"] = at(4)
		f.groupMember[1] = false
	})
	ids, result = p.poll()
	same(t, ids, []string{"deploy.waiting:group/app:101:702"})
	if d := data(t, result, 0); d["canApprove"] != false || fmt.Sprint(d["reviewers"]) != "[release-managers]" {
		t.Fatalf("data %v", d)
	}
}

func TestApproversNeverTheOneWhoStartedIt(t *testing.T) {
	f := newFake(t)
	f.addMembers()
	f.deploys = []obj{deployObj(801, 101, "blocked", "production", alex,
		obj{"approval_summary": obj{"rules": []obj{{"user_id": 1, "access_level_description": "Alex", "required_approvals": 1}}}})}
	g := f.gitlab()
	waiting, err := g.WaitingDeploys(context.Background(), project, "")
	if err != nil || len(waiting) != 1 {
		t.Fatalf("waiting %v %v", waiting, err)
	}
	reviewers, can, err := g.Approvers(context.Background(), project, waiting[0])
	if err != nil || can || fmt.Sprint(reviewers) != "[Alex]" {
		t.Fatalf("reviewers %v, can %v, %v", reviewers, can, err)
	}
}

func TestPathOfAPipelinesPage(t *testing.T) {
	for web, want := range map[string]string{
		"https://gitlab.test/group/sub/app/-/pipelines/12": "group/sub/app",
		"https://gitlab.test/gitlab/group/app/-/jobs/1":    "gitlab/group/app",
		"":                               "7",
		"https://gitlab.test/no-dash/12": "7",
	} {
		if got := pathOf(web, "7"); got != want {
			t.Fatalf("pathOf(%q) = %q, want %q", web, got, want)
		}
	}
	if !deployPattern.MatchString("gitlab:group/app/review/feature-1/12") || deployPattern.MatchString("gitlab:group/app/review/a b/12") {
		t.Fatal("deployPattern")
	}
}
