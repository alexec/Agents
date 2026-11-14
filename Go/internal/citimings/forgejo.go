package citimings

import (
	"encoding/json"
	"fmt"
	"math"
	"path"
	"strings"
	"time"
)

// Forgejo and Gitea Actions (#5224, spec 5166, "The data spike"): a run from the repository's
// run list (actions/runs, newest first), its jobs from actions/runs/{id}/jobs, and a job's
// steps from actions/jobs/{id} when the list gives none. Forgejo and Gitea share the API's
// paths but name the fields apart; this reads both (from Codeberg's swagger, Forgejo 17, and
// gitea.com's):
//
//   - Forgejo's run: created, started, stopped, status (its result), workflow_id, prettyref,
//     commit_sha, event, index_in_repo, event_payload. Its job: attempt, runs_on, status and
//     steps with started and stopped, and no time of its own: a job starts when its first step
//     starts and ends when its last step stops. A job with no needs is made with its run; one
//     with needs when the last job that ended before it started ended.
//   - Gitea's run and job are GitHub's: created_at, started_at, completed_at, status completed
//     with a conclusion, run_attempt, labels, and steps with started_at and completed_at.
//   - The forge keeps only a job's last try, so a run is one line, at attempt 1, when no job
//     was run again. When one was (a job's attempt, or Gitea's run_attempt, is over 1), the
//     run is two lines: the highest attempt with the jobs as they ran last, and attempt 1, a
//     failure that has the times of the jobs that were not run again, and the others with no
//     time. So the run counts once as a run and once as a re-run, as on GitHub. Forgejo 16
//     gives no steps, so its jobs have no time.
//   - The run's number (index_in_repo, run_number) is its id, as run.completed says it.

// ForgejoRun is a run as Forgejo's or Gitea's run list says it.
type ForgejoRun struct {
	ID          int64 `json:"id"`
	IndexInRepo int   `json:"index_in_repo"`
	RunNumber   int   `json:"run_number"`
	RunAttempt  int   `json:"run_attempt"`
	// WorkflowID is Forgejo's workflow file (ci.yml); Path is Gitea's
	// (.gitea/workflows/ci.yml@refs/heads/main).
	WorkflowID string `json:"workflow_id"`
	Path       string `json:"path"`
	Event      string `json:"event"`
	// HeadBranch is Gitea's; PrettyRef Forgejo's.
	HeadBranch string `json:"head_branch"`
	PrettyRef  string `json:"prettyref"`
	HeadSHA    string `json:"head_sha"`
	CommitSHA  string `json:"commit_sha"`
	HTMLURL    string `json:"html_url"`
	Status     string `json:"status"`
	Conclusion string `json:"conclusion"`
	// Times: Forgejo's created, started, stopped and updated; Gitea's with _at.
	Created     string `json:"created"`
	Started     string `json:"started"`
	Stopped     string `json:"stopped"`
	Updated     string `json:"updated"`
	CreatedAt   string `json:"created_at"`
	StartedAt   string `json:"started_at"`
	CompletedAt string `json:"completed_at"`
	UpdatedAt   string `json:"updated_at"`
	// PullRequests is Gitea's; Forgejo's pull request is in its event's payload.
	PullRequests []struct {
		Number int `json:"number"`
	} `json:"pull_requests"`
	EventPayload string `json:"event_payload"`
}

// ForgejoRunList is a page of actions/runs.
type ForgejoRunList struct {
	TotalCount int          `json:"total_count"`
	Runs       []ForgejoRun `json:"workflow_runs"`
}

func firstOf(s ...string) string {
	for _, v := range s {
		if v != "" {
			return v
		}
	}
	return ""
}

// forgeTime is a time the forge said; Forgejo writes a step that never ran as year 1.
func forgeTime(s string) (time.Time, bool) {
	t, err := time.Parse(time.RFC3339, s)
	return t, err == nil && t.Year() > 2000
}

// Number is the run's number in its repository.
func (r ForgejoRun) Number() int { return max(r.IndexInRepo, r.RunNumber) }

// MadeAt is when the run was made.
func (r ForgejoRun) MadeAt() (time.Time, bool) {
	return forgeTime(firstOf(r.Created, r.CreatedAt, r.Started, r.StartedAt))
}

// Result is how the run finished, or "" while it has not.
func (r ForgejoRun) Result() string {
	if r.Status == "completed" {
		return forgejoConclusion(firstOf(r.Conclusion, "success"))
	}
	switch r.Status {
	case "success", "failure", "cancelled", "canceled", "skipped":
		return forgejoConclusion(r.Status)
	}
	return ""
}

// Workflow is its workflow's file name: ci.yml.
func (r ForgejoRun) Workflow() string {
	p, _, _ := strings.Cut(firstOf(r.WorkflowID, r.Path), "@")
	if p == "" {
		return "actions"
	}
	return path.Base(p)
}

type forgejoPayload struct {
	Number      int `json:"number"`
	PullRequest struct {
		Number int `json:"number"`
		Head   struct {
			Ref string `json:"ref"`
		} `json:"head"`
	} `json:"pull_request"`
}

// PR is the run's pull request number, 0 for none.
func (r ForgejoRun) PR() int {
	if len(r.PullRequests) > 0 {
		return r.PullRequests[0].Number
	}
	if !strings.HasPrefix(r.Event, "pull_request") || r.EventPayload == "" {
		return 0
	}
	var p forgejoPayload
	if json.Unmarshal([]byte(r.EventPayload), &p) != nil {
		return 0
	}
	return max(p.PullRequest.Number, p.Number)
}

// Branch is the run's branch (a pull request's head branch) or tag.
func (r ForgejoRun) Branch() string {
	if r.HeadBranch != "" {
		return r.HeadBranch
	}
	if strings.HasPrefix(r.Event, "pull_request") && r.EventPayload != "" {
		var p forgejoPayload
		if json.Unmarshal([]byte(r.EventPayload), &p) == nil && p.PullRequest.Head.Ref != "" {
			return p.PullRequest.Head.Ref
		}
	}
	return strings.TrimPrefix(strings.TrimPrefix(r.PrettyRef, "refs/heads/"), "refs/tags/")
}

// ForgejoJob is a job as a run's jobs answer, or a job's own answer, says it.
type ForgejoJob struct {
	ID         int64    `json:"id"`
	Name       string   `json:"name"`
	Status     string   `json:"status"`
	Conclusion string   `json:"conclusion"`
	Attempt    int      `json:"attempt"`
	RunAttempt int      `json:"run_attempt"`
	Needs      []string `json:"needs"`
	RunsOn     []string `json:"runs_on"`
	Labels     []string `json:"labels"`
	CreatedAt  string   `json:"created_at"`
	StartedAt  string   `json:"started_at"`
	// CompletedAt is Gitea's end of the job.
	CompletedAt string `json:"completed_at"`
	Steps       []struct {
		Name       string `json:"name"`
		Number     int    `json:"number"`
		Status     string `json:"status"`
		Conclusion string `json:"conclusion"`
		// Started and Stopped are Forgejo's; StartedAt and CompletedAt Gitea's.
		Started     string `json:"started"`
		Stopped     string `json:"stopped"`
		StartedAt   string `json:"started_at"`
		CompletedAt string `json:"completed_at"`
	} `json:"steps"`
}

// Timed says the job says its own times, or its steps': it needs no further read.
func (j ForgejoJob) Timed() bool {
	if _, ok := forgeTime(j.StartedAt); ok {
		return true
	}
	return len(j.Steps) > 0
}

// ForgejoJobs is a run's jobs answer: Forgejo answers a list, Gitea {"jobs": […]}.
func ForgejoJobs(raw []byte) ([]ForgejoJob, error) {
	var jobs []ForgejoJob
	if json.Unmarshal(raw, &jobs) == nil {
		return jobs, nil
	}
	var wrapped struct {
		Jobs []ForgejoJob `json:"jobs"`
	}
	if err := json.Unmarshal(raw, &wrapped); err != nil {
		return nil, err
	}
	return wrapped.Jobs, nil
}

func forgejoConclusion(s string) string {
	switch s {
	case "canceled":
		return "cancelled"
	case "blocked", "waiting", "unknown":
		return "skipped"
	}
	return s
}

// FromForgejo is run's lines, from its jobs: ref is its ci-run ref; onDefault and onTag say
// what its branch is.
func FromForgejo(run ForgejoRun, jobs []ForgejoJob, ref string, onDefault, onTag bool) ([]Run, error) {
	made, ok := run.MadeAt()
	if !ok {
		return nil, fmt.Errorf("run %d: no made time", run.Number())
	}
	since := func(s string) (float64, bool) {
		t, ok := forgeTime(s)
		if !ok {
			return 0, false
		}
		return math.Round(t.Sub(made).Seconds()*10) / 10, true
	}
	out := Run{Ref: ref, ID: int64(run.Number()), Attempt: max(run.RunAttempt, 1), Workflow: run.Workflow(),
		Event: run.Event, Branch: run.Branch(), HeadSHA: firstOf(run.HeadSHA, run.CommitSHA), Default: onDefault,
		Tag: onTag && !onDefault, PR: run.PR(), URL: run.HTMLURL, Made: made.Unix(), Conclusion: run.Result(), Jobs: []Job{}}
	if out.ID == 0 {
		out.ID = run.ID
	}
	needs := make([]bool, len(jobs))
	for i, j := range jobs {
		out.Attempt = max(out.Attempt, j.Attempt, j.RunAttempt)
		job := Job{Name: j.Name, Conclusion: forgejoConclusion(firstOf(j.Conclusion, j.Status))}
		if job.Conclusion == "completed" {
			job.Conclusion = "success"
		}
		job.Runner = firstOf(append(append([]string{}, j.RunsOn...), j.Labels...)...)
		started, ended := math.Inf(1), math.Inf(-1)
		for _, s := range j.Steps {
			a, okA := since(firstOf(s.StartedAt, s.Started))
			b, okB := since(firstOf(s.CompletedAt, s.Stopped))
			if !okA || !okB {
				continue
			}
			started, ended = math.Min(started, a), math.Max(ended, b)
			c := forgejoConclusion(firstOf(s.Conclusion, s.Status))
			job.Steps = append(job.Steps, Step{Name: s.Name, Number: s.Number, Started: a, Ended: b, Conclusion: c})
		}
		if a, ok := since(j.StartedAt); ok {
			// Gitea's job says its own times.
			job.Started, job.Ended = a, a
			if b, ok := since(j.CompletedAt); ok {
				job.Ended = b
			}
			job.Made = a
			if m, ok := since(j.CreatedAt); ok {
				job.Made = m
			}
		} else if !math.IsInf(started, 1) {
			job.Started, job.Ended = started, ended
			needs[i] = len(j.Needs) > 0
		}
		out.Jobs = append(out.Jobs, job)
	}
	// A Forgejo job that needs others was made when the last job that ended before it started
	// ended; one with no needs, with its run (0).
	for i := range out.Jobs {
		if !needs[i] {
			continue
		}
		for k, other := range out.Jobs {
			if k != i && other.Ended > out.Jobs[i].Made && other.Ended <= out.Jobs[i].Started {
				out.Jobs[i].Made = other.Ended
			}
		}
	}
	earliest, last := math.Inf(1), 0.0
	for _, j := range out.Jobs {
		if j.Ended > 0 {
			earliest = math.Min(earliest, j.Made)
		}
		last = math.Max(last, j.Ended)
	}
	if s, ok := since(firstOf(run.Started, run.StartedAt)); ok {
		out.Started = s
	} else if !math.IsInf(earliest, 1) {
		out.Started = earliest
	}
	out.Ended = last
	if out.Ended == 0 {
		out.Ended, _ = since(firstOf(run.Stopped, run.CompletedAt, run.Updated, run.UpdatedAt))
	}
	if out.Conclusion == "" {
		out.Conclusion = "success"
	}
	if out.Attempt == 1 {
		return []Run{out}, nil
	}
	// The first attempt did not pass: a job of it was run again.
	one := out
	one.Attempt, one.Conclusion, one.Jobs = 1, "failure", make([]Job, 0, len(out.Jobs))
	for i, j := range jobs {
		job := out.Jobs[i]
		if max(j.Attempt, j.RunAttempt) > 1 {
			job = Job{Name: job.Name, Conclusion: "failure", Runner: job.Runner}
		}
		one.Jobs = append(one.Jobs, job)
	}
	one.Started, one.Ended = 0, 0
	for _, j := range one.Jobs {
		one.Ended = math.Max(one.Ended, j.Ended)
	}
	return []Run{one, out}, nil
}
