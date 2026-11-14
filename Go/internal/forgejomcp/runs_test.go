package forgejomcp

import (
	"fmt"
	"testing"

	"github.com/agentloops-dev/agent-loops/Go/internal/mcpevents"
)

// run.completed over the fake Forgejo (#4217): Forgejo's runs and Gitea's.

// forgejoRun is a run as Forgejo lists it.
func forgejoRun(number int, status, ref string, by obj, extra obj) obj {
	r := obj{"id": 900 + number, "index_in_repo": number, "title": fmt.Sprintf("Run %d", number), "workflow_id": "ci.yml",
		"trigger_event": "push", "prettyref": ref, "commit_sha": fmt.Sprintf("sha%d", number), "status": status, "trigger_user": by,
		"html_url": fmt.Sprintf("https://fj.test/acme/app/actions/runs/%d", number), "created": at(0), "started": at(0), "stopped": at(2)}
	for k, v := range extra {
		r[k] = v
	}
	return r
}

func completedID(number, minutes int) string {
	return fmt.Sprintf("run.completed:%s:%d:%s", repo, number, mcpevents.Normalized(at(minutes)))
}

func TestRunCompletedForAnActionsRunOfAnyTrigger(t *testing.T) {
	f := newFake(t)
	p := newPoller(t, f, "run.completed", nil)
	release := newPoller(t, f, "run.completed", map[string]any{"workflow": "release.yml"})
	tags := newPoller(t, f, "run.completed", map[string]any{"branch": "v1.2.0"})
	anyone := newPoller(t, f, "run.completed", map[string]any{"anyone": true})
	one := newPoller(t, f, "run.completed", map[string]any{"run": 4})
	for _, q := range []*poller{p, release, tags, anyone, one} {
		q.poll()
	}
	f.set(func() {
		// Newest first, as Forgejo lists them.
		f.runs = []obj{
			forgejoRun(6, "failure", "main", alex, obj{"created": at(-300)}),
			forgejoRun(5, "success", "main", renovate, nil),
			forgejoRun(4, "running", "main", alex, obj{"stopped": ""}),
			forgejoRun(3, "success", "main", stranger, nil),
			forgejoRun(2, "failure", "fix", dev, obj{"is_fork_pull_request": true, "trigger_event": "pull_request"}),
			forgejoRun(1, "success", "", dev, obj{"workflow_id": "release.yml", "prettyref": "", "ref": "refs/tags/v1.2.0",
				"trigger_event": "workflow_dispatch", "stopped": at(3)}),
			// Created long before the cutoff: the listing stops here.
			forgejoRun(0, "success", "main", alex, obj{"created": at(-1000), "stopped": at(-990)}),
		}
	})
	ids, result := p.poll()
	same(t, ids, []string{completedID(6, 2), completedID(1, 3)})
	d := data(t, result, 1)
	r := d["run"].(map[string]any)
	if r["id"] != 1 || r["name"] != "Run 1" || r["workflow"] != "release.yml" || r["event"] != "workflow_dispatch" || r["branch"] != "v1.2.0" ||
		r["conclusion"] != "success" || r["actor"] != "dev" || r["headSha"] != "sha1" || r["url"] != "https://fj.test/acme/app/actions/runs/1" ||
		d["completedAt"] != mcpevents.Normalized(at(3)) {
		t.Fatalf("data %v", d)
	}
	same(t, d["deploys"], []string{})
	ids, _ = release.poll()
	same(t, ids, []string{completedID(1, 3)})
	ids, _ = tags.poll()
	same(t, ids, []string{completedID(1, 3)})
	// anyone: a stranger's, a bot's and a fork's too; never one still running.
	ids, _ = anyone.poll()
	same(t, ids, []string{completedID(2, 2), completedID(3, 2), completedID(5, 2), completedID(6, 2), completedID(1, 3)})
	ids, _ = one.poll()
	same(t, ids, []string(nil))

	// Run again, it finishes again: a new event; and run 4, by its number.
	f.set(func() {
		f.runs[0]["stopped"] = at(8)
		f.runs[2]["status"], f.runs[2]["stopped"] = "success", at(8)
	})
	ids, _ = p.poll()
	same(t, ids, []string{completedID(4, 8), completedID(6, 8)})
	ids, _ = one.poll()
	same(t, ids, []string{completedID(4, 8)})
}

func TestRunCompletedReadsGiteasRuns(t *testing.T) {
	f := newFake(t)
	f.giteaJobs = true
	p := newPoller(t, f, "run.completed", map[string]any{"workflow": "release.yml"})
	p.poll()
	f.set(func() {
		f.runs = []obj{
			{"id": 31, "run_number": 3, "display_title": "Release", "path": ".gitea/workflows/release.yml@refs/tags/v2.0.0", "event": "push",
				"head_branch": "v2.0.0", "head_sha": "abc", "status": "completed", "conclusion": "failure", "trigger_actor": dev,
				"actor": alex, "html_url": "https://gitea.test/acme/app/actions/runs/3", "started_at": at(0), "completed_at": at(2)},
			{"id": 30, "run_number": 2, "path": ".gitea/workflows/release.yml@refs/heads/main", "status": "in_progress",
				"trigger_actor": dev, "started_at": at(0)},
			// The index_in_repo the fake lists by, as Forgejo's.
			{"id": 29, "run_number": 1, "index_in_repo": 1, "path": ".gitea/workflows/ci.yml@refs/heads/main", "status": "completed",
				"conclusion": "success", "trigger_actor": dev, "started_at": at(0), "completed_at": at(2)},
		}
		f.runs[0]["index_in_repo"], f.runs[1]["index_in_repo"] = 3, 2
	})
	ids, result := p.poll()
	same(t, ids, []string{completedID(3, 2)})
	r := data(t, result, 0)["run"].(map[string]any)
	if r["name"] != "Release" || r["actor"] != "dev" || r["branch"] != "v2.0.0" || r["conclusion"] != "failure" || r["headSha"] != "abc" {
		t.Fatalf("run %v", r)
	}
}
