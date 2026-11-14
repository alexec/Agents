package citimings

import (
	"fmt"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// The wire's answers (builds/history, builds/run), made the same way from the machine's store
// (agentsd/citimings.go) and from the control plane's copy (controlplane/builds.go, #5232).

// HistoryAsk is a builds/history request, read: its repository, range, days and filter.
type HistoryAsk struct {
	Repo     Repo
	From, To time.Time
	Loc      *time.Location
	Filter   Filter
}

// ReadHistoryAsk reads r, or says why it cannot.
func ReadHistoryAsk(r wire.BuildsHistoryRequest) (HistoryAsk, error) {
	repo, err := ParseRepo(r.Repo)
	if err != nil {
		return HistoryAsk{}, err
	}
	from, to := r.From.Time(), r.To.Time()
	if !to.After(from) || to.Sub(from) > (KeepDays+1)*24*time.Hour {
		return HistoryAsk{}, fmt.Errorf("from must be before to, at most %d days", KeepDays)
	}
	loc := time.UTC
	if r.TimeZone != nil && *r.TimeZone != "" {
		if loc, err = time.LoadLocation(*r.TimeZone); err != nil {
			return HistoryAsk{}, fmt.Errorf("no time zone %q", *r.TimeZone)
		}
	}
	return HistoryAsk{Repo: repo, From: from, To: to, Loc: loc, Filter: Filter{Workflow: deref(r.Workflow), Job: deref(r.Job),
		Branch: deref(r.Branch), PullRequests: r.PullRequests != nil && *r.PullRequests}}, nil
}

// Reads says a machine reads CI timings from forge (GitHub #5177, GitLab #5221, Azure DevOps
// #5222), so the history of its repositories has a reader.
func Reads(forge string) bool {
	return forge == "github" || forge == "gitlab" || forge == "azuredevops"
}

// EmptyHistory is the answer for a repository with no runs: reader none, as for a forge
// Agents does not read CI timings from.
func EmptyHistory(repo Repo) wire.BuildsHistory {
	return wire.BuildsHistory{Repo: repo.String(), Reader: "none", Workflows: []string{}, Jobs: []string{},
		Branches: []string{}, Days: []wire.BuildsDay{}, Changes: []wire.BuildsChange{}, Total: FiguresToWire(Figures{})}
}

// History fills out with the figures of runs (those made in the range) and the change points
// in the range of changes (found over every run kept). mark, when not nil, adds to each change
// point what only its answerer knows.
func History(out wire.BuildsHistory, a HistoryAsk, runs []Run, changes []Change, mark func(Change, *wire.BuildsChange)) wire.BuildsHistory {
	out.Workflows, out.Jobs, out.Branches = Names(runs)
	for _, l := range []*[]string{&out.Workflows, &out.Jobs, &out.Branches} {
		if *l == nil {
			*l = []string{}
		}
	}
	total, days := Trend(runs, a.Filter, a.Loc)
	out.Total = FiguresToWire(total)
	out.Days = []wire.BuildsDay{}
	for _, day := range days {
		out.Days = append(out.Days, wire.BuildsDay{Day: day.Day, Figures: FiguresToWire(day.Figures)})
	}
	if w, ok := LongestRunnerWait(runs, a.Filter); ok {
		out.LongestRunnerWait = &wire.BuildsRunnerWait{Run: RunRefToWire(w.Run), Job: w.Job, Wait: w.Wait, Ran: w.Ran}
	}
	out.Changes = []wire.BuildsChange{}
	f := a.Filter
	for _, c := range changes {
		at := c.FirstSlow.MadeAt()
		if at.Before(a.From) || !at.Before(a.To) || f.Workflow != "" && c.Workflow != f.Workflow || f.Job != "" && c.Job != f.Job {
			continue
		}
		w := ChangeToWire(c)
		if mark != nil {
			mark(c, &w)
		}
		out.Changes = append(out.Changes, w)
	}
	return out
}

// RunAnswer is builds/run's answer: the attempt want of attempts (every attempt of one ref),
// with the run before it from near, the runs made in the StepDays before it. Not ok when
// attempts has no attempt want.
func RunAnswer(attempts []Run, want int, near func(Run) ([]Run, error)) (wire.BuildsRunAnswer, bool, error) {
	for _, run := range attempts {
		if run.Attempt != want {
			continue
		}
		out := wire.BuildsRunAnswer{Run: RunToWire(run), Attempts: int64(len(attempts))}
		runs, err := near(run)
		if err != nil {
			return out, true, err
		}
		if before, ok := Before(runs, run); ok {
			b := RunToWire(before)
			out.Before = &b
		}
		return out, true, nil
	}
	return wire.BuildsRunAnswer{}, false, nil
}

// NearFrom is where RunAnswer's near looks from: the run before is days old at most for a
// pull request, and StepDays covers it.
func NearFrom(r Run) (from, to time.Time) {
	return r.MadeAt().AddDate(0, 0, -StepDays), r.MadeAt().Add(time.Second)
}

func statToWire(s Stat) wire.BuildsStat {
	return wire.BuildsStat{Median: s.Median, P90: s.P90, N: int64(s.N)}
}

// FiguresToWire is f on the wire.
func FiguresToWire(f Figures) wire.BuildsFigures {
	return wire.BuildsFigures{Runs: int64(f.Runs), Green: int64(f.Green), Reruns: int64(f.Reruns),
		ToGreen: statToWire(f.ToGreen), Run: statToWire(f.Run), Runner: statToWire(f.Runner), Turn: statToWire(f.Turn)}
}

// RunRefToWire names r on the wire.
func RunRefToWire(r Run) wire.BuildsRunRef {
	out := wire.BuildsRunRef{Ref: r.Ref, ID: r.ID, Attempt: int64(r.Attempt), Made: wire.DateOf(r.MadeAt()),
		URL: optional(r.URL), HeadSha: optional(r.HeadSHA), Branch: optional(r.Branch), Conclusion: optional(r.Conclusion)}
	if r.PR > 0 {
		out.Pr = new(int64(r.PR))
	}
	return out
}

// ChangeToWire is c on the wire.
func ChangeToWire(c Change) wire.BuildsChange {
	out := wire.BuildsChange{Workflow: c.Workflow, Job: c.Job, Slower: c.Slower(), At: wire.DateOf(c.FirstSlow.MadeAt()),
		LastFast: RunRefToWire(c.LastFast), FirstSlow: RunRefToWire(c.FirstSlow), MedianBefore: c.MedianBefore,
		MedianAfter: c.MedianAfter, QueueBefore: c.QueueBefore, QueueAfter: c.QueueAfter, Score: c.Score,
		Runner: optional(c.Runner), Between: []wire.BuildsBetween{}, Points: []wire.BuildsPoint{}}
	for _, b := range c.Between {
		w := wire.BuildsBetween{Run: RunRefToWire(b.Run), Ran: b.Ran}
		if b.Ran {
			w.JobRun = new(b.JobRun)
		}
		out.Between = append(out.Between, w)
	}
	for _, p := range c.Points {
		out.Points = append(out.Points, wire.BuildsPoint{Ref: p.Run.Ref, Made: wire.DateOf(p.Run.MadeAt()), Ran: p.Ran, Queue: p.Queue})
	}
	return out
}

// RunToWire is r on the wire, with its jobs and steps.
func RunToWire(r Run) wire.BuildsRun {
	out := wire.BuildsRun{Ref: r.Ref, ID: r.ID, Attempt: int64(r.Attempt), Workflow: r.Workflow, Event: optional(r.Event),
		Branch: optional(r.Branch), HeadSha: optional(r.HeadSHA), URL: optional(r.URL), Made: wire.DateOf(r.MadeAt()),
		Started: r.Started, Ended: r.Ended, Turn: r.Turn(), Conclusion: optional(r.Conclusion), Jobs: []wire.BuildsJob{}}
	if r.PR > 0 {
		out.Pr = new(int64(r.PR))
	}
	if r.Default {
		out.Default = new(true)
	}
	if r.Tag {
		out.Tag = new(true)
	}
	for _, j := range r.Jobs {
		job := wire.BuildsJob{Name: j.Name, Made: j.Made, Started: j.Started, Ended: j.Ended, Conclusion: optional(j.Conclusion),
			Runner: optional(j.Runner), Steps: []wire.BuildsStep{}}
		for _, s := range j.Steps {
			job.Steps = append(job.Steps, wire.BuildsStep{Name: s.Name, Number: int64(s.Number), Started: s.Started,
				Ended: s.Ended, Conclusion: optional(s.Conclusion)})
		}
		out.Jobs = append(out.Jobs, job)
	}
	return out
}

// RunFromWire is a run as RunToWire sent it; its turn is worked out again from its jobs.
func RunFromWire(w wire.BuildsRun) Run {
	r := Run{Ref: w.Ref, ID: w.ID, Attempt: int(w.Attempt), Workflow: w.Workflow, Event: deref(w.Event), Branch: deref(w.Branch),
		HeadSHA: deref(w.HeadSha), URL: deref(w.URL), Made: w.Made.Time().Round(time.Second).Unix(), Started: w.Started,
		Ended: w.Ended, Conclusion: deref(w.Conclusion), Default: w.Default != nil && *w.Default, Tag: w.Tag != nil && *w.Tag,
		Jobs: make([]Job, 0, len(w.Jobs))}
	if w.Pr != nil {
		r.PR = int(*w.Pr)
	}
	for _, j := range w.Jobs {
		job := Job{Name: j.Name, Made: j.Made, Started: j.Started, Ended: j.Ended, Conclusion: deref(j.Conclusion), Runner: deref(j.Runner)}
		for _, s := range j.Steps {
			job.Steps = append(job.Steps, Step{Name: s.Name, Number: int(s.Number), Started: s.Started, Ended: s.Ended, Conclusion: deref(s.Conclusion)})
		}
		r.Jobs = append(r.Jobs, job)
	}
	return r
}

// Once is runs with one run for each ci-run ref and attempt, the first of each (two machines
// that read one repository send the same runs), oldest first.
func Once(runs []Run) []Run {
	seen := make(map[string]bool, len(runs))
	out := runs[:0:0]
	for _, r := range runs {
		if k := r.key(); !seen[k] {
			seen[k] = true
			out = append(out, r)
		}
	}
	sortRuns(out)
	return out
}

func optional(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

func deref(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}
