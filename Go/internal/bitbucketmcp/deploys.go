package bitbucketmcp

import (
	"context"
	"fmt"
	"regexp"
	"slices"
	"strings"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/mcpevents"
)

// Pipelines of any trigger and their deploys on Bitbucket Cloud (#4217), in the github
// server's shapes (#3810, #3584):
//
//   - run.completed: a Bitbucket Pipelines run that finished, whatever started it (a push, a
//     tag, a schedule, a person) and whatever its result, from the completed pipelines newest
//     created first; one event per pipeline and finish time, so a run again is a new one.
//   - What a pipeline deployed: a step with deployment: is one of the repository's
//     deployments, so no step has to say it. Each of the pipeline's successful deployments is
//     one deploy, bitbucket:<workspace/name>/<environment>/<build number>, read only for a
//     pipeline that is raised.
//   - No deploy.waiting: Bitbucket has no API to read or answer a deployment that waits (a
//     manual step, or Premium's deployment permissions).

const (
	// mostDeploys bounds what one pipeline may say it deployed, as the github server's.
	mostDeploys = 10
	// longestRun is how long before since a pipeline may have been created and still finish
	// after it: Bitbucket stops a step at 12 hours.
	longestRun = 12 * time.Hour
)

// deployPattern is a deploy's ref, <target>:<id>/<version>, as the github server's.
var deployPattern = regexp.MustCompile(`^[a-z][a-z0-9-]{0,19}:[^\s/]+(/[^\s/]+)*/[^\s/]+$`)

// runJSON is a Pipelines run as run.completed reads it.
type runJSON struct {
	UUID        string `json:"uuid"`
	BuildNumber int    `json:"build_number"`
	Creator     *user  `json:"creator"`
	Target      struct {
		Type    string `json:"type"`
		RefName string `json:"ref_name"`
		Source  string `json:"source"`
		Commit  struct {
			Hash string `json:"hash"`
		} `json:"commit"`
		Selector struct {
			Type    string `json:"type"`
			Pattern string `json:"pattern"`
		} `json:"selector"`
	} `json:"target"`
	Trigger struct {
		Name string `json:"name"`
	} `json:"trigger"`
	State struct {
		Name   string `json:"name"`
		Result *struct {
			Name string `json:"name"`
		} `json:"result"`
	} `json:"state"`
	CreatedOn   string `json:"created_on"`
	CompletedOn string `json:"completed_on"`
}

// name is the pipeline of bitbucket-pipelines.yml it ran: a custom pipeline's name, a branch
// or tag pattern, or default.
func (p runJSON) name() string {
	if p.Target.Selector.Pattern != "" {
		return p.Target.Selector.Pattern
	}
	return p.Target.Selector.Type
}

// branch is its branch or tag, or a pull request's source branch.
func (p runJSON) branch() string {
	if p.Target.RefName != "" {
		return p.Target.RefName
	}
	return p.Target.Source
}

// CompletedPipeline is a Pipelines run that finished, as run.completed sees it. ID is its
// build number (what failed_log and retry_pipeline take), Name the pipeline it ran, Trigger
// what started it (push, manual, schedule…), Result its result in lower case (successful,
// failed, error, stopped, expired). Trusted says whether a person with write access started
// it, never an app or a bot (#728).
type CompletedPipeline struct {
	ID                                 int
	UUID, Name, Trigger, Branch, SHA   string
	URL, Result, Actor, At, Repository string
	Trusted                            bool
}

func (c CompletedPipeline) data(deploys []string) map[string]any {
	if deploys == nil {
		deploys = []string{}
	}
	return map[string]any{"run": map[string]any{"id": c.ID, "name": c.Name, "number": c.ID, "event": c.Trigger,
		"branch": c.Branch, "headSha": c.SHA, "url": c.URL, "conclusion": c.Result, "actor": c.Actor},
		"completedAt": c.At, "deploys": deploys}
}

// CompletedPipelines are the runs that finished at or after since, of pipeline (its name),
// branch (or tag) and run (a build number) when each is set, in any order: the completed
// runs created since longestRun before it, a listing shared by every wait (#932).
func (b *RealBitbucket) CompletedPipelines(ctx context.Context, repo, pipeline, branch string, run int, since string) ([]CompletedPipeline, Listed, error) {
	var list []runJSON
	var listed Listed
	if run != 0 {
		var p runJSON
		if err := b.get(ctx, fmt.Sprintf("%s/pipelines/%d", repoPath(repo), run), true, &p); err != nil {
			return nil, Listed{}, err
		}
		list = []runJSON{p}
	} else {
		from := ""
		if t, ok := mcpevents.ParseTime(since); ok {
			from = mcpevents.TimeString(t.Add(-longestRun))
		}
		var err error
		list, listed, err = newest(ctx, b, repoPath(repo)+"/pipelines/?status=COMPLETED&sort=-created_on", from, "",
			func(p runJSON) string { return p.CreatedOn })
		if err != nil {
			return nil, Listed{}, err
		}
	}
	var out []CompletedPipeline
	for _, p := range list {
		if p.State.Name != "COMPLETED" || p.CompletedOn == "" || mcpevents.Before(p.CompletedOn, since) ||
			(pipeline != "" && !strings.EqualFold(p.name(), pipeline)) || (branch != "" && p.branch() != branch) {
			continue
		}
		trusted, err := b.trusted(ctx, repo, p.Creator)
		if err != nil {
			return nil, Listed{}, err
		}
		c := CompletedPipeline{ID: p.BuildNumber, UUID: p.UUID, Name: p.name(), Trigger: strings.ToLower(p.Trigger.Name),
			Branch: p.branch(), SHA: p.Target.Commit.Hash, URL: fmt.Sprintf("https://%s/%s/pipelines/results/%d", Host, repo, p.BuildNumber),
			Actor: p.Creator.name(), At: mcpevents.Normalized(p.CompletedOn), Repository: repo, Trusted: trusted}
		if p.State.Result != nil {
			c.Result = strings.ToLower(p.State.Result.Name)
		}
		out = append(out, c)
	}
	return out, listed, nil
}

// deploymentJSON is one of a repository's deployments: a step with deployment: of a pipeline.
type deploymentJSON struct {
	Environment struct {
		UUID string `json:"uuid"`
	} `json:"environment"`
	Release struct {
		Pipeline struct {
			UUID string `json:"uuid"`
		} `json:"pipeline"`
	} `json:"release"`
	State struct {
		Name   string `json:"name"`
		Status *struct {
			Name string `json:"name"`
		} `json:"status"`
	} `json:"state"`
}

// environmentJSON is a deployment environment: Test, Staging, Production or one's own.
type environmentJSON struct {
	UUID string `json:"uuid"`
	Name string `json:"name"`
	Slug string `json:"slug"`
}

// PipelineDeploys are what a pipeline deployed: its successful deployments among the
// repository's newest page of them, each as bitbucket:<workspace/name>/<environment>/<build
// number>, in their order, each once.
func (b *RealBitbucket) PipelineDeploys(ctx context.Context, repo string, c CompletedPipeline) ([]string, error) {
	var deployments paged[deploymentJSON]
	if err := b.get(ctx, query(repoPath(repo)+"/deployments/", 1), true, &deployments); err != nil {
		return nil, err
	}
	var envs []environmentJSON
	read := false
	var deploys []string
	for _, d := range deployments.Values {
		if d.Release.Pipeline.UUID != c.UUID || d.State.Name != "COMPLETED" || d.State.Status == nil || d.State.Status.Name != "SUCCESSFUL" {
			continue
		}
		if !read {
			var list paged[environmentJSON]
			if err := b.get(ctx, query(repoPath(repo)+"/environments/", 1), true, &list); err != nil {
				return nil, err
			}
			envs, read = list.Values, true
		}
		i := slices.IndexFunc(envs, func(e environmentJSON) bool { return e.UUID != "" && e.UUID == d.Environment.UUID })
		if i < 0 {
			continue
		}
		name := envs[i].Slug
		if name == "" {
			name = strings.ToLower(envs[i].Name)
		}
		ref := fmt.Sprintf("bitbucket:%s/%s/%d", repo, name, c.ID)
		if deployPattern.MatchString(ref) && !slices.Contains(deploys, ref) && len(deploys) < mostDeploys {
			deploys = append(deploys, ref)
		}
	}
	return deploys, nil
}
