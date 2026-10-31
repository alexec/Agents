package githubmcp

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
)

// The reads that prove a folder's set-up (#1336): each slot reads one real thing (the newest
// issue, the newest pull request, the last workflow run), and the page asks whether the App
// is installed on the repository. A refusal is a GitHubError with Kind NotFound or Failed
// (403); a read that does not reach GitHub is Failed with no status.

// Newest is the newest issue or pull request, or the last run, as a slot shows it.
type Newest struct {
	Number  int
	Title   string
	URL     string
	At      string
	Outcome string // a run's: passed, failed, running, cancelled
}

// NewestIssue is the newest issue (not a pull request), or nil when the repo has none.
func (g *RealGitHub) NewestIssue(ctx context.Context, repo string) (*Newest, error) {
	var list []issueJSON
	if err := g.get(ctx, fmt.Sprintf("repos/%s/issues?state=all&sort=created&direction=desc&per_page=20", repo), false, &list); err != nil {
		return nil, err
	}
	for _, i := range list {
		if !i.isPR() {
			return &Newest{Number: i.Number, Title: i.Title, URL: i.HTMLURL, At: i.CreatedAt}, nil
		}
	}
	return nil, nil
}

// NewestPull is the newest pull request, or nil when the repo has none.
func (g *RealGitHub) NewestPull(ctx context.Context, repo string) (*Newest, error) {
	var list []struct {
		Number    int    `json:"number"`
		Title     string `json:"title"`
		HTMLURL   string `json:"html_url"`
		CreatedAt string `json:"created_at"`
	}
	if err := g.get(ctx, fmt.Sprintf("repos/%s/pulls?state=all&sort=created&direction=desc&per_page=1", repo), false, &list); err != nil {
		return nil, err
	}
	if len(list) == 0 {
		return nil, nil
	}
	p := list[0]
	return &Newest{Number: p.Number, Title: p.Title, URL: p.HTMLURL, At: p.CreatedAt}, nil
}

// LastRun is the last workflow run, or nil when the repo has none.
func (g *RealGitHub) LastRun(ctx context.Context, repo string) (*Newest, error) {
	var list struct {
		Runs []struct {
			Name         string `json:"name"`
			DisplayTitle string `json:"display_title"`
			HeadBranch   string `json:"head_branch"`
			HTMLURL      string `json:"html_url"`
			Status       string `json:"status"`
			Conclusion   string `json:"conclusion"`
			UpdatedAt    string `json:"updated_at"`
		} `json:"workflow_runs"`
	}
	if err := g.get(ctx, fmt.Sprintf("repos/%s/actions/runs?per_page=1", repo), false, &list); err != nil {
		return nil, err
	}
	if len(list.Runs) == 0 {
		return nil, nil
	}
	r := list.Runs[0]
	name := r.Name
	if name == "" {
		name = r.DisplayTitle
	}
	if r.HeadBranch != "" {
		name += " on " + r.HeadBranch
	}
	return &Newest{Title: name, URL: r.HTMLURL, At: r.UpdatedAt, Outcome: runOutcome(r.Status, r.Conclusion)}, nil
}

func runOutcome(status, conclusion string) string {
	if status != "completed" {
		return "running"
	}
	switch conclusion {
	case "success":
		return "passed"
	case "cancelled":
		return "cancelled"
	case "skipped", "neutral":
		return conclusion
	}
	return "failed"
}

// AppReach is whether the GitHub App named slug is installed on repo for the person, and how
// many repositories it lets the person's token see. Installations past the first page are
// not read: a person has a few.
func (g *RealGitHub) AppReach(ctx context.Context, repo, slug string) (installed bool, repositories int, err error) {
	var installations struct {
		Installations []struct {
			ID      int64  `json:"id"`
			AppSlug string `json:"app_slug"`
		} `json:"installations"`
	}
	if err := g.get(ctx, "user/installations?per_page=100", false, &installations); err != nil {
		return false, 0, err
	}
	for _, in := range installations.Installations {
		if in.AppSlug != slug {
			continue
		}
		for page := 1; page <= maxPages; page++ {
			var repos struct {
				Total        int `json:"total_count"`
				Repositories []struct {
					FullName string `json:"full_name"`
				} `json:"repositories"`
			}
			path := fmt.Sprintf("user/installations/%d/repositories", in.ID)
			if err := g.get(ctx, query(path, page), false, &repos); err != nil {
				return installed, repositories, err
			}
			if page == 1 {
				repositories += repos.Total
			}
			for _, r := range repos.Repositories {
				installed = installed || strings.EqualFold(r.FullName, repo)
			}
			if len(repos.Repositories) < perPage {
				break
			}
		}
	}
	return installed, repositories, nil
}

// RepoAt is the GitHub repo a folder pushes to, from its git remote (origin first).
func RepoAt(ctx context.Context, folder string) (string, bool) {
	for _, remote := range remotesAt(ctx, folder) {
		out, err := gitIn(ctx, folder, "remote", "get-url", remote)
		if err != nil {
			continue
		}
		if name, ok := RepoOfRemote(strings.TrimSpace(out)); ok {
			return name, true
		}
	}
	return "", false
}

func remotesAt(ctx context.Context, folder string) []string {
	out, err := gitIn(ctx, folder, "remote")
	if err != nil {
		return nil
	}
	remotes := []string{}
	for _, r := range strings.Fields(out) {
		if r == "origin" {
			remotes = append([]string{r}, remotes...)
		} else {
			remotes = append(remotes, r)
		}
	}
	return remotes
}

func gitIn(ctx context.Context, folder string, args ...string) (string, error) {
	out, err := exec.CommandContext(ctx, "git", append([]string{"-C", folder}, args...)...).Output()
	return string(out), err
}
