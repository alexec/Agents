package bitbucketmcp

import (
	"context"
	"strings"

	"github.com/agentloops-dev/agents/Go/internal/mcpevents"
	"github.com/agentloops-dev/agents/Go/wire"
)

// Bitbucket Pipelines' deployments as the deploy model (#5244, spec 5239-deploy-model), in the
// github server's shape (#5240): a step with deployment: is one of the repository's
// deployments, with a state (UNDEPLOYED, IN_PROGRESS, COMPLETED with SUCCESSFUL, FAILED or
// STOPPED), so no CI change is needed. deploy.started, deploy.succeeded and deploy.failed are a
// deployment's changes of state, in the wire's Deploy.

// deployRecordJSON is a deployment as deploy.* read it: its state's times, its commit and its
// step's page.
type deployRecordJSON struct {
	UUID        string `json:"uuid"`
	Environment struct {
		UUID string `json:"uuid"`
	} `json:"environment"`
	Release struct {
		Commit struct {
			Hash string `json:"hash"`
		} `json:"commit"`
		URL string `json:"url"`
	} `json:"release"`
	Deployable struct {
		Commit struct {
			Hash string `json:"hash"`
		} `json:"commit"`
		URL string `json:"url"`
	} `json:"deployable"`
	State struct {
		Name   string `json:"name"`
		URL    string `json:"url"`
		Status *struct {
			Name string `json:"name"`
		} `json:"status"`
		// Bitbucket names a state's times start_date and completion_date; started_on and
		// completed_on are read too, as some answers name them.
		StartDate      string `json:"start_date"`
		StartedOn      string `json:"started_on"`
		CompletionDate string `json:"completion_date"`
		CompletedOn    string `json:"completed_on"`
	} `json:"state"`
}

// deployEnvironmentJSON is a deployment environment with its type: Test, Staging or Production.
type deployEnvironmentJSON struct {
	UUID            string `json:"uuid"`
	Name            string `json:"name"`
	EnvironmentType struct {
		Name string `json:"name"`
	} `json:"environment_type"`
}

// Deployments are the repository's newest page of deployments, in the deploy model, with their
// environments' names and tiers: two reads, the environments only when a deployment started.
func (b *RealBitbucket) Deployments(ctx context.Context, repo string) ([]mcpevents.ForgeDeploy, error) {
	var deployments paged[deployRecordJSON]
	if err := b.get(ctx, query(repoPath(repo)+"/deployments/", 1), true, &deployments); err != nil {
		return nil, err
	}
	var envs map[string]deployEnvironmentJSON
	var out []mcpevents.ForgeDeploy
	for _, d := range deployments.Values {
		changes := d.changes()
		if len(changes) == 0 {
			continue
		}
		if envs == nil {
			var list paged[deployEnvironmentJSON]
			if err := b.get(ctx, query(repoPath(repo)+"/environments/", 1), true, &list); err != nil {
				return nil, err
			}
			envs = map[string]deployEnvironmentJSON{}
			for _, e := range list.Values {
				envs[e.UUID] = e
			}
		}
		env, ok := envs[d.Environment.UUID]
		if !ok {
			continue
		}
		sha := d.Release.Commit.Hash
		if sha == "" {
			sha = d.Deployable.Commit.Hash
		}
		u := d.State.URL
		if u == "" {
			u = d.Deployable.URL
		}
		out = append(out, mcpevents.ForgeDeploy{System: "bitbucket", Repo: repo, ID: strings.Trim(d.UUID, "{}"), SHA: sha,
			Environment: env.Name, Tier: tierOf(env.EnvironmentType.Name, env.Name), URL: u, Changes: changes})
	}
	return out, nil
}

// tierOf is the environment's type as a tier (Bitbucket's three), else one from its name.
func tierOf(kind, name string) wire.EnvironmentTier {
	switch strings.ToLower(kind) {
	case "production":
		return wire.EnvironmentTierProduction
	case "staging":
		return wire.EnvironmentTierStaging
	case "test":
		return wire.EnvironmentTierTesting
	}
	return mcpevents.TierByName(name)
}

func firstOf(a, b string) string {
	if a != "" {
		return a
	}
	return b
}

// changes are the deployment's changes of state (spec, "Deploy states"): IN_PROGRESS is running,
// COMPLETED is succeeded (SUCCESSFUL), failed (FAILED) or cancelled (STOPPED). UNDEPLOYED is a
// step that has not run, and is none. Bitbucket keeps only the state now, so a deployment that
// started and ended between two polls raises both, each at its own time.
func (d deployRecordJSON) changes() []mcpevents.DeployChange {
	started, finished := firstOf(d.State.StartDate, d.State.StartedOn), firstOf(d.State.CompletionDate, d.State.CompletedOn)
	var out []mcpevents.DeployChange
	if (d.State.Name == "IN_PROGRESS" || d.State.Name == "COMPLETED") && started != "" {
		out = append(out, mcpevents.DeployChange{State: wire.DeployStateRunning, RawState: "IN_PROGRESS", At: started})
	}
	if d.State.Name != "COMPLETED" || d.State.Status == nil || finished == "" {
		return out
	}
	var state wire.DeployState
	switch d.State.Status.Name {
	case "SUCCESSFUL":
		state = wire.DeployStateSucceeded
	case "FAILED":
		state = wire.DeployStateFailed
	case "STOPPED":
		state = wire.DeployStateCancelled
	default:
		return out
	}
	return append(out, mcpevents.DeployChange{State: state, RawState: d.State.Status.Name, At: finished})
}

// deployEvent is one of deploy.started, deploy.succeeded and deploy.failed (#5244).
func deployEvent(name, title, description string) event {
	return mcpevents.DeployEvent(name, title, description+" deploy is the wire's Deploy: the repository is its component, the environment and its type its target, the commit its version's one artifact; its ref is bitbucket:deploy:<workspace/name>#<deployment uuid>, its url the step's. Every deployment of the repository, whoever started its run.",
		mcpevents.DeployEventInput{Repo: repoProperty, Environment: "As Production or Staging, in any case.",
			TierHow:   "The environment's type in Bitbucket: Test is testing, Staging staging, Production production.",
			Component: "on Bitbucket, the repository, workspace/name."})
}
