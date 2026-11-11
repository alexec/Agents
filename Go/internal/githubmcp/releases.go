package githubmcp

import (
	"context"
	"fmt"
)

// RepoRelease is a release as forge/releases reads it (#4426): its tag, name and notes, whether
// it is a draft or a pre-release, when it was made and published, who published it, how many
// files it has, and its page. A draft has no PublishedAt.
type RepoRelease struct {
	Tag, Name, Body          string
	Draft, Prerelease        bool
	CreatedAt, PublishedAt   string
	Author, AuthorAvatar     string
	Assets                   int
	URL                      string
}

// MostReleases bounds the releases one read lists: one page.
const MostReleases = 100

// Releases are the repo's newest releases, at most limit (1 to MostReleases), as GitHub lists
// them: drafts only to a person who can push.
func (g *RealGitHub) Releases(ctx context.Context, repo string, limit int) ([]RepoRelease, error) {
	if _, _, err := ownerName(repo); err != nil {
		return nil, err
	}
	var list []struct {
		TagName     string `json:"tag_name"`
		Name        string `json:"name"`
		Body        string `json:"body"`
		Draft       bool   `json:"draft"`
		Prerelease  bool   `json:"prerelease"`
		CreatedAt   string `json:"created_at"`
		PublishedAt string `json:"published_at"`
		Author      struct {
			Login     string `json:"login"`
			AvatarURL string `json:"avatar_url"`
		} `json:"author"`
		Assets  []struct{} `json:"assets"`
		HTMLURL string     `json:"html_url"`
	}
	if err := g.get(ctx, fmt.Sprintf("repos/%s/releases?per_page=%d", repo, min(max(limit, 1), MostReleases)), true, &list); err != nil {
		return nil, err
	}
	out := make([]RepoRelease, len(list))
	for i, r := range list {
		out[i] = RepoRelease{Tag: r.TagName, Name: r.Name, Body: r.Body, Draft: r.Draft, Prerelease: r.Prerelease,
			CreatedAt: r.CreatedAt, PublishedAt: r.PublishedAt, Author: r.Author.Login, AuthorAvatar: r.Author.AvatarURL,
			Assets: len(r.Assets), URL: r.HTMLURL}
	}
	return out, nil
}
