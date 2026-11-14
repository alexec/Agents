package bitbucketmcp

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"os/exec"
	"strings"

	"github.com/agentloops-dev/agent-loops/Go/internal/mcpevents"
)

// The reads that prove a repository's set-up on Bitbucket Cloud (#3785), as the forgejo
// server's (#3752): each slot reads one real thing, the newest issue, the newest pull request
// and the main branch's checks. A refusal is a BitbucketError with Refused; a repository with
// its issue tracker off is a NoTrackerError; a read that does not reach Bitbucket is Failed.

// Newest is the newest issue or pull request, or the main branch's checks, as a slot shows it.
type Newest struct {
	Number  int
	Title   string
	URL     string
	At      string
	Outcome string // the checks': passed, failed, running
}

// NoTrackerError is a repository whose issue tracker is off, so its Tasks slot has nothing to
// read.
type NoTrackerError struct{ Repo string }

func (e *NoTrackerError) Error() string { return e.Repo + " has its issue tracker off" }

// repoJSON is what the set-up reads of a repository.
type repoJSON struct {
	HasIssues  bool `json:"has_issues"`
	MainBranch *struct {
		Name string `json:"name"`
	} `json:"mainbranch"`
	Links links `json:"links"`
}

// NewestIssue is the repository's newest issue, open or closed, or nil when it has none.
func (b *RealBitbucket) NewestIssue(ctx context.Context, repo string) (*Newest, error) {
	var list paged[issueJSON]
	err := b.get(ctx, repoPath(repo)+"/issues?sort=-created_on&pagelen=1", false, &list)
	if noTracker(err) {
		// A 404 is also a repository this token can't see: the repository's own read says which.
		var info repoJSON
		if b.get(ctx, repoPath(repo), false, &info) == nil && !info.HasIssues {
			return nil, &NoTrackerError{Repo: repo}
		}
	}
	if err != nil {
		return nil, err
	}
	if len(list.Values) == 0 {
		return nil, nil
	}
	i := list.Values[0]
	return &Newest{Number: i.ID, Title: i.Title, URL: i.Links.HTML.Href, At: i.CreatedOn}, nil
}

// NewestPull is the repository's newest pull request, in any state, or nil when it has none.
func (b *RealBitbucket) NewestPull(ctx context.Context, repo string) (*Newest, error) {
	var list paged[pullJSON]
	path := repoPath(repo) + "/pullrequests?state=OPEN&state=MERGED&state=DECLINED&state=SUPERSEDED&sort=-created_on&pagelen=1"
	if err := b.get(ctx, path, false, &list); err != nil {
		return nil, err
	}
	if len(list.Values) == 0 {
		return nil, nil
	}
	p := list.Values[0]
	return &Newest{Number: p.ID, Title: p.Title, URL: p.Links.HTML.Href, At: p.CreatedOn}, nil
}

// LastChecks is the statuses of the main branch's head as one: Pipelines or any CI that
// reports a status. Nil when nothing reported one.
func (b *RealBitbucket) LastChecks(ctx context.Context, repo string) (*Newest, error) {
	var info repoJSON
	if err := b.get(ctx, repoPath(repo), false, &info); err != nil {
		return nil, err
	}
	if info.MainBranch == nil || info.MainBranch.Name == "" {
		return nil, nil
	}
	branch := info.MainBranch.Name
	var ref struct {
		Target struct {
			Hash string `json:"hash"`
		} `json:"target"`
	}
	if err := b.get(ctx, fmt.Sprintf("%s/refs/branches/%s", repoPath(repo), url.PathEscape(branch)), false, &ref); err != nil {
		var be *BitbucketError
		if errors.As(err, &be) && be.Kind == NotFound {
			// A branch with no commit yet.
			return nil, nil
		}
		return nil, err
	}
	statuses, err := b.statuses(ctx, repo, ref.Target.Hash, false)
	if err != nil {
		return nil, err
	}
	if len(statuses) == 0 {
		return nil, nil
	}
	n := &Newest{Title: "Checks on " + branch, Outcome: checksOutcome(combined(statuses))}
	for _, s := range statuses {
		if when := s.UpdatedOn; n.At == "" || mcpevents.Before(n.At, when) {
			n.At, n.URL = when, s.URL
		}
	}
	if n.URL == "" && info.Links.HTML.Href != "" {
		n.URL = strings.TrimSuffix(info.Links.HTML.Href, "/") + "/commits/" + ref.Target.Hash
	}
	return n, nil
}

// checksOutcome is a combined state in the words a slot uses for a GitHub run.
func checksOutcome(state string) string {
	switch state {
	case "success":
		return "passed"
	case "failure":
		return "failed"
	}
	return "running"
}

// RepoAt is the Bitbucket Cloud repository (workspace/name) that folder's git remote names,
// origin first.
func RepoAt(ctx context.Context, folder string) (string, bool) {
	out, err := exec.CommandContext(ctx, "git", "-C", folder, "remote").Output()
	if err != nil {
		return "", false
	}
	names := []string{}
	for _, r := range strings.Fields(string(out)) {
		if r == "origin" {
			names = append([]string{r}, names...)
		} else {
			names = append(names, r)
		}
	}
	for _, name := range names {
		out, err := exec.CommandContext(ctx, "git", "-C", folder, "remote", "get-url", name).Output()
		if err != nil {
			continue
		}
		if repo, ok := RepoOfRemote(strings.TrimSpace(string(out))); ok {
			return repo, true
		}
	}
	return "", false
}
