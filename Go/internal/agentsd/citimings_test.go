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

	"github.com/agentloops-dev/agent-loops/Go/internal/citimings"
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

	other, err := d.buildsHistory(wire.BuildsHistoryRequest{Repo: "circleci:group/project",
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
	defer d.Shutdown()
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

// A fake Bitbucket with three completed pipelines: one on main run again by "Rerun failed
// steps" (run 2), one for a pull request with its steps on two pages, and one on main older
// than the store keeps.
func TestCITimingsBitbucket(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	at := func(d time.Duration) string { return now.Add(d).UTC().Format(time.RFC3339) }
	var srv *httptest.Server
	repo := "/2.0/repositories/team/app"
	mux := http.NewServeMux()
	mux.HandleFunc(repo, func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer test" {
			t.Errorf("auth %q", r.Header.Get("Authorization"))
		}
		fmt.Fprint(w, `{"mainbranch":{"name":"main"}}`)
	})
	var lists atomic.Int32
	mux.HandleFunc(repo+"/pipelines/", func(w http.ResponseWriter, r *http.Request) {
		lists.Add(1)
		q := r.URL.Query()
		if q.Get("status") != "COMPLETED" || q.Get("sort") != "-created_on" {
			t.Errorf("listed %s", r.URL.RawQuery)
		}
		if q.Get("page") != "1" {
			fmt.Fprint(w, `{"values":[]}`)
			return
		}
		fmt.Fprintf(w, `{"values":[
		 {"uuid":"{a}","build_number":41,"run_number":2,"created_on":%q,"completed_on":%q,"state":{"name":"COMPLETED","result":{"name":"SUCCESSFUL"}},
		  "target":{"type":"pipeline_ref_target","ref_type":"branch","ref_name":"main","commit":{"hash":"aaa"},"selector":{"type":"branches","pattern":"main"}},"trigger":{"name":"PUSH"}},
		 {"uuid":"{b}","build_number":42,"created_on":%q,"completed_on":%q,"state":{"name":"COMPLETED","result":{"name":"FAILED"}},
		  "target":{"type":"pipeline_pullrequest_target","source":"feature","destination":"main","commit":{"hash":"bbb"},"selector":{"type":"pull-requests","pattern":"**"},"pullrequest":{"id":9}},"trigger":{"name":"PUSH"}},
		 {"uuid":"{c}","build_number":7,"created_on":%q,"completed_on":%q,"state":{"name":"COMPLETED","result":{"name":"SUCCESSFUL"}},
		  "target":{"type":"pipeline_ref_target","ref_type":"branch","ref_name":"main","selector":{"type":"default"}},"trigger":{"name":"PUSH"}}]}`,
			at(-2*time.Hour), at(-time.Hour), at(-30*time.Minute), at(-20*time.Minute), at(-100*24*time.Hour), at(-100*24*time.Hour))
	})
	mux.HandleFunc(repo+"/pipelines/41/steps/", func(w http.ResponseWriter, _ *http.Request) {
		base := -2 * time.Hour
		fmt.Fprintf(w, `{"values":[
		 {"name":"Build","run_number":1,"started_on":%q,"completed_on":%q,"state":{"name":"COMPLETED","result":{"name":"SUCCESSFUL"}}},
		 {"name":"Test","run_number":1,"started_on":%q,"completed_on":%q,"state":{"name":"COMPLETED","result":{"name":"FAILED"}}},
		 {"name":"Test","run_number":2,"started_on":%q,"completed_on":%q,"state":{"name":"COMPLETED","result":{"name":"SUCCESSFUL"}},"runs_on":["self.hosted","linux"]}]}`,
			at(base+30*time.Second), at(base+2*time.Minute), at(base+2*time.Minute), at(base+5*time.Minute), at(base+40*time.Minute), at(base+45*time.Minute))
	})
	mux.HandleFunc(repo+"/pipelines/42/steps/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("page") == "2" {
			fmt.Fprintf(w, `{"values":[{"name":"Deploy","state":{"name":"COMPLETED","result":{"name":"NOT_RUN"}},"completed_on":%q}]}`, at(-20*time.Minute))
			return
		}
		fmt.Fprintf(w, `{"values":[{"name":"Test","started_on":%q,"completed_on":%q,"state":{"name":"COMPLETED","result":{"name":"FAILED"}}}],"next":%q}`,
			at(-29*time.Minute), at(-21*time.Minute), srv.URL+repo+"/pipelines/42/steps/?pagelen=100&page=2")
	})
	mux.HandleFunc(repo+"/pipelines/7/steps/", func(w http.ResponseWriter, _ *http.Request) {
		t.Error("read the steps of a pipeline older than the store keeps")
	})
	srv = httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	d, err := New(context.Background(), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	// A daemon left running scans on its clock into a later test's AGENTS_PERSONAL_HOME (#5368).
	t.Cleanup(d.Shutdown)
	d.ciBitbucketAPI = srv.URL + "/2.0/"
	h := ciRepoHere{forgeRepo{"bitbucket", "team/app"}, t.TempDir()}
	if err := d.readCIRepo(context.Background(), h); err != nil {
		t.Fatal(err)
	}
	hist, err := d.buildsHistory(wire.BuildsHistoryRequest{Repo: "bitbucket:team/app",
		From: wire.DateOf(now.Add(-24 * time.Hour)), To: wire.DateOf(now.Add(time.Hour))})
	if err != nil {
		t.Fatal(err)
	}
	if hist.Reader != "bitbucket" || hist.DefaultBranch == nil || *hist.DefaultBranch != "main" || hist.ReadAt == nil {
		t.Fatalf("history %+v", hist)
	}
	// Main's first run failed its Test step; the second is a rerun of it.
	if hist.Total.Runs != 1 || hist.Total.Reruns != 1 || hist.Total.Green != 0 {
		t.Fatalf("total %+v", hist.Total)
	}
	main, err := d.buildsRun(wire.BuildsRunRequest{Repo: "bitbucket:team/app", Ref: "bitbucket:run:team/app#41", Attempt: new(int64(2))})
	if err != nil {
		t.Fatal(err)
	}
	// Run 2 is its rerun steps only; its runner is the first runs-on label.
	if main.Attempts != 2 || *main.Run.Conclusion != "success" {
		t.Fatalf("pipeline 41's attempts %+v", main)
	}
	if r := main.Run; r.Default == nil || !*r.Default || len(r.Jobs) != 1 || r.Jobs[0].Name != "Test" || r.Jobs[0].Runner == nil ||
		*r.Jobs[0].Runner != "self.hosted" || r.Started != 2400 || r.Ended != 3600 || r.URL == nil ||
		*r.URL != "https://bitbucket.org/team/app/pipelines/results/41" || r.Workflow != "main" {
		t.Fatalf("pipeline 41 %+v", r)
	}
	first, err := d.buildsRun(wire.BuildsRunRequest{Repo: "bitbucket:team/app", Ref: "bitbucket:run:team/app#41"})
	if err != nil || len(first.Run.Jobs) != 2 || *first.Run.Conclusion != "failure" || first.Run.Started != 30 || first.Run.Ended != 300 {
		t.Fatalf("pipeline 41, run 1 %+v %v", first.Run, err)
	}
	pr, err := d.buildsRun(wire.BuildsRunRequest{Repo: "bitbucket:team/app", Ref: "bitbucket:run:team/app#42"})
	if err != nil {
		t.Fatal(err)
	}
	if r := pr.Run; r.Pr == nil || *r.Pr != 9 || r.Default != nil || len(r.Jobs) != 2 || *r.Conclusion != "failure" ||
		*r.Jobs[1].Conclusion != "skipped" || r.Jobs[0].Made != 60 || r.Jobs[0].Ended != 540 {
		t.Fatalf("pipeline 42 %+v", r)
	}
	d.ciMu.Lock()
	st := *d.ciFileLocked().Repos["bitbucket:team/app"]
	calls := d.ciFileLocked().BitbucketCalls
	d.ciMu.Unlock()
	if !st.Filled || st.FilledFrom == nil || st.BackfillPage != 1 {
		t.Fatalf("backfill %+v", st)
	}
	// The repository, the list twice (live, backfill), and 41's one and 42's two pages of steps.
	if calls != 6 {
		t.Fatalf("%d Bitbucket calls", calls)
	}

	// A second read keeps what it has: no steps again.
	if err := d.readCIRepo(context.Background(), h); err != nil {
		t.Fatal(err)
	}
	d.ciMu.Lock()
	again := d.ciFileLocked().BitbucketCalls
	d.ciMu.Unlock()
	if again != calls+1 {
		t.Fatalf("%d Bitbucket calls after a second read", again)
	}
}

// A fake Forgejo 17 with three runs: one on main whose test job was run again (its jobs list
// has no steps, so each job is read), one for a pull request in Gitea's shape, and one still
// running.
func TestCITimingsForgejo(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	at := func(d time.Duration) string { return now.Add(d).UTC().Format(time.RFC3339) }
	repo := "/api/v1/repos/scratch/app"
	var jobLists atomic.Int32
	mux := http.NewServeMux()
	mux.HandleFunc(repo, func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprint(w, `{"default_branch":"main"}`)
	})
	mux.HandleFunc(repo+"/actions/runs", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("page") != "1" {
			fmt.Fprint(w, `{"total_count":3,"workflow_runs":[]}`)
			return
		}
		fmt.Fprintf(w, `{"total_count":3,"workflow_runs":[
		 {"id":903,"index_in_repo":7,"workflow_id":"ci.yml","event":"push","prettyref":"main","status":"running","created":%q,"started":%q},
		 {"id":901,"run_number":6,"run_attempt":1,"path":".gitea/workflows/ci.yml@refs/pull/9/head","event":"pull_request","head_branch":"feature","head_sha":"bbb",
		  "status":"completed","conclusion":"failure","pull_requests":[{"number":9}],"created_at":%q,"started_at":%q,"completed_at":%q},
		 {"id":900,"index_in_repo":5,"workflow_id":"ci.yml","event":"push","prettyref":"main","commit_sha":"aaa","status":"success",
		  "html_url":"https://codeberg.org/scratch/app/actions/runs/5","created":%q,"started":%q,"stopped":%q}]}`,
			at(-time.Minute), at(-time.Minute), at(-30*time.Minute), at(-29*time.Minute), at(-25*time.Minute),
			at(-2*time.Hour), at(-2*time.Hour+5*time.Second), at(-2*time.Hour+20*time.Minute))
	})
	mux.HandleFunc(repo+"/actions/runs/900/jobs", func(w http.ResponseWriter, _ *http.Request) {
		jobLists.Add(1)
		fmt.Fprint(w, `[{"id":1,"name":"build","attempt":1,"status":"success","runs_on":["docker"]},
		 {"id":2,"name":"test","attempt":2,"needs":["build"],"status":"success","runs_on":["docker"]}]`)
	})
	mux.HandleFunc(repo+"/actions/jobs/1", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprintf(w, `{"id":1,"name":"build","attempt":1,"status":"success","runs_on":["docker"],"steps":[
		 {"name":"Build","number":1,"status":"success","started":%q,"stopped":%q}]}`, at(-2*time.Hour+20*time.Second), at(-2*time.Hour+2*time.Minute))
	})
	mux.HandleFunc(repo+"/actions/jobs/2", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprintf(w, `{"id":2,"name":"test","attempt":2,"needs":["build"],"status":"success","runs_on":["docker"],"steps":[
		 {"name":"Test","number":1,"status":"success","started":%q,"stopped":%q}]}`, at(-2*time.Hour+15*time.Minute), at(-2*time.Hour+20*time.Minute))
	})
	mux.HandleFunc(repo+"/actions/runs/901/jobs", func(w http.ResponseWriter, _ *http.Request) {
		jobLists.Add(1)
		fmt.Fprintf(w, `{"total_count":1,"jobs":[{"id":3,"name":"test","run_attempt":1,"status":"completed","conclusion":"failure","labels":["ubuntu-latest"],
		 "created_at":%q,"started_at":%q,"completed_at":%q,"steps":[]}]}`, at(-30*time.Minute), at(-29*time.Minute), at(-25*time.Minute))
	})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "token test" {
			t.Errorf("auth %q", r.Header.Get("Authorization"))
		}
		mux.ServeHTTP(w, r)
	}))
	t.Cleanup(srv.Close)

	d, err := New(context.Background(), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	// A daemon left running scans on its clock into a later test's AGENTS_PERSONAL_HOME (#5368).
	t.Cleanup(d.Shutdown)
	d.ciForgejoAPI = srv.URL + "/"
	h := ciRepoHere{forgeRepo{"forgejo", "scratch/app"}, t.TempDir()}
	if err := d.readCIRepo(context.Background(), h); err != nil {
		t.Fatal(err)
	}
	if n := jobLists.Load(); n != 2 {
		t.Fatalf("jobs read %d times, want once a finished run", n)
	}
	// A second read finds nothing new: the runs it has are not read again.
	if err := d.readCIRepo(context.Background(), h); err != nil || jobLists.Load() != 2 {
		t.Fatalf("again: %v, jobs read %d times", err, jobLists.Load())
	}
	hist, err := d.buildsHistory(wire.BuildsHistoryRequest{Repo: "forgejo:scratch/app",
		From: wire.DateOf(now.Add(-24 * time.Hour)), To: wire.DateOf(now.Add(time.Hour))})
	if err != nil {
		t.Fatal(err)
	}
	if hist.Reader != "forgejo" || hist.DefaultBranch == nil || *hist.DefaultBranch != "main" || hist.ReadAt == nil {
		t.Fatalf("history %+v", hist)
	}
	// Main's run (the default filter), not green: its test job was run again.
	if hist.Total.Runs != 1 || hist.Total.Reruns != 1 || hist.Total.Green != 0 {
		t.Fatalf("total %+v", hist.Total)
	}
	last, err := d.buildsRun(wire.BuildsRunRequest{Repo: "forgejo:scratch/app", Ref: "forgejo:run:scratch/app#5", Attempt: new(int64(2))})
	if err != nil || len(last.Run.Jobs) != 2 || len(last.Run.Jobs[1].Steps) != 1 {
		t.Fatalf("attempt 2 %+v %v", last, err)
	}
	if j := last.Run.Jobs[1]; j.Made != 120 || j.Started != 900 || j.Ended != 1200 {
		t.Fatalf("test job %+v", j)
	}
	pr, err := d.buildsRun(wire.BuildsRunRequest{Repo: "forgejo:scratch/app", Ref: "forgejo:run:scratch/app#6"})
	if err != nil || pr.Run.Pr == nil || *pr.Run.Pr != 9 || (pr.Run.Default != nil && *pr.Run.Default) {
		t.Fatalf("pull request run %+v %v", pr.Run, err)
	}
}

// #5410: at connect the control plane has not said what it can do yet, so the first send finds
// no builds.copy/1 and sends nothing; once it says, the send goes then, not on the next hour.
func TestCITimingsSendWhenTheCapabilitiesAreKnown(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	srv, _ := ciFakeGitHub(t, now)
	d, err := New(context.Background(), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer d.Shutdown()
	d.ciAPI = srv.URL
	if err := d.readCIRepo(context.Background(), ciRepoHere{forgeRepo{"github", "alexec/agents"}, t.TempDir()}); err != nil {
		t.Fatal(err)
	}
	var caps atomic.Pointer[[]string]
	d.SetControlCapabilities(func() []string {
		if list := caps.Load(); list != nil {
			return *list
		}
		return nil
	})
	var sent atomic.Int32
	d.SetControlAsk(askControl(func(_ context.Context, method string, _ any) (json.RawMessage, error) {
		if method == wire.CallBuildsSync.Name {
			sent.Add(1)
		}
		return json.RawMessage(`{}`), nil
	}))
	// The link is up, the hello answer is not in.
	d.sendCITimings()
	if n := sent.Load(); n != 0 {
		t.Fatalf("sent %d before the capabilities were known", n)
	}
	caps.Store(&[]string{wire.CapBuildsCopy1})
	d.ControlCapabilitiesKnown()
	if n := sent.Load(); n != 1 {
		t.Fatalf("sent %d once the capabilities were known, want 1", n)
	}
}
