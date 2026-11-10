package agentsd

import (
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"slices"
	"strconv"
	"strings"

	"github.com/alexec/agents/Go/internal/githubmcp"
	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/wire"
)

// The forge writes (#3130): the actions of the GitHub, GitLab, Forgejo (#3753), Bitbucket (#3786), Azure DevOps (#3803), Linear, Jira (#3260) and Azure
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
	// A forge request's answer (#3865).
	SetBody(ctx context.Context, repo string, number int, body string) error
	Unassign(ctx context.Context, repo string, number int, logins []string) error
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

// forgeTarget is the item a write is on, and the forge on the interface (#4329) to write it
// with, with its ref there.
type forgeTarget struct {
	pr    bool
	forge Forge
	ref   forgeRef
}

// forgeTargetOf is node's forge, or why there is none. prOnly refuses an issue; every forge with
// pull requests is on the interface (#4356), so a pull request's target has its forge.
func (d *Daemon) forgeTargetOf(ctx context.Context, method string, node wire.LineageNode, prOnly bool) (forgeTarget, error) {
	if prOnly && node.Kind != lineage.KindPR {
		return forgeTarget{}, Invalid("%s: %s is not a pull request", method, node.Ref)
	}
	if f, ref, ok := d.forgeOwning(node); ok {
		return forgeTarget{forge: f, ref: ref, pr: ref.pr()}, nil
	}
	return forgeTarget{}, Invalid("%s: %s is not an issue or a pull request on GitHub, GitLab, Forgejo, Bitbucket, Azure DevOps, Linear, Jira or Azure Boards", method, node.Ref)
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
	done, err := t.forge.Comment(ctx, t.ref, body)
	if err != nil {
		return wire.ForgeDone{}, forgeCannotErr(method, t.forge, err)
	}
	d.forgeWrote()
	return wire.ForgeDone{URL: done.URL}, nil
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
	if err := t.forge.SetLabels(ctx, t.ref, add, remove); err != nil {
		return wire.ForgeDone{}, forgeCannotErr(method, t.forge, err)
	}
	d.forgeWrote()
	return wire.ForgeDone{}, nil
}

func (d *Daemon) forgeLabels(ctx context.Context, r wire.ForgeNodeRequest) (wire.ForgeLabels, error) {
	t, err := d.forgeTargetOf(ctx, "forge/labels", r.Node, false)
	if err != nil {
		return wire.ForgeLabels{}, err
	}
	labels, err := t.forge.Labels(ctx, t.ref)
	if err != nil {
		return wire.ForgeLabels{}, forgeCannotErr("forge/labels", t.forge, err)
	}
	return wire.ForgeLabels{Labels: labels}, nil
}

func (d *Daemon) forgeClose(ctx context.Context, r wire.ForgeCloseRequest) (wire.ForgeDone, error) {
	const method = "forge/close"
	t, err := d.forgeTargetOf(ctx, method, r.Node, false)
	if err != nil {
		return wire.ForgeDone{}, err
	}
	transition := strings.TrimSpace(deref(r.Transition))
	closed := r.Reopen == nil || !*r.Reopen
	if err := t.forge.SetState(ctx, t.ref, closed, transition); err != nil {
		return wire.ForgeDone{}, forgeCannotErr(method, t.forge, err)
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
	done, err := t.forge.Merge(ctx, t.ref, r.Sha, how, r.Auto != nil && *r.Auto)
	if err != nil {
		return wire.ForgeDone{}, forgeCannotErr(method, t.forge, err)
	}
	d.forgeWrote()
	return done, nil
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
	done, err := t.forge.Approve(ctx, t.ref, r.Sha)
	if err != nil {
		return wire.ForgeDone{}, forgeCannotErr(method, t.forge, err)
	}
	d.forgeWrote()
	return wire.ForgeDone{URL: done.URL}, nil
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

func (d *Daemon) forgeRerun(ctx context.Context, r wire.ForgeNodeRequest) (wire.ForgeDone, error) {
	const method = "forge/rerun"
	t, err := d.forgeTargetOf(ctx, method, r.Node, true)
	if err != nil {
		return wire.ForgeDone{}, err
	}
	done, err := t.forge.Rerun(ctx, t.ref)
	if err != nil {
		return wire.ForgeDone{}, forgeCannotErr(method, t.forge, err)
	}
	d.forgeWrote()
	return done, nil
}

func (d *Daemon) forgeLog(ctx context.Context, r wire.ForgeLogRequest) (wire.ForgeLog, error) {
	const method = "forge/log"
	t, err := d.forgeTargetOf(ctx, method, r.Node, true)
	if err != nil {
		return wire.ForgeLog{}, err
	}
	out, err := t.forge.Log(ctx, t.ref, strings.TrimSpace(deref(r.Check)))
	return out, forgeCannotErr(method, t.forge, err)
}

func (d *Daemon) forgeDiff(ctx context.Context, r wire.ForgeNodeRequest) (wire.ForgeDiff, error) {
	t, err := d.forgeTargetOf(ctx, "forge/diff", r.Node, true)
	if err != nil {
		return wire.ForgeDiff{}, err
	}
	diff, err := t.forge.Diff(ctx, t.ref)
	return diff, forgeCannotErr("forge/diff", t.forge, err)
}

// diffOf is a connector's diff on the wire.
func diffOf(out map[string]any) (wire.ForgeDiff, error) {
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
