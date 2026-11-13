package agentsd

import (
	"cmp"
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"slices"
	"strings"

	"github.com/agentloops-dev/agents/Go/internal/forgejomcp"
	"github.com/agentloops-dev/agents/Go/internal/gitlabmcp"
	"github.com/agentloops-dev/agents/Go/internal/lineage"
	"github.com/agentloops-dev/agents/Go/wire"
)

// The forge's releases (#4426, specs/4328-work-look/milestones.md, task 6): forge/releases lists
// the releases of the folders' repos, and forge/release reads one, with the pull requests between
// its tag and the release before it, for Work's Releases list and a release's page. GitHub,
// GitLab and Forgejo have releases; Bitbucket, Azure Repos, Linear, Jira and Azure Boards say they
// have none (Caps, with the reason), so a client says so. A release's pull requests come from the
// squash titles' (#n) or (!n), as lineage links them (lineagerelease.go), with no call per
// commit: a merge commit with no number is counted in commits but names no pull request.

const (
	// forgeReleasesDefault is how many releases of each repo a list gives when not said, and
	// forgeReleasesMost the most it gives.
	forgeReleasesDefault = 30
	forgeReleasesMost    = 100
)

func (d *Daemon) registerForgeReleases() {
	On(d, wire.CallForgeReleases, func(ctx context.Context, _ *Client, r wire.ForgeReleasesRequest) (wire.ForgeReleases, error) {
		return d.forgeReleases(ctx, r)
	})
	On(d, wire.CallForgeRelease, func(ctx context.Context, _ *Client, r wire.ForgeReleaseRequest) (wire.ForgeReleaseDetail, error) {
		return d.forgeRelease(ctx, r)
	})
}

// forgeReleases are the releases of r.folder's repo, or of every folder's, newest first.
func (d *Daemon) forgeReleases(ctx context.Context, r wire.ForgeReleasesRequest) (wire.ForgeReleases, error) {
	const method = "forge/releases"
	limit := forgeReleasesDefault
	if r.Limit != nil {
		if *r.Limit < 1 || *r.Limit > forgeReleasesMost {
			return wire.ForgeReleases{}, Invalid("%s: limit is 1 to %d", method, forgeReleasesMost)
		}
		limit = int(*r.Limit)
	}
	folders := d.folderPaths()
	if f := deref(r.Folder); f != "" {
		if !slices.Contains(folders, f) {
			return wire.ForgeReleases{}, Invalid("%s: %s is not a folder on this machine", method, f)
		}
		folders = []string{f}
	}
	type scoped struct {
		forge Forge
		scope forgeScope
		err   error
	}
	var in []scoped
	keys := []any{}
	for _, f := range d.forges() {
		// A forge's repos are its issues' scope; a forge with pull requests only, its pull requests'.
		caps := f.Caps()
		s, err := f.Sources(ctx, folders, caps.PRs && !caps.Issues)
		if s == nil || s.Empty() && err == nil {
			continue
		}
		in = append(in, scoped{f, s, err})
		keys = append(keys, f.Name(), s.Key())
	}
	key, _ := json.Marshal([]any{method, keys, limit})
	if a, ok := d.forgeCached(string(key)); ok && a.releases != nil {
		return *a.releases, nil
	}
	out := wire.ForgeReleases{Releases: []wire.ForgeRelease{}}
	for _, s := range in {
		name := s.forge.Name()
		if caps := s.forge.Caps(); !caps.Releases {
			if !scopeNames(s.scope) {
				// A tracker's scope is never empty, for its boards: only one that names a team or
				// a project is in reach.
				continue
			}
			reason := cmp.Or(caps.Reasons[actionReleases], cannot(actionReleases).Error())
			out.None = append(out.None, wire.ForgeListError{Forge: name, Message: reason})
			continue
		}
		releases, err := []wire.ForgeRelease(nil), s.err
		if err == nil {
			releases, err = s.forge.Releases(ctx, s.scope, limit)
		}
		if err != nil {
			out.Errors = append(out.Errors, wire.ForgeListError{Forge: name, Message: err.Error()})
		}
		out.Releases = append(out.Releases, releases...)
	}
	markLatest(out.Releases)
	slices.SortStableFunc(out.Releases, func(a, b wire.ForgeRelease) int {
		return cmp.Or(cmp.Compare(releaseAt(b), releaseAt(a)), cmp.Compare(a.Node.Ref, b.Node.Ref))
	})
	d.forgeRemember(string(key), forgeAnswer{releases: &out})
	return out, nil
}

// scopeNames says s names something to read: a repo, a project or a team (a slice in its Key),
// or a whole workspace (true).
func scopeNames(s forgeScope) bool {
	for _, k := range s.Key() {
		switch v := k.(type) {
		case []string:
			if len(v) > 0 {
				return true
			}
		case bool:
			if v {
				return true
			}
		}
	}
	return false
}

// releaseAt is when a release was published, or a draft made: the list's order.
func releaseAt(r wire.ForgeRelease) wire.Date {
	return forgeDate(cmp.Or(deref(r.PublishedAt), deref(r.CreatedAt)))
}

// markLatest marks each repo's newest published release that is neither a draft nor a
// pre-release, as the forges' own Latest says it unless a person chose another.
func markLatest(releases []wire.ForgeRelease) {
	latest := map[string]int{}
	for i, r := range releases {
		if r.Draft || r.Prerelease || r.PublishedAt == nil {
			continue
		}
		repo := r.Forge + ":" + strings.ToLower(r.Repo)
		if j, ok := latest[repo]; !ok || releaseAt(r) > releaseAt(releases[j]) {
			latest[repo] = i
		}
	}
	for _, i := range latest {
		releases[i].Latest = true
	}
}

// releaseOfNode is the forge, repo (as the node names it) and tag of a release's node.
func releaseOfNode(n wire.LineageNode) (forge, repo, tag string, ok bool) {
	if n.Kind != lineage.KindRelease {
		return "", "", "", false
	}
	r, ok := lineage.RefOf(n)
	if !ok || r.Type != lineage.KindRelease || r.Topic == "" {
		return "", "", "", false
	}
	return r.Provider, r.Topic, r.ID, true
}

// forgeRelease is a release of a folder's repo, the release before it, and the pull requests
// between the two. It is found in the repo's newest forgeReleasesMost releases.
func (d *Daemon) forgeRelease(ctx context.Context, r wire.ForgeReleaseRequest) (wire.ForgeReleaseDetail, error) {
	const method = "forge/release"
	forge, repo, tag, ok := releaseOfNode(r.Node)
	if !ok {
		return wire.ForgeReleaseDetail{}, Invalid("%s: %s is not a release's node", method, r.Node.Ref)
	}
	var f Forge
	for _, x := range d.forges() {
		if x.Name() == forge {
			f = x
		}
	}
	if f == nil {
		return wire.ForgeReleaseDetail{}, Invalid("%s: %s is no forge here", method, forge)
	}
	if caps := f.Caps(); !caps.Releases {
		return wire.ForgeReleaseDetail{}, forgeCannotErr(method, f, cannot(actionReleases))
	}
	list, err := d.forgeReleases(ctx, wire.ForgeReleasesRequest{Limit: new(int64(forgeReleasesMost))})
	if err != nil {
		return wire.ForgeReleaseDetail{}, err
	}
	// This repo's releases, newest first.
	var mine []wire.ForgeRelease
	for _, x := range list.Releases {
		if x.Forge == forge && strings.EqualFold(x.Repo, repo) {
			mine = append(mine, x)
		}
	}
	at := slices.IndexFunc(mine, func(x wire.ForgeRelease) bool { return x.Tag == tag })
	if at < 0 {
		for _, e := range list.Errors {
			if e.Forge == forge {
				return wire.ForgeReleaseDetail{}, fmt.Errorf("%s: %s", method, e.Message)
			}
		}
		return wire.ForgeReleaseDetail{}, Invalid("%s: %s has no release %s in its newest %d", method, repo, tag, forgeReleasesMost)
	}
	out := wire.ForgeReleaseDetail{Release: mine[at], Pulls: []wire.ForgeReleasePull{}}
	if out.Release.Draft {
		// A draft's tag may not be made yet: it has no range.
		return out, nil
	}
	prev := slices.IndexFunc(mine[at+1:], func(x wire.ForgeRelease) bool { return !x.Draft })
	if prev < 0 {
		// The first release: lineage links none of the history to it either.
		return out, nil
	}
	previous := mine[at+1+prev].Tag
	out.Previous = &previous
	commits, page, err := f.ReleaseCommits(ctx, repo, previous, tag)
	if err != nil {
		return wire.ForgeReleaseDetail{}, forgeCannotErr(method, f, err)
	}
	out.CompareUrl = optional(page)
	out.Commits = int64(len(commits))
	out.Pulls = releasePulls(forgeRepo{forge, strings.ToLower(repo)}, commits)
	return out, nil
}

// releasePulls are the pull requests commits merged, each once, from their squash titles.
func releasePulls(repo forgeRepo, commits []compareCommit) []wire.ForgeReleasePull {
	out := []wire.ForgeReleasePull{}
	seen := map[int]bool{}
	for _, c := range commits {
		n, ok := squashPRNumber(repo.forge, c.Message)
		if !ok || seen[n] {
			continue
		}
		seen[n] = true
		title, _, _ := strings.Cut(c.Message, "\n")
		title = strings.TrimSpace(strings.TrimSuffix(strings.TrimRight(title, " "), fmt.Sprintf("(%s%d)", map[bool]string{false: "#", true: "!"}[repo.forge == "gitlab"], n)))
		out = append(out, wire.ForgeReleasePull{Node: repo.pr(n), Number: int64(n), Title: title, Sha: c.SHA})
	}
	return out
}

// forgeReleaseOf is a release on the wire, of repo as its forge names it.
func forgeReleaseOf(forge, repo, folder string, tag, name, body string, draft, prerelease bool,
	createdAt, publishedAt, author, avatar string, assets int, page string) wire.ForgeRelease {
	return wire.ForgeRelease{Node: forgeRepo{forge, strings.ToLower(repo)}.release(tag), Forge: forge, Repo: repo,
		Folder: optional(folder), Tag: tag, Name: cmp.Or(name, tag), Body: optional(body), Draft: draft, Prerelease: prerelease,
		CreatedAt: optional(createdAt), PublishedAt: optional(publishedAt), Author: optional(author),
		AuthorAvatar: optional(avatar), Assets: int64(assets), URL: page}
}

// Releases are each repo's, one call for each: GitHub has no list across repos.
func (g githubForge) Releases(ctx context.Context, scope forgeScope, limit int) ([]wire.ForgeRelease, error) {
	s, _ := scope.(githubScope)
	gh, err := g.d.forgeGitHub()
	if err != nil {
		return nil, err
	}
	var out []wire.ForgeRelease
	for _, repo := range s.repos {
		list, err := gh.Releases(ctx, repo, limit)
		if err != nil {
			return out, err
		}
		for _, r := range list {
			out = append(out, forgeReleaseOf("github", repo, s.folderOf[repo], r.Tag, r.Name, r.Body, r.Draft, r.Prerelease,
				r.CreatedAt, r.PublishedAt, r.Author, r.AuthorAvatar, r.Assets, r.URL))
		}
	}
	return out, nil
}

func (g githubForge) ReleaseCommits(ctx context.Context, repo, base, head string) ([]compareCommit, string, error) {
	gh, err := g.d.forgeGitHub()
	if err != nil {
		return nil, "", err
	}
	commits, err := gh.Compare(ctx, repo, base, head)
	if err != nil {
		return nil, "", githubNotFound("forge/release", err)
	}
	out := make([]compareCommit, len(commits))
	for i, c := range commits {
		out[i] = compareCommit{c.SHA, c.Message}
	}
	return out, fmt.Sprintf("https://github.com/%s/compare/%s...%s", repo, url.PathEscape(base), url.PathEscape(head)), nil
}

// Releases are each project's, one call for each.
func (g gitlabForge) Releases(ctx context.Context, scope forgeScope, limit int) ([]wire.ForgeRelease, error) {
	s, _ := scope.(gitlabScope)
	gl := g.d.forgeGitLab(s.root)
	var out []wire.ForgeRelease
	for _, project := range s.projects {
		list, err := gl.Releases(ctx, project, limit)
		if err != nil {
			return out, err
		}
		for _, r := range list {
			out = append(out, forgeReleaseOf("gitlab", project, s.folderOf[strings.ToLower(project)], r.Tag, r.Name, r.Body, false,
				r.Prerelease, r.CreatedAt, r.ReleasedAt, r.Author, r.AuthorAvatar, r.Assets, r.URL))
		}
	}
	return out, nil
}

func (g gitlabForge) ReleaseCommits(ctx context.Context, repo, base, head string) ([]compareCommit, string, error) {
	gl, project, _, err := g.d.gitlabOf(ctx, "forge/release", forgeRepo{"gitlab", repo})
	if err != nil {
		return nil, "", err
	}
	commits, err := gl.Compare(ctx, project, base, head)
	if err != nil {
		if gitlabmcp.IsNotFound(err) {
			return nil, "", Invalid("forge/release: %v", err)
		}
		return nil, "", err
	}
	out := make([]compareCommit, len(commits))
	for i, c := range commits {
		out[i] = compareCommit{c.SHA, c.Message}
	}
	page := ""
	if gl, ok := g.d.gitlabConnection(); ok {
		page = fmt.Sprintf("%s%s/-/compare/%s...%s", gitlabmcp.BaseURL(gl.URL), project, url.PathEscape(base), url.PathEscape(head))
	}
	return out, page, nil
}

// Releases are each repository's, one call for each.
func (g forgejoForge) Releases(ctx context.Context, scope forgeScope, limit int) ([]wire.ForgeRelease, error) {
	s, _ := scope.(forgejoScope)
	fj := g.d.forgeForgejo(s.conn, s.root)
	var out []wire.ForgeRelease
	for _, repo := range s.repos {
		list, err := fj.Releases(ctx, repo, min(limit, forgejomcp.MostReleases))
		if err != nil {
			return out, err
		}
		for _, r := range list {
			out = append(out, forgeReleaseOf("forgejo", repo, s.folderOf[strings.ToLower(repo)], r.Tag, r.Name, r.Body, r.Draft,
				r.Prerelease, r.CreatedAt, r.PublishedAt, r.Author, r.AuthorAvatar, r.Assets, r.URL))
		}
	}
	return out, nil
}

func (g forgejoForge) ReleaseCommits(ctx context.Context, repo, base, head string) ([]compareCommit, string, error) {
	fj, named, _, err := g.d.forgejoOf(ctx, "forge/release", repo)
	if err != nil {
		return nil, "", err
	}
	commits, err := fj.Compare(ctx, named, base, head)
	if err != nil {
		return nil, "", err
	}
	out := make([]compareCommit, len(commits))
	for i, c := range commits {
		out[i] = compareCommit{c.SHA, c.Message}
	}
	_, root := g.d.forgejoRoot()
	page := ""
	if root != "" {
		page = fmt.Sprintf("%s%s/compare/%s...%s", root, named, url.PathEscape(base), url.PathEscape(head))
	}
	return out, page, nil
}
