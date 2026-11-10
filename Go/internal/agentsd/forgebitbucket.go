package agentsd

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/bitbucketmcp"
	"github.com/alexec/agents/Go/internal/connections"
	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/wire"
)

// Bitbucket Cloud on the Work pages (#3786, after Forgejo's #3753): the issues and pull
// requests of the folders whose git remote is on bitbucket.org, read and written with the
// Bitbucket connection (#3785) through bitbucketmcp.RealBitbucket, a call per repository, as
// Bitbucket has no list across repositories. An issue or a pull request is the node
// bitbucket:workspace/repo#12, in lower case; Bitbucket numbers them apart, so the node's kind
// says which.
//
// Bitbucket's issues have no labels: their kind and component are their labels, as the
// bitbucket server's events say them. A feature:<name> component is the issue's feature on
// Work ▸ Features (#3880); Bitbucket has no epics, sub-issues or dependencies, so it has no plan
// and no board. Its pull requests have none. Rerun failed runs each
// failed Pipelines run again, every step, as Pipelines cannot run only the failed ones.
// bitbucketForge's Caps say what Bitbucket cannot do.

// forgeBitbucket is what the forge reads and writes ask of Bitbucket; a test gives a fake.
type forgeBitbucket interface {
	Search(ctx context.Context, repos []string, f bitbucketmcp.SearchFilter, after string, first int) (bitbucketmcp.SearchPage, error)
	ItemPage(ctx context.Context, repo string, number int, pr bool, before string) (bitbucketmcp.ItemDetail, error)
	Comment(ctx context.Context, repo string, number int, pr bool, body string) (string, error)
	SetLabels(ctx context.Context, repo string, number int, add, remove []string) error
	SetState(ctx context.Context, repo string, number int, pr, closed bool) error
	RepoLabels(ctx context.Context, repo string) ([]string, error)
	MergeMethods(ctx context.Context, repo string, number int) ([]string, error)
	Merge(ctx context.Context, repo string, number int, sha, method string) error
	Approve(ctx context.Context, repo string, number int, sha string) (string, error)
	PRDiff(ctx context.Context, repo string, number int) (map[string]any, error)
	RetryPipeline(ctx context.Context, repo string, run int) (map[string]any, error)
	FailedLog(ctx context.Context, repo string, run int, step string) (string, error)
	// What lineage asks (lineagebitbucket.go).
	Node(ctx context.Context, repo string, number int, pr bool) (bitbucketmcp.Node, error)
	MilestoneNode(ctx context.Context, repo string, id int) (bitbucketmcp.Node, error)
	Milestones(ctx context.Context, repo string) ([]bitbucketmcp.Milestone, error)
	CommitTime(ctx context.Context, repo, ref string) (time.Time, error)
	Compare(ctx context.Context, repo, base, head string) ([]bitbucketmcp.Commit, error)
	CommitPR(ctx context.Context, repo, sha string) (int, error)
	CostComment(ctx context.Context, repo string, number int, id, mark, body string) (string, error)
}

// bitbucketNoAutoMerge is why a merge when checks pass is refused: Bitbucket's API has none.
const bitbucketNoAutoMerge = "Bitbucket's API cannot merge when checks pass: merge once they have"

// bitbucketNoReopen is why a declined pull request is not opened again: Bitbucket cannot.
const bitbucketNoReopen = "Bitbucket cannot reopen a declined pull request: open a new one from its branch"

// bitbucketNoPlan is why a Bitbucket issue has no plan (#3880).
const bitbucketNoPlan = "Bitbucket's issues have no sub-issues or dependencies, so a Bitbucket issue has no plan"

// bitbucketOfNode is the repository, workspace/repo, and the number of a Bitbucket issue's or
// pull request's node.
func bitbucketOfNode(n wire.LineageNode) (string, int, bool) {
	rest, ok := strings.CutPrefix(n.Ref, "bitbucket:")
	at := strings.LastIndex(rest, "#")
	if !ok || (n.Kind != lineage.KindIssue && n.Kind != lineage.KindPR) || at < 0 || strings.Count(rest[:at], "/") != 1 {
		return "", 0, false
	}
	number, err := strconv.Atoi(rest[at+1:])
	if err != nil || number <= 0 || strings.HasPrefix(rest, "/") || strings.HasSuffix(rest[:at], "/") {
		return "", 0, false
	}
	return rest[:at], number, true
}

// bitbucketNode is an issue's or a pull request's node.
func bitbucketNode(repo string, number int, pr bool) wire.LineageNode {
	kind := lineage.KindIssue
	if pr {
		kind = lineage.KindPR
	}
	return wire.LineageNode{Kind: kind, Ref: "bitbucket:" + strings.ToLower(repo) + "#" + strconv.Itoa(number)}
}

// bitbucketConnectedAPI is the connected Bitbucket API, when its connection is usable; else "".
func (d *Daemon) bitbucketConnectedAPI() string {
	c, connected := d.bitbucketConnection()
	if !connected || !c.Usable(nowFunc()) {
		return ""
	}
	return bitbucketmcp.BaseURL(c.URL)
}

// bitbucketRepoAt is the Bitbucket Cloud repository a folder's remote names; read once, as
// GitLab's.
func (d *Daemon) bitbucketRepoAt(ctx context.Context, folder string) string {
	key := "bitbucket " + folder
	d.forgeMu.Lock()
	at, ok := d.forgeRoots[key]
	d.forgeMu.Unlock()
	if ok {
		return at[1]
	}
	gitCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	repo, _ := bitbucketmcp.RepoAt(gitCtx, folder)
	d.forgeMu.Lock()
	defer d.forgeMu.Unlock()
	if d.forgeRoots == nil || len(d.forgeRoots) >= forgeCached {
		d.forgeRoots = map[string][2]string{}
	}
	d.forgeRoots[key] = [2]string{connections.BitbucketSite, repo}
	return repo
}

// bitbucketForge is Bitbucket Cloud on the forge interface (#4329, #4355): the host's Bitbucket
// connection, through forgeBitbucket. Its Caps say what Bitbucket has not: a merge when checks
// pass, labels on a pull request, a way to reopen a declined pull request, and a plan.
type bitbucketForge struct {
	forgeNone
	d *Daemon
}

func (bitbucketForge) Name() string { return "bitbucket" }

func (bitbucketForge) Caps() forgeCaps {
	return forgeCaps{
		Issues: true, PRs: true,
		Issue:   forgeActions{Comment: true, Label: true, Close: true, Reopen: true},
		PR:      forgeActions{Comment: true, Close: true, Merge: true, Approve: true, Rerun: true, Log: true, Diff: true},
		Avatars: true,
		// An issue's comment count is on its own page only.
		CommentCount: "detail",
		Reasons: map[string]string{
			actionTransition: "only a Jira issue or an Azure Boards work item moves by a transition",
			actionAutoMerge:  bitbucketNoAutoMerge,
			actionLabel:      bitbucketmcp.NoPRLabels,
			actionReopen:     bitbucketNoReopen,
			actionPlan:       bitbucketNoPlan,
			actionAddChild:   bitbucketNoPlan,
			actionBlockedBy:  bitbucketNoPlan,
		},
	}
}

// Owns is bitbucket:workspace/repo#12, an issue or a pull request.
func (bitbucketForge) Owns(node wire.LineageNode) (forgeRef, bool) {
	repo, number, ok := bitbucketOfNode(node)
	if !ok {
		return forgeRef{}, false
	}
	return forgeRef{Node: node, Repo: repo, Number: number}, true
}

// bitbucketScope is the repositories on Bitbucket Cloud that a list reads, workspace/repo as
// their folders' remotes say them, each with a folder to act from (by its name in lower case),
// read at root, the connection's API.
type bitbucketScope struct {
	root     string
	repos    []string
	folderOf map[string]string
}

func (s bitbucketScope) Key() []any  { return []any{s.root, s.repos} }
func (s bitbucketScope) Empty() bool { return len(s.repos) == 0 }

// Sources is the repositories of folders on Bitbucket Cloud, each once: a folder whose remote is
// neither GitHub's nor GitLab's. With no connection, err says so.
func (b bitbucketForge) Sources(ctx context.Context, folders []string, _ bool) (forgeScope, error) {
	s := bitbucketScope{root: b.d.bitbucketConnectedAPI(), folderOf: map[string]string{}}
	found := false
	for _, f := range folders {
		if onGitHubOrGitLab(b.d.folderRepo(f)) {
			continue
		}
		repo := b.d.bitbucketRepoAt(ctx, f)
		if repo == "" {
			continue
		}
		found = true
		if _, seen := s.folderOf[strings.ToLower(repo)]; seen || s.root == "" {
			continue
		}
		s.folderOf[strings.ToLower(repo)] = f
		s.repos = append(s.repos, repo)
	}
	slices.Sort(s.repos)
	if found && s.root == "" {
		return s, errors.New(bitbucketmcp.NotConnected)
	}
	return s, nil
}

// List is a call for each repository, as Bitbucket has no list across repositories. Bitbucket
// has no boards, so a board's list has no Bitbucket items (#3938).
func (b bitbucketForge) List(ctx context.Context, scope forgeScope, f forgeFilter, cursor string, limit int) (forgePage, error) {
	s, _ := scope.(bitbucketScope)
	if f.Board != nil || s.Empty() {
		return forgePage{}, nil
	}
	sf := bitbucketmcp.SearchFilter{PRs: f.PRs, State: f.State, Label: f.Label, Assignee: f.Assignee, Query: f.Query, Feature: f.Feature}
	page, err := b.d.forgeBitbucket(s.root).Search(ctx, s.repos, sf, cursor, limit)
	var p forgePage
	for _, i := range page.Items {
		p.items = append(p.items, bitbucketItemOf(i, s.folderOf[strings.ToLower(i.Repo)]))
	}
	p.cursors, p.next = page.Cursors, page.Next
	return p, err
}

// of is the connected Bitbucket, r's repository as its folder's remote says it, and that folder.
func (b bitbucketForge) of(ctx context.Context, method string, r forgeRef) (forgeBitbucket, string, string, error) {
	return b.d.bitbucketOf(ctx, method, r.Repo)
}

func (b bitbucketForge) Item(ctx context.Context, r forgeRef, cursor string) (wire.ForgeItemDetail, error) {
	method := itemMethod(r.Node.Kind)
	bb, named, folder, err := b.of(ctx, method, r)
	if err != nil {
		return wire.ForgeItemDetail{}, err
	}
	p, err := bb.ItemPage(ctx, named, r.Number, r.pr(), cursor)
	if err != nil {
		if bitbucketmcp.IsNotFound(err) {
			return wire.ForgeItemDetail{}, Invalid("%s: %v", method, err)
		}
		return wire.ForgeItemDetail{}, err
	}
	out := wire.ForgeItemDetail{Item: bitbucketItemOf(p.Item, folder), Body: p.Body, Comments: []wire.ForgeComment{}, Cursor: optional(p.Before)}
	for _, c := range p.Thread {
		out.Comments = append(out.Comments, forgeCommentOf(c.Author, c.Avatar, c.Body, c.At, c.URL, c.Bot))
	}
	if !p.PR {
		out.Start = bitbucketStart(out.Item, r.Number)
		return out, nil
	}
	out.Checks = []wire.ForgeCheck{}
	for _, c := range p.CheckRuns {
		out.Checks = append(out.Checks, wire.ForgeCheck{Name: c.Name, State: c.State, URL: optional(c.URL)})
	}
	out.ReviewThreads, out.FilesChanged = new(int64(p.ReviewThreads)), new(int64(p.FilesChanged))
	out.Head = optional(p.Head)
	// The merge menu is a nicety: a page still reads when Bitbucket does not say the branch's.
	if p.State == "open" {
		if methods, err := bb.MergeMethods(ctx, named, r.Number); err == nil {
			out.MergeMethods = mergeMethodsOf(methods)
		}
	}
	return out, nil
}

// Labels are what an issue's labels can be: the kinds and the repository's components. A pull
// request has none.
func (b bitbucketForge) Labels(ctx context.Context, r forgeRef) ([]wire.ForgeLabel, error) {
	if r.pr() {
		return nil, cannot(actionLabel)
	}
	bb, named, _, err := b.of(ctx, "forge/labels", r)
	if err != nil {
		return nil, err
	}
	names, err := bb.RepoLabels(ctx, named)
	if err != nil {
		return nil, err
	}
	return forgeLabelsOf(names, nil), nil
}

func (b bitbucketForge) Diff(ctx context.Context, r forgeRef) (wire.ForgeDiff, error) {
	if !r.pr() {
		return wire.ForgeDiff{}, cannot(actionDiff)
	}
	bb, named, _, err := b.of(ctx, "forge/diff", r)
	if err != nil {
		return wire.ForgeDiff{}, err
	}
	out, err := bb.PRDiff(ctx, named, r.Number)
	if err != nil {
		return wire.ForgeDiff{}, err
	}
	return diffOf(out)
}

// Log is the end of the failed steps' logs of a pull request's Pipelines runs, or of the run of
// the check named.
func (b bitbucketForge) Log(ctx context.Context, r forgeRef, check string) (wire.ForgeLog, error) {
	if !r.pr() {
		return wire.ForgeLog{}, cannot(actionLog)
	}
	bb, named, _, err := b.of(ctx, "forge/log", r)
	if err != nil {
		return wire.ForgeLog{}, err
	}
	runs, err := bitbucketFailedRuns(ctx, bb, named, r.Number, check)
	if err != nil {
		return wire.ForgeLog{}, err
	}
	if len(runs) == 0 {
		if check != "" {
			return wire.ForgeLog{Text: check + " is not a Bitbucket Pipelines run: its log is on its own page."}, nil
		}
		return wire.ForgeLog{Text: "No failed Pipelines run."}, nil
	}
	var parts []string
	for _, run := range runs {
		text, err := bb.FailedLog(ctx, named, run, "")
		if err != nil {
			return wire.ForgeLog{}, err
		}
		parts = append(parts, text)
	}
	return wire.ForgeLog{Text: strings.Join(parts, "\n\n")}, nil
}

func (b bitbucketForge) Comment(ctx context.Context, r forgeRef, body string) (wire.ForgeDone, error) {
	bb, named, _, err := b.of(ctx, "forge/comment", r)
	if err != nil {
		return wire.ForgeDone{}, err
	}
	link, err := bb.Comment(ctx, named, r.Number, r.pr(), body)
	return wire.ForgeDone{URL: optional(link)}, err
}

func (b bitbucketForge) SetLabels(ctx context.Context, r forgeRef, add, remove []string) error {
	if r.pr() {
		return cannot(actionLabel)
	}
	bb, named, _, err := b.of(ctx, "forge/label", r)
	if err != nil {
		return err
	}
	return bb.SetLabels(ctx, named, r.Number, add, remove)
}

func (b bitbucketForge) SetState(ctx context.Context, r forgeRef, closed bool, transition string) error {
	switch {
	case transition != "":
		return cannot(actionTransition)
	case r.pr() && !closed:
		return cannot(actionReopen)
	}
	bb, named, _, err := b.of(ctx, "forge/close", r)
	if err != nil {
		return err
	}
	return bb.SetState(ctx, named, r.Number, r.pr(), closed)
}

// Merge merges a pull request by the method asked for, or the target branch's default.
func (b bitbucketForge) Merge(ctx context.Context, r forgeRef, sha, how string, auto bool) (wire.ForgeDone, error) {
	const method = "forge/merge"
	switch {
	case !r.pr():
		return wire.ForgeDone{}, cannot(actionMerge)
	case auto:
		return wire.ForgeDone{}, cannot(actionAutoMerge)
	}
	bb, named, _, err := b.of(ctx, method, r)
	if err != nil {
		return wire.ForgeDone{}, err
	}
	methods, err := bb.MergeMethods(ctx, named, r.Number)
	if err != nil {
		return wire.ForgeDone{}, err
	}
	if len(methods) == 0 {
		return wire.ForgeDone{}, Invalid("%s: the target branch allows no merge method here: merge it on Bitbucket", method)
	}
	if how == "" {
		how = methods[0]
	}
	if !slices.Contains(methods, how) {
		return wire.ForgeDone{}, Invalid("%s: this branch merges by %s", method, strings.Join(methods, " or "))
	}
	return wire.ForgeDone{}, bb.Merge(ctx, named, r.Number, sha, how)
}

func (b bitbucketForge) Approve(ctx context.Context, r forgeRef, sha string) (wire.ForgeDone, error) {
	if !r.pr() {
		return wire.ForgeDone{}, cannot(actionApprove)
	}
	bb, named, _, err := b.of(ctx, "forge/approve", r)
	if err != nil {
		return wire.ForgeDone{}, err
	}
	link, err := bb.Approve(ctx, named, r.Number, sha)
	return wire.ForgeDone{URL: optional(link)}, err
}

// Rerun runs each failed Pipelines run of a pull request again, every step, as Pipelines cannot
// run only the failed ones.
func (b bitbucketForge) Rerun(ctx context.Context, r forgeRef) (wire.ForgeDone, error) {
	const method = "forge/rerun"
	if !r.pr() {
		return wire.ForgeDone{}, cannot(actionRerun)
	}
	bb, named, _, err := b.of(ctx, method, r)
	if err != nil {
		return wire.ForgeDone{}, err
	}
	runs, err := bitbucketFailedRuns(ctx, bb, named, r.Number, "")
	if err != nil {
		return wire.ForgeDone{}, err
	}
	if len(runs) == 0 {
		return wire.ForgeDone{}, Invalid("%s: %s has no failed Pipelines run to rerun; another CI's checks run again on its own page", method, r.Node.Ref)
	}
	var url string
	for _, run := range runs {
		out, err := bb.RetryPipeline(ctx, named, run)
		if err != nil {
			return wire.ForgeDone{}, err
		}
		url, _ = out["url"].(string)
	}
	return wire.ForgeDone{URL: optional(url), Reran: new(int64(len(runs)))}, nil
}

// bitbucketOf is the connected Bitbucket, repo as its folder's remote says it, and that
// folder: a node names the repository in lower case.
func (d *Daemon) bitbucketOf(ctx context.Context, method, repo string) (forgeBitbucket, string, string, error) {
	root := d.bitbucketConnectedAPI()
	if root == "" {
		return nil, "", "", errors.New(bitbucketmcp.NotConnected)
	}
	for _, f := range d.folderPaths() {
		if onGitHubOrGitLab(d.folderRepo(f)) {
			continue
		}
		if named := d.bitbucketRepoAt(ctx, f); named != "" && strings.EqualFold(named, repo) {
			return d.forgeBitbucket(root), named, f, nil
		}
	}
	return nil, "", "", Invalid("%s: no folder here is on %s on Bitbucket", method, repo)
}

// forgeBitbucket is the Bitbucket API at root as the person's connection; the caller has
// checked there is one.
func (d *Daemon) forgeBitbucket(root string) forgeBitbucket {
	c, _ := d.bitbucketConnection()
	if d.newForgeBitbucket != nil {
		return d.newForgeBitbucket(root, c.User, c.Access)
	}
	token, email := c.Access, c.User
	return bitbucketmcp.NewRealBitbucket(root, func() string { return token }, func() string { return email }, nil)
}

// bitbucketItemOf is a Bitbucket item in the one model, from folder.
func bitbucketItemOf(i bitbucketmcp.Item, folder string) wire.ForgeItem {
	out := wire.ForgeItem{Node: bitbucketNode(i.Repo, i.Number, i.PR), Title: i.Title, State: i.State, URL: optional(i.URL),
		Folder: optional(folder), Labels: forgeLabelsOf(i.Labels, nil), Author: optional(i.Author), AuthorAvatar: optional(i.AuthorAvatar), Assignees: i.Assignees,
		Milestone: optional(i.Milestone), UpdatedAt: forgeDate(i.UpdatedAt), Comments: int64(i.Comments)}
	if out.Assignees == nil {
		out.Assignees = []string{}
	}
	if i.PR {
		// Bitbucket has no merge when checks pass.
		out.Draft, out.AutoMerge = new(i.Draft), new(false)
		out.Checks, out.Review, out.Mergeable = optional(i.Checks), optional(i.Review), optional(i.Mergeable)
		return out
	}
	// An issue's level and feature are its labels' (its component); Bitbucket has no parent.
	withHierarchy(&out, nil, 0, 0)
	return out
}

// bitbucketFailedRuns are the Pipelines runs of a pull request's failed checks, each once, of
// the check named only, when one is.
func bitbucketFailedRuns(ctx context.Context, bb forgeBitbucket, repo string, number int, only string) ([]int, error) {
	p, err := bb.ItemPage(ctx, repo, number, true, "")
	if err != nil {
		return nil, err
	}
	var runs []int
	for _, c := range p.CheckRuns {
		if c.Run == 0 || slices.Contains(runs, c.Run) || (only == "" && c.State != "failing") || (only != "" && c.Name != only) {
			continue
		}
		runs = append(runs, c.Run)
	}
	return runs, nil
}

// bitbucketStart is the new-agent form's prompt for a Bitbucket issue.
func bitbucketStart(i wire.ForgeItem, n int) *wire.ForgeStart {
	return &wire.ForgeStart{Prompt: fmt.Sprintf("#%d: %s\n\nWork on this Bitbucket issue: %s", n, i.Title, deref(i.URL)),
		Labels: []string{"#" + strconv.Itoa(n)}, Worktree: optional(strconv.Itoa(n) + " " + i.Title)}
}
