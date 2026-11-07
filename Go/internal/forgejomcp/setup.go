package forgejomcp

import (
	"context"
	"fmt"
	"net/url"
	"os/exec"
	"strings"
)

// The reads that prove a repository's set-up on Forgejo (#3752), as the gitlab server's
// (#1632): each slot reads one real thing, the newest issue, the newest pull request and the
// default branch's checks. A refusal is a ForgejoError with Refused; a read that does not
// reach Forgejo is Failed.

// Newest is the newest issue or pull request, or the default branch's checks, as a slot
// shows it.
type Newest struct {
	Number  int
	Title   string
	URL     string
	At      string
	Outcome string // the checks': passed, failed, running
}

// NewestIssue is the repository's newest issue, open or closed, or nil when it has none.
func (f *RealForgejo) NewestIssue(ctx context.Context, repo string) (*Newest, error) {
	return f.newestOne(ctx, repoPath(repo)+"/issues?state=all&type=issues&limit=1")
}

// NewestPull is the repository's newest pull request, open or closed, or nil when it has none.
func (f *RealForgejo) NewestPull(ctx context.Context, repo string) (*Newest, error) {
	return f.newestOne(ctx, repoPath(repo)+"/pulls?state=all&limit=1")
}

func (f *RealForgejo) newestOne(ctx context.Context, path string) (*Newest, error) {
	var list []issueJSON
	if err := f.get(ctx, path, false, &list); err != nil {
		return nil, err
	}
	if len(list) == 0 {
		return nil, nil
	}
	n := list[0]
	return &Newest{Number: n.Number, Title: n.Title, URL: n.HTMLURL, At: n.CreatedAt}, nil
}

// LastChecks is the combined commit status of the default branch's head: Forgejo Actions,
// Woodpecker or any CI that reports a status. Nil when nothing reported one.
func (f *RealForgejo) LastChecks(ctx context.Context, repo string) (*Newest, error) {
	var info struct {
		DefaultBranch string `json:"default_branch"`
		HTMLURL       string `json:"html_url"`
	}
	if err := f.get(ctx, repoPath(repo), false, &info); err != nil {
		return nil, err
	}
	if info.DefaultBranch == "" {
		return nil, nil
	}
	var c combinedJSON
	if err := f.get(ctx, fmt.Sprintf("%s/commits/%s/status", repoPath(repo), url.PathEscape(info.DefaultBranch)), false, &c); err != nil {
		return nil, err
	}
	if len(c.Statuses) == 0 {
		return nil, nil
	}
	n := &Newest{Title: "Checks on " + info.DefaultBranch, Outcome: checksOutcome(c.State)}
	for _, s := range c.Statuses {
		if n.At == "" || before(n.At, s.UpdatedAt) {
			n.At, n.URL = s.UpdatedAt, s.TargetURL
		}
	}
	if n.URL == "" && info.HTMLURL != "" && c.SHA != "" {
		n.URL = strings.TrimSuffix(info.HTMLURL, "/") + "/commit/" + c.SHA
	}
	return n, nil
}

// checksOutcome is a combined status in the words a slot uses for a GitHub run.
func checksOutcome(state string) string {
	switch state {
	case "success", "warning":
		return "passed"
	case "failure", "error":
		return "failed"
	}
	return "running"
}

// RepoAt is the Forgejo repository that folder's git remote names (origin first) on one of
// roots, and that root. A remote whose host has "forgejo", "gitea" or "codeberg" in it names a
// Forgejo too, at its host's root, when no root matches: one of one's own before it is
// connected.
func RepoAt(ctx context.Context, folder string, roots []string) (root, repo string, ok bool) {
	var remotes []string
	for _, name := range remotesAt(ctx, folder) {
		out, err := exec.CommandContext(ctx, "git", "-C", folder, "remote", "get-url", name).Output()
		if err == nil {
			remotes = append(remotes, strings.TrimSpace(string(out)))
		}
	}
	for _, r := range roots {
		for _, remote := range remotes {
			if path, ok := RepoOfRemote(r, remote); ok {
				return BaseURL(r), path, true
			}
		}
	}
	for _, remote := range remotes {
		host := strings.ToLower(remoteHost(remote))
		if strings.Contains(host, "forgejo") || strings.Contains(host, "gitea") || strings.Contains(host, "codeberg") {
			if path, ok := RepoOfRemote(host, remote); ok {
				return BaseURL(host), path, true
			}
		}
	}
	return "", "", false
}

// remoteHost is a remote's host: from a URL, or from scp-like [user@]host:path.
func remoteHost(remote string) string {
	if strings.Contains(remote, "://") {
		if u, err := url.Parse(remote); err == nil {
			return u.Hostname()
		}
		return ""
	}
	at := remote
	if _, after, ok := strings.Cut(remote, "@"); ok {
		at = after
	}
	h, _, _ := strings.Cut(at, ":")
	return h
}

func remotesAt(ctx context.Context, folder string) []string {
	out, err := exec.CommandContext(ctx, "git", "-C", folder, "remote").Output()
	if err != nil {
		return nil
	}
	remotes := []string{}
	for _, r := range strings.Fields(string(out)) {
		if r == "origin" {
			remotes = append([]string{r}, remotes...)
		} else {
			remotes = append(remotes, r)
		}
	}
	return remotes
}
