package forgejomcp

import (
	"context"
	"fmt"
	"path"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/mcpevents"
)

// run.completed (#4217): a Forgejo Actions run that finished, whatever started it (a push, a
// tag, workflow_dispatch, a schedule) and whatever its result, in the github server's shape
// (#3810). Forgejo and Gitea list a repository's runs newest first, with no "updated" order,
// so a poll pages back to runs created longestRun before since and keeps those that finished
// at or after it. Forgejo has no deployments or environments, so deploys is always empty, and
// no approval API, so there is no deploy.waiting.

// longestRun is how long before since a run may have been created and still finish after
// it: a job stops at three hours by default, and a runner may wait before it starts one.
const longestRun = 12 * time.Hour

// actionRunJSON is a run as the runs list gives it: Forgejo's fields and Gitea's, which name
// the same things apart.
type actionRunJSON struct {
	runJSON
	Title        string `json:"title"`
	DisplayTitle string `json:"display_title"`
	// WorkflowID is Forgejo's workflow file (release.yml); Path is Gitea's
	// (.gitea/workflows/release.yml@refs/heads/main).
	WorkflowID string `json:"workflow_id"`
	Path       string `json:"path"`
	// Event is Gitea's, TriggerEvent Forgejo's.
	Event        string `json:"event"`
	TriggerEvent string `json:"trigger_event"`
	// HeadBranch is Gitea's; PrettyRef and Ref are Forgejo's.
	HeadBranch string `json:"head_branch"`
	PrettyRef  string `json:"prettyref"`
	Ref        string `json:"ref"`
	HeadSHA    string `json:"head_sha"`
	CommitSHA  string `json:"commit_sha"`
	HTMLURL    string `json:"html_url"`
	// Status is Gitea's completed with its Conclusion, or Forgejo's result itself.
	Status     string `json:"status"`
	Conclusion string `json:"conclusion"`
	// Who started it: Gitea's trigger_actor (or actor), Forgejo's trigger_user.
	TriggerActor *user `json:"trigger_actor"`
	Actor        *user `json:"actor"`
	TriggerUser  *user `json:"trigger_user"`
	// IsForkPR is Forgejo's word for a run of a fork's pull request.
	IsForkPR bool `json:"is_fork_pull_request"`
	// Times: Gitea's started_at and completed_at, Forgejo's created, started and stopped.
	Created     string `json:"created"`
	Started     string `json:"started"`
	Stopped     string `json:"stopped"`
	StartedAt   string `json:"started_at"`
	CompletedAt string `json:"completed_at"`
}

func first(s ...string) string {
	for _, v := range s {
		if v != "" {
			return v
		}
	}
	return ""
}

// result is how it finished, or "" while it has not.
func (r actionRunJSON) result() string {
	if r.Status == "completed" {
		return first(r.Conclusion, "completed")
	}
	switch r.Status {
	case "success", "failure", "cancelled", "skipped":
		return r.Status
	}
	return ""
}

// workflow is its workflow's file name: release.yml.
func (r actionRunJSON) workflow() string {
	p, _, _ := strings.Cut(first(r.WorkflowID, r.Path), "@")
	return path.Base(p)
}

func (r actionRunJSON) branch() string {
	if b := first(r.HeadBranch, r.PrettyRef); b != "" {
		return b
	}
	if tag, ok := strings.CutPrefix(r.Ref, "refs/tags/"); ok {
		return tag
	}
	return strings.TrimPrefix(r.Ref, "refs/heads/")
}

func (r actionRunJSON) by() *user {
	for _, u := range []*user{r.TriggerUser, r.TriggerActor, r.Actor} {
		if u != nil && u.Login != "" {
			return u
		}
	}
	return nil
}

func (r actionRunJSON) createdAt() string  { return first(r.Created, r.StartedAt, r.Started) }
func (r actionRunJSON) finishedAt() string { return first(r.CompletedAt, r.Stopped) }

// CompletedRun is an Actions run that finished, as run.completed sees it. Number is the run's
// number (failed_log and retry_pipeline take it), Workflow its file, Result success, failure,
// cancelled or skipped. Trusted says whether a collaborator with write access started it,
// never a bot, and not for a fork's pull request (#728).
type CompletedRun struct {
	Number                                  int
	Name, Workflow, Event, Branch, SHA, URL string
	Result, Actor, At                       string
	Trusted                                 bool
}

func (c CompletedRun) data() map[string]any {
	return map[string]any{"run": map[string]any{"id": c.Number, "name": c.Name, "workflow": c.Workflow, "event": c.Event,
		"branch": c.Branch, "headSha": c.SHA, "url": c.URL, "conclusion": c.Result, "actor": c.Actor},
		"completedAt": c.At, "deploys": []string{}}
}

// CompletedRuns are the Actions runs that finished at or after since, of workflow (its file),
// branch (or tag) and run (its number) when each is set, in any order.
func (f *RealForgejo) CompletedRuns(ctx context.Context, repo, workflow, branch string, run int, since string) ([]CompletedRun, Listed, error) {
	cutoff := ""
	if t, ok := mcpevents.ParseTime(since); ok {
		cutoff = mcpevents.TimeString(t.Add(-longestRun))
	}
	list := fmt.Sprintf("%s/actions/runs", repoPath(repo))
	if run != 0 {
		list += fmt.Sprintf("?run_number=%d", run)
	}
	var runs []actionRunJSON
	var listed Listed
	for p := 1; ; p++ {
		if p > maxPages {
			listed.Truncated = true
			break
		}
		var page struct {
			Runs []actionRunJSON `json:"workflow_runs"`
		}
		if err := f.get(ctx, query(list, p), true, &page); err != nil {
			return nil, Listed{}, err
		}
		older := false
		for _, r := range page.Runs {
			if cutoff != "" && r.createdAt() != "" && mcpevents.Before(r.createdAt(), cutoff) {
				older = true
				break
			}
			runs = append(runs, r)
		}
		if older || len(page.Runs) < perPage {
			break
		}
	}
	var out []CompletedRun
	for _, r := range runs {
		at := mcpevents.Normalized(r.finishedAt())
		if r.result() == "" || at == "" || mcpevents.Before(at, since) || (run != 0 && r.number() != run) ||
			(workflow != "" && !strings.EqualFold(r.workflow(), workflow)) || (branch != "" && r.branch() != branch) {
			continue
		}
		u := r.by()
		trusted := false
		if !r.IsForkPR {
			var err error
			if trusted, err = f.trusted(ctx, repo, u); err != nil {
				return nil, Listed{}, err
			}
		}
		c := CompletedRun{Number: r.number(), Name: first(r.Title, r.DisplayTitle), Workflow: r.workflow(), Event: first(r.Event, r.TriggerEvent),
			Branch: r.branch(), SHA: first(r.HeadSHA, r.CommitSHA), URL: r.HTMLURL, Result: r.result(), At: at, Trusted: trusted}
		if u != nil {
			c.Actor = u.Login
		}
		out = append(out, c)
	}
	return out, listed, nil
}
