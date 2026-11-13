package citimings

import (
	"encoding/json"
	"fmt"
	"math"
	"path"
	"sort"
	"time"
)

// GitHub Actions (spec 5166, "Is the forge's data enough? Yes, on GitHub"): a run from the run
// list (actions/runs), its jobs and steps from actions/runs/{id}/jobs?filter=all, which gives
// every attempt's jobs, each with its own run_attempt. One line is kept for each attempt.

// GitHubRun is a run as GitHub's run list says it.
type GitHubRun struct {
	ID           int64  `json:"id"`
	RunAttempt   int    `json:"run_attempt"`
	CreatedAt    string `json:"created_at"`
	RunStartedAt string `json:"run_started_at"`
	UpdatedAt    string `json:"updated_at"`
	Status       string `json:"status"`
	Conclusion   string `json:"conclusion"`
	HeadBranch   string `json:"head_branch"`
	HeadSHA      string `json:"head_sha"`
	Event        string `json:"event"`
	Path         string `json:"path"`
	HTMLURL      string `json:"html_url"`
	PullRequests []struct {
		Number int `json:"number"`
	} `json:"pull_requests"`
}

// GitHubRunList is a page of actions/runs.
type GitHubRunList struct {
	TotalCount   int         `json:"total_count"`
	WorkflowRuns []GitHubRun `json:"workflow_runs"`
}

type gitHubJobs struct {
	TotalCount int `json:"total_count"`
	Jobs       []struct {
		RunAttempt  int      `json:"run_attempt"`
		Name        string   `json:"name"`
		CreatedAt   string   `json:"created_at"`
		StartedAt   string   `json:"started_at"`
		CompletedAt string   `json:"completed_at"`
		Conclusion  string   `json:"conclusion"`
		Labels      []string `json:"labels"`
		Steps       []struct {
			Name        string `json:"name"`
			Number      int    `json:"number"`
			StartedAt   string `json:"started_at"`
			CompletedAt string `json:"completed_at"`
			Conclusion  string `json:"conclusion"`
		} `json:"steps"`
	} `json:"jobs"`
}

// JobsTotal is how many jobs a jobs answer says the run has, beside how many it gave.
func JobsTotal(raw []byte) (total, given int) {
	var j gitHubJobs
	if json.Unmarshal(raw, &j) != nil {
		return 0, 0
	}
	return j.TotalCount, len(j.Jobs)
}

// FromGitHub is each attempt of run, from its jobs answer: ref is its ci-run ref; onDefault and
// onTag say what its branch is. An attempt with no job that ran is still kept: it counts.
func FromGitHub(run GitHubRun, jobsRaw []byte, ref string, onDefault, onTag bool) ([]Run, error) {
	made, err := time.Parse(time.RFC3339, run.CreatedAt)
	if err != nil {
		return nil, fmt.Errorf("run %d: no made time", run.ID)
	}
	var jobs gitHubJobs
	if err := json.Unmarshal(jobsRaw, &jobs); err != nil {
		return nil, fmt.Errorf("run %d: the jobs answer: %v", run.ID, err)
	}
	since := func(s string) (float64, bool) {
		t, err := time.Parse(time.RFC3339, s)
		if err != nil {
			return 0, false
		}
		return math.Round(t.Sub(made).Seconds()*10) / 10, true
	}
	base := Run{Ref: ref, ID: run.ID, Workflow: path.Base(run.Path), Event: run.Event, Branch: run.HeadBranch,
		HeadSHA: run.HeadSHA, Default: onDefault, Tag: onTag && !onDefault, URL: run.HTMLURL, Made: made.Unix()}
	if len(run.PullRequests) > 0 {
		base.PR = run.PullRequests[0].Number
	}
	attempts := map[int]*Run{}
	attemptOf := func(n int) *Run {
		if attempts[n] == nil {
			r := base
			r.Attempt, r.Jobs = n, []Job{}
			attempts[n] = &r
		}
		return attempts[n]
	}
	for _, j := range jobs.Jobs {
		n := max(j.RunAttempt, 1)
		r := attemptOf(n)
		job := Job{Name: j.Name, Conclusion: j.Conclusion}
		job.Made, _ = since(j.CreatedAt)
		var ok bool
		if job.Started, ok = since(j.StartedAt); !ok {
			job.Started = job.Made
		}
		if job.Ended, ok = since(j.CompletedAt); !ok {
			job.Ended = job.Started
		}
		if len(j.Labels) > 0 {
			job.Runner = j.Labels[0]
		}
		for _, s := range j.Steps {
			a, okA := since(s.StartedAt)
			b, okB := since(s.CompletedAt)
			if okA && okB {
				job.Steps = append(job.Steps, Step{Name: s.Name, Number: s.Number, Started: a, Ended: b, Conclusion: s.Conclusion})
			}
		}
		r.Jobs = append(r.Jobs, job)
	}
	// The run's own attempt is in the list even with no jobs; its conclusion is the run's.
	latest := attemptOf(max(run.RunAttempt, 1))
	latest.Conclusion = run.Conclusion
	if s, ok := since(run.RunStartedAt); ok {
		latest.Started = s
	}
	var out []Run
	for n, r := range attempts {
		ended, started := 0.0, math.Inf(1)
		failed, cancelled := false, false
		for _, j := range r.Jobs {
			ended = math.Max(ended, j.Ended)
			started = math.Min(started, j.Made)
			failed = failed || j.Conclusion == "failure" || j.Conclusion == "timed_out"
			cancelled = cancelled || j.Conclusion == "cancelled"
		}
		if r.Ended = ended; r.Ended == 0 {
			r.Ended, _ = since(run.UpdatedAt)
		}
		if r.Started == 0 && !math.IsInf(started, 1) && n != run.RunAttempt {
			r.Started = started
		}
		if r.Conclusion == "" {
			// An earlier attempt's conclusion is its jobs': it was run again, so it did not pass.
			switch {
			case failed:
				r.Conclusion = "failure"
			case cancelled:
				r.Conclusion = "cancelled"
			default:
				r.Conclusion = "success"
			}
		}
		out = append(out, *r)
	}
	sort.Slice(out, func(a, b int) bool { return out[a].Attempt < out[b].Attempt })
	return out, nil
}
