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
// bitbucket server's events say them. Its pull requests have none. Rerun failed runs each
// failed Pipelines run again, every step, as Pipelines cannot run only the failed ones.

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

// bitbucketSources adds to s the repositories of folders on Bitbucket Cloud: a folder whose
// remote is neither GitHub's nor GitLab's. With no connection, a list says so.
func (d *Daemon) bitbucketSources(ctx context.Context, s *forgeSources, folders []string) {
	s.bitbucketRoot = d.bitbucketConnectedAPI()
	found := false
	for _, f := range folders {
		if onGitHubOrGitLab(d.folderRepo(f)) {
			continue
		}
		repo := d.bitbucketRepoAt(ctx, f)
		if repo == "" {
			continue
		}
		found = true
		key := forgeRepo{"bitbucket", strings.ToLower(repo)}
		if _, seen := s.folderOf[key]; seen || s.bitbucketRoot == "" {
			continue
		}
		s.folderOf[key] = f
		s.bitbucket = append(s.bitbucket, repo)
	}
	slices.Sort(s.bitbucket)
	if found && s.bitbucketRoot == "" {
		s.bitbucketErr = errors.New(bitbucketmcp.NotConnected)
	}
}

// bitbucketPage is the Bitbucket page of a list.
func (d *Daemon) bitbucketPage(ctx context.Context, s forgeSources, f bitbucketmcp.SearchFilter, after string, limit int) forgePage {
	p := forgePage{forge: "bitbucket", err: s.bitbucketErr}
	if p.err != nil {
		return p
	}
	page, err := d.forgeBitbucket(s.bitbucketRoot).Search(ctx, s.bitbucket, f, after, limit)
	for _, i := range page.Items {
		p.items = append(p.items, bitbucketItemOf(i, s.folderOf[forgeRepo{"bitbucket", strings.ToLower(i.Repo)}]))
	}
	p.cursors, p.next, p.err = page.Cursors, page.Next, err
	return p
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

// bitbucketItem is an issue or pull request on Bitbucket.
func (d *Daemon) bitbucketItem(ctx context.Context, method, kind, repo string, number int, cursor string) (wire.ForgeItemDetail, error) {
	bb, named, folder, err := d.bitbucketOf(ctx, method, repo)
	if err != nil {
		return wire.ForgeItemDetail{}, err
	}
	p, err := bb.ItemPage(ctx, named, number, kind == lineage.KindPR, cursor)
	if err != nil {
		if bitbucketmcp.IsNotFound(err) {
			return wire.ForgeItemDetail{}, Invalid("%s: %v", method, err)
		}
		return wire.ForgeItemDetail{}, err
	}
	out := wire.ForgeItemDetail{Item: bitbucketItemOf(p.Item, folder), Body: p.Body, Comments: []wire.ForgeComment{}, Cursor: optional(p.Before)}
	for _, c := range p.Thread {
		out.Comments = append(out.Comments, forgeCommentOf(c.Author, c.Body, c.At, c.URL, c.Bot))
	}
	if !p.PR {
		out.Start = forgeStartOf(out.Item)
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
		if methods, err := bb.MergeMethods(ctx, named, number); err == nil {
			out.MergeMethods = mergeMethodsOf(methods)
		}
	}
	return out, nil
}

// bitbucketItemOf is a Bitbucket item in the one model, from folder.
func bitbucketItemOf(i bitbucketmcp.Item, folder string) wire.ForgeItem {
	out := wire.ForgeItem{Node: bitbucketNode(i.Repo, i.Number, i.PR), Title: i.Title, State: i.State, URL: optional(i.URL),
		Folder: optional(folder), Labels: forgeLabelsOf(i.Labels, nil), Author: optional(i.Author), Assignees: i.Assignees,
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

// bitbucketMerge merges a pull request by the method asked for, or the target branch's default.
func (d *Daemon) bitbucketMerge(ctx context.Context, method string, t forgeTarget, sha, how string, auto bool) error {
	if auto {
		return Invalid("%s: %s", method, bitbucketNoAutoMerge)
	}
	methods, err := t.bitbucket.MergeMethods(ctx, t.project, t.number)
	if err != nil {
		return err
	}
	if len(methods) == 0 {
		return Invalid("%s: the target branch allows no merge method here: merge it on Bitbucket", method)
	}
	if how == "" {
		how = methods[0]
	}
	if !slices.Contains(methods, how) {
		return Invalid("%s: this branch merges by %s", method, strings.Join(methods, " or "))
	}
	return t.bitbucket.Merge(ctx, t.project, t.number, sha, how)
}

// bitbucketFailedRuns are the Pipelines runs of a pull request's failed checks, each once, of
// the check named only, when one is.
func bitbucketFailedRuns(ctx context.Context, t forgeTarget, only string) ([]int, error) {
	p, err := t.bitbucket.ItemPage(ctx, t.project, t.number, true, "")
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

// bitbucketRerun runs each failed Pipelines run of a pull request again.
func (d *Daemon) bitbucketRerun(ctx context.Context, method string, t forgeTarget, ref string) (wire.ForgeDone, error) {
	runs, err := bitbucketFailedRuns(ctx, t, "")
	if err != nil {
		return wire.ForgeDone{}, err
	}
	if len(runs) == 0 {
		return wire.ForgeDone{}, Invalid("%s: %s has no failed Pipelines run to rerun; another CI's checks run again on its own page", method, ref)
	}
	var url string
	for _, run := range runs {
		out, err := t.bitbucket.RetryPipeline(ctx, t.project, run)
		if err != nil {
			return wire.ForgeDone{}, err
		}
		url, _ = out["url"].(string)
	}
	d.forgeWrote()
	return wire.ForgeDone{URL: optional(url), Reran: new(int64(len(runs)))}, nil
}

// bitbucketLog is the end of the failed steps' logs of a pull request's Pipelines runs, or of
// the run of the check named.
func bitbucketLog(ctx context.Context, t forgeTarget, check string) (wire.ForgeLog, error) {
	runs, err := bitbucketFailedRuns(ctx, t, check)
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
		text, err := t.bitbucket.FailedLog(ctx, t.project, run, "")
		if err != nil {
			return wire.ForgeLog{}, err
		}
		parts = append(parts, text)
	}
	return wire.ForgeLog{Text: strings.Join(parts, "\n\n")}, nil
}

// bitbucketStart is the new-agent form's prompt for a Bitbucket issue.
func bitbucketStart(i wire.ForgeItem, n int) *wire.ForgeStart {
	return &wire.ForgeStart{Prompt: fmt.Sprintf("#%d: %s\n\nWork on this Bitbucket issue: %s", n, i.Title, deref(i.URL)),
		Labels: []string{"#" + strconv.Itoa(n)}, Worktree: optional(strconv.Itoa(n) + " " + i.Title)}
}
