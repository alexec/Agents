package agentsd

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// A fake GitHub with three finished runs: one on main (attempt 2, its first attempt failed),
// one on a PR, and one on main older than the steps bound for PRs.
func ciFakeGitHub(t *testing.T, now time.Time) (*httptest.Server, *atomic.Int32) {
	t.Helper()
	var calls atomic.Int32
	at := func(d time.Duration) string { return now.Add(d).UTC().Format(time.RFC3339) }
	mux := http.NewServeMux()
	mux.HandleFunc("/repos/alexec/agents", func(w http.ResponseWriter, _ *http.Request) {
		calls.Add(1)
		fmt.Fprint(w, `{"default_branch":"main"}`)
	})
	mux.HandleFunc("/repos/alexec/agents/actions/runs", func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		w.Header().Set("X-RateLimit-Limit", "5000")
		if r.URL.Query().Get("status") != "completed" {
			t.Errorf("listed %s", r.URL.RawQuery)
		}
		if r.URL.Query().Get("page") != "1" {
			fmt.Fprint(w, `{"total_count":3,"workflow_runs":[]}`)
			return
		}
		if c := r.URL.Query().Get("created"); c != "" {
			// The backfill's windows: nothing older.
			fmt.Fprint(w, `{"total_count":0,"workflow_runs":[]}`)
			return
		}
		fmt.Fprintf(w, `{"total_count":3,"workflow_runs":[
		 {"id":11,"run_attempt":2,"created_at":%q,"run_started_at":%q,"updated_at":%q,"status":"completed","conclusion":"success","head_branch":"main","head_sha":"aaa","event":"push","path":".github/workflows/ci.yml","html_url":"https://github.com/alexec/agents/actions/runs/11"},
		 {"id":12,"run_attempt":1,"created_at":%q,"updated_at":%q,"status":"completed","conclusion":"success","head_branch":"feature","head_sha":"bbb","event":"pull_request","path":".github/workflows/ci.yml","pull_requests":[{"number":7}]},
		 {"id":13,"run_attempt":1,"created_at":%q,"updated_at":%q,"status":"completed","conclusion":"success","head_branch":"feature","head_sha":"ccc","event":"pull_request","path":".github/workflows/ci.yml"}]}`,
			at(-2*time.Hour), at(-time.Hour), at(-50*time.Minute), at(-30*time.Minute), at(-20*time.Minute),
			at(-20*24*time.Hour), at(-20*24*time.Hour))
	})
	jobs := func(made time.Duration, attempts ...int) string {
		var out []string
		for _, n := range attempts {
			base := made + time.Duration(n-1)*time.Hour
			conclusion := "success"
			if n < len(attempts) {
				conclusion = "failure"
			}
			out = append(out, fmt.Sprintf(`{"run_attempt":%d,"name":"go","created_at":%q,"started_at":%q,"completed_at":%q,"conclusion":%q,"labels":["ubuntu-latest"],
			 "steps":[{"name":"Test","number":1,"started_at":%q,"completed_at":%q,"conclusion":"success"}]}`,
				n, at(base+10*time.Second), at(base+20*time.Second), at(base+5*time.Minute), conclusion, at(base+21*time.Second), at(base+5*time.Minute)))
		}
		return `{"total_count":` + fmt.Sprint(len(out)) + `,"jobs":[` + strings.Join(out, ",") + `]}`
	}
	mux.HandleFunc("/repos/alexec/agents/actions/runs/11/jobs", func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.URL.Query().Get("filter") != "all" {
			t.Errorf("jobs without filter=all: %s", r.URL.RawQuery)
		}
		fmt.Fprint(w, jobs(-2*time.Hour, 1, 2))
	})
	mux.HandleFunc("/repos/alexec/agents/actions/runs/12/jobs", func(w http.ResponseWriter, _ *http.Request) {
		calls.Add(1)
		fmt.Fprint(w, jobs(-30*time.Minute, 1))
	})
	mux.HandleFunc("/repos/alexec/agents/actions/runs/13/jobs", func(w http.ResponseWriter, _ *http.Request) {
		t.Error("a PR run past the steps bound was read")
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv, &calls
}

func TestCITimingsReadAndAnswer(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	srv, calls := ciFakeGitHub(t, now)
	d, err := New(context.Background(), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	d.ciAPI = srv.URL
	h := ciRepoHere{forgeRepo{"github", "alexec/agents"}, t.TempDir()}
	if err := d.readCIRepo(context.Background(), h); err != nil {
		t.Fatal(err)
	}
	read := calls.Load()
	// A second read asks for the list again, and for no jobs it has.
	if err := d.readCIRepo(context.Background(), h); err != nil {
		t.Fatal(err)
	}
	if again := calls.Load() - read; again != 1 {
		t.Fatalf("the second read made %d calls, want 1 (the list)", again)
	}

	hist, err := d.buildsHistory(wire.BuildsHistoryRequest{Repo: "github:alexec/agents",
		From: wire.DateOf(now.Add(-24 * time.Hour)), To: wire.DateOf(now.Add(time.Hour))})
	if err != nil {
		t.Fatal(err)
	}
	if hist.Reader != "github" || hist.DefaultBranch == nil || *hist.DefaultBranch != "main" || hist.ReadAt == nil {
		t.Fatalf("history %+v", hist)
	}
	// Main's first attempt (failed) counts; its second is a re-run, out of the times.
	if hist.Total.Runs != 1 || hist.Total.Reruns != 1 || hist.Total.Green != 0 {
		t.Fatalf("total %+v", hist.Total)
	}
	if len(hist.Workflows) != 1 || hist.Workflows[0] != "ci.yml" || len(hist.Jobs) != 1 {
		t.Fatalf("names %+v %+v", hist.Workflows, hist.Jobs)
	}
	prs, err := d.buildsHistory(wire.BuildsHistoryRequest{Repo: "github:alexec/agents", PullRequests: new(true),
		From: wire.DateOf(now.Add(-24 * time.Hour)), To: wire.DateOf(now.Add(time.Hour))})
	if err != nil || prs.Total.Green != 1 || prs.Total.Run.Median != 280 || prs.Total.Runner.Median != 10 {
		t.Fatalf("PRs %+v %v", prs.Total, err)
	}

	got, err := d.buildsRun(wire.BuildsRunRequest{Repo: "github:alexec/agents", Ref: "github:run:alexec/agents#12"})
	if err != nil {
		t.Fatal(err)
	}
	if got.Run.ID != 12 || len(got.Run.Jobs) != 1 || len(got.Run.Jobs[0].Steps) != 1 || got.Run.Pr == nil || *got.Run.Pr != 7 {
		t.Fatalf("run %+v", got.Run)
	}
	if got.Before != nil {
		t.Fatalf("no passed run before it: %+v", got.Before)
	}
	second, err := d.buildsRun(wire.BuildsRunRequest{Repo: "github:alexec/agents", Ref: "github:run:alexec/agents#11", Attempt: new(int64(2))})
	if err != nil || second.Attempts != 2 || second.Run.Attempt != 2 {
		t.Fatalf("attempt 2: %+v %v", second, err)
	}

	other, err := d.buildsHistory(wire.BuildsHistoryRequest{Repo: "gitlab:group/project",
		From: wire.DateOf(now.Add(-time.Hour)), To: wire.DateOf(now)})
	if err != nil || other.Reader != "none" {
		t.Fatalf("a forge with no reader: %+v %v", other, err)
	}
	if _, err := d.buildsHistory(wire.BuildsHistoryRequest{Repo: "github:../etc", From: wire.DateOf(now.Add(-time.Hour)), To: wire.DateOf(now)}); err == nil {
		t.Fatal("a repo outside the store was read")
	}
}

func TestCITimingsBackfillKeepsToItsBudget(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	srv, _ := ciFakeGitHub(t, now)
	d, err := New(context.Background(), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	d.ciAPI = srv.URL
	h := ciRepoHere{forgeRepo{"github", "alexec/agents"}, t.TempDir()}
	if err := d.readCIRepo(context.Background(), h); err != nil {
		t.Fatal(err)
	}
	d.ciMu.Lock()
	st := *d.ciFileLocked().Repos["github:alexec/agents"]
	calls := d.ciFileLocked().Calls
	d.ciMu.Unlock()
	// 5,000 an hour: the backfill stops at 500 calls, 3 days a window of 2 calls.
	if calls > ciDefaultLimit/ciBackfillShare+5 {
		t.Fatalf("%d calls this hour", calls)
	}
	if !st.Filled || st.FilledFrom == nil || now.Sub(*st.FilledFrom) < 89*24*time.Hour {
		t.Fatalf("backfill %+v", st)
	}
}
