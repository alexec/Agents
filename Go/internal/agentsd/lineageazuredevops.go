package agentsd

import (
	"context"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/azuredevopsmcp"
	"github.com/alexec/agents/Go/wire"
)

// Lineage asks Azure Repos (#3952) what it asks Bitbucket (lineagebitbucket.go), by the
// person's Azure DevOps sign-in (azureDevOpsToken), as the Work pages do: only a repository a
// folder here is on (azureDevOpsOf). Each has the shape of its gh and glab default (forgeAsks).
//
// A pull request is azuredevops:organization/project/repo#12. Azure Repos has no issues: "#12"
// in its repository is the work item 12 of its project on Azure Boards (forgeRepo.issue), which
// lineage does not ask here. It has no milestones either.

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

// azureDevOpsIssue is no milestone: Azure Repos has no issues.
func (d *Daemon) azureDevOpsIssue(context.Context, string, forgeRepo, int) (issueOnForge, error) {
	return issueOnForge{}, nil
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
		out = append(out, compareCommit{c.SHA, c.Message})
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

// azureDevOpsMilestones is none: Azure Repos has no milestones.
func (d *Daemon) azureDevOpsMilestones(context.Context, string, forgeRepo) ([]forgeMilestone, error) {
	return nil, nil
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
