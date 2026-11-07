package azuredevopsmcp

import (
	"context"
	"errors"
	"net/url"
	"os/exec"
	"strconv"
	"strings"
)

// The reads that prove a repository's set-up on Azure DevOps (#3802), as the bitbucket
// server's (#3785): Code review reads the newest pull request and CI the newest Azure
// Pipelines build; Tasks is Azure Boards' (azureboardsmcp.RealBoards.NewestItem). A refusal
// (403, or 404 for a repository the token can't see) is Refused.

// Newest is the newest pull request, or the newest build, as a slot shows it.
type Newest struct {
	Number  int
	Title   string
	URL     string
	At      string
	Outcome string // the build's: passed, failed, running
}

// Refused is whether err is Azure DevOps's no to this token for this repository.
func Refused(err error) bool {
	var e *AzureDevOpsError
	return errors.As(err, &e) && (e.Kind == NotFound || strings.HasPrefix(e.Message, "Azure DevOps: HTTP 403"))
}

// NewestPull is the repository's newest pull request, in any state, or nil when it has none.
func (f *RealAzureDevOps) NewestPull(ctx context.Context, repo string) (*Newest, error) {
	var list struct {
		Value []pullJSON `json:"value"`
	}
	q := url.Values{"searchCriteria.status": {"all"}, "$top": {"1"}}
	if err := f.get(ctx, api(repoPath(repo)+"/pullrequests", q), false, &list); err != nil {
		return nil, err
	}
	if len(list.Value) == 0 {
		return nil, nil
	}
	p := list.Value[0]
	return &Newest{Number: p.ID, Title: p.Title, URL: f.prURL(repo, p.ID), At: p.CreationDate}, nil
}

// LastChecks is the repository's newest Azure Pipelines build, of any branch or pull request,
// or nil when there is none.
func (f *RealAzureDevOps) LastChecks(ctx context.Context, repo string) (*Newest, error) {
	r, err := f.repository(ctx, repo)
	if err != nil {
		return nil, err
	}
	q := url.Values{"repositoryId": {r.ID}, "repositoryType": {"TfsGit"}, "queryOrder": {"queueTimeDescending"}, "$top": {"1"}}
	var list struct {
		Value []buildJSON `json:"value"`
	}
	if err := f.get(ctx, api(projectPath(repo)+"build/builds", q), false, &list); err != nil {
		return nil, err
	}
	if len(list.Value) == 0 {
		return nil, nil
	}
	b := list.Value[0]
	n := &Newest{Number: b.ID, Title: b.Definition.Name + " " + b.BuildNumber, URL: b.Links.Web.Href, At: b.FinishTime, Outcome: "running"}
	if n.At == "" {
		n.At = b.QueueTime
	}
	if b.Status == "completed" {
		// A build canceled, or partly succeeded, did not pass.
		n.Outcome = "failed"
		if passed, _ := buildPassed(b.Result); passed {
			n.Outcome = "passed"
		}
	}
	if n.URL == "" {
		org, project, _ := splitRepo(repo)
		n.URL = f.Base + url.PathEscape(org) + "/" + url.PathEscape(project) + "/_build/results?buildId=" + strconv.Itoa(b.ID)
	}
	return n, nil
}

// RepoAt is the repository (organization/project/name) of the Azure DevOps at base that
// folder's git remote names, origin first.
func RepoAt(ctx context.Context, folder, base string) (string, bool) {
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
		if repo, ok := RepoOfRemote(base, strings.TrimSpace(string(out))); ok {
			return repo, true
		}
	}
	return "", false
}
