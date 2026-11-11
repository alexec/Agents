package agentsd

import (
	"context"
	"errors"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/azuredevopsmcp"
	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/wire"
)

// Azure Repos on the Work pages (#3803, after Bitbucket's #3786): the pull requests of the
// folders whose git remote is on Azure DevOps (dev.azure.com, or the connected Azure DevOps
// Server), read and written through azuredevopsmcp.RealAzureDevOps, a call per repository, as
// Azure DevOps has no list across repositories. The token is the azuredevops connector's
// sign-in (AZURE_DEVOPS_TOKEN and AZURE_DEVOPS_URL in the secrets), else the Azure DevOps
// connection's (#3802), each only on its own Azure DevOps. A pull request is the node
// azuredevops:organization/project/repo#12, in lower case. The issues are Azure Boards' work
// items (forgeazure.go). azureDevOpsForge's Caps say so.
//
// A pull request's tags are its labels. Rerun failed runs each failed Azure Pipelines build of
// the pull request again: its failed jobs.

// forgeAzureDevOps is what the forge reads and writes ask of Azure DevOps; a test gives a fake.
type forgeAzureDevOps interface {
	Search(ctx context.Context, repos []string, f azuredevopsmcp.SearchFilter, after string, first int) (azuredevopsmcp.SearchPage, error)
	ItemPage(ctx context.Context, repo string, number int, before string) (azuredevopsmcp.ItemDetail, error)
	Comment(ctx context.Context, repo string, number int, body string) (string, error)
	SetLabels(ctx context.Context, repo string, number int, add, remove []string) error
	SetState(ctx context.Context, repo string, number int, closed bool) error
	RepoLabels(ctx context.Context, repo string) ([]string, error)
	MergeMethods(ctx context.Context, repo string, number int) ([]string, error)
	Merge(ctx context.Context, repo string, number int, sha, method string, auto bool) error
	Approve(ctx context.Context, repo string, number int, sha string) (string, error)
	PRDiff(ctx context.Context, repo string, number int) (map[string]any, error)
	RetryBuild(ctx context.Context, repo string, build int) (string, error)
	FailedLog(ctx context.Context, repo string, build int) (string, error)
	// What lineage asks (lineageazuredevops.go).
	Node(ctx context.Context, repo string, number int) (azuredevopsmcp.Node, error)
	CommitTime(ctx context.Context, repo, ref string) (time.Time, error)
	Compare(ctx context.Context, repo, base, head string) ([]azuredevopsmcp.Commit, error)
	CommitPR(ctx context.Context, repo, sha string) (int, error)
	CostComment(ctx context.Context, repo string, number int, id, mark, body string) (string, error)
}

// azureDevOpsOfNode is the repository, organization/project/name, and the number of an Azure
// Repos pull request's node.
func azureDevOpsOfNode(n wire.LineageNode) (string, int, bool) {
	rest, ok := strings.CutPrefix(n.Ref, "azuredevops:")
	at := strings.LastIndex(rest, "#")
	if !ok || n.Kind != lineage.KindPR || at < 0 {
		return "", 0, false
	}
	parts := strings.Split(rest[:at], "/")
	if len(parts) != 3 || slices.Contains(parts, "") {
		return "", 0, false
	}
	number, err := strconv.Atoi(rest[at+1:])
	if err != nil || number <= 0 {
		return "", 0, false
	}
	return rest[:at], number, true
}

// azureDevOpsNode is a pull request's node.
func azureDevOpsNode(repo string, number int) wire.LineageNode {
	return wire.LineageNode{Kind: lineage.KindPR, Ref: "azuredevops:" + strings.ToLower(repo) + "#" + strconv.Itoa(number)}
}

// azureDevOpsToken is the token for the Azure DevOps at root: the connector's sign-in when it
// is for root, else the connection's when it is; "" for none.
func (d *Daemon) azureDevOpsToken(root string) string {
	secrets := d.secrets()
	if token := secrets["AZURE_DEVOPS_TOKEN"]; token != "" && azuredevopsmcp.BaseURL(secrets["AZURE_DEVOPS_URL"]) == root {
		return token
	}
	if c, ok := d.azureDevOpsConnection(); ok && c.Usable(nowFunc()) && azuredevopsmcp.BaseURL(c.URL) == root {
		return c.Access
	}
	return ""
}

// azureDevOpsRepoAt is the Azure DevOps a folder's remote is on and its repository there; read
// once for the roots it can be on, as GitLab's is for the connected GitLab: a connection made
// after the folder was added is a new key, so it is read again (#4072).
func (d *Daemon) azureDevOpsRepoAt(ctx context.Context, folder string) (root, repo string) {
	roots := d.azureDevOpsRoots()
	key := "azuredevops " + folder + " " + strings.Join(roots, " ")
	d.forgeMu.Lock()
	at, ok := d.forgeRoots[key]
	d.forgeMu.Unlock()
	if ok {
		return at[0], at[1]
	}
	gitCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if f, found := d.azureDevOpsAtRoots(gitCtx, folder, roots); found {
		root, repo = f.root, f.repo
	}
	d.forgeMu.Lock()
	defer d.forgeMu.Unlock()
	if d.forgeRoots == nil || len(d.forgeRoots) >= forgeCached {
		d.forgeRoots = map[string][2]string{}
	}
	d.forgeRoots[key] = [2]string{root, repo}
	return root, repo
}

// azureDevOpsNoIssues is why Azure Repos has no issue, plan or transition: its issues are Azure
// Boards' work items.
const azureDevOpsNoIssues = "Azure Repos has pull requests only: its issues are Azure Boards' work items"

// azureDevOpsForge is Azure Repos on the forge interface (#4329, #4356): the pull requests of
// the folders on Azure DevOps, through forgeAzureDevOps. Its Caps say it has no issues, so no
// plan.
type azureDevOpsForge struct {
	forgeNone
	d *Daemon
}

func (azureDevOpsForge) Name() string { return "azuredevops" }

func (azureDevOpsForge) Images() forgeImageHost { return azureImages{} }

func (azureDevOpsForge) Caps() forgeCaps {
	return forgeCaps{
		PRs: true,
		PR: forgeActions{Comment: true, Label: true, Close: true, Reopen: true, Merge: true, AutoMerge: true, Approve: true,
			Rerun: true, Log: true, Diff: true},
		Avatars:   true,
		CreatedAt: true, ClosedAt: true,
		// A pull request's branches and merge (#4409); its size, reviewers, closing issues and check times are #4682.
		Branches: true, MergedBy: true, MergeCommit: true,
		// A pull request's comment count is on its own page only.
		CommentCount: "detail",
		Reasons: map[string]string{
			actionAssign:     "an Azure Repos pull request has reviewers, not assignees",
			actionReleases:   "Azure Repos has no releases, only tags",
			actionTransition: "only a Jira issue or an Azure Boards work item moves by a transition",
			actionPlan:       azureDevOpsNoIssues,
			actionAddChild:   azureDevOpsNoIssues,
			actionBlockedBy:  azureDevOpsNoIssues,
		},
	}
}

// Owns is azuredevops:organization/project/repo#12, a pull request.
func (azureDevOpsForge) Owns(node wire.LineageNode) (forgeRef, bool) {
	repo, number, ok := azureDevOpsOfNode(node)
	if !ok {
		return forgeRef{}, false
	}
	return forgeRef{Node: node, Repo: repo, Number: number}, true
}

// azureDevOpsScope is the repositories on Azure DevOps that a list of pull requests reads,
// organization/project/name as their folders' remotes say them, all at root, each with a folder
// to act from (by its name in lower case). unsigned is why none is read: no token here for the
// folders' Azure DevOps.
type azureDevOpsScope struct {
	root     string
	repos    []string
	folderOf map[string]string
	unsigned error
}

func (s azureDevOpsScope) Key() []any { return []any{s.root, s.repos} }

// Empty is false with unsigned, so that a board's list, which says nothing of folders left out,
// still says that its Azure DevOps has no token here (#4055).
func (s azureDevOpsScope) Empty() bool { return len(s.repos) == 0 && s.unsigned == nil }

// Sources is the repositories of the folders on Azure DevOps that a token here is for, all on
// one Azure DevOps: the first such folder's. A folder whose Azure DevOps has no token here
// leaves a reason. An issues list reads none: Azure Boards has the issues.
func (a azureDevOpsForge) Sources(ctx context.Context, folders []string, prs bool) (forgeScope, error) {
	s := azureDevOpsScope{folderOf: map[string]string{}}
	if !prs {
		return s, nil
	}
	unsigned := false
	for _, f := range folders {
		if onGitHubOrGitLab(a.d.folderRepo(f)) {
			continue
		}
		root, repo := a.d.azureDevOpsRepoAt(ctx, f)
		if repo == "" {
			continue
		}
		if a.d.azureDevOpsToken(root) == "" || (s.root != "" && root != s.root) {
			unsigned = true
			continue
		}
		if _, seen := s.folderOf[strings.ToLower(repo)]; seen {
			continue
		}
		s.root = root
		s.folderOf[strings.ToLower(repo)] = f
		s.repos = append(s.repos, repo)
	}
	slices.Sort(s.repos)
	if unsigned && len(s.repos) == 0 {
		s.unsigned = errors.New(azuredevopsmcp.NotConnected)
		return s, s.unsigned
	}
	return s, nil
}

// List is a call for each repository, as Azure DevOps has no list across repositories. A
// board's list is of the repositories of its project, on the Azure DevOps it is on (#4055).
func (a azureDevOpsForge) List(ctx context.Context, scope forgeScope, f forgeFilter, cursor string, limit int) (forgePage, error) {
	s, _ := scope.(azureDevOpsScope)
	if s.unsigned != nil {
		return forgePage{}, s.unsigned
	}
	repos := s.repos
	if f.Board != nil {
		repos = nil
		if root, err := url.Parse(s.root); err == nil && f.Board.azureProject != "" && strings.EqualFold(root.Host, f.Board.azureSite) {
			for _, repo := range s.repos {
				if strings.HasPrefix(strings.ToLower(repo), f.Board.azureProject+"/") {
					repos = append(repos, repo)
				}
			}
		}
	}
	if !f.PRs || len(repos) == 0 {
		return forgePage{}, nil
	}
	sf := azuredevopsmcp.SearchFilter{State: f.State, Label: f.Label, Assignee: f.Assignee, Query: f.Query, Feature: f.Feature}
	page, err := a.d.forgeAzureDevOps(s.root).Search(ctx, repos, sf, cursor, limit)
	var p forgePage
	for _, i := range page.Items {
		p.items = append(p.items, azureDevOpsItemOf(i, s.folderOf[strings.ToLower(i.Repo)]))
	}
	p.cursors, p.next = page.Cursors, page.Next
	return p, err
}

// of is the Azure DevOps of r's repository, the repository as its folder's remote says it, and
// that folder.
func (a azureDevOpsForge) of(ctx context.Context, method string, r forgeRef) (forgeAzureDevOps, string, string, error) {
	return a.d.azureDevOpsOf(ctx, method, r.Repo)
}

func (a azureDevOpsForge) Item(ctx context.Context, r forgeRef, cursor string) (wire.ForgeItemDetail, error) {
	method := itemMethod(r.Node.Kind)
	ado, named, folder, err := a.of(ctx, method, r)
	if err != nil {
		return wire.ForgeItemDetail{}, err
	}
	p, err := ado.ItemPage(ctx, named, r.Number, cursor)
	if err != nil {
		if azuredevopsmcp.IsNotFound(err) {
			return wire.ForgeItemDetail{}, Invalid("%s: %v", method, err)
		}
		return wire.ForgeItemDetail{}, err
	}
	out := wire.ForgeItemDetail{Item: azureDevOpsItemOf(p.Item, folder), Body: p.Body, Comments: []wire.ForgeComment{}, Cursor: optional(p.Before),
		Checks: []wire.ForgeCheck{}}
	for _, c := range p.Thread {
		out.Comments = append(out.Comments, forgeCommentOf(c.Author, c.Avatar, c.Body, c.At, c.URL, c.Bot))
	}
	for _, c := range p.CheckRuns {
		out.Checks = append(out.Checks, wire.ForgeCheck{Name: c.Name, State: c.State, URL: optional(c.URL)})
	}
	out.ReviewThreads, out.FilesChanged = new(int64(p.ReviewThreads)), new(int64(p.FilesChanged))
	out.Head = optional(p.Head)
	// The merge menu is a nicety: a page still reads when the branch's policy cannot be read.
	if p.State == "open" {
		if methods, err := ado.MergeMethods(ctx, named, r.Number); err == nil {
			out.MergeMethods = mergeMethodsOf(methods)
		}
	}
	return out, nil
}

// Labels are what a pull request's labels can be: the repository's tags.
func (a azureDevOpsForge) Labels(ctx context.Context, r forgeRef) ([]wire.ForgeLabel, error) {
	ado, named, _, err := a.of(ctx, "forge/labels", r)
	if err != nil {
		return nil, err
	}
	names, err := ado.RepoLabels(ctx, named)
	if err != nil {
		return nil, err
	}
	return forgeLabelsOf(names, nil), nil
}

func (a azureDevOpsForge) Diff(ctx context.Context, r forgeRef) (wire.ForgeDiff, error) {
	ado, named, _, err := a.of(ctx, "forge/diff", r)
	if err != nil {
		return wire.ForgeDiff{}, err
	}
	out, err := ado.PRDiff(ctx, named, r.Number)
	if err != nil {
		return wire.ForgeDiff{}, err
	}
	return diffOf(out)
}

// Log is the end of the failed steps' logs of a pull request's failed builds, or of the build
// of the check named.
func (a azureDevOpsForge) Log(ctx context.Context, r forgeRef, check string) (wire.ForgeLog, error) {
	ado, named, _, err := a.of(ctx, "forge/log", r)
	if err != nil {
		return wire.ForgeLog{}, err
	}
	builds, err := azureDevOpsFailedBuilds(ctx, ado, named, r.Number, check)
	if err != nil {
		return wire.ForgeLog{}, err
	}
	if len(builds) == 0 {
		if check != "" {
			return wire.ForgeLog{Text: check + " is not an Azure Pipelines build: its log is on its own page."}, nil
		}
		return wire.ForgeLog{Text: "No failed Azure Pipelines build."}, nil
	}
	var parts []string
	for _, b := range builds {
		text, err := ado.FailedLog(ctx, named, b)
		if err != nil {
			return wire.ForgeLog{}, err
		}
		parts = append(parts, text)
	}
	return wire.ForgeLog{Text: strings.Join(parts, "\n\n")}, nil
}

func (a azureDevOpsForge) Comment(ctx context.Context, r forgeRef, body string) (wire.ForgeDone, error) {
	ado, named, _, err := a.of(ctx, "forge/comment", r)
	if err != nil {
		return wire.ForgeDone{}, err
	}
	link, err := ado.Comment(ctx, named, r.Number, body)
	return wire.ForgeDone{URL: optional(link)}, err
}

func (a azureDevOpsForge) SetLabels(ctx context.Context, r forgeRef, add, remove []string) error {
	ado, named, _, err := a.of(ctx, "forge/label", r)
	if err != nil {
		return err
	}
	return ado.SetLabels(ctx, named, r.Number, add, remove)
}

func (a azureDevOpsForge) SetState(ctx context.Context, r forgeRef, closed bool, transition string) error {
	if transition != "" {
		return cannot(actionTransition)
	}
	ado, named, _, err := a.of(ctx, "forge/close", r)
	if err != nil {
		return err
	}
	return ado.SetState(ctx, named, r.Number, closed)
}

// Merge completes a pull request by the method asked for, or the first its target branch
// allows; with auto, once its policies pass.
func (a azureDevOpsForge) Merge(ctx context.Context, r forgeRef, sha, how string, auto bool) (wire.ForgeDone, error) {
	const method = "forge/merge"
	ado, named, _, err := a.of(ctx, method, r)
	if err != nil {
		return wire.ForgeDone{}, err
	}
	methods, err := ado.MergeMethods(ctx, named, r.Number)
	if err != nil {
		return wire.ForgeDone{}, err
	}
	if len(methods) == 0 {
		return wire.ForgeDone{}, Invalid("%s: the target branch's policy allows no merge type here: complete it on Azure DevOps", method)
	}
	if how == "" {
		how = methods[0]
	}
	if !slices.Contains(methods, how) {
		return wire.ForgeDone{}, Invalid("%s: this branch merges by %s", method, strings.Join(methods, " or "))
	}
	if err := ado.Merge(ctx, named, r.Number, sha, how, auto); err != nil {
		return wire.ForgeDone{}, err
	}
	return wire.ForgeDone{Auto: optionalTrue(auto)}, nil
}

func (a azureDevOpsForge) Approve(ctx context.Context, r forgeRef, sha string) (wire.ForgeDone, error) {
	ado, named, _, err := a.of(ctx, "forge/approve", r)
	if err != nil {
		return wire.ForgeDone{}, err
	}
	link, err := ado.Approve(ctx, named, r.Number, sha)
	return wire.ForgeDone{URL: optional(link)}, err
}

// Rerun runs each failed build of a pull request again: its failed jobs.
func (a azureDevOpsForge) Rerun(ctx context.Context, r forgeRef) (wire.ForgeDone, error) {
	const method = "forge/rerun"
	ado, named, _, err := a.of(ctx, method, r)
	if err != nil {
		return wire.ForgeDone{}, err
	}
	builds, err := azureDevOpsFailedBuilds(ctx, ado, named, r.Number, "")
	if err != nil {
		return wire.ForgeDone{}, err
	}
	if len(builds) == 0 {
		return wire.ForgeDone{}, Invalid("%s: %s has no failed Azure Pipelines build to rerun; another service's status runs again on its own page", method, r.Node.Ref)
	}
	var link string
	for _, b := range builds {
		if link, err = ado.RetryBuild(ctx, named, b); err != nil {
			return wire.ForgeDone{}, err
		}
	}
	return wire.ForgeDone{URL: optional(link), Reran: new(int64(len(builds)))}, nil
}

// azureDevOpsOf is the Azure DevOps of a folder on repo, repo as its folder's remote says it,
// and that folder: a node names the repository in lower case.
func (d *Daemon) azureDevOpsOf(ctx context.Context, method, repo string) (forgeAzureDevOps, string, string, error) {
	for _, f := range d.folderPaths() {
		if onGitHubOrGitLab(d.folderRepo(f)) {
			continue
		}
		root, named := d.azureDevOpsRepoAt(ctx, f)
		if named == "" || !strings.EqualFold(named, repo) {
			continue
		}
		if d.azureDevOpsToken(root) == "" {
			return nil, "", "", errors.New(azuredevopsmcp.NotConnected)
		}
		return d.forgeAzureDevOps(root), named, f, nil
	}
	return nil, "", "", Invalid("%s: no folder here is on %s on Azure DevOps", method, repo)
}

// forgeAzureDevOps is the Azure DevOps at root with its token here; the caller has checked
// there is one.
func (d *Daemon) forgeAzureDevOps(root string) forgeAzureDevOps {
	token := d.azureDevOpsToken(root)
	if d.newForgeAzureDevOps != nil {
		return d.newForgeAzureDevOps(root, token)
	}
	return azuredevopsmcp.NewRealAzureDevOps(root, func() string { return token }, nil)
}

// azureDevOpsItemOf is an Azure Repos pull request in the one model, from folder.
func azureDevOpsItemOf(i azuredevopsmcp.Item, folder string) wire.ForgeItem {
	out := wire.ForgeItem{Node: azureDevOpsNode(i.Repo, i.Number), Title: i.Title, State: i.State, URL: optional(i.URL),
		Folder: optional(folder), Labels: forgeLabelsOf(i.Labels, nil), Author: optional(i.Author), AuthorAvatar: optional(i.AuthorAvatar), Assignees: []string{},
		UpdatedAt: forgeDate(i.UpdatedAt), CreatedAt: forgeDateOptional(i.CreatedAt), ClosedAt: forgeDateOptional(i.ClosedAt), Comments: int64(i.Comments), Draft: new(i.Draft), AutoMerge: new(i.AutoMerge),
		Checks: optional(i.Checks), Review: optional(i.Review), Mergeable: optional(i.Mergeable)}
	withPullRefs(&out, i.HeadRef, i.BaseRef, i.MergedBy, i.MergeCommit)
	return out
}

// azureDevOpsFailedBuilds are the Azure Pipelines builds of a pull request's failed checks, or
// of the check named only, when one is.
func azureDevOpsFailedBuilds(ctx context.Context, ado forgeAzureDevOps, repo string, number int, only string) ([]int, error) {
	p, err := ado.ItemPage(ctx, repo, number, "")
	if err != nil {
		return nil, err
	}
	var builds []int
	for _, c := range p.CheckRuns {
		if c.Build == 0 || slices.Contains(builds, c.Build) || (only == "" && c.State != "failing") || (only != "" && c.Name != only) {
			continue
		}
		builds = append(builds, c.Build)
	}
	return builds, nil
}
