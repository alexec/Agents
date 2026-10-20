package gitlabmcp

import (
	"context"
	"fmt"
	"net/url"
	"os/exec"
	"strings"
)

// The reads that prove a project's set-up on GitLab (#1632), as the github server's (#1336):
// each slot reads one real thing, the newest issue, the newest merge request and the last
// pipeline. A refusal is a GitLabError with Refused; a read that does not reach GitLab is
// Failed.

// Newest is the newest issue or merge request, or the last pipeline, as a slot shows it.
type Newest struct {
	Number  int
	Title   string
	URL     string
	At      string
	Outcome string // a pipeline's: passed, failed, running, cancelled, skipped, waiting
}

type newestJSON struct {
	IID       int    `json:"iid"`
	Title     string `json:"title"`
	WebURL    string `json:"web_url"`
	CreatedAt string `json:"created_at"`
}

func (g *RealGitLab) newest(ctx context.Context, path string) (*Newest, error) {
	var list []newestJSON
	if err := g.get(ctx, path, false, &list); err != nil {
		return nil, err
	}
	if len(list) == 0 {
		return nil, nil
	}
	n := list[0]
	return &Newest{Number: n.IID, Title: n.Title, URL: n.WebURL, At: n.CreatedAt}, nil
}

// NewestIssue is the project's newest issue, open or closed, or nil when it has none.
func (g *RealGitLab) NewestIssue(ctx context.Context, project string) (*Newest, error) {
	return g.newest(ctx, fmt.Sprintf("projects/%s/issues?scope=all&order_by=created_at&sort=desc&per_page=1", pid(project)))
}

// NewestMergeRequest is the project's newest merge request, or nil when it has none.
func (g *RealGitLab) NewestMergeRequest(ctx context.Context, project string) (*Newest, error) {
	return g.newest(ctx, fmt.Sprintf("projects/%s/merge_requests?scope=all&order_by=created_at&sort=desc&per_page=1", pid(project)))
}

// LastPipeline is the project's last pipeline, or nil when it has none.
func (g *RealGitLab) LastPipeline(ctx context.Context, project string) (*Newest, error) {
	var list []struct {
		ID        int    `json:"id"`
		Name      string `json:"name"`
		Ref       string `json:"ref"`
		Status    string `json:"status"`
		WebURL    string `json:"web_url"`
		UpdatedAt string `json:"updated_at"`
	}
	if err := g.get(ctx, fmt.Sprintf("projects/%s/pipelines?order_by=id&sort=desc&per_page=1", pid(project)), false, &list); err != nil {
		return nil, err
	}
	if len(list) == 0 {
		return nil, nil
	}
	p := list[0]
	name := p.Name
	if name == "" {
		name = "Pipeline"
	}
	if p.Ref != "" && !strings.HasPrefix(p.Ref, "refs/") {
		name += " on " + p.Ref
	}
	return &Newest{Title: name, URL: p.WebURL, At: p.UpdatedAt, Outcome: pipelineOutcome(p.Status)}, nil
}

// pipelineOutcome is a pipeline's status in the words a slot uses for a GitHub run.
func pipelineOutcome(status string) string {
	switch status {
	case "success":
		return "passed"
	case "failed":
		return "failed"
	case "canceled", "canceling":
		return "cancelled"
	case "skipped":
		return "skipped"
	case "manual", "scheduled":
		return "waiting"
	}
	return "running"
}

// ProjectAt is the GitLab project that folder's git remote names (origin first) on one of
// roots, and that root. A remote whose host has "gitlab" in it names a GitLab too, at its
// host's root, when no root matches: a self-managed GitLab before it is connected.
func ProjectAt(ctx context.Context, folder string, roots []string) (root, project string, ok bool) {
	var remotes []string
	for _, name := range remotesAt(ctx, folder) {
		out, err := exec.CommandContext(ctx, "git", "-C", folder, "remote", "get-url", name).Output()
		if err == nil {
			remotes = append(remotes, strings.TrimSpace(string(out)))
		}
	}
	for _, r := range roots {
		for _, remote := range remotes {
			if path, ok := ProjectOfRemote(r, remote); ok {
				return BaseURL(r), path, true
			}
		}
	}
	for _, remote := range remotes {
		if host := remoteHost(remote); strings.Contains(strings.ToLower(host), "gitlab") {
			if path, ok := ProjectOfRemote(host, remote); ok {
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
