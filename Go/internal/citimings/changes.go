package citimings

import (
	"math"
	"sort"
)

// Change points (spec 5166, findings 1, 5 and 7, open question 4): for each job, on its run
// time in the default branch's first attempts that passed, never on queue time and never on a
// whole run's time (ci.yml's select runs only the jobs a change's paths need).
//
// Binary segmentation on log seconds, the idea of E-divisive as Apache Otava uses it, made
// simple as derive.py does: split where the shift in mean is largest, keep the split when its
// t-like score is over splitScore and the shift is at least splitShift, with at least
// sideRuns runs on each side, and look again inside each side. A change is shown only when the
// medians on each side moved by at least ShownSeconds and ShownShare, with a score of at least
// ShownScore: the rest are noise on a short job or a one-run blip.
//
// Decided: our own code, about 40 lines, because no Go library fits AGENTS.md's rule: the two
// that do change points (pgregory.net/changepoint, github.com/lytics/impact) were last updated
// in 2023 and 2015. Otava is Python.

const (
	// leastRuns is the runs a job needs before it is looked at.
	leastRuns  = 100
	sideRuns   = 25
	mostDepth  = 4
	splitScore = 5
	splitShift = 0.15
	// ShownSeconds, ShownShare and ShownScore are the floor of a change shown (finding 7).
	ShownSeconds = 30
	ShownShare   = 0.20
	ShownScore   = 8
	// aroundRuns is the runs on each side of a change kept as its points (board 2).
	aroundRuns = 60
)

// Point is one run of a job: its run time, and its wait (for a runner and its turn).
type Point struct {
	Run        Run
	Ran, Queue float64
}

// Between is a default-branch run of the workflow made after the last fast run, up to the
// first slow one: whether it ran the job, and how long.
type Between struct {
	Run Run
	// Ran says the run started the job; JobRun is how long it ran.
	Ran    bool
	JobRun float64
}

// Change is a step in one job's run time on the default branch.
type Change struct {
	Workflow, Job string
	// LastFast and FirstSlow are the runs either side of the step (for a speed-up, the last
	// slow run and the first fast one).
	LastFast, FirstSlow       Run
	MedianBefore, MedianAfter float64
	QueueBefore, QueueAfter   float64
	Score                     float64
	Runner                    string
	// Between is every default-branch run of the workflow after LastFast, up to FirstSlow.
	Between []Between
	// Points are the job's runs around the change.
	Points []Point
}

// Slower says the job's run time went up.
func (c Change) Slower() bool { return c.MedianAfter > c.MedianBefore }

// Changes finds the change points of each job of each workflow, oldest first. runs is every
// run the store has, oldest first.
func Changes(runs []Run) []Change {
	type key struct{ workflow, job string }
	series := map[key][]Point{}
	var keys []key
	for _, r := range runs {
		if !r.Default || r.Attempt > 1 || r.Conclusion != "success" {
			continue
		}
		s, ok := r.Shape()
		if !ok {
			continue
		}
		for _, j := range r.Jobs {
			if !j.done() || j.Conclusion != "success" {
				continue
			}
			k := key{r.Workflow, j.Name}
			if series[k] == nil {
				keys = append(keys, k)
			}
			series[k] = append(series[k], Point{Run: r, Ran: j.RunTime(), Queue: j.RunnerWait() + s.Turn})
		}
	}
	var out []Change
	for _, k := range keys {
		points := series[k]
		if len(points) < leastRuns {
			continue
		}
		logs := make([]float64, len(points))
		for i, p := range points {
			logs[i] = math.Log(math.Max(p.Ran, 1))
		}
		var found []split
		segment(logs, 0, len(logs), 0, &found)
		for _, s := range found {
			if c, ok := changeAt(runs, k.workflow, k.job, points, s); ok {
				out = append(out, c)
			}
		}
	}
	sort.SliceStable(out, func(a, b int) bool { return out[a].FirstSlow.Made < out[b].FirstSlow.Made })
	return out
}

type split struct {
	at    int
	score float64
}

// segment is binary segmentation on v[lo:hi].
func segment(v []float64, lo, hi, depth int, found *[]split) {
	n := hi - lo
	if n < 2*sideRuns || depth > mostDepth {
		return
	}
	pre := make([]float64, n+1)
	mean := 0.0
	for i, x := range v[lo:hi] {
		pre[i+1] = pre[i] + x
		mean += x
	}
	mean /= float64(n)
	sd := 0.0
	for _, x := range v[lo:hi] {
		sd += (x - mean) * (x - mean)
	}
	sd = math.Sqrt(sd / float64(n))
	if sd == 0 {
		sd = 1e-9
	}
	best, at := 0.0, -1
	for k := sideRuns; k < n-sideRuns; k++ {
		ml, mr := pre[k]/float64(k), (pre[n]-pre[k])/float64(n-k)
		if s := math.Abs(mr-ml) / sd * math.Sqrt(float64(k*(n-k))/float64(n)); s > best {
			best, at = s, k
		}
	}
	if at < 0 {
		return
	}
	ml, mr := pre[at]/float64(at), (pre[n]-pre[at])/float64(n-at)
	if best > splitScore && math.Abs(math.Exp(mr-ml)-1) >= splitShift {
		*found = append(*found, split{lo + at, best})
		segment(v, lo, lo+at, depth+1, found)
		segment(v, lo+at, hi, depth+1, found)
	}
}

// changeAt is the change at s in a job's points, when it passes the shown floor.
func changeAt(runs []Run, workflow, job string, points []Point, s split) (Change, bool) {
	i := s.at
	lo, hi := max(0, i-sideRuns), min(len(points), i+sideRuns)
	median := func(ps []Point, of func(Point) float64) float64 {
		v := make([]float64, len(ps))
		for k, p := range ps {
			v[k] = of(p)
		}
		return StatOf(v).Median
	}
	ran := func(p Point) float64 { return p.Ran }
	queue := func(p Point) float64 { return p.Queue }
	before, after := median(points[lo:i], ran), median(points[i:hi], ran)
	if before <= 0 || math.Abs(after-before) < ShownSeconds || math.Abs(after/before-1) < ShownShare || s.score < ShownScore {
		return Change{}, false
	}
	c := Change{Workflow: workflow, Job: job, LastFast: points[i-1].Run, FirstSlow: points[i].Run,
		MedianBefore: before, MedianAfter: after, QueueBefore: median(points[lo:i], queue),
		QueueAfter: median(points[i:hi], queue), Score: s.score,
		Points: points[max(0, i-aroundRuns):min(len(points), i+aroundRuns)]}
	if j, ok := c.FirstSlow.Job(job); ok {
		c.Runner = j.Runner
	}
	for _, r := range runs {
		if !r.Default || r.Workflow != workflow || r.Attempt > 1 || r.Made < c.LastFast.Made || r.Made > c.FirstSlow.Made ||
			r.Ref == c.LastFast.Ref {
			continue
		}
		b := Between{Run: r}
		if j, ok := r.Job(job); ok && j.done() {
			b.Ran, b.JobRun = true, j.RunTime()
		}
		c.Between = append(c.Between, b)
	}
	return c, true
}
