package githubmcp

import (
	"context"
	"testing"
)

// #4426: a repo's releases, a draft with no publishedAt, a pre-release, the author and the assets.
func TestReleases(t *testing.T) {
	api := newFakeAPI(t, map[string]string{
		"repos/" + repo + "/releases": `[
			{"tag_name": "v0.18.0", "name": "", "draft": true, "created_at": "2026-11-09T10:00:00Z", "published_at": null, "assets": [], "html_url": "u0"},
			{"tag_name": "v0.17.0", "name": "0.17.0", "body": "Notes", "prerelease": true, "created_at": "2026-11-05T09:00:00Z",
			 "published_at": "2026-11-05T10:00:00Z", "author": {"login": "alexec", "avatar_url": "a"}, "assets": [{}, {}], "html_url": "u1"}]`,
	})
	got, err := api.github().Releases(context.Background(), repo, 500)
	if err != nil || len(got) != 2 {
		t.Fatalf("%+v %v", got, err)
	}
	if d := got[0]; !d.Draft || d.PublishedAt != "" || d.Tag != "v0.18.0" || d.URL != "u0" {
		t.Errorf("draft: %+v", d)
	}
	if r := got[1]; r.Name != "0.17.0" || r.Body != "Notes" || !r.Prerelease || r.Author != "alexec" || r.AuthorAvatar != "a" || r.Assets != 2 ||
		r.PublishedAt != "2026-11-05T10:00:00Z" {
		t.Errorf("release: %+v", r)
	}
}
