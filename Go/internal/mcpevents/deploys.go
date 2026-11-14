package mcpevents

import (
	"encoding/json"
	"regexp"
	"strings"

	"github.com/agentloops-dev/agents/Go/wire"
)

// The deploy events every forge's server sends (#5240, #5244, spec 5239-deploy-model):
// deploy.started, deploy.succeeded and deploy.failed, with the wire's DeployEvent as their
// details, so the github, gitlab, azuredevops and bitbucket servers say a deploy the same way.

// DeployEventNames are the three events of a deploy's change of state.
var DeployEventNames = []string{"deploy.started", "deploy.succeeded", "deploy.failed"}

// IsDeployEvent is whether name is one of DeployEventNames.
func IsDeployEvent(name string) bool {
	return name == "deploy.started" || name == "deploy.succeeded" || name == "deploy.failed"
}

// DeployEventOf is the event a deploy's state raises: running is deploy.started, succeeded is
// deploy.succeeded, failed and cancelled are deploy.failed; "" for waiting, deploy.waiting's.
func DeployEventOf(state wire.DeployState) string {
	switch state {
	case wire.DeployStateRunning:
		return "deploy.started"
	case wire.DeployStateSucceeded:
		return "deploy.succeeded"
	case wire.DeployStateFailed, wire.DeployStateCancelled:
		return "deploy.failed"
	}
	return ""
}

// TierByName is an environment's tier from its name alone (spec, "What it gives us"), for a
// system that has none, or says none: production or prod is production; other when the name
// says nothing.
func TierByName(name string) wire.EnvironmentTier {
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

// DeployData is a deploy's DeployEvent, as a map: its target's component, environment and tier
// flat beside it; outcome only for deploy.failed (failed, or cancelled for a cancelled deploy).
func DeployData(d wire.Deploy) (map[string]any, error) {
	e := wire.DeployEvent{Deploy: d, Component: d.Target.Component.ID, Environment: d.Target.Environment.Name,
		Tier: d.Target.Environment.Tier}
	switch d.State {
	case wire.DeployStateFailed:
		e.Outcome = new(wire.DeployOutcomeFailed)
	case wire.DeployStateCancelled:
		e.Outcome = new(wire.DeployOutcomeCancelled)
	}
	b, err := json.Marshal(e)
	if err != nil {
		return nil, err
	}
	var out map[string]any
	return out, json.Unmarshal(b, &out)
}

// DeployFilter is what deploy.*'s environment, tier and component ask for: a deploy is wanted
// when each one that is set matches, without regard to case (a repo's name, Bitbucket's
// Production).
type DeployFilter struct{ Environment, Tier, Component string }

// Wants is whether a deploy to environment, of tier, of component is one the filter asks for.
func (f DeployFilter) Wants(environment string, tier wire.EnvironmentTier, component string) bool {
	return (f.Environment == "" || strings.EqualFold(f.Environment, environment)) && (f.Tier == "" || f.Tier == string(tier)) &&
		(f.Component == "" || strings.EqualFold(f.Component, component))
}

// DeployFilterOf is the filter of an event's checked values.
func DeployFilterOf(v Values) DeployFilter {
	return DeployFilter{Environment: v.String("environment"), Tier: v.String("tier"), Component: v.String("component")}
}

// tiers are the wire's five environment tiers.
var tiers = []string{"production", "staging", "testing", "development", "other"}

// TierProperty is the tier filter, with how this system's environments get a tier.
func TierProperty(how string) Property {
	return Property{Name: "tier", Kind: "string",
		Description: "Only deploys to an environment of this tier: production, staging, testing, development or other. " + how,
		Pattern:     regexp.MustCompile(`^(production|staging|testing|development|other)$`), LooksLike: "production"}
}

// DeployPayload is deploy.*'s payload schema: the wire's DeployEvent.
func DeployPayload(name string) map[string]any {
	str := map[string]any{"type": "string"}
	props := map[string]any{
		// The wire's Deploy: system, id, ref, target, version, state, rawState, started, finished, url.
		"deploy":    map[string]any{"type": "object"},
		"component": str, "environment": str, "tier": map[string]any{"type": "string", "enum": tiers},
	}
	if name == "deploy.failed" {
		props["outcome"] = map[string]any{"type": "string", "enum": []string{"failed", "cancelled"}}
	}
	return map[string]any{"type": "object", "properties": props}
}

// releaseTag is a tag that names a release, as v0.18.0.
var releaseTag = regexp.MustCompile(`^v[0-9]`)

// DeployChange is one change of a deploy's state: the model's state, the system's own word for
// it, and when it changed, a time that does not move (a poll raises an event once per id and
// time).
type DeployChange struct {
	State    wire.DeployState
	RawState string
	At       string
}

// ForgeDeploy is a forge's deploy record in the model's simple case (spec, "The simple case
// stays simple"): the repo is the component, the commit the version's one artifact, named by
// its v* tag when it ran on one, and the forge's environment the target's. System is the
// forge (gitlab, azuredevops, bitbucket); Repo the repo as its refs name it; ID the deploy's id
// there. Changes are its state changes, oldest first, at most one for each event.
type ForgeDeploy struct {
	System, Repo, ID string
	SHA, Ref         string
	Environment      string
	Tier             wire.EnvironmentTier
	Ephemeral        bool
	EnvironmentURL   string
	// Labels tell targets apart when a forge has more than component × environment (an Azure
	// pipeline, a Bitbucket step); URL is the job's page.
	Labels  map[string]string
	URL     string
	Changes []DeployChange
	// Complete, when set, reads what the record does not say (Azure's commit, from its build),
	// only once one of its events is taken; false skips the event (a build of another repo).
	Complete func(*ForgeDeploy) (bool, error)
}

// DeployRef is the deploy's ref, <system>:deploy:<repo>#<id>.
func (f ForgeDeploy) DeployRef() wire.Ref { return Ref(f.System, "deploy", f.Repo, f.ID) }

func refText(r wire.Ref) *string { s := r.String(); return &s }

// Deploy is the record, at change c, in the wire's model.
func (f ForgeDeploy) Deploy(c DeployChange) wire.Deploy {
	env := wire.DeployEnvironment{System: f.System, Name: f.Environment, Tier: f.Tier}
	if f.Ephemeral {
		env.Ephemeral = new(true)
	}
	if f.EnvironmentURL != "" {
		env.URL = new(f.EnvironmentURL)
	}
	target := wire.DeployTarget{Component: wire.DeployComponent{System: f.System, ID: f.Repo, Repo: new(f.Repo)},
		Environment: env, Ref: refText(Ref(f.System, "target", f.Repo, f.Repo+"@"+f.Environment))}
	if len(f.Labels) > 0 {
		target.Labels = f.Labels
	}
	var version wire.DeployVersion
	if f.SHA != "" {
		artifact := wire.DeployArtifact{Kind: "commit", System: f.System, ID: f.SHA, Ref: refText(Ref(f.System, "artifact", f.Repo, f.SHA))}
		version = wire.DeployVersion{Artifacts: []wire.DeployArtifact{artifact}, Ref: artifact.Ref}
	} else {
		version.Artifacts = []wire.DeployArtifact{}
	}
	if releaseTag.MatchString(f.Ref) {
		version.Name = new(f.Ref)
		version.Ref = refText(Ref(f.System, "release", f.Repo, f.Ref))
	}
	out := wire.Deploy{System: f.System, ID: f.ID, Ref: refText(f.DeployRef()), Target: target, Version: version,
		State: c.State, RawState: c.RawState}
	if f.URL != "" {
		out.URL = new(f.URL)
	}
	for _, s := range f.Changes {
		if s.State == wire.DeployStateRunning {
			if at, ok := ParseTime(s.At); ok {
				out.Started = new(wire.DateOf(at))
			}
		}
	}
	if at, ok := ParseTime(c.At); ok && c.State != wire.DeployStateRunning {
		out.Finished = new(wire.DateOf(at))
	}
	return out
}

// DeployCandidates are name's candidates among deploys (one of DeployEventNames): one for each
// deploy that changed to that event's state and that the filter wants, at the change's time.
// The id is the deploy's ref and the event, from the forge's data only, so two machines make
// the same one.
func DeployCandidates(name string, filter DeployFilter, deploys []ForgeDeploy) []Candidate {
	var list []Candidate
	for _, d := range deploys {
		if !filter.Wants(d.Environment, d.Tier, d.Repo) {
			continue
		}
		for _, c := range d.Changes {
			at := Normalized(c.At)
			if DeployEventOf(c.State) != name || at == "" {
				continue
			}
			ref := d.DeployRef()
			list = append(list, Candidate{EventID: ref.String() + "@" + name, Time: at, Subject: ref,
				Data: func() (map[string]any, error) {
					d := d
					if d.Complete != nil {
						if ok, err := d.Complete(&d); err != nil || !ok {
							return nil, err
						}
					}
					return DeployData(d.Deploy(c))
				}})
		}
	}
	return list
}

// DeployEventInput is what a forge's deploy.* events say: where the deploy went (environment),
// how its environments get a tier (tierHow), and what its component is (component).
type DeployEventInput struct {
	Repo                            Property
	Environment, TierHow, Component string
}

// DeployEvent is one of deploy.started, deploy.succeeded and deploy.failed of a forge: its
// arguments are the repo and the three filters, its details the wire's DeployEvent (#5262).
func DeployEvent(name, title, description string, in DeployEventInput) Event {
	return Event{Name: name, Title: title, Description: description,
		Input: Schema{in.Repo,
			Property{Name: "environment", Kind: "string", Description: "Only deploys to this environment, by its name. " + in.Environment},
			TierProperty(in.TierHow),
			Property{Name: "component", Kind: "string", Description: "Only deploys of this component: " + in.Component}},
		Payload: DeployPayload(name)}
}
