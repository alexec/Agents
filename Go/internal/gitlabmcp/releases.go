package gitlabmcp

import (
	"context"
	"fmt"
	"net/url"
)

// RepoRelease is a release as forge/releases reads it (#4426): its tag, name and notes, when it
// was made and released, who made it, how many files it has, and its page. GitLab has no draft
// release; an upcoming release (released in the future) is its pre-release.
type RepoRelease struct {
	Tag, Name, Body        string
	Prerelease             bool
	CreatedAt, ReleasedAt  string
	Author, AuthorAvatar   string
	Assets                 int
	URL                    string
}

// Commit is one commit of a compare: its sha and message.
type Commit struct{ SHA, Message string }

// MostReleases bounds the releases one read lists: one page.
const MostReleases = 100

// Releases are the project's newest releases, at most limit (1 to MostReleases).
func (g *RealGitLab) Releases(ctx context.Context, project string, limit int) ([]RepoRelease, error) {
	var list []struct {
		TagName     string `json:"tag_name"`
		Name        string `json:"name"`
		Description string `json:"description"`
		CreatedAt   string `json:"created_at"`
		ReleasedAt  string `json:"released_at"`
		Upcoming    bool   `json:"upcoming_release"`
		Author      struct {
			Username  string `json:"username"`
			AvatarURL string `json:"avatar_url"`
		} `json:"author"`
		Assets struct {
			Count int `json:"count"`
		} `json:"assets"`
		Links struct {
			Self string `json:"self"`
		} `json:"_links"`
	}
	path := fmt.Sprintf("projects/%s/releases?per_page=%d", pid(project), min(max(limit, 1), MostReleases))
	if err := g.get(ctx, path, true, &list); err != nil {
		return nil, err
	}
	out := make([]RepoRelease, len(list))
	for i, r := range list {
		out[i] = RepoRelease{Tag: r.TagName, Name: r.Name, Body: r.Description, Prerelease: r.Upcoming, CreatedAt: r.CreatedAt,
			ReleasedAt: r.ReleasedAt, Author: r.Author.Username, AuthorAvatar: r.Author.AvatarURL, Assets: r.Assets.Count, URL: r.Links.Self}
	}
	return out, nil
}

// Compare is the commits in to and not in from, oldest first.
func (g *RealGitLab) Compare(ctx context.Context, project, from, to string) ([]Commit, error) {
	var j struct {
		Commits []struct {
			ID      string `json:"id"`
			Message string `json:"message"`
		} `json:"commits"`
	}
	q := url.Values{"from": {from}, "to": {to}}
	if err := g.get(ctx, fmt.Sprintf("projects/%s/repository/compare?%s", pid(project), q.Encode()), true, &j); err != nil {
		return nil, err
	}
	out := make([]Commit, len(j.Commits))
	for i, c := range j.Commits {
		out[i] = Commit{c.ID, c.Message}
	}
	return out, nil
}
