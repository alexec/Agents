package forgejomcp

import (
	"strings"
	"testing"
)

// retry_pipeline (#3842) over the fake Forgejo: a run found by its number, its failed jobs
// sent again one by one on Forgejo or in one call on Gitea, and on a server too old for it,
// the version it needs.

func retried(f *fakeForgejo) []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	paths := []string{}
	for _, p := range f.posted {
		paths = append(paths, p["_path"].(string))
	}
	return paths
}

func TestARetryOnForgejoSendsEachFailedJob(t *testing.T) {
	f := newFake(t)
	fakeRun(f, false)
	c := serve(t, f, false)

	r, ok := c.tool("retry_pipeline", map[string]any{"runId": 4})
	same(t, ok, true)
	same(t, r["retried"], true)
	same(t, r["runId"], float64(4))
	same(t, r["jobs"], []any{"broken"})
	same(t, r["url"], f.server.URL+"/acme/app/actions/runs/4")
	same(t, retried(f), []string{"/api/v1/repos/acme/app/actions/jobs/8/rerun"})
}

// A failed job that needs one sent before it waits again already: Forgejo answers 400.
func TestARetryOnForgejoTakesAJobAlreadyWaitingAgain(t *testing.T) {
	f := newFake(t)
	fakeRun(f, false)
	// late needs broken, and comes after it.
	f.jobs[5][0]["status"] = "failure"
	f.jobs[5][0], f.jobs[5][2] = f.jobs[5][2], f.jobs[5][0]
	f.rerunning[6] = true
	c := serve(t, f, false)

	r, ok := c.tool("retry_pipeline", map[string]any{"runId": 4})
	same(t, ok, true)
	same(t, r["jobs"], []any{"broken", "late"})
	same(t, retried(f), []string{"/api/v1/repos/acme/app/actions/jobs/8/rerun", "/api/v1/repos/acme/app/actions/jobs/6/rerun"})
}

// A run that has not ended: Forgejo refuses the first job, and so does the tool.
func TestARetryOfARunThatHasNotEndedFails(t *testing.T) {
	f := newFake(t)
	fakeRun(f, false)
	f.rerunning[8] = true
	c := serve(t, f, false)

	same(t, retryText(t, c, map[string]any{"runId": 4}), "Forgejo: HTTP 400: job is still running")
}

func TestARetryOnGitea126SendsTheRunsFailedJobs(t *testing.T) {
	f := newFake(t)
	fakeRun(f, true)
	f.version = "1.26.4"
	c := serve(t, f, false)

	r, ok := c.tool("retry_pipeline", map[string]any{"runId": 4})
	same(t, ok, true)
	same(t, r["jobs"], []any{"broken"})
	same(t, retried(f), []string{"/api/v1/repos/acme/app/actions/runs/5/rerun-failed-jobs"})
}

func TestARetryNeedsARunWithAFailedJobOnANewEnoughServer(t *testing.T) {
	for version, want := range map[string]string{
		"16.0.7+gitea-1.22.0": "Forgejo 16.0.7+gitea-1.22.0 has no API that runs an Actions job again: retry_pipeline needs Forgejo 17 or later. ",
		"1.25.5":              "Gitea 1.25.5 has no API that runs an Actions job again: retry_pipeline needs Gitea 1.26 or later. ",
	} {
		f := newFake(t)
		fakeRun(f, !strings.Contains(version, "+gitea-"))
		f.version = version
		text := retryText(t, serve(t, f, false), map[string]any{"runId": 4})
		if !strings.HasPrefix(text, want) {
			t.Errorf("%s: %q", version, text)
		}
		same(t, retried(f), []string{})
	}

	f := newFake(t)
	fakeRun(f, false)
	c := serve(t, f, false)
	same(t, retryText(t, c, map[string]any{"runId": 99}), "acme/app has no Actions run 99")
	same(t, retryText(t, c, map[string]any{"runId": 0}), "runId is a Forgejo Actions run's number")
	same(t, retryText(t, c, map[string]any{"runId": 4, "repo": "no"}), "repo is "+repoWords)
	f.jobs[5][2]["status"] = "success"
	same(t, retryText(t, c, map[string]any{"runId": 4}), "run 4 has no failed jobs ("+f.server.URL+"/acme/app/actions/runs/4)")
	same(t, retried(f), []string{})
}

// retryText is a retry that failed: why.
func retryText(t *testing.T, c *client, args map[string]any) string {
	t.Helper()
	reply := c.call("tools/call", map[string]any{"name": "retry_pipeline", "arguments": args})
	result := reply["result"].(map[string]any)
	if result["isError"] != true {
		t.Fatalf("%v worked: %v", args, result)
	}
	return result["content"].([]any)[0].(map[string]any)["text"].(string)
}
