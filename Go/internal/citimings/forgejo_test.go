package citimings

import "testing"

// Forgejo 17's shapes (Codeberg's swagger): a run with created, started and stopped, and jobs
// whose only times are their steps'; "test" needs "build" and was run again (attempt 2).
func TestFromForgejoTimesAJobByItsSteps(t *testing.T) {
	run := ForgejoRun{ID: 900, IndexInRepo: 5, WorkflowID: "ci.yml", Event: "push", PrettyRef: "main", CommitSHA: "aaa",
		HTMLURL: "https://codeberg.org/scratch/app/actions/runs/5", Status: "success",
		Created: "2026-11-10T10:00:00Z", Started: "2026-11-10T10:00:05Z", Stopped: "2026-11-10T10:20:00Z"}
	jobs, err := ForgejoJobs([]byte(`[
	 {"id":1,"name":"build","attempt":1,"status":"success","runs_on":["docker"],"steps":[
	  {"name":"Set up job","number":0,"status":"success","started":"2026-11-10T10:00:20Z","stopped":"2026-11-10T10:00:30Z"},
	  {"name":"Build","number":1,"status":"success","started":"2026-11-10T10:00:30Z","stopped":"2026-11-10T10:02:00Z"},
	  {"name":"Never","number":2,"status":"skipped","started":"0001-01-01T00:00:00Z","stopped":"0001-01-01T00:00:00Z"}]},
	 {"id":2,"name":"test","attempt":2,"needs":["build"],"status":"success","runs_on":["docker"],"steps":[
	  {"name":"Test","number":1,"status":"success","started":"2026-11-10T10:15:00Z","stopped":"2026-11-10T10:20:00Z"}]}]`))
	if err != nil {
		t.Fatal(err)
	}
	got, err := FromForgejo(run, jobs, "forgejo:run:scratch/app#5", true, false)
	if err != nil || len(got) != 2 {
		t.Fatalf("%+v %v", got, err)
	}
	first, last := got[0], got[1]
	if last.Attempt != 2 || last.ID != 5 || last.Workflow != "ci.yml" || last.Branch != "main" || last.HeadSHA != "aaa" ||
		last.Conclusion != "success" || last.Started != 5 || last.Ended != 1200 || !last.Default {
		t.Fatalf("last %+v", last)
	}
	build, test := last.Jobs[0], last.Jobs[1]
	if build.Made != 0 || build.Started != 20 || build.Ended != 120 || build.Runner != "docker" || len(build.Steps) != 2 {
		t.Fatalf("build %+v", build)
	}
	// It needs build, so it was made when build ended.
	if test.Made != 120 || test.Started != 900 || test.Ended != 1200 {
		t.Fatalf("test %+v", test)
	}
	if first.Attempt != 1 || first.Conclusion != "failure" || first.Jobs[0].Ended != 120 ||
		first.Jobs[1].Ended != 0 || first.Jobs[1].Conclusion != "failure" || first.Ended != 120 {
		t.Fatalf("first %+v", first)
	}
}

// Gitea's shapes are GitHub's; its jobs answer is {"jobs": […]}, and a pull request's run
// says its number.
func TestFromForgejoReadsGitea(t *testing.T) {
	run := ForgejoRun{ID: 77, RunNumber: 6, RunAttempt: 1, Path: ".gitea/workflows/ci.yml@refs/pull/9/head", Event: "pull_request",
		HeadBranch: "feature", HeadSHA: "bbb", Status: "completed", Conclusion: "failure",
		CreatedAt: "2026-11-10T10:00:00Z", StartedAt: "2026-11-10T10:00:10Z", CompletedAt: "2026-11-10T10:05:00Z"}
	run.PullRequests = append(run.PullRequests, struct {
		Number int `json:"number"`
	}{9})
	jobs, err := ForgejoJobs([]byte(`{"total_count":1,"jobs":[{"id":3,"name":"test","run_attempt":1,"status":"completed","conclusion":"failure","labels":["ubuntu-latest"],
	 "created_at":"2026-11-10T10:00:02Z","started_at":"2026-11-10T10:00:12Z","completed_at":"2026-11-10T10:05:00Z",
	 "steps":[{"name":"Test","number":1,"status":"completed","conclusion":"failure","started_at":"2026-11-10T10:00:13Z","completed_at":"2026-11-10T10:05:00Z"}]}]}`))
	if err != nil {
		t.Fatal(err)
	}
	got, err := FromForgejo(run, jobs, "forgejo:run:scratch/app#6", false, false)
	if err != nil || len(got) != 1 {
		t.Fatalf("%+v %v", got, err)
	}
	r := got[0]
	if r.Workflow != "ci.yml" || r.PR != 9 || r.Branch != "feature" || r.Conclusion != "failure" || r.Attempt != 1 {
		t.Fatalf("run %+v", r)
	}
	if j := r.Jobs[0]; j.Made != 2 || j.Started != 12 || j.Ended != 300 || j.Conclusion != "failure" || j.Runner != "ubuntu-latest" ||
		len(j.Steps) != 1 || j.Steps[0].Conclusion != "failure" {
		t.Fatalf("job %+v", j)
	}
}

// A Forgejo pull request's run says its number and head branch only in its event's payload.
func TestForgejoRunPullRequestFromItsPayload(t *testing.T) {
	r := ForgejoRun{Event: "pull_request", PrettyRef: "12",
		EventPayload: `{"number":12,"pull_request":{"number":12,"head":{"ref":"feature"}}}`}
	if r.PR() != 12 || r.Branch() != "feature" {
		t.Fatalf("pr %d branch %q", r.PR(), r.Branch())
	}
	if (ForgejoRun{Status: "running"}).Result() != "" || (ForgejoRun{Status: "canceled"}).Result() != "cancelled" {
		t.Fatal("result")
	}
}
