package agentsd

import (
	"context"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/agentloops-dev/agents/Go/internal/azuredevopsmcp"
	"github.com/agentloops-dev/agents/Go/wire"
)

// ciFakeAzure is an Azure DevOps with three finished builds: one on main whose job was run
// again (attempt 2; attempt 1 failed), one of a pull request, and one of a pull request older
// than the steps bound.
type ciFakeAzure struct {
	*fakeForgeAzureDevOps
	t   *testing.T
	now time.Time

	mu        sync.Mutex
	lists     []azuredevopsmcp.TimingsOrder
	timelines []string
}

func (f *ciFakeAzure) at(d time.Duration) string { return f.now.Add(d).UTC().Format(time.RFC3339Nano) }

func (f *ciFakeAzure) DefaultBranch(context.Context, string) (string, error) { return "main", nil }

func (f *ciFakeAzure) TimingBuilds(_ context.Context, repo string, order azuredevopsmcp.TimingsOrder, _, _ time.Time) ([]byte, error) {
	f.mu.Lock()
	f.lists = append(f.lists, order)
	f.mu.Unlock()
	if repo != "acme/Web App/App" {
		f.t.Errorf("listed %q", repo)
	}
	if order == azuredevopsmcp.ByQueue {
		// The backfill's windows: nothing older.
		return []byte(`{"count":0,"value":[]}`), nil
	}
	build := func(id int, reason, branch, extra string, queued, finished time.Duration) string {
		return fmt.Sprintf(`{"id":%d,"status":"completed","result":"succeeded","queueTime":%q,"startTime":%q,"finishTime":%q,
		 "sourceBranch":%q,"sourceVersion":"sha%d","reason":%q,"definition":{"name":"CI"},"queue":{"name":"Default","pool":{"name":"Azure Pipelines"}},
		 "_links":{"web":{"href":"https://dev.azure.com/acme/Web%%20App/_build/results?buildId=%d"}}%s}`,
			id, f.at(queued), f.at(queued+5*time.Second), f.at(finished), branch, id, reason, id, extra)
	}
	return []byte(`{"count":3,"value":[` +
		build(71, "pullRequest", "refs/pull/7/merge", `,"triggerInfo":{"pr.number":"7","pr.sourceSha":"head7"}`, -30*time.Minute, -20*time.Minute) + "," +
		build(70, "individualCI", "refs/heads/main", "", -2*time.Hour, -50*time.Minute) + "," +
		build(72, "pullRequest", "refs/pull/6/merge", `,"triggerInfo":{"pr.number":"6"}`, -20*24*time.Hour, -20*24*time.Hour+10*time.Minute) +
		`]}`), nil
}

func (f *ciFakeAzure) TimingTimeline(_ context.Context, _ string, build int64, timeline string) ([]byte, error) {
	f.mu.Lock()
	f.timelines = append(f.timelines, fmt.Sprintf("%d/%s", build, timeline))
	f.mu.Unlock()
	job := func(id, phase string, attempt int, result string, from time.Duration, previous string) string {
		return fmt.Sprintf(`{"id":"phase-%[1]s","parentId":"stage","type":"Phase","name":"Build","startTime":%[3]q},
		 {"id":%[1]q,"parentId":"phase-%[1]s","type":"Job","name":"Build","attempt":%[2]d,"result":%[6]q,"startTime":%[4]q,"finishTime":%[5]q,"previousAttempts":[%[7]s]},
		 {"id":"task-%[1]s","parentId":%[1]q,"type":"Task","name":"Test","order":3,"result":%[6]q,"startTime":%[4]q,"finishTime":%[5]q},
		 {"id":"skipped-%[1]s","parentId":%[1]q,"type":"Task","name":"Publish","order":4,"result":"skipped"}`,
			id, attempt, f.at(from), f.at(from+10*time.Second), f.at(from+5*time.Minute), result, previous)
	}
	stage := `{"id":"stage","type":"Stage","name":"__default"},`
	switch {
	case build == 70 && timeline == "":
		return []byte(`{"records":[` + stage + job("job-2", "", 2, "succeeded", -time.Hour, `{"attempt":1,"timelineId":"tl-1","recordId":"job-1"}`) + `]}`), nil
	case build == 70 && timeline == "tl-1":
		return []byte(`{"records":[` + stage + job("job-1", "", 1, "failed", -2*time.Hour+10*time.Second, "") + `]}`), nil
	case build == 71 && timeline == "":
		return []byte(`{"records":[` + stage + job("job-p", "", 1, "succeeded", -30*time.Minute+10*time.Second, "") + `]}`), nil
	}
	f.t.Errorf("read the timeline %d/%s", build, timeline)
	return nil, fmt.Errorf("no timeline")
}

func TestCITimingsReadAzureDevOps(t *testing.T) {
	d, _, ado, _ := azureDevOpsDaemon(t)
	now := time.Now().UTC().Truncate(time.Second)
	fake := &ciFakeAzure{fakeForgeAzureDevOps: ado, t: t, now: now}
	d.newForgeAzureDevOps = func(string, string) forgeAzureDevOps { return fake }

	var h ciRepoHere
	for _, here := range d.ciReposHere(context.Background()) {
		if here.repo.forge == "azuredevops" {
			h = here
		}
	}
	if h.repo.path != "acme/web app/app" {
		t.Fatalf("the Azure DevOps folder is not read: %+v", d.ciReposHere(context.Background()))
	}
	if err := d.readCIRepo(context.Background(), h); err != nil {
		t.Fatal(err)
	}
	fake.mu.Lock()
	read := len(fake.timelines)
	fake.mu.Unlock()
	if read != 3 {
		t.Fatalf("timelines read %v, want 70, its attempt 1, and 71", fake.timelines)
	}
	// A second read asks for the list again, and for no timeline it has.
	if err := d.readCIRepo(context.Background(), h); err != nil {
		t.Fatal(err)
	}
	if fake.mu.Lock(); len(fake.timelines) != read {
		t.Fatalf("the second read read timelines again: %v", fake.timelines)
	}
	fake.mu.Unlock()

	repo := "azuredevops:acme/web app/app"
	hist, err := d.buildsHistory(wire.BuildsHistoryRequest{Repo: repo, From: wire.DateOf(now.Add(-24 * time.Hour)), To: wire.DateOf(now.Add(time.Hour))})
	if err != nil {
		t.Fatal(err)
	}
	if hist.Reader != "azuredevops" || hist.DefaultBranch == nil || *hist.DefaultBranch != "main" || hist.ReadAt == nil {
		t.Fatalf("history %+v", hist)
	}
	// Main's first attempt (failed) counts; its second is a re-run, out of the times.
	if hist.Total.Runs != 1 || hist.Total.Reruns != 1 || hist.Total.Green != 0 {
		t.Fatalf("total %+v", hist.Total)
	}
	if len(hist.Workflows) != 1 || hist.Workflows[0] != "CI" || len(hist.Jobs) != 1 || hist.Jobs[0] != "Build" {
		t.Fatalf("names %+v %+v", hist.Workflows, hist.Jobs)
	}
	prs, err := d.buildsHistory(wire.BuildsHistoryRequest{Repo: repo, PullRequests: new(true),
		From: wire.DateOf(now.Add(-24 * time.Hour)), To: wire.DateOf(now.Add(time.Hour))})
	// The job's phase starts 10 s after the build is queued, an agent takes it 10 s later, and
	// it runs 4 min 50 s.
	if err != nil || prs.Total.Green != 1 || prs.Total.Run.Median != 290 || prs.Total.Runner.Median != 10 {
		t.Fatalf("PRs %+v %v", prs.Total, err)
	}

	got, err := d.buildsRun(wire.BuildsRunRequest{Repo: repo, Ref: "azuredevops:run:acme/web app/app#71"})
	if err != nil {
		t.Fatal(err)
	}
	j := got.Run.Jobs
	if got.Run.Pr == nil || *got.Run.Pr != 7 || got.Run.HeadSha == nil || *got.Run.HeadSha != "head7" || len(j) != 1 ||
		len(j[0].Steps) != 1 || j[0].Steps[0].Number != 3 || j[0].Runner == nil || *j[0].Runner != "Azure Pipelines" {
		t.Fatalf("run %+v", got.Run)
	}
	first, err := d.buildsRun(wire.BuildsRunRequest{Repo: repo, Ref: "azuredevops:run:acme/web app/app#70"})
	if err != nil || first.Attempts != 2 || first.Run.Conclusion == nil || *first.Run.Conclusion != "failure" || first.Run.Default == nil {
		t.Fatalf("attempt 1: %+v %v", first, err)
	}
}
