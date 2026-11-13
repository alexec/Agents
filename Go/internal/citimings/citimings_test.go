package citimings

import (
	"fmt"
	"math"
	"math/rand/v2"
	"os"
	"path/filepath"
	"testing"
	"time"
)

var repo = Repo{"github", "alexec/agents"}

// run is a first attempt made at, on the default branch or a PR, with one job per name, each
// made at 10 s, started at 10+wait and running ran seconds.
func run(id int64, at time.Time, onDefault bool, ran float64, jobs ...string) Run {
	r := Run{Ref: fmt.Sprintf("github:run:alexec/agents#%d", id), ID: id, Attempt: 1, Workflow: "ci.yml", Made: at.Unix(),
		Default: onDefault, Conclusion: "success", Branch: "main"}
	if !onDefault {
		r.Branch, r.PR = "feature", 7
	}
	for _, name := range jobs {
		r.Jobs = append(r.Jobs, Job{Name: name, Made: 10, Started: 15, Ended: 15 + ran, Conclusion: "success", Runner: "ubuntu-latest",
			Steps: []Step{{Name: "Test", Number: 1, Started: 15, Ended: 15 + ran, Conclusion: "success"}}})
	}
	return r
}

func TestPutReplacesTheSameAttemptAndKeepsOthers(t *testing.T) {
	s := &Store{Root: t.TempDir()}
	at := time.Date(2026, 11, 8, 12, 0, 0, 0, time.UTC)
	first := run(1, at, true, 60, "go")
	if err := s.Put(repo, first); err != nil {
		t.Fatal(err)
	}
	again := first
	again.Conclusion = "failure"
	second := first
	second.Attempt = 2
	if err := s.Put(repo, again, second, run(2, at.Add(time.Hour), true, 60, "go")); err != nil {
		t.Fatal(err)
	}
	runs, err := s.Runs(repo, at.Add(-time.Hour), at.Add(2*time.Hour))
	if err != nil || len(runs) != 3 {
		t.Fatalf("runs %d, %v", len(runs), err)
	}
	if runs[0].Conclusion != "failure" || runs[1].Attempt != 2 {
		t.Fatalf("not replaced in place: %+v", runs[:2])
	}
	found, _ := s.Find(repo, first.Ref)
	if len(found) != 2 || found[0].Attempt != 1 {
		t.Fatalf("find: %+v", found)
	}
	if !s.Has(repo, first.Ref, 2, at) || s.Has(repo, first.Ref, 3, at) {
		t.Fatal("has")
	}
	if _, err := os.Stat(filepath.Join(s.Root, "github", "alexec", "agents", "2026-11-08.jsonl")); err != nil {
		t.Fatal(err)
	}
	if got := s.Repos(); len(got) != 1 || got[0] != repo {
		t.Fatalf("repos %+v", got)
	}
}

func TestARepoOutsideTheStoreIsRefused(t *testing.T) {
	for _, bad := range []string{"github:../x", "github:", "github:a//b", "nope"} {
		if _, err := ParseRepo(bad); err == nil {
			t.Errorf("%q was taken", bad)
		}
	}
	if r, err := ParseRepo("GitHub:Alexec/Agents"); err != nil || r != repo {
		t.Fatalf("%+v %v", r, err)
	}
}

func TestSweepKeepsTheBounds(t *testing.T) {
	s := &Store{Root: t.TempDir()}
	now := time.Date(2026, 11, 13, 12, 0, 0, 0, time.UTC)
	old := run(1, now.AddDate(0, 0, -KeepDays-2), true, 60, "go")
	pr20 := run(2, now.AddDate(0, 0, -20), false, 60, "go")
	main20 := run(3, now.AddDate(0, 0, -20).Add(time.Minute), true, 60, "go")
	pr2 := run(4, now.AddDate(0, 0, -2), false, 60, "go")
	if err := s.Put(repo, old, pr20, main20, pr2); err != nil {
		t.Fatal(err)
	}
	if err := s.Sweep(repo, now); err != nil {
		t.Fatal(err)
	}
	runs, _ := s.Runs(repo, now.AddDate(-1, 0, 0), now)
	if len(runs) != 3 {
		t.Fatalf("the run past %d days is kept: %d", KeepDays, len(runs))
	}
	if runs[0].hasSteps() || !runs[1].hasSteps() || !runs[2].hasSteps() {
		t.Fatalf("steps: a PR run's go at %d days, the default branch's stay: %v %v %v", StepDays,
			runs[0].hasSteps(), runs[1].hasSteps(), runs[2].hasSteps())
	}
	// Past the run bound, the oldest PR runs go first, then the oldest of any kind.
	mostRuns = 1
	defer func() { mostRuns = MostRuns }()
	if err := s.Sweep(repo, now); err != nil {
		t.Fatal(err)
	}
	runs, _ = s.Runs(repo, now.AddDate(-1, 0, 0), now)
	if len(runs) != 1 || runs[0].ID != 3 {
		t.Fatalf("kept %+v, want the default branch's run", runs)
	}
}

func TestShapeSplitsTheWait(t *testing.T) {
	// Made at 0; job a made at 50 (its turn), started at 60, ran to 160; b made 50, started
	// 100, ended 200. Running: 60..200 = 140; wall 200; queue 60 = 50 turn + 10 runner.
	r := Run{Ref: "x", Attempt: 1, Conclusion: "success", Jobs: []Job{
		{Name: "a", Made: 50, Started: 60, Ended: 160, Conclusion: "success"},
		{Name: "b", Made: 50, Started: 100, Ended: 200, Conclusion: "success"},
		{Name: "skipped", Made: 0, Started: 0, Ended: 0, Conclusion: "skipped"},
	}}
	s, ok := r.Shape()
	if !ok || s != (Shape{ToGreen: 200, Run: 140, Runner: 10, Turn: 50}) {
		t.Fatalf("%+v", s)
	}
}

func TestTrendLeavesReRunsOutOfTheTimes(t *testing.T) {
	at := time.Date(2026, 11, 8, 12, 0, 0, 0, time.UTC)
	rerun := run(1, at, true, 900, "go")
	rerun.Attempt = 2
	failed := run(3, at, true, 60, "go")
	failed.Conclusion = "failure"
	pr := run(4, at.Add(time.Hour), false, 60, "go")
	runs := []Run{run(1, at, true, 60, "go"), rerun, run(2, at.Add(25*time.Hour), true, 120, "go", "lint"), failed, pr}
	total, days := Trend(runs, Filter{}, time.UTC)
	if total.Runs != 3 || total.Green != 2 || total.Reruns != 1 || total.Run.Median != 90 || total.Run.N != 2 {
		t.Fatalf("total %+v", total)
	}
	if len(days) != 2 || days[0].Day != "2026-11-08" || days[1].Run.Median != 120 {
		t.Fatalf("days %+v", days)
	}
	lint, _ := Trend(runs, Filter{Job: "lint"}, time.UTC)
	if lint.Runs != 1 || lint.Run.Median != 120 || lint.Runner.Median != 5 {
		t.Fatalf("one job %+v", lint)
	}
	prs, _ := Trend(runs, Filter{PullRequests: true}, time.UTC)
	if prs.Runs != 1 {
		t.Fatalf("PRs %+v", prs)
	}
	if s := StatOf([]float64{1, 2, 3, 4, 5, 6, 7, 8, 9, 10}); s.Median != 5.5 || math.Abs(s.P90-9.1) > 1e-9 {
		t.Fatalf("stat %+v", s)
	}
	if b, ok := Before(runs, pr); !ok || b.ID != 1 {
		t.Fatalf("a PR with no run before on its branch compares with the default branch's: %+v", b)
	}
}

func TestChangesFindsAStepUpInOneJob(t *testing.T) {
	rng := rand.New(rand.NewPCG(1, 2))
	start := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	var runs []Run
	for i := range 200 {
		ran := 290.0
		if i >= 120 {
			ran = 380
		}
		ran *= 1 + (rng.Float64()-0.5)*0.1
		r := run(int64(i+1), start.Add(time.Duration(i)*time.Hour), true, ran, "go-darwin")
		// lint, steady, never changes; a PR's run never counts.
		r.Jobs = append(r.Jobs, Job{Name: "lint", Made: 10, Started: 12, Ended: 12 + 60*(1+(rng.Float64()-0.5)*0.1), Conclusion: "success"})
		runs = append(runs, r)
		if i == 119 {
			// A run on the default branch that did not start go-darwin, between the two.
			skip := run(1000, start.Add(time.Duration(i)*time.Hour+time.Minute), true, 60, "lint")
			runs = append(runs, skip)
		}
	}
	changes := Changes(runs)
	if len(changes) != 1 {
		t.Fatalf("changes %+v", changes)
	}
	c := changes[0]
	if c.Job != "go-darwin" || !c.Slower() || c.FirstSlow.ID != 121 || c.LastFast.ID != 120 || c.Score < ShownScore {
		t.Fatalf("change %+v", c)
	}
	if len(c.Between) != 2 || c.Between[0].Ran || !c.Between[1].Ran {
		t.Fatalf("between %+v", c.Between)
	}
	if len(c.Points) != 2*aroundRuns {
		t.Fatalf("points %d", len(c.Points))
	}
}

func TestASmallStepIsNotShown(t *testing.T) {
	start := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	var runs []Run
	for i := range 200 {
		// 40 s to 50 s: 25 %, but under 30 s.
		ran := 40.0
		if i >= 100 {
			ran = 50
		}
		runs = append(runs, run(int64(i+1), start.Add(time.Duration(i)*time.Hour), true, ran+float64(i%3), "select"))
	}
	if c := Changes(runs); len(c) != 0 {
		t.Fatalf("shown %+v", c)
	}
}

func TestFromGitHubKeepsEachAttempt(t *testing.T) {
	gr := GitHubRun{ID: 36315623551, RunAttempt: 2, CreatedAt: "2026-11-10T11:20:00Z", RunStartedAt: "2026-11-10T13:00:00Z",
		UpdatedAt: "2026-11-10T13:10:00Z", Conclusion: "success", HeadBranch: "main", HeadSHA: "abc", Event: "push",
		Path: ".github/workflows/ci.yml", HTMLURL: "https://github.com/alexec/agents/actions/runs/36315623551"}
	jobs := []byte(`{"total_count":2,"jobs":[
	 {"run_attempt":1,"name":"test","created_at":"2026-11-10T11:20:10Z","started_at":"2026-11-10T11:20:30Z","completed_at":"2026-11-10T11:24:00Z","conclusion":"failure","labels":["ubuntu-latest"],
	  "steps":[{"name":"Test","number":1,"started_at":"2026-11-10T11:20:31Z","completed_at":"2026-11-10T11:24:00Z","conclusion":"failure"},{"name":"Never","number":2,"started_at":null,"completed_at":null}]},
	 {"run_attempt":2,"name":"test","created_at":"2026-11-10T13:00:05Z","started_at":"2026-11-10T13:01:00Z","completed_at":"2026-11-10T13:05:00Z","conclusion":"success","labels":["ubuntu-latest"],"steps":[]}]}`)
	got, err := FromGitHub(gr, jobs, "github:run:alexec/agents#36315623551", true, false)
	if err != nil || len(got) != 2 {
		t.Fatalf("%+v %v", got, err)
	}
	first, second := got[0], got[1]
	if first.Attempt != 1 || first.Conclusion != "failure" || first.Workflow != "ci.yml" || first.Jobs[0].Made != 10 ||
		first.Jobs[0].Started != 30 || first.Jobs[0].Ended != 240 || len(first.Jobs[0].Steps) != 1 || first.Jobs[0].Runner != "ubuntu-latest" {
		t.Fatalf("first %+v", first)
	}
	if second.Attempt != 2 || second.Conclusion != "success" || second.Started != 6000 || second.Ended != 6300 || !second.Default {
		t.Fatalf("second %+v", second)
	}
}
