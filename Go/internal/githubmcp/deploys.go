package githubmcp

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"path"
	"strings"
)

// A deploy held by a GitHub environment with required reviewers (#3587): the run waits until a
// reviewer approves it, on GitHub or here. The gate and its audit are GitHub's; Agents only
// shows the run and answers through the pending-deployments API with the person's own sign-in.

// mostWaiting bounds the waiting runs one read lists: one page.
const mostWaiting = 50

// Environment is a GitHub environment a run waits on.
type Environment struct {
	ID   int64
	Name string
	URL  string
}

// WaitingDeploy is a workflow run waiting for a reviewer of one or more environments.
type WaitingDeploy struct {
	Run CompletedRun
	// Environments are the ones it waits on that have required reviewers; a wait timer alone
	// is not a gate a person answers.
	Environments []Environment
	// Reviewers are who may approve: logins, and teams as org/team.
	Reviewers []string
	// CanApprove says whether the connection's owner may approve every one of Environments.
	CanApprove bool
}

// EnvironmentIDs is what an answer names.
func (w WaitingDeploy) EnvironmentIDs() []int64 {
	ids := make([]int64, len(w.Environments))
	for i, e := range w.Environments {
		ids[i] = e.ID
	}
	return ids
}

// EnvironmentNames is the environments, as "production" or "staging, production".
func (w WaitingDeploy) EnvironmentNames() string {
	names := make([]string, len(w.Environments))
	for i, e := range w.Environments {
		names[i] = e.Name
	}
	return strings.Join(names, ", ")
}

// key tells one wait from the next of the same run: an attempt, then the environments.
func (w WaitingDeploy) key() string {
	ids := make([]string, len(w.Environments))
	for i, e := range w.Environments {
		ids[i] = fmt.Sprint(e.ID)
	}
	return fmt.Sprintf("%d:%d:%s", w.Run.Run.ID, w.Run.Run.Attempt, strings.Join(ids, ","))
}

// data is deploy.waiting's payload.
func (w WaitingDeploy) data() map[string]any {
	envs := make([]any, len(w.Environments))
	for i, e := range w.Environments {
		envs[i] = map[string]any{"id": e.ID, "name": e.Name, "url": e.URL}
	}
	reviewers := w.Reviewers
	if reviewers == nil {
		reviewers = []string{}
	}
	c := w.Run
	return map[string]any{"run": map[string]any{
		"id": c.Run.ID, "attempt": c.Run.Attempt, "name": c.Run.Name, "workflow": c.Workflow, "event": c.Event,
		"branch": c.Run.Branch, "headSha": c.Run.HeadSHA, "url": c.Run.URL, "actor": c.Actor,
	}, "environments": envs, "reviewers": reviewers, "canApprove": w.CanApprove, "waitingSince": c.Run.UpdatedAt}
}

// pendingJSON is one of a run's pending deployments, as GitHub's API lists them.
type pendingJSON struct {
	Environment struct {
		ID      int64  `json:"id"`
		Name    string `json:"name"`
		HTMLURL string `json:"html_url"`
	} `json:"environment"`
	CanApprove bool `json:"current_user_can_approve"`
	Reviewers  []struct {
		Type     string `json:"type"`
		Reviewer struct {
			Login string `json:"login"`
			Slug  string `json:"slug"`
		} `json:"reviewer"`
	} `json:"reviewers"`
}

// WaitingDeploys are the repo's runs waiting for an environment's reviewers: only workflow's
// (a file name) when it is set, only branch's (a branch or a tag) when it is set.
func (g *RealGitHub) WaitingDeploys(ctx context.Context, repo, workflow, branch string) ([]WaitingDeploy, error) {
	if _, _, err := ownerName(repo); err != nil {
		return nil, err
	}
	var page struct {
		Runs []runJSON `json:"workflow_runs"`
	}
	if err := g.get(ctx, fmt.Sprintf("repos/%s/actions/runs?status=waiting&per_page=%d", repo, mostWaiting), true, &page); err != nil {
		return nil, err
	}
	var out []WaitingDeploy
	for _, r := range page.Runs {
		if r.Status != "waiting" || (workflow != "" && path.Base(r.Path) != workflow) || (branch != "" && r.HeadBranch != branch) {
			continue
		}
		var pending []pendingJSON
		if err := g.get(ctx, fmt.Sprintf("repos/%s/actions/runs/%d/pending_deployments", repo, r.ID), false, &pending); err != nil {
			return nil, err
		}
		w := WaitingDeploy{Run: r.completed(repo), CanApprove: true}
		for _, p := range pending {
			if len(p.Reviewers) == 0 {
				continue
			}
			w.Environments = append(w.Environments, Environment{ID: p.Environment.ID, Name: p.Environment.Name, URL: p.Environment.HTMLURL})
			w.CanApprove = w.CanApprove && p.CanApprove
			for _, rv := range p.Reviewers {
				who := rv.Reviewer.Login
				if rv.Type == "Team" {
					who = strings.SplitN(repo, "/", 2)[0] + "/" + rv.Reviewer.Slug
				}
				if who != "" && !contains(w.Reviewers, who) {
					w.Reviewers = append(w.Reviewers, who)
				}
			}
		}
		if len(w.Environments) > 0 {
			out = append(out, w)
		}
	}
	return out, nil
}

// ReviewDeployments approves or rejects a run's wait on environments, as the person: GitHub
// refuses it when they are not one of its reviewers, and keeps who answered and comment.
func (g *RealGitHub) ReviewDeployments(ctx context.Context, repo string, runID int, environments []int64, approve bool, comment string) error {
	if _, _, err := ownerName(repo); err != nil {
		return err
	}
	if len(environments) == 0 {
		return &GitHubError{Kind: NotFound, Message: "name the environments to answer"}
	}
	state := "rejected"
	if approve {
		state = "approved"
	}
	body, _ := json.Marshal(map[string]any{"environment_ids": environments, "state": state, "comment": comment})
	_, err := g.do(ctx, http.MethodPost, fmt.Sprintf("repos/%s/actions/runs/%d/pending_deployments", repo, runID), body, false)
	return err
}

// Commit is a commit as a compare lists it: its sha and its message.
type Commit struct{ SHA, Message string }

// mostTags bounds the tags one read lists: one page.
const mostTags = 100

// Tags are the repo's tag names, one page of them, as GitHub lists them.
func (g *RealGitHub) Tags(ctx context.Context, repo string) ([]string, error) {
	if _, _, err := ownerName(repo); err != nil {
		return nil, err
	}
	var tags []struct {
		Name string `json:"name"`
	}
	if err := g.get(ctx, fmt.Sprintf("repos/%s/tags?per_page=%d", repo, mostTags), true, &tags); err != nil {
		return nil, err
	}
	out := make([]string, len(tags))
	for i, t := range tags {
		out[i] = t.Name
	}
	return out, nil
}

// Compare is the commits in head and not in base, oldest first, at most GitHub's 250.
func (g *RealGitHub) Compare(ctx context.Context, repo, base, head string) ([]Commit, error) {
	if _, _, err := ownerName(repo); err != nil {
		return nil, err
	}
	var c struct {
		Commits []struct {
			SHA    string `json:"sha"`
			Commit struct {
				Message string `json:"message"`
			} `json:"commit"`
		} `json:"commits"`
	}
	if err := g.get(ctx, fmt.Sprintf("repos/%s/compare/%s...%s", repo, url.PathEscape(base), url.PathEscape(head)), true, &c); err != nil {
		return nil, err
	}
	out := make([]Commit, len(c.Commits))
	for i, x := range c.Commits {
		out[i] = Commit{SHA: x.SHA, Message: x.Commit.Message}
	}
	return out, nil
}
