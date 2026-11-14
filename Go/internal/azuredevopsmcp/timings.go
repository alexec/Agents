package azuredevopsmcp

import (
	"context"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// What the build timings read (#5222; Go/internal/citimings/azuredevops.go): a page of a
// repository's finished builds and a build's timeline, as Azure DevOps says them. The daemon
// parses them; they are not shared, as no poll asks the same page.

// TimingsOrder is how a page of builds is ordered and windowed: by when each finished (the
// live read: a build that ran long is still found when it ends) or by when each was queued
// (the backfill's windows).
type TimingsOrder string

const (
	ByFinish TimingsOrder = "finishTimeDescending"
	ByQueue  TimingsOrder = "queueTimeDescending"
)

// TimingBuilds is one page, at most perPage, of the repository's finished builds, newest first
// in order, with its time in [from, to] (either zero for no bound): the raw build/builds answer.
func (f *RealAzureDevOps) TimingBuilds(ctx context.Context, repo string, order TimingsOrder, from, to time.Time) ([]byte, error) {
	r, err := f.repository(ctx, repo)
	if err != nil {
		return nil, err
	}
	q := url.Values{"repositoryId": {r.ID}, "repositoryType": {"TfsGit"}, "statusFilter": {"completed"},
		"queryOrder": {string(order)}, "$top": {strconv.Itoa(perPage)}}
	if !from.IsZero() {
		q.Set("minTime", from.UTC().Format(time.RFC3339Nano))
	}
	if !to.IsZero() {
		q.Set("maxTime", to.UTC().Format(time.RFC3339Nano))
	}
	return f.do(ctx, http.MethodGet, api(projectPath(repo)+"build/builds", q), nil)
}

// TimingTimeline is a build's timeline, or, with timeline, the one an earlier attempt of its
// jobs is in: the raw answer.
func (f *RealAzureDevOps) TimingTimeline(ctx context.Context, repo string, build int64, timeline string) ([]byte, error) {
	path := fmt.Sprintf("%sbuild/builds/%d/timeline", projectPath(repo), build)
	if timeline != "" {
		path += "/" + url.PathEscape(timeline)
	}
	return f.do(ctx, http.MethodGet, api(path, nil), nil)
}

// DefaultBranch is the repository's default branch, with no refs/heads/.
func (f *RealAzureDevOps) DefaultBranch(ctx context.Context, repo string) (string, error) {
	r, err := f.repository(ctx, repo)
	if err != nil {
		return "", err
	}
	return strings.TrimPrefix(r.DefaultBranch, "refs/heads/"), nil
}
