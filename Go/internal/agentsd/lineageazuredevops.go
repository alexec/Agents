package agentsd

import (
	"context"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/azuredevopsmcp"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// Lineage asks Azure Repos (#3952) what it asks Bitbucket (lineagebitbucket.go), by the
// person's Azure DevOps sign-in (azureDevOpsToken), as the Work pages do: only a repository a
// folder here is on (azureDevOpsOf). Each has the shape of its gh and glab default (forgeAsks).
//
// A pull request is azuredevops:organization/project/repo#12. Azure Repos has no issues: "#12"
// in its repository is the work item 12 of its project on Azure Boards (forgeRepo.issue), which
// lineage does not ask here.

// azureDevOpsResolveNode is a pull request's title, state and tags.
func (d *Daemon) azureDevOpsResolveNode(ctx context.Context, _ string, repo forgeRepo, _ string, n int) (wire.LineageResolved, error) {
	ado, named, _, err := d.azureDevOpsOf(ctx, "lineage", repo.path)
	if err != nil {
		return wire.LineageResolved{}, err
	}
	got, err := ado.Node(ctx, named, n)
	if err != nil {
		return wire.LineageResolved{}, err
	}
	return wire.LineageResolved{Title: got.Title, State: &got.State, Labels: got.Labels}, nil
}

// azureDevOpsCommitTime is the commit time of a tag or sha.
func (d *Daemon) azureDevOpsCommitTime(ctx context.Context, _ string, repo forgeRepo, ref string) (time.Time, error) {
	ado, named, _, err := d.azureDevOpsOf(ctx, "lineage", repo.path)
	if err != nil {
		return time.Time{}, err
	}
	return ado.CommitTime(ctx, named, ref)
}

// azureDevOpsCompareCommits is the commits between base and head.
func (d *Daemon) azureDevOpsCompareCommits(ctx context.Context, _ string, repo forgeRepo, base, head string) ([]compareCommit, error) {
	ado, named, _, err := d.azureDevOpsOf(ctx, "lineage", repo.path)
	if err != nil {
		return nil, err
	}
	commits, err := ado.Compare(ctx, named, base, head)
	if err != nil {
		return nil, err
	}
	out := make([]compareCommit, 0, len(commits))
	for _, c := range commits {
		out = append(out, compareCommit{SHA: c.SHA, Message: c.Message})
	}
	return out, nil
}

// azureDevOpsCommitPR is the pull request a commit was merged by, 0 for none.
func (d *Daemon) azureDevOpsCommitPR(ctx context.Context, _ string, repo forgeRepo, sha string) (int, error) {
	ado, named, _, err := d.azureDevOpsOf(ctx, "lineage", repo.path)
	if err != nil {
		return 0, err
	}
	return ado.CommitPR(ctx, named, sha)
}

// azureDevOpsCostComment posts the cost comment, or edits the one r.ID names or the one the
// pull request already has, and says its id (thread/comment).
func (d *Daemon) azureDevOpsCostComment(ctx context.Context, r prCommentRecord, body string) (string, error) {
	ado, named, _, err := d.azureDevOpsOf(ctx, "lineage", r.Path)
	if err != nil {
		return "", err
	}
	return ado.CostComment(ctx, named, r.Number, r.ID, prCommentMark, body)
}

// azureDevOpsOfPath is the repository (organization/project/name) of an Azure Repos address's
// host and path, up to the repository's name: dev.azure.com/org/project/_git/name,
// org.visualstudio.com/project/_git/name, or ssh.dev.azure.com:v3/org/project/name, as
// azuredevopsmcp.RepoOfRemote reads a remote. With anyHost, an Azure DevOps Server's too:
// <server>/[prefix/]collection/project/_git/name, the collection as its organization.
func azureDevOpsOfPath(host, path string, anyHost bool) (string, bool) {
	parts := strings.Split(strings.Trim(path, "/"), "/")
	for _, p := range parts {
		if p == "" {
			return "", false
		}
	}
	escaped := make([]string, len(parts))
	for i, p := range parts {
		escaped[i] = strings.ReplaceAll(p, " ", "%20")
	}
	if repo, ok := azuredevopsmcp.RepoOfRemote(azuredevopsmcp.DefaultBase, "https://"+host+"/"+strings.Join(escaped, "/")); ok {
		return strings.ToLower(repo), true
	}
	// A Server's path may start with a prefix of its own (tfs/), so the collection is the part
	// two before _git. One named as its project (collection/_git/name) is not found here.
	if n := len(parts); anyHost && n >= 4 && parts[n-2] == "_git" {
		return strings.ToLower(parts[n-4] + "/" + parts[n-3] + "/" + parts[n-1]), true
	}
	return "", false
}

// azureDevOpsServerRoot is the root of the connected Azure DevOps Server, with its trailing
// slash: the Azure DevOps connection's, else the one AZURE_DEVOPS_URL names with
// AZURE_DEVOPS_TOKEN, as azureDevOpsAt and azureDevOpsToken read them; "" for none or for
// dev.azure.com. It may be under a path of its host (tfs/), which an address's own path does
// not tell apart from a collection (#4107).
func (d *Daemon) azureDevOpsServerRoot() string {
	var bases []string
	if c, ok := d.azureDevOpsConnection(); ok && c.Usable(nowFunc()) && c.URL != "" {
		bases = append(bases, c.URL)
	}
	if secrets := d.secrets(); secrets["AZURE_DEVOPS_TOKEN"] != "" && secrets["AZURE_DEVOPS_URL"] != "" {
		bases = append(bases, secrets["AZURE_DEVOPS_URL"])
	}
	for _, base := range bases {
		if root := azuredevopsmcp.BaseURL(base); root != azuredevopsmcp.DefaultBase {
			return root
		}
	}
	return ""
}

// onAzureDevOpsRoot says raw is an address under root: its host and the path root has.
func onAzureDevOpsRoot(raw, root string) bool {
	u, err := url.Parse(raw)
	r, rerr := url.Parse(root)
	if err != nil || rerr != nil || root == "" || !strings.EqualFold(u.Host, r.Host) {
		return false
	}
	prefix := strings.Trim(r.Path, "/")
	path := strings.Trim(u.Path, "/")
	return prefix == "" || strings.EqualFold(path, prefix) || len(path) > len(prefix) && strings.EqualFold(path[:len(prefix)+1], prefix+"/")
}

// azureDevOpsOfURLOn is the repository and number of a pull request's address on the Azure
// DevOps Server at root, root's path left out: [prefix/]collection/project/_git/name or
// [prefix/]collection/_git/name, read as azuredevopsmcp.RepoOfRemote reads a remote.
func azureDevOpsOfURLOn(raw, root string) (forgeRepo, int, bool) {
	u, err := url.Parse(raw)
	if err != nil || !onAzureDevOpsRoot(raw, root) {
		return forgeRepo{}, 0, false
	}
	repo, num, ok := strings.Cut(u.EscapedPath(), "/pullrequest/")
	n, nerr := strconv.Atoi(strings.SplitN(num, "/", 2)[0])
	if !ok || nerr != nil || n <= 0 {
		return forgeRepo{}, 0, false
	}
	named, ok := azuredevopsmcp.RepoOfRemote(root, u.Scheme+"://"+u.Host+repo)
	if !ok {
		return forgeRepo{}, 0, false
	}
	return forgeRepo{"azuredevops", strings.ToLower(named)}, n, true
}

// prOfURLHere is prOfURL, or a pull request on the connected Azure DevOps Server, whose path
// may start with a prefix of its own (#4107).
func (d *Daemon) prOfURLHere(raw string) (forgeRepo, int, bool) {
	if repo, n, ok := azureDevOpsOfURLOn(raw, d.azureDevOpsServerRoot()); ok {
		return repo, n, true
	}
	return prOfURL(raw)
}
