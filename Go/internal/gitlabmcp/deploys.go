package gitlabmcp

import (
	"context"
	"fmt"
	"net/url"
	"regexp"
	"slices"
	"strings"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/mcpevents"
)

// Pipelines of any trigger and their deploys on GitLab (#4217), in the github server's shapes
// (#3810, #3584, #3587):
//
//   - run.completed: a pipeline of the project that finished, whatever started it (a push, a
//     tag, a schedule, a person) and whatever its status, from the finished pipelines updated
//     since; one event per pipeline and update time, so a pipeline retried is a new one.
//   - What a pipeline deployed: GitLab keeps a deployment for each job with an environment:, so
//     no job has to say it. Each of the pipeline's successful deployments is one deploy,
//     gitlab:<project>/<environment>/<deployment iid>, read only for a pipeline that is raised.
//   - deploy.waiting: a protected environment's deployment approvals hold a job until an
//     approver answers (GitLab Premium). Each blocked deployment is one of its pipeline's
//     environments. The gate and its audit are GitLab's.

const (
	// mostDeploys bounds what one pipeline may say it deployed, as the github server's.
	mostDeploys = 10
	// mostWaiting bounds the blocked deployments one read lists: one page.
	mostWaiting = 50
)

// deployPattern is a deploy's ref, <target>:<id>/<version>, as the github server's.
var deployPattern = regexp.MustCompile(`^[a-z][a-z0-9-]{0,19}:[^\s/]+(/[^\s/]+)*/[^\s/]+$`)

// finished is a pipeline status that is done: GitLab's scope=finished, and skipped.
func finished(status string) bool {
	return status == "success" || status == "failed" || status == "canceled" || status == "skipped"
}

// CompletedPipeline is a pipeline that finished, as run.completed sees it: one of main, a tag,
// a schedule or a person, which no merge request owns, or a merge request's. Name is its name
// (workflow:name, or "Pipeline #<id>"), Number its iid, Source what started it (push, web,
// schedule, merge_request_event…), Branch its ref (a branch or a tag). Trusted says whether a
// member with Reporter access or more started it, never a bot (#728).
type CompletedPipeline struct {
	ID, Number                   int
	Name, Source, Branch, SHA    string
	URL, Status, Actor, At, Path string
	Created                      string
	Trusted                      bool
}

func (c CompletedPipeline) run() map[string]any {
	return map[string]any{"id": c.ID, "name": c.Name, "number": c.Number, "event": c.Source, "branch": c.Branch,
		"headSha": c.SHA, "url": c.URL, "actor": c.Actor}
}

func (c CompletedPipeline) data(deploys []string) map[string]any {
	run := c.run()
	run["conclusion"] = c.Status
	if deploys == nil {
		deploys = []string{}
	}
	return map[string]any{"run": run, "completedAt": c.At, "deploys": deploys}
}

// FinishedPipelines are the finished pipelines updated at or after since, on branch (a branch
// or a tag) when it is set, or the one pipeline run, in any order. The listing is shared by
// every wait (#932).
func (g *RealGitLab) FinishedPipelines(ctx context.Context, project, branch string, run int, since string) ([]Pipeline, Listed, error) {
	var list []pipelineJSON
	var listed Listed
	if run != 0 {
		var p pipelineJSON
		if err := g.get(ctx, fmt.Sprintf("projects/%s/pipelines/%d", pid(project), run), true, &p); err != nil {
			return nil, Listed{}, err
		}
		list = []pipelineJSON{p}
	} else {
		path := fmt.Sprintf("projects/%s/pipelines?scope=finished&order_by=updated_at&sort=desc&updated_after=%s",
			pid(project), url.QueryEscape(since))
		var err error
		if list, listed, err = newest(ctx, g, path, since, func(p pipelineJSON) string { return p.UpdatedAt }); err != nil {
			return nil, Listed{}, err
		}
	}
	var out []Pipeline
	for _, p := range list {
		if finished(p.Status) && !mcpevents.Before(p.UpdatedAt, since) && (branch == "" || p.Ref == branch) {
			out = append(out, p.pipeline())
		}
	}
	return out, listed, nil
}

// CompletedPipeline is a pipeline as run.completed raises it: who started it, and when it finished.
func (g *RealGitLab) CompletedPipeline(ctx context.Context, project string, id int) (*CompletedPipeline, error) {
	var p pipelineJSON
	if err := g.get(ctx, fmt.Sprintf("projects/%s/pipelines/%d", pid(project), id), true, &p); err != nil {
		return nil, err
	}
	trusted, err := g.trusted(ctx, project, p.User)
	if err != nil {
		return nil, err
	}
	at := p.FinishedAt
	if at == "" {
		at = p.UpdatedAt
	}
	c := CompletedPipeline{ID: p.ID, Number: p.IID, Name: p.pipeline().Name, Source: p.Source, Branch: p.Ref, SHA: p.SHA,
		URL: p.WebURL, Status: p.Status, At: mcpevents.Normalized(at), Created: p.CreatedAt, Path: pathOf(p.WebURL, project),
		Trusted: trusted}
	if p.User != nil {
		c.Actor = p.User.Username
	}
	return &c, nil
}

// pathOf is a project's path from one of its pages' web address (group/app/-/pipelines/12),
// or project as asked for when it has none.
func pathOf(web, project string) string {
	u, err := url.Parse(web)
	if err != nil {
		return project
	}
	if p, _, ok := strings.Cut(strings.TrimPrefix(u.Path, "/"), "/-/"); ok && p != "" {
		return p
	}
	return project
}

// deploymentJSON is a deployment as GitLab lists it: of a job with an environment:.
type deploymentJSON struct {
	ID          int    `json:"id"`
	IID         int    `json:"iid"`
	Status      string `json:"status"`
	CreatedAt   string `json:"created_at"`
	User        *user  `json:"user"`
	Environment struct {
		ID   int    `json:"id"`
		Name string `json:"name"`
	} `json:"environment"`
	Deployable *struct {
		Name     string        `json:"name"`
		WebURL   string        `json:"web_url"`
		Pipeline *pipelineJSON `json:"pipeline"`
	} `json:"deployable"`
	// The approvals so far, on GitLab Premium.
	Approvals []approval `json:"approvals"`
	// ApprovalSummary is a single deployment's rules: who may approve, and how many must.
	ApprovalSummary *struct {
		Rules []approvalRule `json:"rules"`
	} `json:"approval_summary"`
}

// pipelineID is the deployment's pipeline, or 0 when GitLab did not say.
func (d deploymentJSON) pipelineID() int {
	if d.Deployable == nil || d.Deployable.Pipeline == nil {
		return 0
	}
	return d.Deployable.Pipeline.ID
}

// approvalRule is one rule of a protected environment's approvals: a person, a group or an
// access level, and how many of them must approve.
type approvalRule struct {
	UserID              int        `json:"user_id"`
	GroupID             int        `json:"group_id"`
	AccessLevel         int        `json:"access_level"`
	Description         string     `json:"access_level_description"`
	RequiredApprovals   int        `json:"required_approvals"`
	DeploymentApprovals []approval `json:"deployment_approvals"`
}

// approval is one answer to a deployment: approved or rejected, and by whom.
type approval struct {
	User   user   `json:"user"`
	Status string `json:"status"`
}

// open says whether the rule still wants an approval.
func (r approvalRule) open() bool {
	approved := 0
	for _, a := range r.DeploymentApprovals {
		if a.Status == "approved" {
			approved++
		}
	}
	return approved < max(1, r.RequiredApprovals)
}

// PipelineDeploys are what a pipeline deployed: its successful deployments, in their order,
// each as gitlab:<project>/<environment>/<deployment iid>. Only the deployments that finished
// while it ran are read: one page, at most.
func (g *RealGitLab) PipelineDeploys(ctx context.Context, project string, c CompletedPipeline) ([]string, error) {
	from, ok := mcpevents.ParseTime(c.Created)
	to, ok2 := mcpevents.ParseTime(c.At)
	if !ok || !ok2 {
		return nil, nil
	}
	q := url.Values{"status": {"success"}, "order_by": {"finished_at"}, "sort": {"asc"}, "per_page": {fmt.Sprint(perPage)},
		"finished_after": {mcpevents.TimeString(from.Add(-time.Second))}, "finished_before": {mcpevents.TimeString(to.Add(time.Second))}}
	var list []deploymentJSON
	if err := g.get(ctx, fmt.Sprintf("projects/%s/deployments?%s", pid(project), q.Encode()), true, &list); err != nil {
		return nil, err
	}
	var deploys []string
	for _, d := range list {
		ref := fmt.Sprintf("gitlab:%s/%s/%d", c.Path, d.Environment.Name, d.IID)
		if d.pipelineID() == c.ID && d.Status == "success" && deployPattern.MatchString(ref) &&
			!slices.Contains(deploys, ref) && len(deploys) < mostDeploys {
			deploys = append(deploys, ref)
		}
	}
	return deploys, nil
}

// Environment is one blocked deployment of a pipeline: its id, its environment's name, and
// the job's page, where it is answered.
type Environment struct {
	ID   int
	Name string
	URL  string
}

// WaitingDeploy is a pipeline whose deployments wait for an approver.
type WaitingDeploy struct {
	Pipeline Pipeline
	// Environments are its blocked deployments, oldest first.
	Environments []Environment
	// Since is when the newest of Environments began to wait.
	Since string
}

// key tells one wait from the next of the same pipeline: the deployments it waits on.
func (w WaitingDeploy) key() string {
	ids := make([]string, len(w.Environments))
	for i, e := range w.Environments {
		ids[i] = fmt.Sprint(e.ID)
	}
	return strings.Join(ids, ",")
}

// WaitingDeploys are the project's pipelines with deployments blocked for an approval, on
// branch (its ref) when it is set: the newest mostWaiting blocked deployments.
func (g *RealGitLab) WaitingDeploys(ctx context.Context, project, branch string) ([]WaitingDeploy, error) {
	var list []deploymentJSON
	path := fmt.Sprintf("projects/%s/deployments?status=blocked&order_by=created_at&sort=desc&per_page=%d", pid(project), mostWaiting)
	if err := g.get(ctx, path, true, &list); err != nil {
		return nil, err
	}
	byPipeline := map[int]*WaitingDeploy{}
	var order []int
	for i := len(list) - 1; i >= 0; i-- { // oldest first
		d := list[i]
		id := d.pipelineID()
		if d.Status != "blocked" || id == 0 || (branch != "" && d.Deployable.Pipeline.Ref != branch) {
			continue
		}
		w, ok := byPipeline[id]
		if !ok {
			w = &WaitingDeploy{Pipeline: d.Deployable.Pipeline.pipeline()}
			byPipeline[id] = w
			order = append(order, id)
		}
		w.Environments = append(w.Environments, Environment{ID: d.ID, Name: d.Environment.Name, URL: d.Deployable.WebURL})
		if at := mcpevents.Normalized(d.CreatedAt); at > w.Since {
			w.Since = at
		}
	}
	out := make([]WaitingDeploy, 0, len(order))
	for _, id := range order {
		out = append(out, *byPipeline[id])
	}
	return out, nil
}

// Approvers is who may answer a waiting pipeline's deployments, by their rules' names, and
// whether the connection's owner may answer every one: a rule still open names them, their
// group, or an access level they have, and they neither started the deployment nor answered it.
func (g *RealGitLab) Approvers(ctx context.Context, project string, w WaitingDeploy) (reviewers []string, canApprove bool, err error) {
	var me user
	if err := g.get(ctx, "user", true, &me); err != nil {
		return nil, false, err
	}
	reviewers = []string{}
	canApprove = len(w.Environments) > 0
	for _, e := range w.Environments {
		var d deploymentJSON
		if err := g.get(ctx, fmt.Sprintf("projects/%s/deployments/%d", pid(project), e.ID), true, &d); err != nil {
			return nil, false, err
		}
		mine := false
		if d.User != nil && d.User.ID == me.ID || slices.ContainsFunc(d.Approvals, func(a approval) bool { return a.User.ID == me.ID }) {
			canApprove = false
		}
		var rules []approvalRule
		if d.ApprovalSummary != nil {
			rules = d.ApprovalSummary.Rules
		}
		for _, r := range rules {
			if !r.open() {
				continue
			}
			if r.Description != "" && !slices.Contains(reviewers, r.Description) {
				reviewers = append(reviewers, r.Description)
			}
			if !mine && me.ID != 0 {
				if mine, err = g.fits(ctx, project, r, me); err != nil {
					return nil, false, err
				}
			}
		}
		canApprove = canApprove && mine
	}
	return reviewers, canApprove, nil
}

// fits says whether u is one a rule asks: the person it names, a member of its group, or a
// member of the project with its access level or more.
func (g *RealGitLab) fits(ctx context.Context, project string, r approvalRule, u user) (bool, error) {
	switch {
	case r.UserID != 0:
		return r.UserID == u.ID, nil
	case r.GroupID != 0:
		var m struct {
			AccessLevel int `json:"access_level"`
		}
		err := g.get(ctx, fmt.Sprintf("groups/%d/members/all/%d", r.GroupID, u.ID), true, &m)
		if gl, ok := err.(*GitLabError); ok && gl.Kind == NotFound {
			return false, nil
		}
		return err == nil && m.AccessLevel > 0, err
	case r.AccessLevel != 0:
		level, err := g.level(ctx, project, u.ID)
		return level >= r.AccessLevel, err
	}
	return false, nil
}
