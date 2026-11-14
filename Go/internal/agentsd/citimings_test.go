package agentsd

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/agentloops-dev/agents/Go/internal/citimings"
	"github.com/agentloops-dev/agents/Go/wire"
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
	defer d.Shutdown()
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

	other, err := d.buildsHistory(wire.BuildsHistoryRequest{Repo: "bitbucket:group/project",
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
	defer d.Shutdown()
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

// A fake GitLab with two finished pipelines: one on main with a retried job, one merge request's.
func TestCITimingsGitLab(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	at := func(d time.Duration) string { return now.Add(d).UTC().Format(time.RFC3339) }
	mux := http.NewServeMux()
	mux.HandleFunc("/api/v4/projects/group/project", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprint(w, `{"default_branch":"main"}`)
	})
	mux.HandleFunc("/api/v4/projects/group/project/pipelines", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("scope") != "finished" {
			t.Errorf("listed %s", r.URL.RawQuery)
		}
		if r.URL.Query().Get("page") != "1" || r.URL.Query().Get("created_after") != "" {
			fmt.Fprint(w, `[]`)
			return
		}
		fmt.Fprintf(w, `[{"id":21,"iid":5,"status":"success","source":"push","ref":"main","sha":"aaa","web_url":"https://gitlab.com/group/project/-/pipelines/21","created_at":%q,"updated_at":%q},
		 {"id":22,"iid":6,"status":"failed","source":"merge_request_event","ref":"refs/merge-requests/9/head","sha":"bbb","created_at":%q,"updated_at":%q}]`,
			at(-2*time.Hour), at(-time.Hour), at(-30*time.Minute), at(-20*time.Minute))
	})
	mux.HandleFunc("/api/v4/projects/group/project/pipelines/21/jobs", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("include_retried") != "true" {
			t.Errorf("jobs without include_retried: %s", r.URL.RawQuery)
		}
		base := -2 * time.Hour
		fmt.Fprintf(w, `[{"id":1,"name":"build","status":"success","created_at":%q,"started_at":%q,"finished_at":%q,"queued_duration":5.0,"runner":{"description":"shared-1"}},
		 {"id":2,"name":"test","status":"failed","created_at":%q,"started_at":%q,"finished_at":%q,"queued_duration":20.0,"runner":{"description":"shared-1"}},
		 {"id":3,"name":"test","status":"success","created_at":%q,"started_at":%q,"finished_at":%q,"queued_duration":10.0,"runner":{"description":"shared-1"}}]`,
			at(base), at(base+10*time.Second), at(base+time.Minute),
			at(base), at(base+90*time.Second), at(base+3*time.Minute),
			at(base), at(base+5*time.Minute), at(base+7*time.Minute))
	})
	mux.HandleFunc("/api/v4/projects/group/project/pipelines/22/jobs", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprintf(w, `[{"id":4,"name":"test","status":"failed","created_at":%q,"started_at":%q,"finished_at":%q,"queued_duration":3.0}]`,
			at(-30*time.Minute), at(-30*time.Minute+10*time.Second), at(-25*time.Minute))
	})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.URL.RawPath = "" // the project's / arrives as %2F
		mux.ServeHTTP(w, r)
	}))
	t.Cleanup(srv.Close)

	d, err := New(context.Background(), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	d.ciGitLabAPI = srv.URL
	h := ciRepoHere{forgeRepo{"gitlab", "group/project"}, t.TempDir()}
	if err := d.readCIRepo(context.Background(), h); err != nil {
		t.Fatal(err)
	}
	hist, err := d.buildsHistory(wire.BuildsHistoryRequest{Repo: "gitlab:group/project",
		From: wire.DateOf(now.Add(-24 * time.Hour)), To: wire.DateOf(now.Add(time.Hour))})
	if err != nil {
		t.Fatal(err)
	}
	if hist.Reader != "gitlab" || hist.DefaultBranch == nil || *hist.DefaultBranch != "main" || hist.ReadAt == nil {
		t.Fatalf("history %+v", hist)
	}
	// Main's first attempt failed its test job, the second is a re-run.
	if hist.Total.Runs != 1 || hist.Total.Reruns != 1 || hist.Total.Green != 0 {
		t.Fatalf("total %+v", hist.Total)
	}
	got, err := d.buildsRun(wire.BuildsRunRequest{Repo: "gitlab:group/project", Ref: "gitlab:run:group/project#21", Attempt: new(int64(2))})
	if err != nil {
		t.Fatal(err)
	}
	if got.Attempts != 2 || got.Run.Conclusion == nil || *got.Run.Conclusion != "success" || len(got.Run.Jobs) != 1 || len(got.Run.Jobs[0].Steps) != 0 {
		t.Fatalf("attempt 2 %+v", got)
	}
	first, err := d.buildsRun(wire.BuildsRunRequest{Repo: "gitlab:group/project", Ref: "gitlab:run:group/project#21"})
	if err != nil || len(first.Run.Jobs) != 2 || first.Run.Jobs[1].Runner == nil || *first.Run.Jobs[1].Runner != "shared-1" {
		t.Fatalf("attempt 1 %+v %v", first, err)
	}
	// The job's wait for a runner is its queued_duration: made 20 s before it started.
	if w := first.Run.Jobs[1]; w.Started-w.Made != 20 || w.Made != 70 {
		t.Fatalf("test job made %v started %v", w.Made, w.Started)
	}
	mr, err := d.buildsRun(wire.BuildsRunRequest{Repo: "gitlab:group/project", Ref: "gitlab:run:group/project#22"})
	if err != nil || mr.Run.Pr == nil || *mr.Run.Pr != 9 || (mr.Run.Default != nil && *mr.Run.Default) {
		t.Fatalf("merge request pipeline %+v %v", mr.Run, err)
	}
}

// #5232: the machine sends its days of runs to the control plane: first all of them with reset,
// then only a day that changed; a control plane with no copy is sent all again, and what is
// unsent outlives the daemon.
func TestCITimingsSyncSendsWhatChanged(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	srv, _ := ciFakeGitHub(t, now)
	root := t.TempDir()
	d, err := New(context.Background(), root)
	if err != nil {
		t.Fatal(err)
	}
	// Shut down before the second daemon reads the same root; Shutdown saves what is unsent.
	var once sync.Once
	stop := func() { once.Do(d.Shutdown) }
	defer stop()
	d.ciAPI = srv.URL
	h := ciRepoHere{forgeRepo{"github", "alexec/agents"}, t.TempDir()}
	if err := d.readCIRepo(context.Background(), h); err != nil {
		t.Fatal(err)
	}
	var mu sync.Mutex
	var sent []wire.BuildsSync
	full := false
	d.SetControlCapabilities(func() []string { return []string{wire.CapBuildsCopy1} })
	d.SetControlAsk(askControl(func(_ context.Context, method string, params any) (json.RawMessage, error) {
		if method != wire.CallBuildsSync.Name {
			return json.RawMessage(`{}`), nil
		}
		mu.Lock()
		defer mu.Unlock()
		sent = append(sent, params.(wire.BuildsSync))
		if full {
			full = false
			return json.RawMessage(`{"full":true}`), nil
		}
		return json.RawMessage(`{}`), nil
	}))
	took := func() []wire.BuildsSync {
		t.Helper()
		d.sendCITimings()
		mu.Lock()
		defer mu.Unlock()
		out := sent
		sent = nil
		return out
	}
	repo := citimings.Repo{Forge: "github", Path: "alexec/agents"}
	days, err := d.ciTimings().DayList(repo)
	if err != nil || len(days) == 0 {
		t.Fatalf("days %v %v", days, err)
	}
	first := took()
	if len(first) != 1 || first[0].Reset == nil || first[0].Repo != "github:alexec/agents" || len(first[0].Days) != len(days) ||
		first[0].DefaultBranch == nil || *first[0].DefaultBranch != "main" || first[0].ReadAt == nil {
		t.Fatalf("first %+v", first)
	}
	runs := 0
	for _, day := range first[0].Days {
		runs += len(day.Runs)
	}
	if runs == 0 {
		t.Fatal("no runs sent")
	}
	if again := took(); len(again) != 0 {
		t.Fatalf("sent again: %+v", again)
	}

	d.noteCIDays(repo, days[0])
	changed := took()
	if len(changed) != 1 || changed[0].Reset != nil || len(changed[0].Days) != 1 || changed[0].Days[0].Day != days[0] {
		t.Fatalf("changed %+v", changed)
	}

	// A control plane with no copy: the next send is every day again, with reset.
	full = true
	d.noteCIDays(repo, days[0])
	again := took()
	if len(again) != 2 || again[0].Reset != nil || again[1].Reset == nil || len(again[1].Days) != len(days) {
		t.Fatalf("after full %+v", again)
	}

	// What is unsent is kept: a new daemon on the same root sends it.
	d.noteCIDays(repo, days[0])
	stop()
	d2, err := New(context.Background(), root)
	if err != nil {
		t.Fatal(err)
	}
	defer d2.Shutdown()
	d2.SetControlCapabilities(func() []string { return []string{wire.CapBuildsCopy1} })
	d2.SetControlAsk(askControl(func(_ context.Context, _ string, params any) (json.RawMessage, error) {
		mu.Lock()
		defer mu.Unlock()
		sent = append(sent, params.(wire.BuildsSync))
		return json.RawMessage(`{}`), nil
	}))
	d2.sendCITimings()
	mu.Lock()
	defer mu.Unlock()
	if len(sent) != 1 || len(sent[0].Days) != 1 || sent[0].Days[0].Day != days[0] {
		t.Fatalf("after a restart %+v", sent)
	}
}
