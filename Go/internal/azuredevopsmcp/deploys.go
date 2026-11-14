package azuredevopsmcp

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"

	"github.com/agentloops-dev/agents/Go/internal/mcpevents"
)

// Deploys on Azure Pipelines (#3820), in the github server's shapes (#3584, #3587):
//
//   - What a build deployed: Azure Pipelines has no notice, and a build tag cannot hold a colon,
//     so a job says it with a warning whose code is deploy and whose message is the deploy's
//     ref, ##vso[task.logissue type=warning;code=deploy]testflight:com.example.app/42. It is
//     read from the build's timeline, only for a build that is raised.
//   - A deploy waiting: an environment's Approvals check holds a stage until an approver
//     answers. Each pending approval is one of the build's environments, named by the stage it
//     holds (the approval's Checkpoint.Approval record in the timeline, under its stage). The
//     gate and its audit are Azure DevOps's.

const (
	// deployCode is the code of the warning a job writes to say what it deployed, and
	// mostDeploys bounds what one build may say, as the github server's.
	deployCode  = "deploy"
	mostDeploys = 10
	// mostWaiting bounds the pending approvals one read lists: one page.
	mostWaiting = 50
)

// deployPattern is a deploy's ref, <target>:<id>/<version>, as the github server's.
var deployPattern = regexp.MustCompile(`^[a-z][a-z0-9-]{0,19}:[^\s/]+(/[^\s/]+)*/[^\s/]+$`)

// timelineRecord is one record of a build's timeline: a stage, a job, a task or a checkpoint.
type timelineRecord struct {
	ID       string `json:"id"`
	ParentID string `json:"parentId"`
	Type     string `json:"type"`
	Name     string `json:"name"`
	Result   string `json:"result"`
	Log      *struct {
		ID int `json:"id"`
	} `json:"log"`
	Issues []struct {
		Type    string            `json:"type"`
		Message string            `json:"message"`
		Data    map[string]string `json:"data"`
	} `json:"issues"`
}

// timeline is a build's records.
func (f *RealAzureDevOps) timeline(ctx context.Context, repo string, build int) ([]timelineRecord, error) {
	var t struct {
		Records []timelineRecord `json:"records"`
	}
	if err := f.get(ctx, api(fmt.Sprintf("%sbuild/builds/%d/timeline", projectPath(repo), build), nil), false, &t); err != nil {
		return nil, err
	}
	return t.Records, nil
}

// BuildDeploys are what a build's jobs say they deployed, in their order, each once.
func (f *RealAzureDevOps) BuildDeploys(ctx context.Context, repo string, build int) ([]string, error) {
	records, err := f.timeline(ctx, repo, build)
	if err != nil {
		return nil, err
	}
	var deploys []string
	for _, r := range records {
		for _, i := range r.Issues {
			ref := strings.TrimSpace(i.Message)
			if i.Type == "warning" && i.Data["code"] == deployCode && deployPattern.MatchString(ref) &&
				!slices.Contains(deploys, ref) && len(deploys) < mostDeploys {
				deploys = append(deploys, ref)
			}
		}
	}
	return deploys, nil
}

// Environment is one pending approval of a build: its id, and the stage it holds.
type Environment struct {
	ID, Name, URL string
}

// WaitingDeploy is a build that waits for an approver of one or more environments.
type WaitingDeploy struct {
	Build CompletedBuild
	// Environments are its pending approvals, oldest first.
	Environments []Environment
	// Reviewers are who may approve, as their sign-in names, and groups by their names.
	Reviewers []string
	// CanApprove says whether the token's owner may answer every one of Environments.
	CanApprove bool
	// Since is when the newest of Environments began to wait.
	Since string
}

// key tells one wait from the next of the same build: the approvals it waits on.
func (w WaitingDeploy) key() string {
	ids := make([]string, len(w.Environments))
	for i, e := range w.Environments {
		ids[i] = e.ID
	}
	return fmt.Sprintf("%d:%s", w.Build.ID, strings.Join(ids, ","))
}

// data is deploy.waiting's payload, as the github server's; a build has no attempt.
func (w WaitingDeploy) data() map[string]any {
	envs := make([]any, len(w.Environments))
	for i, e := range w.Environments {
		envs[i] = map[string]any{"id": e.ID, "name": e.Name, "url": e.URL}
	}
	reviewers := w.Reviewers
	if reviewers == nil {
		reviewers = []string{}
	}
	b := w.Build
	return map[string]any{"run": map[string]any{
		"id": b.ID, "name": b.Name, "number": b.Number, "event": b.Reason, "branch": b.Branch, "headSha": b.HeadSHA,
		"url": b.URL, "actor": b.Actor,
	}, "environments": envs, "reviewers": reviewers, "canApprove": w.CanApprove, "waitingSince": w.Since}
}

// approvalJSON is a pending approval, as the approvals API lists it with its steps and the
// token's owner's permissions; pipeline.owner is the build it holds.
type approvalJSON struct {
	ID          string          `json:"id"`
	Status      string          `json:"status"`
	CreatedOn   string          `json:"createdOn"`
	Permissions json.RawMessage `json:"permissions"`
	Steps       []struct {
		Status           string   `json:"status"`
		AssignedApprover identity `json:"assignedApprover"`
	} `json:"steps"`
	Pipeline struct {
		Owner struct {
			ID int `json:"id"`
		} `json:"owner"`
	} `json:"pipeline"`
}

// updatePermission is ApprovalPermissions' update flag (none 0, view 1, update 2).
const updatePermission = 2

// canUpdate says whether the token's owner may answer it: the flags as a number, or as
// their names ("view, update").
func (a approvalJSON) canUpdate() bool {
	var n int
	if json.Unmarshal(a.Permissions, &n) == nil {
		return n&updatePermission != 0
	}
	var s string
	if json.Unmarshal(a.Permissions, &s) == nil {
		for _, p := range strings.Split(s, ",") {
			if strings.EqualFold(strings.TrimSpace(p), "update") {
				return true
			}
		}
	}
	return false
}

// WaitingDeploys are the repository's builds waiting for an approval: only pipeline's (its
// name) when it is set, only branch's (a branch or a tag) when it is set.
func (f *RealAzureDevOps) WaitingDeploys(ctx context.Context, repo, pipeline, branch string) ([]WaitingDeploy, error) {
	r, err := f.repository(ctx, repo)
	if err != nil {
		return nil, err
	}
	q := url.Values{"state": {"pending"}, "$expand": {"steps,permissions"}, "top": {strconv.Itoa(mostWaiting)}}
	var list struct {
		Value []approvalJSON `json:"value"`
	}
	if err := f.get(ctx, api(projectPath(repo)+"pipelines/approvals", q), true, &list); err != nil {
		return nil, err
	}
	// The project's approvals, by the build each holds, in the order the builds came.
	byBuild := map[int][]approvalJSON{}
	var order []int
	for _, a := range list.Value {
		id := a.Pipeline.Owner.ID
		if a.Status != "pending" || id == 0 {
			continue
		}
		if _, ok := byBuild[id]; !ok {
			order = append(order, id)
		}
		byBuild[id] = append(byBuild[id], a)
	}
	var out []WaitingDeploy
	for _, id := range order {
		var b buildJSON
		if err := f.get(ctx, api(fmt.Sprintf("%sbuild/builds/%d", projectPath(repo), id), nil), true, &b); err != nil {
			return nil, err
		}
		// An approval is the project's: one of another repository's build is not this one's.
		if b.Repository.ID != r.ID || (pipeline != "" && !strings.EqualFold(b.Definition.Name, pipeline)) ||
			(branch != "" && b.ref() != branch && b.SourceBranch != branch) {
			continue
		}
		records, err := f.timeline(ctx, repo, id)
		if err != nil {
			return nil, err
		}
		approvals := byBuild[id]
		sort.SliceStable(approvals, func(i, j int) bool {
			return mcpevents.Normalized(approvals[i].CreatedOn) < mcpevents.Normalized(approvals[j].CreatedOn)
		})
		w := WaitingDeploy{Build: completed(b), CanApprove: true}
		for _, a := range approvals {
			w.Environments = append(w.Environments, Environment{ID: a.ID, Name: stageOf(records, a.ID), URL: b.Links.Web.Href})
			w.CanApprove = w.CanApprove && a.canUpdate()
			if at := mcpevents.Normalized(a.CreatedOn); at > w.Since {
				w.Since = at
			}
			for _, s := range a.Steps {
				if who := s.AssignedApprover.name(); who != "" && s.Status != "approved" && s.Status != "rejected" && !contains(w.Reviewers, who) {
					w.Reviewers = append(w.Reviewers, who)
				}
			}
		}
		out = append(out, w)
	}
	return out, nil
}

// stageOf is the name of the stage an approval holds: its Checkpoint.Approval record's
// nearest Stage above it, or "" when the timeline does not have it yet.
func stageOf(records []timelineRecord, approval string) string {
	byID := make(map[string]timelineRecord, len(records))
	for _, r := range records {
		byID[strings.ToLower(r.ID)] = r
	}
	r, ok := byID[strings.ToLower(approval)]
	for range len(records) {
		if !ok {
			return ""
		}
		if r.Type == "Stage" {
			return r.Name
		}
		r, ok = byID[strings.ToLower(r.ParentID)]
	}
	return ""
}
