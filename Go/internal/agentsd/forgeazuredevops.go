package agentsd

import (
	"context"
	"errors"
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
// items (forgeazure.go).
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

// azureDevOpsSources adds to s the repositories of the folders on Azure DevOps that a token
// here is for, all on one Azure DevOps: the first such folder's. A folder whose Azure DevOps
// has no token here leaves a reason.
func (d *Daemon) azureDevOpsSources(ctx context.Context, s *forgeSources, folders []string) {
	unsigned := false
	for _, f := range folders {
		if onGitHubOrGitLab(d.folderRepo(f)) {
			continue
		}
		root, repo := d.azureDevOpsRepoAt(ctx, f)
		if repo == "" {
			continue
		}
		if d.azureDevOpsToken(root) == "" || (s.azureDevOpsRoot != "" && root != s.azureDevOpsRoot) {
			unsigned = true
			continue
		}
		key := forgeRepo{"azuredevops", strings.ToLower(repo)}
		if _, seen := s.folderOf[key]; seen {
			continue
		}
		s.azureDevOpsRoot = root
		s.folderOf[key] = f
		s.azureDevOps = append(s.azureDevOps, repo)
	}
	slices.Sort(s.azureDevOps)
	if unsigned && len(s.azureDevOps) == 0 {
		s.azureDevOpsErr = errors.New(azuredevopsmcp.NotConnected)
	}
}

// azureDevOpsPage is the Azure DevOps page of a list of pull requests.
func (d *Daemon) azureDevOpsPage(ctx context.Context, s forgeSources, f azuredevopsmcp.SearchFilter, after string, limit int) forgePage {
	p := forgePage{forge: "azuredevops", err: s.azureDevOpsErr}
	if p.err != nil {
		return p
	}
	page, err := d.forgeAzureDevOps(s.azureDevOpsRoot).Search(ctx, s.azureDevOps, f, after, limit)
	for _, i := range page.Items {
		p.items = append(p.items, azureDevOpsItemOf(i, s.folderOf[forgeRepo{"azuredevops", strings.ToLower(i.Repo)}]))
	}
	p.cursors, p.next, p.err = page.Cursors, page.Next, err
	return p
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

// azureDevOpsItem is a pull request on Azure DevOps.
func (d *Daemon) azureDevOpsItem(ctx context.Context, method, repo string, number int, cursor string) (wire.ForgeItemDetail, error) {
	ado, named, folder, err := d.azureDevOpsOf(ctx, method, repo)
	if err != nil {
		return wire.ForgeItemDetail{}, err
	}
	p, err := ado.ItemPage(ctx, named, number, cursor)
	if err != nil {
		if azuredevopsmcp.IsNotFound(err) {
			return wire.ForgeItemDetail{}, Invalid("%s: %v", method, err)
		}
		return wire.ForgeItemDetail{}, err
	}
	out := wire.ForgeItemDetail{Item: azureDevOpsItemOf(p.Item, folder), Body: p.Body, Comments: []wire.ForgeComment{}, Cursor: optional(p.Before),
		Checks: []wire.ForgeCheck{}}
	for _, c := range p.Thread {
		out.Comments = append(out.Comments, forgeCommentOf(c.Author, c.Body, c.At, c.URL, c.Bot))
	}
	for _, c := range p.CheckRuns {
		out.Checks = append(out.Checks, wire.ForgeCheck{Name: c.Name, State: c.State, URL: optional(c.URL)})
	}
	out.ReviewThreads, out.FilesChanged = new(int64(p.ReviewThreads)), new(int64(p.FilesChanged))
	out.Head = optional(p.Head)
	// The merge menu is a nicety: a page still reads when the branch's policy cannot be read.
	if p.State == "open" {
		if methods, err := ado.MergeMethods(ctx, named, number); err == nil {
			out.MergeMethods = mergeMethodsOf(methods)
		}
	}
	return out, nil
}

// azureDevOpsItemOf is an Azure Repos pull request in the one model, from folder.
func azureDevOpsItemOf(i azuredevopsmcp.Item, folder string) wire.ForgeItem {
	return wire.ForgeItem{Node: azureDevOpsNode(i.Repo, i.Number), Title: i.Title, State: i.State, URL: optional(i.URL),
		Folder: optional(folder), Labels: forgeLabelsOf(i.Labels, nil), Author: optional(i.Author), Assignees: []string{},
		UpdatedAt: forgeDate(i.UpdatedAt), Comments: int64(i.Comments), Draft: new(i.Draft), AutoMerge: new(i.AutoMerge),
		Checks: optional(i.Checks), Review: optional(i.Review), Mergeable: optional(i.Mergeable)}
}

// azureDevOpsMerge completes a pull request by the method asked for, or the first its target
// branch allows.
func (d *Daemon) azureDevOpsMerge(ctx context.Context, method string, t forgeTarget, sha, how string, auto bool) error {
	methods, err := t.azureDevOps.MergeMethods(ctx, t.project, t.number)
	if err != nil {
		return err
	}
	if len(methods) == 0 {
		return Invalid("%s: the target branch's policy allows no merge type here: complete it on Azure DevOps", method)
	}
	if how == "" {
		how = methods[0]
	}
	if !slices.Contains(methods, how) {
		return Invalid("%s: this branch merges by %s", method, strings.Join(methods, " or "))
	}
	return t.azureDevOps.Merge(ctx, t.project, t.number, sha, how, auto)
}

// azureDevOpsFailedBuilds are the Azure Pipelines builds of a pull request's failed checks, or
// of the check named only, when one is.
func azureDevOpsFailedBuilds(ctx context.Context, t forgeTarget, only string) ([]int, error) {
	p, err := t.azureDevOps.ItemPage(ctx, t.project, t.number, "")
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

// azureDevOpsRerun runs each failed build of a pull request again: its failed jobs.
func (d *Daemon) azureDevOpsRerun(ctx context.Context, method string, t forgeTarget, ref string) (wire.ForgeDone, error) {
	builds, err := azureDevOpsFailedBuilds(ctx, t, "")
	if err != nil {
		return wire.ForgeDone{}, err
	}
	if len(builds) == 0 {
		return wire.ForgeDone{}, Invalid("%s: %s has no failed Azure Pipelines build to rerun; another service's status runs again on its own page", method, ref)
	}
	var url string
	for _, b := range builds {
		if url, err = t.azureDevOps.RetryBuild(ctx, t.project, b); err != nil {
			return wire.ForgeDone{}, err
		}
	}
	d.forgeWrote()
	return wire.ForgeDone{URL: optional(url), Reran: new(int64(len(builds)))}, nil
}

// azureDevOpsLog is the end of the failed steps' logs of a pull request's failed builds, or of
// the build of the check named.
func azureDevOpsLog(ctx context.Context, t forgeTarget, check string) (wire.ForgeLog, error) {
	builds, err := azureDevOpsFailedBuilds(ctx, t, check)
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
		text, err := t.azureDevOps.FailedLog(ctx, t.project, b)
		if err != nil {
			return wire.ForgeLog{}, err
		}
		parts = append(parts, text)
	}
	return wire.ForgeLog{Text: strings.Join(parts, "\n\n")}, nil
}
