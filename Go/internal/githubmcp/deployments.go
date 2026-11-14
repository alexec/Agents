package githubmcp

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"regexp"
	"strconv"
	"strings"

	"github.com/agentloops-dev/agents/Go/internal/mcpevents"
	"github.com/agentloops-dev/agents/Go/wire"
)

// GitHub's Deployments as the deploy model (#5240, spec 5239-deploy-model): GitHub records a
// Deployment for each job with environment:, and a status for each step of it (waiting, queued,
// in_progress, success or failure, then inactive), so no CI change is needed. deploy.started,
// deploy.succeeded and deploy.failed are a Deployment's state changes, in the wire's Deploy.

const (
	// mostDeployments bounds the Deployments one read lists: one page, the newest made first.
	mostDeployments = 50
	// mostStatuses bounds the statuses read of one Deployment: one page.
	mostStatuses = 100
)

// DeploymentStatus is one status of a Deployment: GitHub's state, when, the job's url
// (target_url) and the environment's url, when the status says one.
type DeploymentStatus struct {
	ID             int64
	State          string
	At             string
	URL            string
	EnvironmentURL string
}

// Deployment is one GitHub Deployment and its statuses, oldest first. Ref is the branch or tag
// it was made for; Production and Transient are GitHub's production_environment and
// transient_environment.
type Deployment struct {
	ID                    int64
	SHA, Ref, Environment string
	Production, Transient bool
	Created, Updated      string
	Statuses              []DeploymentStatus
}

type deploymentJSON struct {
	ID          int64  `json:"id"`
	SHA         string `json:"sha"`
	Ref         string `json:"ref"`
	Environment string `json:"environment"`
	Production  bool   `json:"production_environment"`
	Transient   bool   `json:"transient_environment"`
	CreatedAt   string `json:"created_at"`
	UpdatedAt   string `json:"updated_at"`
}

type deploymentStatusJSON struct {
	ID             int64  `json:"id"`
	State          string `json:"state"`
	CreatedAt      string `json:"created_at"`
	TargetURL      string `json:"target_url"`
	LogURL         string `json:"log_url"`
	EnvironmentURL string `json:"environment_url"`
}

// Deployments are the repo's Deployments updated at or after since, of environment when it is
// set, with their statuses: one page of the newest made, and the statuses of only those that
// changed since. A Deployment's updated_at moves with each new status.
func (g *RealGitHub) Deployments(ctx context.Context, repo, environment, since string) ([]Deployment, error) {
	if _, _, err := ownerName(repo); err != nil {
		return nil, err
	}
	q := url.Values{"per_page": {strconv.Itoa(mostDeployments)}}
	if environment != "" {
		q.Set("environment", environment)
	}
	var page []deploymentJSON
	if err := g.get(ctx, fmt.Sprintf("repos/%s/deployments?%s", repo, q.Encode()), true, &page); err != nil {
		return nil, err
	}
	var out []Deployment
	for _, d := range page {
		if at := mcpevents.Normalized(d.UpdatedAt); at == "" || at < since {
			continue
		}
		var statuses []deploymentStatusJSON
		if err := g.get(ctx, fmt.Sprintf("repos/%s/deployments/%d/statuses?per_page=%d", repo, d.ID, mostStatuses), true, &statuses); err != nil {
			return nil, err
		}
		dep := Deployment{ID: d.ID, SHA: d.SHA, Ref: d.Ref, Environment: d.Environment, Production: d.Production,
			Transient: d.Transient, Created: d.CreatedAt, Updated: d.UpdatedAt}
		// GitHub lists the newest first.
		for i := len(statuses) - 1; i >= 0; i-- {
			s := statuses[i]
			u := s.TargetURL
			if u == "" {
				u = s.LogURL
			}
			dep.Statuses = append(dep.Statuses, DeploymentStatus{ID: s.ID, State: s.State, At: s.CreatedAt, URL: u, EnvironmentURL: s.EnvironmentURL})
		}
		out = append(out, dep)
	}
	return out, nil
}

// JobConclusion is an Actions job's conclusion (success, failure, cancelled…), "" while it runs.
func (g *RealGitHub) JobConclusion(ctx context.Context, repo string, job int64) (string, error) {
	if _, _, err := ownerName(repo); err != nil {
		return "", err
	}
	var j struct {
		Conclusion string `json:"conclusion"`
	}
	if err := g.get(ctx, fmt.Sprintf("repos/%s/actions/jobs/%d", repo, job), true, &j); err != nil {
		return "", err
	}
	return j.Conclusion, nil
}

// deployState is GitHub's state as the model's (spec, "Deploy states"); ok is false for waiting,
// which deploy.waiting says, for inactive, which is not "replaced" in a repo whose jobs share an
// environment (spec, finding 2), and for a state GitHub may add.
func deployState(raw string) (wire.DeployState, bool) {
	switch raw {
	case "queued", "in_progress":
		return wire.DeployStateRunning, true
	case "success":
		return wire.DeployStateSucceeded, true
	case "failure", "error":
		return wire.DeployStateFailed, true
	}
	return "", false
}

// deployEventOf is the event a state change raises.
var deployEventOf = map[wire.DeployState]string{
	wire.DeployStateRunning:   "deploy.started",
	wire.DeployStateSucceeded: "deploy.succeeded",
	wire.DeployStateFailed:    "deploy.failed",
}

// deployChange is one of a Deployment's state changes: the event it raises and its status.
type deployChange struct {
	Event  string
	State  wire.DeployState
	Status DeploymentStatus
}

// changes are a Deployment's state changes, oldest first: the first status of each state, so a
// queued after in_progress is no new start. Each event is raised once for a Deployment.
func (d Deployment) changes() []deployChange {
	var out []deployChange
	seen := map[wire.DeployState]bool{}
	for _, s := range d.Statuses {
		st, ok := deployState(s.State)
		if !ok || seen[st] {
			continue
		}
		seen[st] = true
		out = append(out, deployChange{Event: deployEventOf[st], State: st, Status: s})
	}
	return out
}

// tierOf is an environment's tier (spec, "What it gives us"): production when GitHub says it is
// one, or by its name; other when nothing says.
func tierOf(name string, production bool) wire.EnvironmentTier {
	if production {
		return wire.EnvironmentTierProduction
	}
	switch strings.ToLower(name) {
	case "production", "prod":
		return wire.EnvironmentTierProduction
	case "staging", "stage":
		return wire.EnvironmentTierStaging
	case "testing", "test", "qa":
		return wire.EnvironmentTierTesting
	case "development", "dev":
		return wire.EnvironmentTierDevelopment
	}
	return wire.EnvironmentTierOther
}

// releaseTag is a tag that names a release, as v0.18.0.
var releaseTag = regexp.MustCompile(`^v[0-9]`)

// jobURL is an Actions job's url: …/actions/runs/<run>/job/<job>.
var jobURL = regexp.MustCompile(`/actions/runs/[0-9]+/job/([0-9]+)`)

// jobOf is the Actions job a status's url names, or 0.
func jobOf(u string) int64 {
	m := jobURL.FindStringSubmatch(u)
	if m == nil {
		return 0
	}
	id, _ := strconv.ParseInt(m[1], 10, 64)
	return id
}

func deployRef(repo string, id int64) wire.Ref {
	return mcpevents.Ref("github", "deploy", repo, fmt.Sprint(id))
}

func refText(r wire.Ref) *string { s := r.String(); return &s }

// deploy is the Deployment, at change c, in the wire's model (spec, "The simple case stays
// simple"): the repo is the component, the sha the one artifact, its v* tag the version's name.
func (d Deployment) deploy(repo string, c deployChange) wire.Deploy {
	tier := tierOf(d.Environment, d.Production)
	env := wire.DeployEnvironment{System: "github", Name: d.Environment, Tier: tier}
	if d.Transient {
		env.Ephemeral = new(true)
	}
	for _, s := range d.Statuses {
		if s.EnvironmentURL != "" {
			env.URL = new(s.EnvironmentURL)
		}
	}
	component := wire.DeployComponent{System: "github", ID: repo, Repo: new(repo)}
	artifact := wire.DeployArtifact{Kind: "commit", System: "github", ID: d.SHA,
		Ref: refText(mcpevents.Ref("github", "artifact", repo, d.SHA))}
	version := wire.DeployVersion{Artifacts: []wire.DeployArtifact{artifact}, Ref: artifact.Ref}
	if releaseTag.MatchString(d.Ref) {
		version.Name = new(d.Ref)
		version.Ref = refText(mcpevents.Ref("github", "release", repo, d.Ref))
	}
	target := wire.DeployTarget{Component: component, Environment: env,
		Ref: refText(mcpevents.Ref("github", "target", repo, repo+"@"+d.Environment))}
	out := wire.Deploy{System: "github", ID: fmt.Sprint(d.ID), Ref: refText(deployRef(repo, d.ID)),
		Target: target, Version: version, State: c.State, RawState: c.Status.State}
	if c.Status.URL != "" {
		out.URL = new(c.Status.URL)
	}
	// started is the first running status; finished is the change's own time, when it ends it.
	for _, s := range d.Statuses {
		if st, _ := deployState(s.State); st == wire.DeployStateRunning && !mcpevents.Before(c.Status.At, s.At) {
			if at, ok := mcpevents.ParseTime(s.At); ok {
				out.Started = new(wire.DateOf(at))
			}
			break
		}
	}
	if at, ok := mcpevents.ParseTime(c.Status.At); ok && c.State != wire.DeployStateRunning {
		out.Finished = new(wire.DateOf(at))
	}
	return out
}

// deployData is a state change's DeployEvent, as a map; outcome is deploy.failed's.
func deployData(repo string, d Deployment, c deployChange, outcome wire.DeployOutcome) (map[string]any, error) {
	dep := d.deploy(repo, c)
	e := wire.DeployEvent{Deploy: dep, Component: repo, Environment: d.Environment, Tier: dep.Target.Environment.Tier}
	if c.State == wire.DeployStateFailed {
		e.Outcome = &outcome
	}
	b, err := json.Marshal(e)
	if err != nil {
		return nil, err
	}
	var out map[string]any
	return out, json.Unmarshal(b, &out)
}

// deployCandidates are deploy.started's, deploy.succeeded's or deploy.failed's candidates at or
// after since: one for each Deployment that changed to that state, at its status's time. The id
// is the deploy's ref and the event, from GitHub's data only, so two machines make the same.
func deployCandidates(ctx context.Context, gh GitHub, name string, a args, since string) ([]candidate, bool, error) {
	repo := a.repo
	if a.component != "" && !strings.EqualFold(a.component, repo) {
		return nil, false, nil
	}
	deps, err := gh.Deployments(ctx, repo, a.environment, since)
	if err != nil {
		return nil, false, err
	}
	var list []candidate
	for _, d := range deps {
		if a.tier != "" && string(tierOf(d.Environment, d.Production)) != a.tier {
			continue
		}
		for _, c := range d.changes() {
			at := mcpevents.Normalized(c.Status.At)
			if c.Event != name || at == "" {
				continue
			}
			ref := deployRef(repo, d.ID)
			list = append(list, candidate{EventID: ref.String() + "@" + name, Time: at, Subject: ref,
				Data: func() (map[string]any, error) {
					outcome := wire.DeployOutcomeFailed
					// GitHub has no cancelled status: a cancelled job's Deployment says failure.
					if job := jobOf(c.Status.URL); c.State == wire.DeployStateFailed && job != 0 {
						conclusion, err := gh.JobConclusion(ctx, repo, job)
						if err != nil {
							return nil, err
						}
						if conclusion == "cancelled" {
							outcome = wire.DeployOutcomeCancelled
						}
					}
					return deployData(repo, d, c, outcome)
				}})
		}
	}
	return list, false, nil
}

var (
	environmentProperty = property{Name: "environment", Kind: "string",
		Description: "Only deploys to this GitHub environment, by its name, as production or github-pages."}
	tierProperty = property{Name: "tier", Kind: "string",
		Description: "Only deploys to an environment of this tier: production (GitHub's production environment, or one named production or prod), staging, testing, development or other.",
		Pattern:     regexp.MustCompile(`^(production|staging|testing|development|other)$`), LooksLike: "production"}
	componentProperty = property{Name: "component", Kind: "string",
		Description: "Only deploys of this component: on GitHub, the repo, owner/name."}
)

var tierSchema = map[string]any{"type": "string", "enum": []string{"production", "staging", "testing", "development", "other"}}

// deployEvent is one of deploy.started, deploy.succeeded and deploy.failed: its details are the
// wire's DeployEvent (#5262).
func deployEvent(name, title, description string) event {
	props := map[string]any{
		// The wire's Deploy: system, id, ref, target, version, state, rawState, started, finished, url.
		"deploy":    map[string]any{"type": "object"},
		"component": str, "environment": str, "tier": tierSchema,
	}
	if name == "deploy.failed" {
		props["outcome"] = map[string]any{"type": "string", "enum": []string{"failed", "cancelled"}}
	}
	return event{Name: name, Title: title,
		Description: description + " deploy is the wire's Deploy: the repo is its component, the environment and its tier its target, the sha its version's one artifact, named by the run's v* tag when it ran on one; its ref is github:deploy:<owner>/<repo>#<deployment id>, its url the job's. Every Deployment of the repo, whoever started its run.",
		Input:       schema{repoProperty, environmentProperty, tierProperty, componentProperty},
		Payload:     object(props)}
}
