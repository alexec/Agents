package citimings

import (
	"encoding/json"
	"fmt"
	"math"
	"slices"
	"sort"
	"strings"
	"time"
)

// Azure Pipelines (#5222; spec 5166, "Is the forge's data enough?"): a build from the build
// list (build/builds), its jobs and their steps from its timeline (build/builds/{id}/timeline):
// the Job records and their Task records. A build is one run; a job run again ("Rerun failed
// jobs") keeps the build's id, and its record says its attempt and where each earlier attempt's
// record is (previousAttempts: a timeline id and a record id). One line is kept for each
// attempt, as on GitHub.
//
//   - Made is the build's queueTime, the attempt's start its startTime.
//   - A job is made when its phase starts (the Phase record above it), and starts when an
//     agent takes it (its own startTime): its wait for a runner is between them.
//   - A job's runner is the build's agent pool: a timeline record does not say its own.
//   - A job's name has its stage's name before it when the pipeline has stages, as
//     "Build / macOS": two stages may each have a job of the same name.
//   - Results are said in GitHub's words, so the figures read them the same: succeeded is
//     success, partiallySucceeded and succeededWithIssues are neutral (Azure DevOps does not
//     count them as passed), failed is failure, canceled and abandoned are cancelled.

// AzureBuild is a build as Azure DevOps's build list says it.
type AzureBuild struct {
	ID           int64             `json:"id"`
	BuildNumber  string            `json:"buildNumber"`
	Status       string            `json:"status"`
	Result       string            `json:"result"`
	QueueTime    string            `json:"queueTime"`
	StartTime    string            `json:"startTime"`
	FinishTime   string            `json:"finishTime"`
	SourceBranch string            `json:"sourceBranch"`
	SourceVer    string            `json:"sourceVersion"`
	Reason       string            `json:"reason"`
	TriggerInfo  map[string]string `json:"triggerInfo"`
	Definition   struct {
		Name string `json:"name"`
	} `json:"definition"`
	Queue struct {
		Name string `json:"name"`
		Pool struct {
			Name string `json:"name"`
		} `json:"pool"`
	} `json:"queue"`
	Links struct {
		Web struct {
			Href string `json:"href"`
		} `json:"web"`
	} `json:"_links"`
}

// AzureBuildList is a page of build/builds.
type AzureBuildList struct {
	Count int          `json:"count"`
	Value []AzureBuild `json:"value"`
}

// MadeAt is when the build was queued.
func (b AzureBuild) MadeAt() (time.Time, bool) {
	t, err := time.Parse(time.RFC3339Nano, b.QueueTime)
	return t, err == nil
}

// FinishedAt is when the build finished.
func (b AzureBuild) FinishedAt() (time.Time, bool) {
	t, err := time.Parse(time.RFC3339Nano, b.FinishTime)
	return t, err == nil
}

// Branch is the build's branch or tag, with no refs/heads/ or refs/tags/.
func (b AzureBuild) Branch() string {
	if tag, ok := strings.CutPrefix(b.SourceBranch, "refs/tags/"); ok {
		return tag
	}
	return strings.TrimPrefix(b.SourceBranch, "refs/heads/")
}

// OnTag says the build is of a tag.
func (b AzureBuild) OnTag() bool { return strings.HasPrefix(b.SourceBranch, "refs/tags/") }

// PullRequest is the build's pull request, from its trigger or its refs/pull/12/merge; 0 for none.
func (b AzureBuild) PullRequest() int {
	var n int
	if _, err := fmt.Sscanf(b.TriggerInfo["pr.number"], "%d", &n); err == nil && n > 0 {
		return n
	}
	if rest, ok := strings.CutPrefix(b.SourceBranch, "refs/pull/"); ok {
		if _, err := fmt.Sscanf(strings.TrimSuffix(rest, "/merge"), "%d", &n); err == nil && n > 0 {
			return n
		}
	}
	return 0
}

// AzureRecord is one record of a build's timeline.
type AzureRecord struct {
	ID               string `json:"id"`
	ParentID         string `json:"parentId"`
	Type             string `json:"type"`
	Name             string `json:"name"`
	StartTime        string `json:"startTime"`
	FinishTime       string `json:"finishTime"`
	Result           string `json:"result"`
	Order            int    `json:"order"`
	Attempt          int    `json:"attempt"`
	PreviousAttempts []struct {
		Attempt    int    `json:"attempt"`
		TimelineID string `json:"timelineId"`
		RecordID   string `json:"recordId"`
	} `json:"previousAttempts"`
}

type azureTimeline struct {
	Records []AzureRecord `json:"records"`
}

// MostAzureTimelines bounds the earlier attempts' timelines read for one build.
const MostAzureTimelines = 5

// AzureEarlierTimelines is the ids of the timelines a build's timeline says its earlier
// attempts are in, each once, at most MostAzureTimelines.
func AzureEarlierTimelines(raw []byte) []string {
	var t azureTimeline
	if json.Unmarshal(raw, &t) != nil {
		return nil
	}
	var ids []string
	for _, r := range t.Records {
		for _, p := range r.PreviousAttempts {
			if p.TimelineID != "" && !slices.Contains(ids, p.TimelineID) && len(ids) < MostAzureTimelines {
				ids = append(ids, p.TimelineID)
			}
		}
	}
	return ids
}

// AzureConclusion is an Azure DevOps result in GitHub's words.
func AzureConclusion(result string) string {
	switch strings.ToLower(result) {
	case "succeeded":
		return "success"
	case "partiallysucceeded", "succeededwithissues":
		return "neutral"
	case "failed":
		return "failure"
	case "canceled", "abandoned":
		return "cancelled"
	case "skipped":
		return "skipped"
	}
	return strings.ToLower(result)
}

// FromAzureDevOps is each attempt of build, from its timeline and the timelines its earlier
// attempts are in (keyed by id): ref is its ci-run ref; onDefault and onTag say what its branch
// is.
func FromAzureDevOps(b AzureBuild, timelineRaw []byte, earlier map[string][]byte, ref string, onDefault, onTag bool) ([]Run, error) {
	made, ok := b.MadeAt()
	if !ok {
		return nil, fmt.Errorf("build %d: no queue time", b.ID)
	}
	var now azureTimeline
	if err := json.Unmarshal(timelineRaw, &now); err != nil {
		return nil, fmt.Errorf("build %d: the timeline: %v", b.ID, err)
	}
	since := func(s string) (float64, bool) {
		t, err := time.Parse(time.RFC3339Nano, s)
		if err != nil || t.IsZero() {
			return 0, false
		}
		return math.Round(t.Sub(made).Seconds()*10) / 10, true
	}
	runner := b.Queue.Pool.Name
	if runner == "" {
		runner = b.Queue.Name
	}
	base := Run{Ref: ref, ID: b.ID, Workflow: b.Definition.Name, Event: b.Reason, Branch: b.Branch(), HeadSHA: b.SourceVer,
		Default: onDefault, Tag: onTag && !onDefault, PR: b.PullRequest(), URL: b.Links.Web.Href, Made: made.Unix()}
	if sha := b.TriggerInfo["pr.sourceSha"]; sha != "" {
		base.HeadSHA = sha
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
	// A job of one timeline: its phase, its stage and its tasks are in the same timeline.
	jobOf := func(records []AzureRecord, rec AzureRecord) Job {
		byID := map[string]AzureRecord{}
		for _, r := range records {
			byID[r.ID] = r
		}
		job := Job{Name: rec.Name, Conclusion: AzureConclusion(rec.Result), Runner: runner}
		phase, hasPhase := byID[rec.ParentID]
		if hasPhase {
			if stage, ok := byID[phase.ParentID]; ok && stage.Type == "Stage" && stage.Name != "" && stage.Name != "__default" {
				job.Name = stage.Name + " / " + rec.Name
			}
		}
		var okStart, okEnd bool
		job.Started, okStart = since(rec.StartTime)
		if job.Made, ok = since(phase.StartTime); !hasPhase || !ok || job.Made > job.Started {
			job.Made = job.Started
		}
		if !okStart {
			job.Started = job.Made
		}
		if job.Ended, okEnd = since(rec.FinishTime); !okEnd {
			job.Ended = job.Started
		}
		var tasks []AzureRecord
		for _, r := range records {
			if r.ParentID == rec.ID && r.Type == "Task" {
				tasks = append(tasks, r)
			}
		}
		sort.SliceStable(tasks, func(a, b int) bool { return tasks[a].Order < tasks[b].Order })
		for i, t := range tasks {
			a, okA := since(t.StartTime)
			e, okE := since(t.FinishTime)
			if okA && okE {
				n := t.Order
				if n == 0 {
					n = i + 1
				}
				job.Steps = append(job.Steps, Step{Name: t.Name, Number: n, Started: a, Ended: e, Conclusion: AzureConclusion(t.Result)})
			}
		}
		return job
	}
	latest := 1
	for _, rec := range now.Records {
		if rec.Type != "Job" {
			continue
		}
		n := max(rec.Attempt, 1)
		latest = max(latest, n)
		r := attemptOf(n)
		job := jobOf(now.Records, rec)
		name := job.Name
		r.Jobs = append(r.Jobs, job)
		// Each earlier attempt of this job, from the timeline it is in.
		for _, p := range rec.PreviousAttempts {
			raw, ok := earlier[p.TimelineID]
			if !ok || p.Attempt < 1 || p.Attempt >= n {
				continue
			}
			var old azureTimeline
			if json.Unmarshal(raw, &old) != nil {
				continue
			}
			for _, o := range old.Records {
				if o.ID == p.RecordID && o.Type == "Job" {
					// Its own timeline's phase first; the name is the newest one's, as it is one job.
					job := jobOf(append(append([]AzureRecord{}, now.Records...), old.Records...), o)
					job.Name = name
					attemptOf(p.Attempt).Jobs = append(attemptOf(p.Attempt).Jobs, job)
				}
			}
		}
	}
	// The latest attempt is the build's: its result, its start and its end.
	last := attemptOf(latest)
	last.Conclusion = AzureConclusion(b.Result)
	if s, ok := since(b.StartTime); ok {
		last.Started = s
	}
	finished, hasFinish := since(b.FinishTime)
	var out []Run
	for n, r := range attempts {
		ended, started := 0.0, math.Inf(1)
		failed, cancelled := false, false
		for _, j := range r.Jobs {
			ended = math.Max(ended, j.Ended)
			started = math.Min(started, j.Made)
			failed = failed || j.Conclusion == "failure" || j.Conclusion == "neutral"
			cancelled = cancelled || j.Conclusion == "cancelled"
		}
		r.Ended = ended
		if n == latest && hasFinish {
			r.Ended = math.Max(ended, finished)
		}
		if n != latest && !math.IsInf(started, 1) {
			r.Started = started
		}
		if r.Conclusion == "" {
			r.Conclusion = earlierConclusion(failed, cancelled)
		}
		out = append(out, *r)
	}
	sort.Slice(out, func(a, b int) bool { return out[a].Attempt < out[b].Attempt })
	return out, nil
}

// earlierConclusion is an earlier attempt's conclusion, from its jobs': it was run again, so
// it did not pass as a whole, but its jobs say how it ended.
func earlierConclusion(failed, cancelled bool) string {
	switch {
	case failed:
		return "failure"
	case cancelled:
		return "cancelled"
	}
	return "success"
}
