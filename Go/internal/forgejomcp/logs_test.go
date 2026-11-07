package forgejomcp

import (
	"fmt"
	"strings"
	"testing"
)

// failed_log (#3761) over the fake Forgejo: a run found by its number, its failed jobs, and
// each log's end in plain text, read with a Range; on Forgejo 17 the failed step's only, and
// on a server too old for it, the version it needs.

func logText(t *testing.T, c *client, args map[string]any) (string, bool) {
	t.Helper()
	reply := c.call("tools/call", map[string]any{"name": "failed_log", "arguments": args})
	result := reply["result"].(map[string]any)
	return result["content"].([]any)[0].(map[string]any)["text"].(string), result["isError"] != true
}

// fakeRun puts run number 4, whose id is 5, in the fake: a job that waited on the broken
// one, one that passed, and the broken one, id 8, whose step 2 (test) failed.
func fakeRun(f *fakeForgejo, gitea bool) {
	failed := obj{"status": "failure"}
	if gitea {
		failed = obj{"status": "completed", "conclusion": "failure"}
	}
	job := func(id int, name string, state obj) obj {
		j := obj{"id": id, "name": name, "run_id": 5,
			"html_url": fmt.Sprintf("https://forgejo.test/acme/app/actions/runs/4/jobs/%d", id-6)}
		for k, v := range state {
			j[k] = v
		}
		return j
	}
	broken := job(8, "broken", failed)
	broken["steps"] = []any{obj{"number": 0, "name": "Set up job", "status": "success"},
		obj{"number": 1, "name": "prepare", "status": "success"}, obj{"number": 2, "name": "test", "status": "failure"},
		obj{"number": 3, "name": "after", "status": "skipped"}}
	f.runs = []obj{{"id": 6, "index_in_repo": 5, "run_number": 5}, {"id": 5, "index_in_repo": 4, "run_number": 4},
		{"id": 2, "index_in_repo": 3, "run_number": 3}}
	f.jobs[5] = []obj{job(6, "late", obj{"status": "blocked"}), job(7, "ok", obj{"status": "success"}), broken}
	f.giteaJobs = gitea
	whole := "2026-11-07T11:34:20.0220043Z received task 4 of job broken\n2026-11-07T11:34:20.0263640Z preparing\n" +
		"2026-11-07T11:34:20.0294070Z running the tests\n2026-11-07T11:34:20.0294580Z \x1b[31mFAIL: TestThing\x1b[0m\r\n" +
		"2026-11-07T11:34:20.0317775Z Job failed\n\n"
	f.logs["8"] = whole
	f.logs["8?step=2"] = "2026-11-07T11:34:20.0294070Z running the tests\n2026-11-07T11:34:20.0294580Z \x1b[31mFAIL: TestThing\x1b[0m\n"
	f.logs["7"] = "all good\n"
}

func TestAFailedLogOnForgejo17IsItsFailedStepsEnd(t *testing.T) {
	f := newFake(t)
	fakeRun(f, false)
	c := serve(t, f, false)

	text, ok := logText(t, c, map[string]any{"runId": 4})
	same(t, ok, true)
	same(t, text, "== broken ▸ test (https://forgejo.test/acme/app/actions/runs/4/jobs/2), last 300 lines ==\n"+
		"running the tests\nFAIL: TestThing")
	f.mu.Lock()
	same(t, f.ranges, []string{fmt.Sprintf("bytes=-%d", logBytes)})
	f.mu.Unlock()

	// A step that failed with nothing to say: the whole job's log.
	f.set(func() { f.logs["8?step=2"] = "" })
	whole, _ := logText(t, c, map[string]any{"runId": 4})
	if !strings.HasPrefix(whole, "== broken (https://forgejo.test/acme/app/actions/runs/4/jobs/2), last 300 lines ==\n"+
		"received task 4") {
		t.Fatalf("an empty step %q", whole)
	}

	none, ok := logText(t, c, map[string]any{"runId": 4, "job": "ok"})
	if !ok || !strings.HasPrefix(none, `No failed job "ok" in run 4 (`) {
		t.Fatalf("one job %q", none)
	}
}

func TestAFailedLogOnForgejo16IsTheWholeJobsEnd(t *testing.T) {
	f := newFake(t)
	f.version = "16.0.7+gitea-1.22.0"
	fakeRun(f, false)
	c := serve(t, f, false)

	text, ok := logText(t, c, map[string]any{"runId": 4, "job": "broken"})
	same(t, ok, true)
	same(t, text, "== broken (https://forgejo.test/acme/app/actions/runs/4/jobs/2), last 300 lines ==\n"+
		"received task 4 of job broken\npreparing\nrunning the tests\nFAIL: TestThing\nJob failed")
}

func TestAFailedLogOnGitea125FindsTheRunByItsNumber(t *testing.T) {
	f := newFake(t)
	f.version = "1.25.5"
	fakeRun(f, true)
	c := serve(t, f, false)

	text, ok := logText(t, c, map[string]any{"runId": 4})
	if !ok || !strings.HasPrefix(text, "== broken (https://forgejo.test/acme/app/actions/runs/4/jobs/2), last 300 lines ==\n") ||
		!strings.HasSuffix(text, "FAIL: TestThing\nJob failed") || strings.Contains(text, "all good") {
		t.Fatalf("log %q", text)
	}
	if text, ok := logText(t, c, map[string]any{"runId": 9}); ok || text != "acme/app has no Actions run 9" {
		t.Fatalf("no run: %q", text)
	}
}

func TestAnOlderServerSaysWhichVersionItNeeds(t *testing.T) {
	for version, want := range map[string]string{
		"11.0.16+gitea-1.22.0": "Forgejo 11.0.16+gitea-1.22.0 has no API for an Actions job's log: failed_log needs Forgejo 16 or later. ",
		"1.24.7":               "Gitea 1.24.7 has no API that lists an Actions run's jobs: failed_log needs Gitea 1.25 or later. ",
	} {
		f := newFake(t)
		f.version = version
		c := serve(t, f, false)
		text, ok := logText(t, c, map[string]any{"runId": 4})
		if ok || text != want+"The run is at "+f.server.URL+"/acme/app/actions/runs/4." {
			t.Fatalf("%s: %q", version, text)
		}
	}
	f := newFake(t)
	c := serve(t, f, false)
	if text, ok := logText(t, c, map[string]any{"runId": 0}); ok || text != "runId is a Forgejo Actions run's number" {
		t.Fatalf("no run: %q", text)
	}
}

func TestALogTailIsItsLastLinesWithoutTheCutOne(t *testing.T) {
	var log strings.Builder
	for i := range 500 {
		fmt.Fprintf(&log, "2026-11-07T11:34:20Z line %d\n", i)
	}
	tail, err := logTail(strings.NewReader("ne cut\n"+log.String()+"\n\n"), logLines, true)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(tail, "\n")
	same(t, len(lines), logLines)
	same(t, lines[0], "line 200")
	same(t, lines[len(lines)-1], "line 499")
	if empty, _ := logTail(strings.NewReader(""), logLines, false); empty != "" {
		t.Fatalf("empty %q", empty)
	}
}
