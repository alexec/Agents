package citimings

import (
	"math"
	"slices"
	"sort"
	"time"
)

// The figures (spec 5166, "The design point"; the terms in derive.py):
//
//   - Time to green: a run's made time to its last job's end, for a run that passed.
//   - Run: the time at least one of its jobs ran. Waiting its turn: the run's made time to its
//     first job's made time (ci.yml's concurrency group keeps one run on main going). Waiting
//     for a runner: the rest. Run + runner + turn = time to green.
//   - A job's run is its start to its end; its wait for a runner its made time to its start.
//   - Re-runs (attempt 2 or more) are out of the time figures and counted apart: the gap before
//     a re-run is a choice, not a queue (finding 3).

// Shape is one run attempt's time figures, in seconds.
type Shape struct {
	ToGreen, Run, Runner, Turn float64
}

// done is a job that ran: started, ended, and not skipped.
func (j Job) done() bool {
	return j.Conclusion != "skipped" && j.Ended > j.Started && j.Started >= 0
}

// RunTime is a job's start to its end; RunnerWait its made time to its start.
func (j Job) RunTime() float64    { return j.Ended - j.Started }
func (j Job) RunnerWait() float64 { return math.Max(0, j.Started-j.Made) }

// Shape is the run's time figures; not ok when no job ran.
func (r Run) Shape() (Shape, bool) {
	type span struct{ a, b float64 }
	var spans []span
	firstMade, end := math.Inf(1), 0.0
	for _, j := range r.Jobs {
		if !j.done() {
			continue
		}
		spans = append(spans, span{j.Started, j.Ended})
		firstMade, end = math.Min(firstMade, j.Made), math.Max(end, j.Ended)
	}
	if len(spans) == 0 {
		return Shape{}, false
	}
	sort.Slice(spans, func(a, b int) bool { return spans[a].a < spans[b].a })
	running, reach := 0.0, math.Inf(-1)
	for _, s := range spans {
		switch {
		case s.a > reach:
			running += s.b - s.a
			reach = s.b
		case s.b > reach:
			running += s.b - reach
			reach = s.b
		}
	}
	queue := math.Max(0, end-running)
	turn := math.Min(math.Max(0, firstMade), queue)
	return Shape{ToGreen: end, Run: running, Runner: queue - turn, Turn: turn}, true
}

// Turn is the run's wait for its turn: its made time to its first job's made time.
func (r Run) Turn() float64 {
	s, _ := r.Shape()
	return s.Turn
}

// Job is the run's job of that name, the last of them when it has several.
func (r Run) Job(name string) (Job, bool) {
	for i := len(r.Jobs) - 1; i >= 0; i-- {
		if r.Jobs[i].Name == name {
			return r.Jobs[i], true
		}
	}
	return Job{}, false
}

// Filter picks runs: a workflow (its file name), a job, and the default branch (Branch and
// PullRequests unset), the pull requests' runs, or one branch.
type Filter struct {
	Workflow, Job, Branch string
	PullRequests          bool
}

// Match says whether r is one of f's runs, its job aside.
func (f Filter) Match(r Run) bool {
	if f.Workflow != "" && r.Workflow != f.Workflow {
		return false
	}
	switch {
	case f.Branch != "":
		return r.Branch == f.Branch
	case f.PullRequests:
		return r.pullRequest()
	}
	return r.Default
}

// shapeOf is r's time figures under f: the whole run's, or its job's when f names one. Not ok
// when r did not pass (or its job did not), or did not run it.
func (f Filter) shapeOf(r Run) (Shape, bool) {
	whole, ok := r.Shape()
	if !ok || r.Conclusion != "success" {
		return Shape{}, false
	}
	if f.Job == "" {
		return whole, true
	}
	j, ok := r.Job(f.Job)
	if !ok || !j.done() || j.Conclusion != "success" {
		return Shape{}, false
	}
	return Shape{ToGreen: j.Ended, Run: j.RunTime(), Runner: j.RunnerWait(), Turn: whole.Turn}, true
}

// Stat is a median and a 90th percentile of N values, in seconds.
type Stat struct {
	Median, P90 float64
	N           int
}

// StatOf is the median and P90 of v, interpolated as derive.py's pct does.
func StatOf(v []float64) Stat {
	if len(v) == 0 {
		return Stat{}
	}
	s := slices.Clone(v)
	slices.Sort(s)
	return Stat{Median: percentile(s, 0.5), P90: percentile(s, 0.9), N: len(s)}
}

func percentile(sorted []float64, p float64) float64 {
	k := float64(len(sorted)-1) * p
	lo, hi := math.Floor(k), math.Ceil(k)
	return sorted[int(lo)] + (sorted[int(hi)]-sorted[int(lo)])*(k-lo)
}

// Figures are a set of runs' counts and time figures.
type Figures struct {
	// Runs is the first attempts that match; Green those of them that passed; Reruns the later
	// attempts, counted apart.
	Runs, Green, Reruns        int
	ToGreen, Run, Runner, Turn Stat
}

// Day is one day's figures, the day in the trend's time zone.
type Day struct {
	Day string
	Figures
}

type values struct {
	runs, green, reruns        int
	toGreen, run, runner, turn []float64
}

func (v *values) add(f Filter, r Run) {
	if f.Job != "" {
		if _, ok := r.Job(f.Job); !ok {
			return
		}
	}
	if r.Attempt > 1 {
		v.reruns++
		return
	}
	v.runs++
	s, ok := f.shapeOf(r)
	if !ok {
		return
	}
	v.green++
	v.toGreen, v.run = append(v.toGreen, s.ToGreen), append(v.run, s.Run)
	v.runner, v.turn = append(v.runner, s.Runner), append(v.turn, s.Turn)
}

func (v values) figures() Figures {
	return Figures{Runs: v.runs, Green: v.green, Reruns: v.reruns, ToGreen: StatOf(v.toGreen), Run: StatOf(v.run),
		Runner: StatOf(v.runner), Turn: StatOf(v.turn)}
}

// Trend is f's runs' figures, in all and by day in loc, oldest day first.
func Trend(runs []Run, f Filter, loc *time.Location) (Figures, []Day) {
	var all values
	byDay := map[string]*values{}
	var days []string
	for _, r := range runs {
		if !f.Match(r) {
			continue
		}
		all.add(f, r)
		d := r.MadeAt().In(loc).Format(time.DateOnly)
		if byDay[d] == nil {
			byDay[d] = &values{}
			days = append(days, d)
		}
		byDay[d].add(f, r)
	}
	sort.Strings(days)
	out := make([]Day, 0, len(days))
	for _, d := range days {
		if fig := byDay[d].figures(); fig.Runs+fig.Reruns > 0 {
			out = append(out, Day{Day: d, Figures: fig})
		}
	}
	return all.figures(), out
}

// Names is the workflows, jobs and branches of runs, each sorted: what the filters offer.
func Names(runs []Run) (workflows, jobs, branches []string) {
	seen := map[string]bool{}
	add := func(list *[]string, kind, name string) {
		if name != "" && !seen[kind+name] {
			seen[kind+name] = true
			*list = append(*list, name)
		}
	}
	for _, r := range runs {
		add(&workflows, "w", r.Workflow)
		add(&branches, "b", r.Branch)
		for _, j := range r.Jobs {
			add(&jobs, "j", j.Name)
		}
	}
	slices.Sort(workflows)
	slices.Sort(jobs)
	slices.Sort(branches)
	return workflows, jobs, branches
}

// RunnerWait is the longest wait for a runner of one job in a run that passed.
type RunnerWait struct {
	Run       Run
	Job       string
	Wait, Ran float64
}

// LongestRunnerWait is the job of f's runs that waited longest for a runner (board 3, note 4);
// not ok when none ran.
func LongestRunnerWait(runs []Run, f Filter) (RunnerWait, bool) {
	var best RunnerWait
	found := false
	for _, r := range runs {
		if !f.Match(r) || r.Attempt > 1 || r.Conclusion != "success" {
			continue
		}
		for _, j := range r.Jobs {
			if j.done() && (f.Job == "" || j.Name == f.Job) && (!found || j.RunnerWait() > best.Wait) {
				best, found = RunnerWait{Run: r, Job: j.Name, Wait: j.RunnerWait(), Ran: j.RunTime()}, true
			}
		}
	}
	return best, found
}

// Before is the run to compare r with (board 3): the newest first attempt of the same workflow
// made before r on r's branch that passed, or on the default branch when its branch has none.
func Before(runs []Run, r Run) (Run, bool) {
	var onBranch, onDefault *Run
	for i := range runs {
		k := &runs[i]
		if k.Workflow != r.Workflow || k.Attempt > 1 || k.Conclusion != "success" || k.Made >= r.Made || k.Ref == r.Ref {
			continue
		}
		if k.Branch == r.Branch && (onBranch == nil || k.Made > onBranch.Made) {
			onBranch = k
		}
		if k.Default && (onDefault == nil || k.Made > onDefault.Made) {
			onDefault = k
		}
	}
	switch {
	case onBranch != nil:
		return *onBranch, true
	case onDefault != nil:
		return *onDefault, true
	}
	return Run{}, false
}
