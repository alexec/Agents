package forgejomcp

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"

	"github.com/agentloops-dev/agent-loops/Go/internal/mcpevents"
)

// failed_log (#3761, decided in #3754): the end of each failed job's log in a Forgejo Actions
// run, as the bitbucket server's (Go/internal/bitbucketmcp/logs.go) gives a failed step's, so
// Fix failed checks works on Forgejo and Gitea too. A run is named by its number, the one in
// its page's address (…/actions/runs/12) and run.id in a checks.failed event.
//
// Forgejo 16 has the routes (a run by its number, its jobs, a job's log), and Forgejo 17 also
// a job's steps and one step's log, so the failed step's is given. Gitea 1.24 has a job's log
// but no list of a run's jobs, so no job's id to read it by: Gitea needs 1.25. Forgejo 11 LTS
// has neither, and the tool says which version it needs.

// logLines is how much of each failed job's log is given: its end, where the failure is.
const logLines = 300

// logBytes is how much of a log's end is asked for: the logs take a Range, and a log can be
// tens of MB.
const logBytes = 4 << 20

// The versions with the routes failed_log reads.
const (
	forgejoLogs     = 16
	forgejoStepLogs = 17
	giteaLogs       = 25 // 1.25
)

var (
	escapes  = regexp.MustCompile("\x1b\\[[0-9;?]*[ -/]*[@-~]|\x1b\\][^\x07\x1b]*(\x07|\x1b\\\\)")
	controls = regexp.MustCompile("[\x00-\x08\x0b-\x1f\x7f]")
	// stamp is the time the runner puts before each line: 2026-11-07T11:34:20.0294070Z.
	stamp = regexp.MustCompile(`^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z ?`)
	// numbers are a version's first numbers: 17.0.1+gitea-1.22.0, 1.25.5.
	numbers = regexp.MustCompile(`^v?([0-9]+)(?:\.([0-9]+))?`)
)

// plain is a log's line without its time, terminal escapes or other control characters.
func plain(text string) string {
	return stamp.ReplaceAllString(controls.ReplaceAllString(escapes.ReplaceAllString(text, ""), ""), "")
}

// logTail is the last n lines of a log as it is read, cleaned, without the trailing lines
// that are nothing once cleaned; with partial, the first line is dropped, as it is the end of
// one the range cut (mcpevents.LogTail).
func logTail(r io.Reader, n int, partial bool) (string, error) {
	tail, err := mcpevents.LogTail(r, n, partial, plain)
	if err != nil {
		return "", &ForgejoError{Kind: Failed, Message: "Forgejo: " + err.Error()}
	}
	return tail, nil
}

// forge is which server and version answers: Forgejo's version is 17.0.1+gitea-1.22.0,
// Gitea's 1.25.5. known is false for a version that is neither, such as a build of its own.
type forge struct {
	version      string
	forgejo      bool
	major, minor int
	known        bool
}

func forgeOf(version string) forge {
	s := forge{version: version, forgejo: strings.Contains(version, "+gitea-")}
	m := numbers.FindStringSubmatch(version)
	if m == nil {
		return s
	}
	s.major, _ = strconv.Atoi(m[1])
	s.minor, _ = strconv.Atoi(m[2])
	s.known = s.forgejo || s.major == 1
	return s
}

// noLogs is why this server cannot give a job's log, or "" when it can (or may).
func (s forge) noLogs() string {
	switch {
	case !s.known:
		return ""
	case s.forgejo && s.major < forgejoLogs:
		return fmt.Sprintf("Forgejo %s has no API for an Actions job's log: failed_log needs Forgejo %d or later", s.version, forgejoLogs)
	case !s.forgejo && s.minor < giteaLogs:
		return fmt.Sprintf("Gitea %s has no API that lists an Actions run's jobs: failed_log needs Gitea 1.%d or later", s.version, giteaLogs)
	}
	return ""
}

// steps says whether a job's steps can be read, and one step's log: Forgejo 17.
func (s forge) steps() bool { return s.forgejo && s.major >= forgejoStepLogs }

type runJSON struct {
	ID int `json:"id"`
	// RunNumber is Gitea's number for the run, IndexInRepo Forgejo's.
	RunNumber   int `json:"run_number"`
	IndexInRepo int `json:"index_in_repo"`
}

func (r runJSON) number() int { return max(r.RunNumber, r.IndexInRepo) }

type jobJSON struct {
	ID      int    `json:"id"`
	Name    string `json:"name"`
	Status  string `json:"status"`
	HTMLURL string `json:"html_url"`
	// Conclusion is Gitea's: its status is completed, and this says how.
	Conclusion string `json:"conclusion"`
	Steps      []struct {
		Number int    `json:"number"`
		Name   string `json:"name"`
		Status string `json:"status"`
	} `json:"steps"`
}

func (j jobJSON) failed() bool { return j.Status == "failure" || j.Conclusion == "failure" }

// FailedLog is the end of each failed job's log in the Actions run with number run, or of
// one job by name.
func (f *RealForgejo) FailedLog(ctx context.Context, repo string, run int, job string) (string, error) {
	page := fmt.Sprintf("%s%s/actions/runs/%d", f.Base, repo, run)
	var v struct {
		Version string `json:"version"`
	}
	if err := f.get(ctx, "version", true, &v); err != nil {
		return "", err
	}
	srv := forgeOf(v.Version)
	if why := srv.noLogs(); why != "" {
		return "", &ForgejoError{Kind: Failed, Message: fmt.Sprintf("%s. The run is at %s.", why, page)}
	}
	id, err := f.runID(ctx, repo, run)
	if err != nil {
		return "", err
	}
	if id == 0 {
		return "", &ForgejoError{Kind: NotFound, Message: fmt.Sprintf("%s has no Actions run %d", repo, run)}
	}
	jobs, err := f.runJobs(ctx, repo, id)
	if err != nil {
		return "", err
	}
	var parts []string
	for _, j := range jobs {
		if !j.failed() || (job != "" && j.Name != job) {
			continue
		}
		logs := fmt.Sprintf("%s/actions/jobs/%d/logs", repoPath(repo), j.ID)
		name, end := j.Name, ""
		if srv.steps() {
			if s, ok := f.failedStep(ctx, repo, j.ID); ok {
				if end, err = f.jobLog(ctx, logs+"?step="+strconv.Itoa(s.number)); err != nil {
					return "", err
				}
				if strings.TrimSpace(end) != "" {
					name += " ▸ " + s.name
				}
			}
		}
		// A step that failed with nothing to say: the whole job's log says what ran before it.
		if strings.TrimSpace(end) == "" {
			if end, err = f.jobLog(ctx, logs); err != nil {
				return "", err
			}
		}
		url := j.HTMLURL
		if url == "" {
			url = page
		}
		parts = append(parts, fmt.Sprintf("== %s (%s), last %d lines ==\n%s", name, url, logLines, end))
	}
	if len(parts) == 0 {
		if job != "" {
			return fmt.Sprintf("No failed job %q in run %d (%s).", job, run, page), nil
		}
		return fmt.Sprintf("No failed jobs in run %d (%s).", run, page), nil
	}
	return strings.Join(parts, "\n\n"), nil
}

// runID is the id of the run with number run, or 0: Forgejo finds it by run_number, and Gitea,
// which has no such filter, lists its runs newest first, so the pages stop at an older run.
func (f *RealForgejo) runID(ctx context.Context, repo string, run int) (int, error) {
	for p := 1; p <= maxPages; p++ {
		var list struct {
			Runs []runJSON `json:"workflow_runs"`
		}
		if err := f.get(ctx, query(fmt.Sprintf("%s/actions/runs?run_number=%d", repoPath(repo), run), p), false, &list); err != nil {
			return 0, err
		}
		for _, r := range list.Runs {
			if r.number() == run {
				return r.ID, nil
			}
			if r.number() < run {
				return 0, nil
			}
		}
		if len(list.Runs) < perPage {
			return 0, nil
		}
	}
	return 0, nil
}

// runJobs are a run's jobs: Forgejo answers a list, Gitea {"jobs": […]}.
func (f *RealForgejo) runJobs(ctx context.Context, repo string, id int) ([]jobJSON, error) {
	var raw json.RawMessage
	if err := f.get(ctx, fmt.Sprintf("%s/actions/runs/%d/jobs?limit=%d", repoPath(repo), id, perPage), false, &raw); err != nil {
		return nil, err
	}
	var jobs []jobJSON
	if json.Unmarshal(raw, &jobs) == nil {
		return jobs, nil
	}
	var wrapped struct {
		Jobs []jobJSON `json:"jobs"`
	}
	if json.Unmarshal(raw, &wrapped) != nil {
		return nil, &ForgejoError{Kind: Failed, Message: "Forgejo's answer is not a list of jobs"}
	}
	return wrapped.Jobs, nil
}

type step struct {
	number int
	name   string
}

// failedStep is a job's first failed step, from Forgejo 17's job.
func (f *RealForgejo) failedStep(ctx context.Context, repo string, job int) (step, bool) {
	var j jobJSON
	if f.get(ctx, fmt.Sprintf("%s/actions/jobs/%d", repoPath(repo), job), false, &j) != nil {
		return step{}, false
	}
	for _, s := range j.Steps {
		if s.Status == "failure" {
			return step{s.Number, s.Name}, true
		}
	}
	return step{}, false
}

// jobLog is the end of a job's log, read as it comes: only its last logBytes are asked for.
func (f *RealForgejo) jobLog(ctx context.Context, path string) (string, error) {
	res, err := f.request(ctx, http.MethodGet, path, nil,
		http.Header{"Accept": {"text/plain"}, "Range": {fmt.Sprintf("bytes=-%d", logBytes)}})
	if err != nil {
		return "", err
	}
	defer res.Body.Close()
	switch {
	case res.StatusCode == http.StatusRequestedRangeNotSatisfiable:
		return "", nil // an empty log
	case res.StatusCode == http.StatusNotFound:
		return "(no log)", nil
	case res.StatusCode < 200 || res.StatusCode >= 300:
		data, _ := io.ReadAll(io.LimitReader(res.Body, 64<<10))
		return "", failure(res, data)
	}
	partial := res.StatusCode == http.StatusPartialContent && !strings.HasPrefix(res.Header.Get("Content-Range"), "bytes 0-")
	return logTail(res.Body, logLines, partial)
}
