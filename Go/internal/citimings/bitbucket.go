package citimings

import (
	"encoding/json"
	"fmt"
	"math"
	"sort"
	"strings"
	"time"
)

// Bitbucket Pipelines (#5223, spec 5166, "The data spike"): a pipeline from the repository's
// pipeline list (pipelines/?status=COMPLETED&sort=-created_on), its steps from
// pipelines/{uuid}/steps/. A Bitbucket step is a job here: it has its own runner and its own
// times, and Bitbucket has nothing below it, so a job's Steps stay empty.
//
//   - A pipeline is named by its build number, as run.completed and failed_log name it, so its
//     ci-run ref is bitbucket:run:<workspace/repo>#<build number>.
//   - Attempt n is the pipeline's run n: "Rerun failed steps" runs the same pipeline again, its
//     run_number one more, and each step says the run_number it ran in. "Run again"
//     (retry_pipeline) is a new pipeline with a build number of its own.
//   - Bitbucket says no time a step was made or waited for a runner: a step is made when it
//     started, and the wait before the first step is the pipeline's (its Started).

// BitbucketPipeline is a pipeline as Bitbucket's list says it.
type BitbucketPipeline struct {
	UUID        string `json:"uuid"`
	BuildNumber int64  `json:"build_number"`
	RunNumber   int    `json:"run_number"`
	CreatedOn   string `json:"created_on"`
	CompletedOn string `json:"completed_on"`
	State       struct {
		Name   string `json:"name"`
		Result *struct {
			Name string `json:"name"`
		} `json:"result"`
	} `json:"state"`
	Target struct {
		Type    string `json:"type"`
		RefType string `json:"ref_type"`
		RefName string `json:"ref_name"`
		Source  string `json:"source"`
		Commit  struct {
			Hash string `json:"hash"`
		} `json:"commit"`
		Selector struct {
			Type    string `json:"type"`
			Pattern string `json:"pattern"`
		} `json:"selector"`
		PullRequest *struct {
			ID int `json:"id"`
		} `json:"pullrequest"`
	} `json:"target"`
	Trigger struct {
		Name string `json:"name"`
	} `json:"trigger"`
}

// BitbucketPipelines is a page of the pipeline list.
type BitbucketPipelines struct {
	Values []BitbucketPipeline `json:"values"`
	Next   string              `json:"next"`
}

// Completed says the pipeline is done.
func (p BitbucketPipeline) Completed() bool { return p.State.Name == "COMPLETED" }

// Branch is the pipeline's branch or tag, or a pull request's source branch.
func (p BitbucketPipeline) Branch() string {
	if p.Target.RefName != "" {
		return p.Target.RefName
	}
	return p.Target.Source
}

// PullRequest says the pipeline ran for a pull request.
func (p BitbucketPipeline) PullRequest() bool {
	return p.Target.Type == "pipeline_pullrequest_target" || p.Target.PullRequest != nil
}

// OnTag says the pipeline ran for a tag.
func (p BitbucketPipeline) OnTag() bool { return p.Target.RefType == "tag" }

// workflow is the pipeline of bitbucket-pipelines.yml it ran: a custom pipeline's name, a
// branch, tag or pull request pattern, or default.
func (p BitbucketPipeline) workflow() string {
	if p.Target.Selector.Pattern != "" {
		return p.Target.Selector.Pattern
	}
	if p.Target.Selector.Type != "" {
		return p.Target.Selector.Type
	}
	return "default"
}

type bitbucketSteps struct {
	Values []struct {
		Name        string `json:"name"`
		RunNumber   int    `json:"run_number"`
		StartedOn   string `json:"started_on"`
		CompletedOn string `json:"completed_on"`
		State       struct {
			Name   string `json:"name"`
			Result *struct {
				Name string `json:"name"`
			} `json:"result"`
		} `json:"state"`
		// RunsOn is a self-hosted step's runner labels, as runs-on: says them.
		RunsOn []string `json:"runs_on"`
	} `json:"values"`
	Next string `json:"next"`
}

// BitbucketStepsNext is the next page of a steps answer, "" for none.
func BitbucketStepsNext(raw []byte) string {
	var s bitbucketSteps
	if json.Unmarshal(raw, &s) != nil {
		return ""
	}
	return s.Next
}

func bitbucketConclusion(result string) string {
	switch result {
	case "SUCCESSFUL":
		return "success"
	case "FAILED", "ERROR":
		return "failure"
	case "STOPPED", "EXPIRED":
		return "cancelled"
	case "NOT_RUN", "SKIPPED":
		return "skipped"
	}
	return strings.ToLower(result)
}

// FromBitbucket is each attempt of the pipeline, from its steps answers (every page): ref is
// its ci-run ref, url its page; onDefault says it ran for the default branch. A step names the
// run it ran in; the pipeline's own run is kept even with no step, and has its conclusion.
func FromBitbucket(p BitbucketPipeline, stepPages [][]byte, ref, url string, onDefault bool) ([]Run, error) {
	made, err := time.Parse(time.RFC3339, p.CreatedOn)
	if err != nil {
		return nil, fmt.Errorf("pipeline %d: no made time", p.BuildNumber)
	}
	since := func(s string) (float64, bool) {
		t, err := time.Parse(time.RFC3339, s)
		if err != nil {
			return 0, false
		}
		return math.Round(t.Sub(made).Seconds()*10) / 10, true
	}
	base := Run{Ref: ref, ID: p.BuildNumber, Workflow: p.workflow(), Event: strings.ToLower(p.Trigger.Name),
		Branch: p.Branch(), HeadSHA: p.Target.Commit.Hash, Default: onDefault, Tag: p.OnTag() && !onDefault, URL: url,
		Made: made.Unix()}
	if p.PullRequest() {
		base.Default, base.Tag = false, false
		if p.Target.PullRequest != nil {
			base.PR = p.Target.PullRequest.ID
		}
	}
	latest := max(p.RunNumber, 1)
	attempts := map[int]*Run{}
	attemptOf := func(n int) *Run {
		if attempts[n] == nil {
			r := base
			r.Attempt, r.Jobs = n, []Job{}
			attempts[n] = &r
		}
		return attempts[n]
	}
	attemptOf(latest)
	started := map[int]float64{}
	for _, raw := range stepPages {
		var steps bitbucketSteps
		if err := json.Unmarshal(raw, &steps); err != nil {
			return nil, fmt.Errorf("pipeline %d: the steps answer: %v", p.BuildNumber, err)
		}
		for _, s := range steps.Values {
			n := latest
			if s.RunNumber > 0 {
				n = min(s.RunNumber, latest)
			}
			job := Job{Name: s.Name}
			if s.State.Result != nil {
				job.Conclusion = bitbucketConclusion(s.State.Result.Name)
			}
			if len(s.RunsOn) > 0 {
				job.Runner = s.RunsOn[0]
			}
			if a, ok := since(s.StartedOn); ok {
				job.Made, job.Started = a, a
				if first, ok := started[n]; !ok || a < first {
					started[n] = a
				}
				if job.Ended, ok = since(s.CompletedOn); !ok {
					job.Ended = a
				}
			} else if e, ok := since(s.CompletedOn); ok {
				// It never ran (not run, or stopped before a runner took it).
				job.Made, job.Started, job.Ended = e, e, e
			}
			r := attemptOf(n)
			r.Jobs = append(r.Jobs, job)
		}
	}
	var out []Run
	for n, r := range attempts {
		failed, cancelled := false, false
		for _, j := range r.Jobs {
			r.Ended = math.Max(r.Ended, j.Ended)
			failed = failed || j.Conclusion == "failure"
			cancelled = cancelled || j.Conclusion == "cancelled"
		}
		r.Started = started[n]
		switch {
		case n == latest:
			if p.State.Result != nil {
				r.Conclusion = bitbucketConclusion(p.State.Result.Name)
			}
			if e, ok := since(p.CompletedOn); ok && e > r.Ended {
				r.Ended = e
			}
		case failed:
			// An earlier run was run again, so it did not pass.
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
