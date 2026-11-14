package agentsd

import (
	"context"
	"time"

	"github.com/agentloops-dev/agents/Go/wire"
)

// Lineage asks Forgejo (#3844) what it asks gh and glab of GitHub and GitLab: a node's title
// and state (lineageresolve.go), a release's commits and pull requests (lineagerelease.go), and the cost comment on a merged
// pull request (lineagecomment.go). It asks by the person's Forgejo connection (#3752), as the
// Work pages do, so only a repository a folder here is on, on the connected Forgejo, is asked
// (forgejoOf). Each has the shape of its gh and glab default; the folder it is given is not
// used, as the connection is the person's in every folder.
//
// Forgejo says no parent issue, so a Forgejo issue gets none, as a GitLab issue.

// forgejoResolveNode is an issue's or a pull request's title, state and labels.
func (d *Daemon) forgejoResolveNode(ctx context.Context, _ string, repo forgeRepo, kind string, n int) (wire.LineageResolved, error) {
	fj, named, _, err := d.forgejoOf(ctx, "lineage", repo.path)
	if err != nil {
		return wire.LineageResolved{}, err
	}
	got, err := fj.Node(ctx, named, n)
	if err != nil {
		return wire.LineageResolved{}, err
	}
	r := wire.LineageResolved{Title: got.Title, Labels: got.Labels}
	if got.State != "" {
		r.State = &got.State
	}
	return r, nil
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

// forgejoCostComment posts the cost comment, or edits the one r.ID names or the one the pull
// request already has, and says its id.
func (d *Daemon) forgejoCostComment(ctx context.Context, r prCommentRecord, body string) (string, error) {
	fj, named, _, err := d.forgejoOf(ctx, "lineage", r.Path)
	if err != nil {
		return "", err
	}
	return fj.CostComment(ctx, named, r.Number, r.ID, prCommentMark, body)
}
