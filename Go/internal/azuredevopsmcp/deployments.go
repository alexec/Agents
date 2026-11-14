package azuredevopsmcp

import (
	"context"
	"fmt"
	"net/url"
	"strconv"

	"github.com/agentloops-dev/agents/Go/internal/mcpevents"
	"github.com/agentloops-dev/agents/Go/wire"
)

// Azure Pipelines environments' deployment records as the deploy model (#5244, spec
// 5239-deploy-model), in the github server's shape (#5240): a deployment job with an
// environment: leaves a record in that environment, with its build, start, finish and result,
// so no CI change is needed. deploy.started, deploy.succeeded and deploy.failed are a record's
// changes of state, in the wire's Deploy.

const (
	// mostEnvironments bounds the environments one read lists, and mostRecords the records read
	// of each: one page, the newest first.
	mostEnvironments = 20
	mostRecords      = 25
)

// DeployRecord is one deployment record of an environment: its build (owner), which says the
// repository and commit, and the pipeline (definition) and stage that deployed.
type DeployRecord struct {
	ID                     int
	Environment            string
	Build                  int
	Pipeline, Stage, Job   string
	Result                 string
	Started, Finished, URL string
}

type environmentJSON struct {
	ID   int    `json:"id"`
	Name string `json:"name"`
}

type deployRecordJSON struct {
	ID         int    `json:"id"`
	PlanType   string `json:"planType"`
	StageName  string `json:"stageName"`
	JobName    string `json:"jobName"`
	Result     string `json:"result"`
	StartTime  string `json:"startTime"`
	FinishTime string `json:"finishTime"`
	Definition struct {
		Name string `json:"name"`
	} `json:"definition"`
	Owner struct {
		ID    int `json:"id"`
		Links struct {
			Web struct {
				Href string `json:"href"`
			} `json:"web"`
		} `json:"_links"`
	} `json:"owner"`
}

// DeployRecords are the newest deployment records of the project's environments (only
// environment's when it is set): one page of environments, and one page of each one's records.
// The project's, of every repository: deploy.* keeps the repo's by each record's build.
func (f *RealAzureDevOps) DeployRecords(ctx context.Context, repo, environment string) ([]DeployRecord, error) {
	q := url.Values{"$top": {strconv.Itoa(mostEnvironments)}}
	if environment != "" {
		q.Set("name", environment)
	}
	var envs struct {
		Value []environmentJSON `json:"value"`
	}
	if err := f.get(ctx, api(projectPath(repo)+"distributedtask/environments", q), true, &envs); err != nil {
		return nil, err
	}
	var out []DeployRecord
	for _, e := range envs.Value {
		var records struct {
			Value []deployRecordJSON `json:"value"`
		}
		path := fmt.Sprintf("%sdistributedtask/environments/%d/environmentdeploymentrecords", projectPath(repo), e.ID)
		if err := f.get(ctx, api(path, url.Values{"top": {strconv.Itoa(mostRecords)}}), true, &records); err != nil {
			return nil, err
		}
		for _, r := range records.Value {
			if r.PlanType != "" && r.PlanType != "Build" || r.Owner.ID == 0 {
				continue
			}
			out = append(out, DeployRecord{ID: r.ID, Environment: e.Name, Build: r.Owner.ID, Pipeline: r.Definition.Name,
				Stage: r.StageName, Job: r.JobName, Result: r.Result, Started: r.StartTime, Finished: r.FinishTime, URL: r.Owner.Links.Web.Href})
		}
	}
	return out, nil
}

// DeployBuild is a record's build: whether it is of repo, its commit and its branch or tag.
func (f *RealAzureDevOps) DeployBuild(ctx context.Context, repo string, build int) (ours bool, sha, ref string, err error) {
	r, err := f.repository(ctx, repo)
	if err != nil {
		return false, "", "", err
	}
	var b buildJSON
	if err := f.get(ctx, api(fmt.Sprintf("%sbuild/builds/%d", projectPath(repo), build), nil), true, &b); err != nil {
		return false, "", "", err
	}
	return b.Repository.ID == r.ID, b.SourceVer, b.ref(), nil
}

// deployResult is a record's result as the model's (spec, "Deploy states"): succeeded (and
// succeededWithIssues), failed, canceled; ok is false for skipped and abandoned, which never
// deployed.
func deployResult(result string) (wire.DeployState, bool) {
	switch result {
	case "succeeded", "succeededWithIssues":
		return wire.DeployStateSucceeded, true
	case "failed":
		return wire.DeployStateFailed, true
	case "canceled":
		return wire.DeployStateCancelled, true
	}
	return "", false
}

// forgeDeploy is the record in the model, with no commit yet: its start is deploy.started, its
// result the event of its end. The pipeline and stage that deployed are its target's labels.
func (r DeployRecord) forgeDeploy(repo string) mcpevents.ForgeDeploy {
	out := mcpevents.ForgeDeploy{System: "azuredevops", Repo: repo, ID: fmt.Sprint(r.ID), Environment: r.Environment,
		Tier: mcpevents.TierByName(r.Environment), URL: r.URL, Labels: map[string]string{}}
	if r.Pipeline != "" {
		out.Labels["pipeline"] = r.Pipeline
	}
	if r.Stage != "" {
		out.Labels["stage"] = r.Stage
	}
	if r.Started != "" {
		out.Changes = append(out.Changes, mcpevents.DeployChange{State: wire.DeployStateRunning, RawState: "inProgress", At: r.Started})
	}
	if state, ok := deployResult(r.Result); ok && r.Finished != "" {
		out.Changes = append(out.Changes, mcpevents.DeployChange{State: state, RawState: r.Result, At: r.Finished})
	}
	return out
}

// deployCandidates are deploy.*'s candidates: the records the filter wants, each one's build
// read only once its event is taken, and skipped when the build is of another repository.
func deployCandidates(ctx context.Context, f AzureDevOps, name string, a args) ([]candidate, error) {
	records, err := f.DeployRecords(ctx, a.repo, a.deploy.Environment)
	if err != nil {
		return nil, err
	}
	deploys := make([]mcpevents.ForgeDeploy, len(records))
	for i, r := range records {
		deploys[i] = r.forgeDeploy(a.repo)
		deploys[i].Complete = func(d *mcpevents.ForgeDeploy) (bool, error) {
			ours, sha, ref, err := f.DeployBuild(ctx, a.repo, r.Build)
			d.SHA, d.Ref = sha, ref
			return ours, err
		}
	}
	return mcpevents.DeployCandidates(name, a.deploy, deploys), nil
}

// deployEvent is one of deploy.started, deploy.succeeded and deploy.failed (#5244).
func deployEvent(name, title, description string) event {
	return mcpevents.DeployEvent(name, title, description+" deploy is the wire's Deploy: the repository is its component, the environment its target, with the pipeline and stage that deployed as the target's labels, the build's commit its version's one artifact, named by its v* tag when it ran on one; its ref is azuredevops:deploy:<organization/project/name>#<record id>, its url the build's. Every deployment record of the project's environments whose build is of this repository, whoever started it.",
		mcpevents.DeployEventInput{Repo: repoProperty, Environment: "As production; an Azure Pipelines environment of the project.",
			TierHow:   "Azure DevOps has no tier: production or prod is production, staging, testing and development come from the name, anything else is other.",
			Component: "on Azure DevOps, the repository, organization/project/name."})
}
