package gitlabmcp

import (
	"context"
	"fmt"
	"net/url"

	"github.com/agentloops-dev/agents/Go/internal/mcpevents"
	"github.com/agentloops-dev/agents/Go/wire"
)

// GitLab's deployments as the deploy model (#5244, spec 5239-deploy-model), in the github
// server's shape (#5240): GitLab keeps a deployment for each job with an environment:, with
// one status (created, blocked, running, success, failed, canceled, skipped), so no CI change
// is needed. deploy.started, deploy.succeeded and deploy.failed are a deployment's changes of
// state, in the wire's Deploy.

// Deployments are the project's deployments updated at or after since, of environment when it
// is set, newest first: at most maxPages pages. A deployment's updated_at moves with its status.
func (g *RealGitLab) Deployments(ctx context.Context, project, environment, since string) ([]mcpevents.ForgeDeploy, Listed, error) {
	q := url.Values{"updated_after": {since}, "order_by": {"updated_at"}, "sort": {"desc"}}
	if environment != "" {
		q.Set("environment", environment)
	}
	list, listed, err := newest(ctx, g, fmt.Sprintf("projects/%s/deployments?%s", pid(project), q.Encode()), since,
		func(d deploymentJSON) string { return d.UpdatedAt })
	if err != nil {
		return nil, Listed{}, err
	}
	out := make([]mcpevents.ForgeDeploy, 0, len(list))
	for _, d := range list {
		out = append(out, d.forgeDeploy(project))
	}
	return out, listed, nil
}

// deployState is GitLab's status as the model's (spec, "Deploy states"); ok is false for
// created (the job has not started, and may yet be blocked), blocked (deploy.waiting's) and
// skipped (it never ran).
func deployState(status string) (wire.DeployState, bool) {
	switch status {
	case "running":
		return wire.DeployStateRunning, true
	case "success":
		return wire.DeployStateSucceeded, true
	case "failed":
		return wire.DeployStateFailed, true
	case "canceled":
		return wire.DeployStateCancelled, true
	}
	return "", false
}

// tierOf is GitLab's own tier of the environment, else one from its name.
func tierOf(tier, name string) wire.EnvironmentTier {
	switch t := wire.EnvironmentTier(tier); t {
	case wire.EnvironmentTierProduction, wire.EnvironmentTierStaging, wire.EnvironmentTierTesting,
		wire.EnvironmentTierDevelopment, wire.EnvironmentTierOther:
		return t
	}
	return mcpevents.TierByName(name)
}

// forgeDeploy is the deployment in the model: its job's start is deploy.started, its end the
// event of its last status. GitLab keeps only the status now, so a deployment that started and
// ended between two polls raises both, each at its own time.
func (d deploymentJSON) forgeDeploy(project string) mcpevents.ForgeDeploy {
	out := mcpevents.ForgeDeploy{System: "gitlab", Repo: project, ID: fmt.Sprint(d.ID), SHA: d.SHA, Ref: d.Ref,
		Environment: d.Environment.Name, Tier: tierOf(d.Environment.Tier, d.Environment.Name),
		EnvironmentURL: d.Environment.ExternalURL}
	started, finished := "", d.FinishedAt
	if d.Deployable != nil {
		out.URL = d.Deployable.WebURL
		started = d.Deployable.StartedAt
		if finished == "" {
			finished = d.Deployable.FinishedAt
		}
		if out.SHA == "" && d.Deployable.Pipeline != nil {
			out.SHA = d.Deployable.Pipeline.SHA
		}
	}
	state, ok := deployState(d.Status)
	if !ok {
		return out
	}
	if started == "" && state == wire.DeployStateRunning {
		started = d.UpdatedAt
	}
	if started != "" {
		out.Changes = append(out.Changes, mcpevents.DeployChange{State: wire.DeployStateRunning, RawState: "running", At: started})
	}
	if state != wire.DeployStateRunning {
		if finished == "" {
			finished = d.UpdatedAt
		}
		out.Changes = append(out.Changes, mcpevents.DeployChange{State: state, RawState: d.Status, At: finished})
	}
	return out
}

// deployEvent is one of deploy.started, deploy.succeeded and deploy.failed (#5244).
func deployEvent(name, title, description string) event {
	return mcpevents.DeployEvent(name, title, description+" deploy is the wire's Deploy: the project is its component, the environment and its tier its target, the sha its version's one artifact, named by the deployment's v* tag when it ran on one; its ref is gitlab:deploy:<project>#<deployment id>, its url the job's. Every deployment of the project, whoever started its pipeline.",
		mcpevents.DeployEventInput{Repo: projectProperty, Environment: "As production or review/my-branch.",
			TierHow:   "GitLab's own tier of the environment (deployment_tier), which GitLab guesses from the name when nobody set it.",
			Component: "on GitLab, the project, by its path or id as project names it."})
}
