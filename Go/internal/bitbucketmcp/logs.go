package bitbucketmcp

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"

	"github.com/agentloops-dev/agent-loops/Go/internal/mcpevents"
)

// failed_log (#3787): the end of each failed step's log in a Pipelines run, as the gitlab
// server's (Go/internal/gitlabmcp/pages.go) gives a failed job's, so Fix failed checks works
// on Bitbucket too. A run is named by its build number, run.id in a checks.failed event.

// logLines is how much of each failed step's log is given: its end, where the failure is.
const logLines = 300

// logBytes is how much of a log's end is asked for: Bitbucket's logs take a Range, and a
// log can be tens of MB.
const logBytes = 4 << 20

var (
	escapes  = regexp.MustCompile("\x1b\\[[0-9;?]*[ -/]*[@-~]|\x1b\\][^\x07\x1b]*(\x07|\x1b\\\\)")
	controls = regexp.MustCompile("[\x00-\x08\x0b-\x1f\x7f]")
)

// plain is text without terminal escapes or other control characters, tabs and newlines kept.
func plain(text string) string {
	return controls.ReplaceAllString(escapes.ReplaceAllString(text, ""), "")
}

// logTail is the last n lines of a log as it is read, cleaned, without the trailing lines
// that are nothing once cleaned; with partial, the first line is dropped, as it is the end of
// one the range cut (mcpevents.LogTail).
func logTail(r io.Reader, n int, partial bool) (string, error) {
	tail, err := mcpevents.LogTail(r, n, partial, plain)
	if err != nil {
		return "", &BitbucketError{Kind: Failed, Message: "Bitbucket: " + err.Error()}
	}
	return tail, nil
}

type stepJSON struct {
	UUID  string `json:"uuid"`
	Name  string `json:"name"`
	State struct {
		Name   string `json:"name"`
		Result struct {
			Name string `json:"name"`
		} `json:"result"`
	} `json:"state"`
}

// failed says whether a step ended in failure: FAILED, or ERROR (Pipelines' own fault).
func (s stepJSON) failed() bool {
	return s.State.Name == "COMPLETED" && (s.State.Result.Name == "FAILED" || s.State.Result.Name == "ERROR")
}

// FailedLog is the end of each failed step's log in the Pipelines run with build number run,
// or of one step by name.
func (b *RealBitbucket) FailedLog(ctx context.Context, repo string, run int, step string) (string, error) {
	pipeline := fmt.Sprintf("%s/pipelines/%d", repoPath(repo), run)
	steps, _, err := all[stepJSON](ctx, b, pipeline+"/steps", false)
	if err != nil {
		return "", err
	}
	page := fmt.Sprintf("https://%s/%s/pipelines/results/%d", Host, repo, run)
	var parts []string
	for i, s := range steps {
		if !s.failed() || (step != "" && s.Name != step) {
			continue
		}
		name := s.Name
		if name == "" {
			name = "step " + strconv.Itoa(i+1)
		}
		end, err := b.stepLog(ctx, pipeline, s.UUID)
		if err != nil {
			return "", err
		}
		parts = append(parts, fmt.Sprintf("== %s (%s/steps/%s), last %d lines ==\n%s", name, page, s.UUID, logLines, end))
	}
	if len(parts) == 0 {
		return fmt.Sprintf("No failed steps in pipeline %d.", run), nil
	}
	return strings.Join(parts, "\n\n"), nil
}

// stepLog is the end of a step's log, read as it comes: only its last logBytes are asked for.
func (b *RealBitbucket) stepLog(ctx context.Context, pipeline, step string) (string, error) {
	res, err := b.request(ctx, http.MethodGet, pipeline+"/steps/"+url.PathEscape(step)+"/log", nil,
		http.Header{"Accept": {"application/octet-stream"}, "Range": {fmt.Sprintf("bytes=-%d", logBytes)}})
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
