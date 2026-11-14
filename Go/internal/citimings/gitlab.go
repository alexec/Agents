package citimings

import (
	"encoding/json"
	"fmt"
	"math"
	"regexp"
	"sort"
	"strconv"
	"time"
)

// GitLab pipelines (#5221, spec 5166, "The data spike"): a pipeline from the project's pipeline
// list, its jobs from pipelines/{id}/jobs?include_retried=true, which gives a retried job's
// earlier tries too. GitLab has jobs and no steps, so a job's Steps stay empty.
//
//   - Made is the pipeline's created_at. A job is made when it became pending: its started_at
//     less its queued_duration, so "waiting its turn" is the stages before it, and "waiting for a
//     runner" is queued_duration. A job that GitLab gave no queued_duration is made at its
//     created_at.
//   - Attempt n holds the nth try of each job of one name, oldest first: a retried job is a
//     re-run of it.

// GitLabPipeline is a pipeline as GitLab's list says it.
type GitLabPipeline struct {
	ID        int64  `json:"id"`
	IID       int    `json:"iid"`
	Name      string `json:"name"`
	Status    string `json:"status"`
	Source    string `json:"source"`
	Ref       string `json:"ref"`
	SHA       string `json:"sha"`
	WebURL    string `json:"web_url"`
	CreatedAt string `json:"created_at"`
	UpdatedAt string `json:"updated_at"`
}

var mergeRequestRef = regexp.MustCompile(`^refs/merge-requests/(\d+)/`)

// Finished says a pipeline status is one that is done.
func (p GitLabPipeline) Finished() bool {
	switch p.Status {
	case "success", "failed", "canceled", "skipped":
		return true
	}
	return false
}

type gitLabJob struct {
	ID             int64    `json:"id"`
	Name           string   `json:"name"`
	Status         string   `json:"status"`
	Tag            bool     `json:"tag"`
	CreatedAt      string   `json:"created_at"`
	StartedAt      string   `json:"started_at"`
	FinishedAt     string   `json:"finished_at"`
	QueuedDuration *float64 `json:"queued_duration"`
	Runner         *struct {
		Description string `json:"description"`
	} `json:"runner"`
}

func gitLabConclusion(status string) string {
	switch status {
	case "success":
		return "success"
	case "failed":
		return "failure"
	case "canceled", "canceling":
		return "cancelled"
	case "skipped", "manual":
		return "skipped"
	}
	return status
}

// GitLabJobsFull says a jobs answer is a full page, so there may be more jobs than it gave.
func GitLabJobsFull(raw []byte, perPage int) bool {
	var j []json.RawMessage
	return json.Unmarshal(raw, &j) == nil && len(j) >= perPage
}

// FromGitLab is each attempt of p, from its jobs answer (every page joined into one array): ref
// is its ci-run ref; onDefault and onTag say what its ref is. A job that never ran has no time
// of its own and is made, started and ended when its pipeline was made.
func FromGitLab(p GitLabPipeline, jobsRaw []byte, ref string, onDefault, onTag bool) ([]Run, error) {
	made, err := time.Parse(time.RFC3339, p.CreatedAt)
	if err != nil {
		return nil, fmt.Errorf("pipeline %d: no made time", p.ID)
	}
	var jobs []gitLabJob
	if err := json.Unmarshal(jobsRaw, &jobs); err != nil {
		return nil, fmt.Errorf("pipeline %d: the jobs answer: %v", p.ID, err)
	}
	// The oldest try of a name first: GitLab numbers its jobs as it makes them.
	sort.SliceStable(jobs, func(a, b int) bool { return jobs[a].ID < jobs[b].ID })
	since := func(s string) (float64, bool) {
		t, err := time.Parse(time.RFC3339, s)
		if err != nil {
			return 0, false
		}
		return math.Round(t.Sub(made).Seconds()*10) / 10, true
	}
	base := Run{Ref: ref, ID: p.ID, Workflow: p.Name, Event: p.Source, Branch: p.Ref, HeadSHA: p.SHA, Default: onDefault,
		URL: p.WebURL, Made: made.Unix()}
	if base.Workflow == "" {
		base.Workflow = "pipeline"
	}
	if m := mergeRequestRef.FindStringSubmatch(p.Ref); m != nil {
		base.PR, _ = strconv.Atoi(m[1])
	}
	for _, j := range jobs {
		onTag = onTag || j.Tag
	}
	base.Tag = onTag && !onDefault
	tries := map[string]int{}
	firstMade := map[int]float64{}
	attempts := map[int]*Run{}
	for _, j := range jobs {
		tries[j.Name]++
		n := tries[j.Name]
		r := attempts[n]
		if r == nil {
			c := base
			c.Attempt, c.Jobs = n, []Job{}
			r = &c
			attempts[n] = r
		}
		job := Job{Name: j.Name, Conclusion: gitLabConclusion(j.Status)}
		if j.Runner != nil {
			job.Runner = j.Runner.Description
		}
		started, ran := since(j.StartedAt)
		if !ran {
			// It never ran (skipped, manual, or cancelled before a runner took it).
			created, ok := since(j.CreatedAt)
			if !ok {
				created = 0
			}
			job.Made, job.Started = created, created
			job.Ended = created
			if e, ok := since(j.FinishedAt); ok {
				job.Ended = e
			}
		} else {
			job.Started = started
			job.Made, _ = since(j.CreatedAt)
			if j.QueuedDuration != nil {
				job.Made = math.Max(math.Round((started-*j.QueuedDuration)*10)/10, 0)
			}
			if job.Ended, ran = since(j.FinishedAt); !ran {
				job.Ended = started
			}
			if f, ok := firstMade[n]; !ok || job.Made < f {
				firstMade[n] = job.Made
			}
		}
		r.Jobs = append(r.Jobs, job)
	}
	last := 1
	for n := range attempts {
		last = max(last, n)
	}
	if attempts[1] == nil {
		c := base
		c.Attempt, c.Jobs = 1, []Job{}
		attempts[1] = &c
	}
	var out []Run
	for n, r := range attempts {
		ended := 0.0
		failed, cancelled := false, false
		for _, j := range r.Jobs {
			ended = math.Max(ended, j.Ended)
			failed = failed || j.Conclusion == "failure"
			cancelled = cancelled || j.Conclusion == "cancelled"
		}
		r.Started = firstMade[n]
		if r.Ended = ended; r.Ended == 0 {
			r.Ended, _ = since(p.UpdatedAt)
		}
		switch {
		case n == last && p.Status != "":
			r.Conclusion = gitLabConclusion(p.Status)
		case failed:
			// An earlier try was run again, so it did not pass.
			r.Conclusion = "failure"
		case cancelled:
			r.Conclusion = "cancelled"
		default:
			r.Conclusion = "success"
		}
		out = append(out, *r)
	}
	sort.Slice(out, func(a, b int) bool { return out[a].Attempt < out[b].Attempt })
	return out, nil
}
