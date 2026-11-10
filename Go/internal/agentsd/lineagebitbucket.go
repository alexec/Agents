package agentsd

import (
	"context"
	"time"

	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/wire"
)

// Lineage asks Bitbucket Cloud (#3879) what it asks Forgejo (lineageforgejo.go), by the
// person's Bitbucket connection (#3785), as the Work pages do: only a repository a folder here
// is on (bitbucketOf). Each has the shape of its gh and glab default (forgeAsks).
//
// Bitbucket says no parent issue, so a Bitbucket issue gets none. An issue's labels are its kind
// and component.

// bitbucketResolveNode is an issue's or a pull request's title, state and labels.
func (d *Daemon) bitbucketResolveNode(ctx context.Context, _ string, repo forgeRepo, kind string, n int) (wire.LineageResolved, error) {
	bb, named, _, err := d.bitbucketOf(ctx, "lineage", repo.path)
	if err != nil {
		return wire.LineageResolved{}, err
	}
	got, err := bb.Node(ctx, named, n, kind == lineage.KindPR)
	if err != nil {
		return wire.LineageResolved{}, err
	}
	r := wire.LineageResolved{Title: got.Title, Labels: got.Labels}
	if got.State != "" {
		r.State = &got.State
	}
	return r, nil
}

// bitbucketCommitTime is the commit time of a tag or sha.
func (d *Daemon) bitbucketCommitTime(ctx context.Context, _ string, repo forgeRepo, ref string) (time.Time, error) {
	bb, named, _, err := d.bitbucketOf(ctx, "lineage", repo.path)
	if err != nil {
		return time.Time{}, err
	}
	return bb.CommitTime(ctx, named, ref)
}

// bitbucketCompareCommits is the commits between base and head.
func (d *Daemon) bitbucketCompareCommits(ctx context.Context, _ string, repo forgeRepo, base, head string) ([]compareCommit, error) {
	bb, named, _, err := d.bitbucketOf(ctx, "lineage", repo.path)
	if err != nil {
		return nil, err
	}
	commits, err := bb.Compare(ctx, named, base, head)
	if err != nil {
		return nil, err
	}
	out := make([]compareCommit, 0, len(commits))
	for _, c := range commits {
		out = append(out, compareCommit{c.SHA, c.Message})
	}
	return out, nil
}

// bitbucketCommitPR is the pull request a commit was merged by, 0 for none.
func (d *Daemon) bitbucketCommitPR(ctx context.Context, _ string, repo forgeRepo, sha string) (int, error) {
	bb, named, _, err := d.bitbucketOf(ctx, "lineage", repo.path)
	if err != nil {
		return 0, err
	}
	return bb.CommitPR(ctx, named, sha)
}

// bitbucketCostComment posts the cost comment, or edits the one r.ID names or the one the pull
// request already has, and says its id.
func (d *Daemon) bitbucketCostComment(ctx context.Context, r prCommentRecord, body string) (string, error) {
	bb, named, _, err := d.bitbucketOf(ctx, "lineage", r.Path)
	if err != nil {
		return "", err
	}
	return bb.CostComment(ctx, named, r.Number, r.ID, prCommentMark, body)
}
