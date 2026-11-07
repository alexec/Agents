package forgejomcp

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strings"
)

// retry_pipeline (#3842): a Forgejo Actions run's failed jobs run again, as the gitlab
// server's retry_pipeline (Go/internal/gitlabmcp/pages.go) retries a pipeline's. The run is
// named by its number, as for failed_log.
//
// Forgejo 17 reruns one job and the jobs that need it (POST actions/jobs/{id}/rerun), so each
// failed job is sent; a job that needs an earlier one is already waiting again, and Forgejo
// answers 400 for it. Gitea 1.26 reruns a run's failed jobs in one call (POST
// actions/runs/{id}/rerun-failed-jobs). Forgejo 16 and Gitea 1.25 have no rerun in their API.

// The versions with a rerun.
const (
	forgejoRerun = 17
	giteaRerun   = 26 // 1.26
)

// noRerun is why this server cannot run a job again, or "" when it can (or may).
func (s forge) noRerun() string {
	switch {
	case !s.known:
		return ""
	case s.forgejo && s.major < forgejoRerun:
		return fmt.Sprintf("Forgejo %s has no API that runs an Actions job again: retry_pipeline needs Forgejo %d or later", s.version, forgejoRerun)
	case !s.forgejo && s.minor < giteaRerun:
		return fmt.Sprintf("Gitea %s has no API that runs an Actions job again: retry_pipeline needs Gitea 1.%d or later", s.version, giteaRerun)
	}
	return ""
}

// RetryRun runs the failed jobs of the Actions run with number run again.
func (f *RealForgejo) RetryRun(ctx context.Context, repo string, run int) (map[string]any, error) {
	page := fmt.Sprintf("%s%s/actions/runs/%d", f.Base, repo, run)
	var v struct {
		Version string `json:"version"`
	}
	if err := f.get(ctx, "version", true, &v); err != nil {
		return nil, err
	}
	srv := forgeOf(v.Version)
	if why := srv.noRerun(); why != "" {
		return nil, &ForgejoError{Kind: Failed, Message: fmt.Sprintf("%s. Run it again from %s.", why, page)}
	}
	id, err := f.runID(ctx, repo, run)
	if err != nil {
		return nil, err
	}
	if id == 0 {
		return nil, &ForgejoError{Kind: NotFound, Message: fmt.Sprintf("%s has no Actions run %d", repo, run)}
	}
	jobs, err := f.runJobs(ctx, repo, id)
	if err != nil {
		return nil, err
	}
	names := []string{}
	var failedJobs []jobJSON
	for _, j := range jobs {
		if j.failed() {
			failedJobs = append(failedJobs, j)
			names = append(names, j.Name)
		}
	}
	if len(failedJobs) == 0 {
		return nil, &ForgejoError{Kind: Failed, Message: fmt.Sprintf("run %d has no failed jobs (%s)", run, page)}
	}
	if srv.forgejo || !srv.known {
		for i, j := range failedJobs {
			err := f.send(ctx, http.MethodPost, fmt.Sprintf("%s/actions/jobs/%d/rerun", repoPath(repo), j.ID), nil, nil)
			// A job that needs one sent before it is waiting again already.
			var fe *ForgejoError
			if err != nil && (i == 0 || !errors.As(err, &fe) || !strings.HasPrefix(fe.Message, "Forgejo: HTTP 400")) {
				return nil, err
			}
		}
	} else if err := f.send(ctx, http.MethodPost, fmt.Sprintf("%s/actions/runs/%d/rerun-failed-jobs", repoPath(repo), id), nil, nil); err != nil {
		return nil, err
	}
	return map[string]any{"retried": true, "runId": run, "jobs": names, "url": page}, nil
}
