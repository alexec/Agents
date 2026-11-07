package agentsd

import (
	"context"
	"time"

	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/wire"
)

// Lineage asks Forgejo (#3844) what it asks gh and glab of GitHub and GitLab: a node's title
// and state (lineageresolve.go), an issue's milestone (lineagemilestone.go), a release's
// commits, pull requests and milestones (lineagerelease.go), and the cost comment on a merged
// pull request (lineagecomment.go). It asks by the person's Forgejo connection (#3752), as the
// Work pages do, so only a repository a folder here is on, on the connected Forgejo, is asked
// (forgejoOf). Each has the shape of its gh and glab default; the folder it is given is not
// used, as the connection is the person's in every folder.
//
// Forgejo says no parent issue, so a Forgejo issue gets none, as a GitLab issue. A milestone is
// forgejo:owner/repo/milestone/<id>.

// forgejoResolveNode is an issue's, a pull request's or a milestone's title, state and labels.
func (d *Daemon) forgejoResolveNode(ctx context.Context, _ string, repo forgeRepo, kind string, n int) (wire.LineageResolved, error) {
	fj, named, _, err := d.forgejoOf(ctx, "lineage", repo.path)
	if err != nil {
		return wire.LineageResolved{}, err
	}
	ask := fj.Node
	if kind == lineage.KindMilestone {
		ask = fj.MilestoneNode
	}
	got, err := ask(ctx, named, n)
	if err != nil {
		return wire.LineageResolved{}, err
	}
	r := wire.LineageResolved{Title: got.Title, Labels: got.Labels}
	if got.State != "" {
		r.State = &got.State
	}
	return r, nil
}

// forgejoIssue is an issue's milestone.
func (d *Daemon) forgejoIssue(ctx context.Context, _ string, repo forgeRepo, n int) (issueOnForge, error) {
	fj, named, _, err := d.forgejoOf(ctx, "lineage", repo.path)
	if err != nil {
		return issueOnForge{}, err
	}
	got, err := fj.Node(ctx, named, n)
	return issueOnForge{milestone: got.Milestone}, err
}

// forgejoCommitTime is the commit time of a tag or sha.
func (d *Daemon) forgejoCommitTime(ctx context.Context, _ string, repo forgeRepo, ref string) (time.Time, error) {
	fj, named, _, err := d.forgejoOf(ctx, "lineage", repo.path)
	if err != nil {
		return time.Time{}, err
	}
	return fj.CommitTime(ctx, named, ref)
}

// forgejoCompareCommits is the commits between base and head.
func (d *Daemon) forgejoCompareCommits(ctx context.Context, _ string, repo forgeRepo, base, head string) ([]compareCommit, error) {
	fj, named, _, err := d.forgejoOf(ctx, "lineage", repo.path)
	if err != nil {
		return nil, err
	}
	commits, err := fj.Compare(ctx, named, base, head)
	if err != nil {
		return nil, err
	}
	out := make([]compareCommit, 0, len(commits))
	for _, c := range commits {
		out = append(out, compareCommit{c.SHA, c.Message})
	}
	return out, nil
}

// forgejoCommitPR is the pull request a commit was merged by, 0 for none.
func (d *Daemon) forgejoCommitPR(ctx context.Context, _ string, repo forgeRepo, sha string) (int, error) {
	fj, named, _, err := d.forgejoOf(ctx, "lineage", repo.path)
	if err != nil {
		return 0, err
	}
	return fj.CommitPR(ctx, named, sha)
}

// forgejoMilestones is every milestone of repo, open and closed, by its id.
func (d *Daemon) forgejoMilestones(ctx context.Context, _ string, repo forgeRepo) ([]forgeMilestone, error) {
	fj, named, _, err := d.forgejoOf(ctx, "lineage", repo.path)
	if err != nil {
		return nil, err
	}
	found, err := fj.Milestones(ctx, named)
	if err != nil {
		return nil, err
	}
	out := make([]forgeMilestone, 0, len(found))
	for _, m := range found {
		out = append(out, forgeMilestone{m.ID, m.Title})
	}
	return out, nil
}

// forgejoCostComment posts the cost comment, or edits the one r.ID names or the one the pull
// request already has, and says its id.
func (d *Daemon) forgejoCostComment(ctx context.Context, r prCommentRecord, body string) (string, error) {
	fj, named, _, err := d.forgejoOf(ctx, "lineage", r.Path)
	if err != nil {
		return "", err
	}
	return fj.CostComment(ctx, named, r.Number, r.ID, prCommentMark, body)
}
