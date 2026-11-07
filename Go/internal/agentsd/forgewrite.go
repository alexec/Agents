package agentsd

import (
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"slices"
	"strconv"
	"strings"

	"github.com/alexec/agents/Go/internal/bitbucketmcp"
	"github.com/alexec/agents/Go/internal/githubmcp"
	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/wire"
)

// The forge writes (#3130): the actions of the GitHub, GitLab, Forgejo (#3753), Bitbucket (#3786), Linear, Jira (#3260) and Azure
// Boards (#3815) views, on the Work pages' issue and pull request pages: comment, labels (a work
// item's tags), close and reopen (a Jira issue's move by a transition of its workflow, a work
// item's to another state of its type), and a pull request's merge, approve, rerun of its failed
// checks, their logs and its diff. Next to the reads (forge.go), with the same tokens and the
// connectors' own write code.
//
// Each write is a person's own click on their own page. Only a window or a device may call these
// (Role.Allows: an agent's connection has none of them), and the control plane opens a channel to
// a machine only for its owner (Router.OpenFromPeer), so a write is always the token owner's own
// action on their own machine. The policy's layers (#2957) rule what agents may do, not a person,
// so no approval card is asked for.
const (
	// forgeCommentMost bounds a comment, as GitHub does.
	forgeCommentMost = 65536
	// forgeLabelsMost bounds the labels one call adds or takes off.
	forgeLabelsMost = 20
)

// forgeGitHubWrites is what the writes ask of GitHub; a test gives a fake.
type forgeGitHubWrites interface {
	CommentOnPR(ctx context.Context, repo string, number int, words string) (map[string]any, error)
	SetLabels(ctx context.Context, repo string, number int, add, remove []string) error
	SetState(ctx context.Context, repo string, number int, closed bool) error
	MergeBy(ctx context.Context, repo string, number int, sha, method string, auto bool) (map[string]any, error)
	ReviewPR(ctx context.Context, repo string, number int, sha string, approve bool, words string) (map[string]any, error)
	RerunFailed(ctx context.Context, repo string, runID int) (map[string]any, error)
	FailedLog(ctx context.Context, repo string, runID int, job string) (string, error)
	PRDiff(ctx context.Context, repo string, number int, sha string) (map[string]any, error)
	RepoLabels(ctx context.Context, repo string) ([]string, map[string]string, error)
	// The plan's (#3271).
	CreateIssue(ctx context.Context, repo, title string, labels []string) (int, string, error)
	AddSubIssue(ctx context.Context, repo string, number int, childRepo string, childNumber int) error
	SetBlockedBy(ctx context.Context, repo string, number int, blockerRepo string, blockerNumber int, blocked bool) error
	// A waiting deploy's answer (#3587).
	ReviewDeployments(ctx context.Context, repo string, runID int, environments []int64, approve bool, comment string) error
	// A repository's CI settings, for the app tools (#3706).
	SetActionsSecret(ctx context.Context, repo, name, value string) error
	SetActionsVariable(ctx context.Context, repo, name, value string) (bool, error)
	SetEnvironmentGate(ctx context.Context, repo, environment string, reviewers []string) error
	// A new app's repository (#3708).
	MakeRepository(ctx context.Context, owner, name, description string) (githubmcp.Repository, bool, error)
}

// forgeGitLabWrites is what the writes ask of GitLab; a test gives a fake.
type forgeGitLabWrites interface {
	Comment(ctx context.Context, project string, number int, mr bool, body string) error
	SetLabels(ctx context.Context, project string, number int, mr bool, add, remove []string) error
	SetState(ctx context.Context, project string, number int, mr, closed bool) error
	MergeMethods(ctx context.Context, project string) ([]string, error)
	Merge(ctx context.Context, project string, number int, sha string, squash, auto bool) error
	Approve(ctx context.Context, project string, number int, sha string) (map[string]any, error)
	RetryPipeline(ctx context.Context, project string, pipelineID int) (map[string]any, error)
	FailedLog(ctx context.Context, project string, pipelineID int, job string) (string, error)
	MRDiff(ctx context.Context, project string, number int) (map[string]any, error)
	ProjectLabels(ctx context.Context, project string) ([]string, map[string]string, error)
}

// forgeLinearWrites is what the writes ask of Linear; a test gives a fake.
type forgeLinearWrites interface {
	Comment(ctx context.Context, identifier, body string) (string, error)
	SetLabels(ctx context.Context, identifier string, add, remove []string) error
	SetState(ctx context.Context, identifier string, closed bool) error
	Labels(ctx context.Context, identifier string) ([]string, map[string]string, error)
	// The plan's (#3271).
	AddChild(ctx context.Context, epic, title string, labels []string) (string, string, error)
	SetParent(ctx context.Context, identifier, epic string) error
	SetBlockedBy(ctx context.Context, identifier, blocker string, blocked bool) error
}

func (d *Daemon) registerForgeWrites() {
	On(d, wire.CallForgeComment, func(ctx context.Context, _ *Client, r wire.ForgeCommentRequest) (wire.ForgeDone, error) {
		return d.forgeComment(ctx, r)
	})
	On(d, wire.CallForgeLabel, func(ctx context.Context, _ *Client, r wire.ForgeLabelRequest) (wire.ForgeDone, error) {
		return d.forgeLabel(ctx, r)
	})
	On(d, wire.CallForgeLabels, func(ctx context.Context, _ *Client, r wire.ForgeNodeRequest) (wire.ForgeLabels, error) {
		return d.forgeLabels(ctx, r)
	})
	On(d, wire.CallForgeClose, func(ctx context.Context, _ *Client, r wire.ForgeCloseRequest) (wire.ForgeDone, error) {
		return d.forgeClose(ctx, r)
	})
	On(d, wire.CallForgeMerge, func(ctx context.Context, _ *Client, r wire.ForgeMergeRequest) (wire.ForgeDone, error) {
		return d.forgeMerge(ctx, r)
	})
	On(d, wire.CallForgeApprove, func(ctx context.Context, _ *Client, r wire.ForgeApproveRequest) (wire.ForgeDone, error) {
		return d.forgeApprove(ctx, r)
	})
	On(d, wire.CallForgeRerun, func(ctx context.Context, _ *Client, r wire.ForgeNodeRequest) (wire.ForgeDone, error) {
		return d.forgeRerun(ctx, r)
	})
	On(d, wire.CallForgeLog, func(ctx context.Context, _ *Client, r wire.ForgeLogRequest) (wire.ForgeLog, error) {
		return d.forgeLog(ctx, r)
	})
	On(d, wire.CallForgeDiff, func(ctx context.Context, _ *Client, r wire.ForgeNodeRequest) (wire.ForgeDiff, error) {
		return d.forgeDiff(ctx, r)
	})
}

// forgeTarget is the item a write is on, and the forge to write it with: one of github, gitlab
// (with its project there), forgejo or bitbucket (with its repository there, in project), linear (with its identifier), jira (with its key, in identifier) or
// boards (with its project and its id, in number).
type forgeTarget struct {
	repo       forgeRepo
	number     int
	pr         bool
	github     forgeGitHub
	gitlab     forgeGitLab
	project    string
	linear     forgeLinear
	jira       forgeJira
	boards     forgeAzureBoards
	forgejo    forgeForgejo
	bitbucket  forgeBitbucket
	identifier string
}

// forgeTargetOf is node's forge, or why there is none. prOnly refuses an issue.
func (d *Daemon) forgeTargetOf(ctx context.Context, method string, node wire.LineageNode, prOnly bool) (forgeTarget, error) {
	if prOnly && node.Kind != lineage.KindPR {
		return forgeTarget{}, Invalid("%s: %s is not a pull request", method, node.Ref)
	}
	if identifier, ok := strings.CutPrefix(node.Ref, "linear:"); ok && node.Kind == lineage.KindIssue && linearLabel.MatchString(identifier) {
		l, err := d.forgeLinear()
		if err != nil {
			return forgeTarget{}, err
		}
		return forgeTarget{linear: l, identifier: identifier}, nil
	}
	if key, ok := strings.CutPrefix(node.Ref, "jira:"); ok && node.Kind == lineage.KindIssue && linearLabel.MatchString(key) {
		j, err := d.forgeJira()
		if err != nil {
			return forgeTarget{}, err
		}
		return forgeTarget{jira: j, identifier: key}, nil
	}
	if project, id, ok := boardsOfNode(node); ok {
		b, err := d.forgeAzureBoards()
		if err != nil {
			return forgeTarget{}, err
		}
		return forgeTarget{boards: b, project: project, number: id}, nil
	}
	if repo, number, ok := forgejoOfNode(node); ok {
		fj, named, _, err := d.forgejoOf(ctx, method, repo)
		if err != nil {
			return forgeTarget{}, err
		}
		return forgeTarget{forgejo: fj, project: named, number: number, pr: node.Kind == lineage.KindPR}, nil
	}
	if repo, number, ok := bitbucketOfNode(node); ok {
		bb, named, _, err := d.bitbucketOf(ctx, method, repo)
		if err != nil {
			return forgeTarget{}, err
		}
		return forgeTarget{bitbucket: bb, project: named, number: number, pr: node.Kind == lineage.KindPR}, nil
	}
	repo, number, ok := nodeOfRepo(node)
	if !ok {
		return forgeTarget{}, Invalid("%s: %s is not an issue or a pull request on GitHub, GitLab, Forgejo, Bitbucket, Linear, Jira or Azure Boards", method, node.Ref)
	}
	t := forgeTarget{repo: repo, number: number, pr: node.Kind == lineage.KindPR}
	if repo.forge == "gitlab" {
		gl, project, _, err := d.gitlabOf(ctx, method, repo)
		if err != nil {
			return forgeTarget{}, err
		}
		t.gitlab, t.project = gl, project
		return t, nil
	}
	gh, err := d.forgeGitHub()
	if err != nil {
		return forgeTarget{}, err
	}
	t.github = gh
	return t, nil
}

// forgeWrote forgets every answer kept, so the page's next read shows the write.
func (d *Daemon) forgeWrote() {
	d.forgeMu.Lock()
	defer d.forgeMu.Unlock()
	d.forgeCache = nil
}

func (d *Daemon) forgeComment(ctx context.Context, r wire.ForgeCommentRequest) (wire.ForgeDone, error) {
	const method = "forge/comment"
	body := strings.TrimSpace(r.Body)
	if body == "" {
		return wire.ForgeDone{}, Invalid("%s: write the comment first", method)
	}
	if len(body) > forgeCommentMost {
		return wire.ForgeDone{}, Invalid("%s: a comment is at most %d bytes", method, forgeCommentMost)
	}
	t, err := d.forgeTargetOf(ctx, method, r.Node, false)
	if err != nil {
		return wire.ForgeDone{}, err
	}
	var url string
	switch {
	case t.linear != nil:
		url, err = t.linear.Comment(ctx, t.identifier, body)
	case t.jira != nil:
		url, err = t.jira.Comment(ctx, t.identifier, body)
	case t.boards != nil:
		url, err = t.boards.Comment(ctx, t.project, t.number, body)
	case t.forgejo != nil:
		url, err = t.forgejo.Comment(ctx, t.project, t.number, body)
	case t.bitbucket != nil:
		url, err = t.bitbucket.Comment(ctx, t.project, t.number, t.pr, body)
	case t.gitlab != nil:
		err = t.gitlab.Comment(ctx, t.project, t.number, t.pr, body)
	default:
		var out map[string]any
		out, err = t.github.CommentOnPR(ctx, t.repo.path, t.number, body)
		url, _ = out["url"].(string)
	}
	if err != nil {
		return wire.ForgeDone{}, err
	}
	d.forgeWrote()
	return wire.ForgeDone{URL: optional(url)}, nil
}

// labelNames are the names given, trimmed, each once, or why not.
func labelNames(method, what string, names []string) ([]string, error) {
	out := []string{}
	for _, n := range names {
		if n = strings.TrimSpace(n); n != "" && !slices.Contains(out, n) {
			out = append(out, n)
		}
	}
	if len(out) > forgeLabelsMost {
		return nil, Invalid("%s: at most %d labels to %s at once", method, forgeLabelsMost, what)
	}
	return out, nil
}

func (d *Daemon) forgeLabel(ctx context.Context, r wire.ForgeLabelRequest) (wire.ForgeDone, error) {
	const method = "forge/label"
	add, err := labelNames(method, "add", r.Add)
	if err != nil {
		return wire.ForgeDone{}, err
	}
	remove, err := labelNames(method, "take off", r.Remove)
	if err != nil {
		return wire.ForgeDone{}, err
	}
	if len(add)+len(remove) == 0 {
		return wire.ForgeDone{}, Invalid("%s: name a label to add or take off", method)
	}
	t, err := d.forgeTargetOf(ctx, method, r.Node, false)
	if err != nil {
		return wire.ForgeDone{}, err
	}
	switch {
	case t.linear != nil:
		err = t.linear.SetLabels(ctx, t.identifier, add, remove)
	case t.jira != nil:
		err = t.jira.SetLabels(ctx, t.identifier, add, remove)
	case t.boards != nil:
		err = t.boards.SetTags(ctx, t.project, t.number, add, remove)
	case t.forgejo != nil:
		err = t.forgejo.SetLabels(ctx, t.project, t.number, add, remove)
	case t.bitbucket != nil && t.pr:
		err = Invalid("%s: %s", method, bitbucketmcp.NoPRLabels)
	case t.bitbucket != nil:
		err = t.bitbucket.SetLabels(ctx, t.project, t.number, add, remove)
	case t.gitlab != nil:
		err = t.gitlab.SetLabels(ctx, t.project, t.number, t.pr, add, remove)
	default:
		err = t.github.SetLabels(ctx, t.repo.path, t.number, add, remove)
	}
	if err != nil {
		return wire.ForgeDone{}, err
	}
	d.forgeWrote()
	return wire.ForgeDone{}, nil
}

func (d *Daemon) forgeLabels(ctx context.Context, r wire.ForgeNodeRequest) (wire.ForgeLabels, error) {
	t, err := d.forgeTargetOf(ctx, "forge/labels", r.Node, false)
	if err != nil {
		return wire.ForgeLabels{}, err
	}
	var names []string
	var colors map[string]string
	switch {
	case t.linear != nil:
		names, colors, err = t.linear.Labels(ctx, t.identifier)
	case t.jira != nil:
		names, colors, err = t.jira.Labels(ctx, t.identifier)
	case t.boards != nil:
		names, colors, err = t.boards.Labels(ctx, t.project, t.number)
	case t.forgejo != nil:
		names, colors, err = t.forgejo.RepoLabels(ctx, t.project)
	case t.bitbucket != nil && t.pr:
		err = Invalid("forge/labels: %s", bitbucketmcp.NoPRLabels)
	case t.bitbucket != nil:
		names, err = t.bitbucket.RepoLabels(ctx, t.project)
	case t.gitlab != nil:
		names, colors, err = t.gitlab.ProjectLabels(ctx, t.project)
	default:
		names, colors, err = t.github.RepoLabels(ctx, t.repo.path)
	}
	if err != nil {
		return wire.ForgeLabels{}, err
	}
	return wire.ForgeLabels{Labels: forgeLabelsOf(names, colors)}, nil
}

func (d *Daemon) forgeClose(ctx context.Context, r wire.ForgeCloseRequest) (wire.ForgeDone, error) {
	const method = "forge/close"
	t, err := d.forgeTargetOf(ctx, method, r.Node, false)
	if err != nil {
		return wire.ForgeDone{}, err
	}
	transition := strings.TrimSpace(deref(r.Transition))
	if transition != "" && t.jira == nil && t.boards == nil {
		return wire.ForgeDone{}, Invalid("%s: only a Jira issue or an Azure Boards work item moves by a transition", method)
	}
	closed := r.Reopen == nil || !*r.Reopen
	switch {
	case transition != "" && t.boards != nil:
		err = t.boards.Transition(ctx, t.project, t.number, transition)
	case transition != "":
		err = t.jira.Transition(ctx, t.identifier, transition)
	case t.boards != nil:
		err = t.boards.SetState(ctx, t.project, t.number, closed)
	case t.jira != nil:
		err = t.jira.SetState(ctx, t.identifier, closed)
	case t.linear != nil:
		err = t.linear.SetState(ctx, t.identifier, closed)
	case t.forgejo != nil:
		err = t.forgejo.SetState(ctx, t.project, t.number, closed)
	case t.bitbucket != nil:
		err = t.bitbucket.SetState(ctx, t.project, t.number, t.pr, closed)
	case t.gitlab != nil:
		err = t.gitlab.SetState(ctx, t.project, t.number, t.pr, closed)
	default:
		err = t.github.SetState(ctx, t.repo.path, t.number, closed)
	}
	if err != nil {
		return wire.ForgeDone{}, err
	}
	d.forgeWrote()
	return wire.ForgeDone{}, nil
}

func (d *Daemon) forgeMerge(ctx context.Context, r wire.ForgeMergeRequest) (wire.ForgeDone, error) {
	const method = "forge/merge"
	if strings.TrimSpace(r.Sha) == "" {
		return wire.ForgeDone{}, Invalid("%s: sha is needed: the head commit that the page shows", method)
	}
	t, err := d.forgeTargetOf(ctx, method, r.Node, true)
	if err != nil {
		return wire.ForgeDone{}, err
	}
	how := ""
	if r.Method != nil {
		how = string(*r.Method)
	}
	auto := r.Auto != nil && *r.Auto
	if t.forgejo != nil {
		if err := d.forgejoMerge(ctx, method, t, r.Sha, how, auto); err != nil {
			return wire.ForgeDone{}, err
		}
		d.forgeWrote()
		return wire.ForgeDone{Auto: optionalTrue(auto)}, nil
	}
	if t.bitbucket != nil {
		if err := d.bitbucketMerge(ctx, method, t, r.Sha, how, auto); err != nil {
			return wire.ForgeDone{}, err
		}
		d.forgeWrote()
		return wire.ForgeDone{}, nil
	}
	if t.gitlab != nil {
		methods, err := t.gitlab.MergeMethods(ctx, t.project)
		if err != nil {
			return wire.ForgeDone{}, err
		}
		if how == "" {
			how = methods[0]
		}
		if !slices.Contains(methods, how) {
			return wire.ForgeDone{}, Invalid("%s: this project merges by %s", method, strings.Join(methods, " or "))
		}
		if err := t.gitlab.Merge(ctx, t.project, t.number, r.Sha, how == "squash", auto); err != nil {
			return wire.ForgeDone{}, err
		}
		d.forgeWrote()
		return wire.ForgeDone{Auto: optionalTrue(auto)}, nil
	}
	if how == "" {
		p, err := t.github.ItemPage(ctx, t.repo.path, t.number, "")
		if err != nil {
			return wire.ForgeDone{}, err
		}
		if len(p.MergeMethods) == 0 {
			return wire.ForgeDone{}, Invalid("%s: %s allows no merge method", method, t.repo.path)
		}
		how = p.MergeMethods[0]
	}
	out, err := t.github.MergeBy(ctx, t.repo.path, t.number, r.Sha, how, auto)
	if err != nil {
		return wire.ForgeDone{}, err
	}
	d.forgeWrote()
	url, _ := out["url"].(string)
	return wire.ForgeDone{URL: optional(url), Auto: optionalTrue(auto)}, nil
}

func (d *Daemon) forgeApprove(ctx context.Context, r wire.ForgeApproveRequest) (wire.ForgeDone, error) {
	const method = "forge/approve"
	if strings.TrimSpace(r.Sha) == "" {
		return wire.ForgeDone{}, Invalid("%s: sha is needed: the head commit that the page shows", method)
	}
	t, err := d.forgeTargetOf(ctx, method, r.Node, true)
	if err != nil {
		return wire.ForgeDone{}, err
	}
	var url string
	switch {
	case t.forgejo != nil:
		url, err = t.forgejo.Approve(ctx, t.project, t.number, r.Sha)
	case t.bitbucket != nil:
		url, err = t.bitbucket.Approve(ctx, t.project, t.number, r.Sha)
	case t.gitlab != nil:
		_, err = t.gitlab.Approve(ctx, t.project, t.number, r.Sha)
	default:
		var out map[string]any
		out, err = t.github.ReviewPR(ctx, t.repo.path, t.number, r.Sha, true, "")
		url, _ = out["url"].(string)
	}
	if err != nil {
		return wire.ForgeDone{}, err
	}
	d.forgeWrote()
	return wire.ForgeDone{URL: optional(url)}, nil
}

// actionsRun is an Actions run's id in a check's link: …/actions/runs/123/job/456.
var actionsRun = regexp.MustCompile(`/actions/runs/([0-9]+)(?:/|$)`)

// failedRuns are the Actions runs of a pull request's failing checks, each once, and of the one
// check named when one is.
func failedRuns(checks []forgeCheckLink, only string) []int {
	var runs []int
	for _, c := range checks {
		if c.state != "failing" || (only != "" && c.name != only) {
			continue
		}
		if m := actionsRun.FindStringSubmatch(c.url); m != nil {
			if id, err := strconv.Atoi(m[1]); err == nil && !slices.Contains(runs, id) {
				runs = append(runs, id)
			}
		}
	}
	return runs
}

type forgeCheckLink struct{ name, state, url string }

// githubFailedRuns reads the pull request now, not from the cache: its head may have moved.
func githubFailedRuns(ctx context.Context, t forgeTarget, only string) ([]int, error) {
	p, err := t.github.ItemPage(ctx, t.repo.path, t.number, "")
	if err != nil {
		return nil, err
	}
	var checks []forgeCheckLink
	for _, c := range p.CheckRuns {
		checks = append(checks, forgeCheckLink{c.Name, c.State, c.URL})
	}
	return failedRuns(checks, only), nil
}

func (d *Daemon) forgeRerun(ctx context.Context, r wire.ForgeNodeRequest) (wire.ForgeDone, error) {
	const method = "forge/rerun"
	t, err := d.forgeTargetOf(ctx, method, r.Node, true)
	if err != nil {
		return wire.ForgeDone{}, err
	}
	if t.forgejo != nil {
		return wire.ForgeDone{}, Invalid("%s: %s", method, forgejoNoChecksAPI)
	}
	if t.bitbucket != nil {
		return d.bitbucketRerun(ctx, method, t, r.Node.Ref)
	}
	if t.gitlab != nil {
		p, err := t.gitlab.ItemPage(ctx, t.project, t.number, true, "")
		if err != nil {
			return wire.ForgeDone{}, err
		}
		if p.Pipeline == 0 {
			return wire.ForgeDone{}, Invalid("%s: %s has no pipeline to retry", method, r.Node.Ref)
		}
		out, err := t.gitlab.RetryPipeline(ctx, t.project, p.Pipeline)
		if err != nil {
			return wire.ForgeDone{}, err
		}
		d.forgeWrote()
		url, _ := out["url"].(string)
		return wire.ForgeDone{URL: optional(url), Reran: new(int64(1))}, nil
	}
	runs, err := githubFailedRuns(ctx, t, "")
	if err != nil {
		return wire.ForgeDone{}, err
	}
	if len(runs) == 0 {
		return wire.ForgeDone{}, Invalid("%s: %s has no failed Actions run to rerun", method, r.Node.Ref)
	}
	var url string
	for _, run := range runs {
		out, err := t.github.RerunFailed(ctx, t.repo.path, run)
		if err != nil {
			return wire.ForgeDone{}, err
		}
		url, _ = out["url"].(string)
	}
	d.forgeWrote()
	return wire.ForgeDone{URL: optional(url), Reran: new(int64(len(runs)))}, nil
}

func (d *Daemon) forgeLog(ctx context.Context, r wire.ForgeLogRequest) (wire.ForgeLog, error) {
	const method = "forge/log"
	t, err := d.forgeTargetOf(ctx, method, r.Node, true)
	if err != nil {
		return wire.ForgeLog{}, err
	}
	check := strings.TrimSpace(deref(r.Check))
	if t.forgejo != nil {
		return wire.ForgeLog{Text: forgejoNoChecksAPI + "."}, nil
	}
	if t.bitbucket != nil {
		return bitbucketLog(ctx, t, check)
	}
	if t.gitlab != nil {
		p, err := t.gitlab.ItemPage(ctx, t.project, t.number, true, "")
		if err != nil {
			return wire.ForgeLog{}, err
		}
		if p.Pipeline == 0 {
			return wire.ForgeLog{}, Invalid("%s: %s has no pipeline", method, r.Node.Ref)
		}
		// A GitLab check is "stage: job"; its log is the job's.
		if _, job, ok := strings.Cut(check, ": "); ok {
			check = job
		}
		text, err := t.gitlab.FailedLog(ctx, t.project, p.Pipeline, check)
		return wire.ForgeLog{Text: text}, err
	}
	runs, err := githubFailedRuns(ctx, t, check)
	if err != nil {
		return wire.ForgeLog{}, err
	}
	if len(runs) == 0 {
		return wire.ForgeLog{Text: "No failed Actions run."}, nil
	}
	var parts []string
	for _, run := range runs {
		text, err := t.github.FailedLog(ctx, t.repo.path, run, check)
		if err != nil {
			return wire.ForgeLog{}, err
		}
		parts = append(parts, text)
	}
	return wire.ForgeLog{Text: strings.Join(parts, "\n\n")}, nil
}

func (d *Daemon) forgeDiff(ctx context.Context, r wire.ForgeNodeRequest) (wire.ForgeDiff, error) {
	t, err := d.forgeTargetOf(ctx, "forge/diff", r.Node, true)
	if err != nil {
		return wire.ForgeDiff{}, err
	}
	var out map[string]any
	switch {
	case t.forgejo != nil:
		out, err = t.forgejo.PRDiff(ctx, t.project, t.number)
	case t.bitbucket != nil:
		out, err = t.bitbucket.PRDiff(ctx, t.project, t.number)
	case t.gitlab != nil:
		out, err = t.gitlab.MRDiff(ctx, t.project, t.number)
	default:
		out, err = t.github.PRDiff(ctx, t.repo.path, t.number, "")
	}
	if err != nil {
		return wire.ForgeDiff{}, err
	}
	// The connectors' diff is the views' agents/open-diff's (#1341), which is this one's shape.
	b, err := json.Marshal(out)
	if err != nil {
		return wire.ForgeDiff{}, err
	}
	diff := wire.ForgeDiff{Files: []wire.ForgeDiffFile{}}
	if err := json.Unmarshal(b, &diff); err != nil {
		return wire.ForgeDiff{}, fmt.Errorf("forge/diff: %w", err)
	}
	return diff, nil
}

// mergeMethodsOf are the forge's merge methods on the wire, the default first.
func mergeMethodsOf(methods []string) []wire.ForgeMergeMethod {
	out := []wire.ForgeMergeMethod{}
	for _, m := range methods {
		out = append(out, wire.ForgeMergeMethod(m))
	}
	return out
}

// forgeStartOf is the new-agent form for an issue (Start Agent), as the GitHub issues view fills it
// (#834): the prompt names the issue and how to read it, and the session is labelled with it.
func forgeStartOf(i wire.ForgeItem) *wire.ForgeStart {
	if i.Node.Kind != lineage.KindIssue {
		return nil
	}
	url := deref(i.URL)
	if identifier, ok := strings.CutPrefix(i.Node.Ref, "linear:"); ok {
		return &wire.ForgeStart{Prompt: fmt.Sprintf("%s: %s\n\nWork on this Linear issue: %s", identifier, i.Title, url),
			Labels: []string{identifier}, Worktree: optional(identifier + " " + i.Title)}
	}
	if key, ok := strings.CutPrefix(i.Node.Ref, "jira:"); ok {
		return &wire.ForgeStart{Prompt: fmt.Sprintf("%s: %s\n\nWork on this Jira issue: %s", key, i.Title, url),
			Labels: []string{key}, Worktree: optional(key + " " + i.Title)}
	}
	if _, id, ok := boardsOfNode(i.Node); ok {
		key := "AB#" + strconv.Itoa(id)
		return &wire.ForgeStart{Prompt: fmt.Sprintf("%s: %s\n\nWork on this Azure Boards work item: %s\n\n"+
			"Name %s in the pull request's title, so Azure Boards links it.", key, i.Title, url, key),
			Labels: []string{key}, Worktree: optional(strconv.Itoa(id) + " " + i.Title)}
	}
	if _, n, ok := forgejoOfNode(i.Node); ok {
		return forgejoStart(i, n)
	}
	if _, n, ok := bitbucketOfNode(i.Node); ok {
		return bitbucketStart(i, n)
	}
	repo, n, ok := nodeOfRepo(i.Node)
	if !ok {
		return nil
	}
	prompt := fmt.Sprintf("#%d: %s\n\nWork on this GitLab issue: %s", n, i.Title, url)
	if repo.forge == "github" {
		on := " --repo " + repo.path
		prompt = fmt.Sprintf("#%d: %s\n\nWork on this GitHub issue (`gh issue view %d%s`).\n\n"+
			"First assign it to yourself: `gh issue edit %d%s --add-assignee @me`.", n, i.Title, n, on, n, on)
	}
	return &wire.ForgeStart{Prompt: prompt, Labels: []string{"#" + strconv.Itoa(n)}, Worktree: optional(strconv.Itoa(n) + " " + i.Title)}
}

func optionalTrue(b bool) *bool {
	if !b {
		return nil
	}
	return &b
}
