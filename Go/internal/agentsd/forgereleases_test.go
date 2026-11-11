package agentsd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/forgejomcp"
	"github.com/alexec/agents/Go/internal/githubmcp"
	"github.com/alexec/agents/Go/internal/gitlabmcp"
	"github.com/alexec/agents/Go/wire"
)

// The fakes' releases (#4426): alexec/agents has a draft, two releases and their range (deploys_test.go's
// Compare); alexec/web a release and a later pre-release.
func (f *fakeForgeGitHub) Releases(_ context.Context, repo string, limit int) ([]githubmcp.RepoRelease, error) {
	f.note("releases %s %d", repo, limit)
	switch repo {
	case "alexec/agents":
		return []githubmcp.RepoRelease{
			{Tag: "v0.18.0", Draft: true, CreatedAt: "2026-11-09T10:00:00Z", URL: "https://github.com/alexec/agents/releases/tag/untagged-1"},
			{Tag: "v0.17.0", Name: "0.17.0", Body: "## Milestones finished", CreatedAt: "2026-11-05T09:00:00Z", PublishedAt: "2026-11-05T10:00:00Z",
				Author: "alexec", AuthorAvatar: "https://avatars.githubusercontent.com/u/1", Assets: 2, URL: "https://github.com/alexec/agents/releases/tag/v0.17.0"},
			{Tag: "v0.16.0", PublishedAt: "2026-11-01T10:00:00Z", URL: "https://github.com/alexec/agents/releases/tag/v0.16.0"},
		}, nil
	case "alexec/web":
		return []githubmcp.RepoRelease{
			{Tag: "v1.1.0-rc.1", Prerelease: true, PublishedAt: "2026-11-08T10:00:00Z", URL: "https://github.com/alexec/web/releases/tag/v1.1.0-rc.1"},
			{Tag: "v1.0.0", PublishedAt: "2026-11-03T10:00:00Z", URL: "https://github.com/alexec/web/releases/tag/v1.0.0"},
		}, nil
	}
	return nil, nil
}

func (f *fakeForgeGitLab) Releases(_ context.Context, project string, _ int) ([]gitlabmcp.RepoRelease, error) {
	if project != "Group/App" {
		return nil, fmt.Errorf("releases of %s", project)
	}
	return []gitlabmcp.RepoRelease{
		{Tag: "v2.0.0", Name: "Two", Body: "Notes.", ReleasedAt: "2026-11-04T10:00:00Z", Author: "kim", Assets: 1, URL: "https://gitlab.com/Group/App/-/releases/v2.0.0"},
		{Tag: "v1.9.0", ReleasedAt: "2026-10-20T10:00:00Z", URL: "https://gitlab.com/Group/App/-/releases/v1.9.0"},
	}, nil
}

func (f *fakeForgeGitLab) Compare(_ context.Context, project, from, to string) ([]gitlabmcp.Commit, error) {
	if project != "Group/App" || from != "v1.9.0" || to != "v2.0.0" {
		return nil, fmt.Errorf("compare %s %s...%s", project, from, to)
	}
	return []gitlabmcp.Commit{{SHA: "c1", Message: "Faster lists (!4)\n\nBody."}, {SHA: "c2", Message: "Merge branch 'x' into 'main'"}}, nil
}

func (f *fakeForgeForgejo) Releases(_ context.Context, repo string, _ int) ([]forgejomcp.RepoRelease, error) {
	f.note(&f.asked, "releases "+repo)
	return []forgejomcp.RepoRelease{
		{Tag: "v0.2.0", PublishedAt: "2026-11-06T10:00:00Z", URL: "http://localhost:3753/walkalex/App/releases/tag/v0.2.0"},
		{Tag: "v0.1.0", PublishedAt: "2026-10-01T10:00:00Z", URL: "http://localhost:3753/walkalex/App/releases/tag/v0.1.0"},
	}, nil
}

func releaseTags(rs []wire.ForgeRelease) string {
	var out []string
	for _, r := range rs {
		s := r.Node.Ref
		if r.Latest {
			s += "*"
		}
		out = append(out, s)
	}
	return strings.Join(out, " ")
}

// #4426: forge/releases lists every folder's repo's releases on GitHub and the connected GitLab,
// newest first (a draft by when it was made), marks each repo's latest, and says that Linear,
// which the folders reach, has none; the same list within a minute asks GitHub nothing.
func TestForgeReleasesListsEveryForge(t *testing.T) {
	_, c, gh, _, _, _ := allForgesDaemon(t)
	var list wire.ForgeReleases
	if err := json.Unmarshal(c.call(t, 1, "forge/releases", wire.ForgeReleasesRequest{}), &list); err != nil {
		t.Fatal(err)
	}
	want := "github:alexec/agents/release/v0.18.0 github:alexec/web/release/v1.1.0-rc.1 github:alexec/agents/release/v0.17.0* " +
		"gitlab:group/app/release/v2.0.0* github:alexec/web/release/v1.0.0* github:alexec/agents/release/v0.16.0 gitlab:group/app/release/v1.9.0"
	if got := releaseTags(list.Releases); got != want {
		t.Fatalf("releases:\n%s\nwant\n%s", got, want)
	}
	if len(list.Errors) != 0 || len(list.None) != 1 || list.None[0].Forge != "linear" || !strings.Contains(list.None[0].Message, "Linear has no releases") {
		t.Fatalf("errors %+v none %+v", list.Errors, list.None)
	}
	r := list.Releases[2]
	if r.Node.Kind != "release" || r.Forge != "github" || r.Repo != "alexec/agents" || r.Name != "0.17.0" || deref(r.Body) != "## Milestones finished" ||
		deref(r.Author) != "alexec" || r.Assets != 2 || deref(r.Folder) == "" || deref(r.PublishedAt) != "2026-11-05T10:00:00Z" {
		t.Fatalf("release: %+v", r)
	}
	if d := list.Releases[0]; !d.Draft || d.PublishedAt != nil || d.Name != "v0.18.0" {
		t.Fatalf("draft: %+v", d)
	}
	asked := len(gh.writes())
	json.Unmarshal(c.call(t, 2, "forge/releases", wire.ForgeReleasesRequest{}), &list)
	if len(gh.writes()) != asked {
		t.Fatalf("the same list within a minute asked again: %q", gh.writes())
	}
	if err := c.callErr(t, 3, "forge/releases", wire.ForgeReleasesRequest{Limit: new(int64(101))}); !strings.Contains(err, "limit is 1 to 100") {
		t.Fatalf("a limit over 100: %s", err)
	}
}

// #4426: forge/release is a release, the release before it and the pull requests between them,
// from the squash titles, on GitHub and GitLab; a draft and the first release have no range.
func TestForgeReleaseReadsItsPullRequests(t *testing.T) {
	_, c, _, _, _, _ := allForgesDaemon(t)
	var got wire.ForgeReleaseDetail
	json.Unmarshal(c.call(t, 1, "forge/release", wire.ForgeReleaseRequest{Node: wire.LineageNode{Kind: "release", Ref: "github:alexec/agents/release/v0.17.0"}}), &got)
	if got.Release.Tag != "v0.17.0" || deref(got.Previous) != "v0.16.0" || got.Commits != 2 ||
		deref(got.CompareUrl) != "https://github.com/alexec/agents/compare/v0.16.0...v0.17.0" {
		t.Fatalf("release: %+v", got)
	}
	if len(got.Pulls) != 2 || got.Pulls[0] != (wire.ForgeReleasePull{Node: wire.LineageNode{Kind: "pr", Ref: "github:alexec/agents#3587"}, Number: 3587,
		Title: "Waiting deploys in Needs You", Sha: "a1"}) || got.Pulls[1].Number != 3585 {
		t.Fatalf("pulls: %+v", got.Pulls)
	}

	json.Unmarshal(c.call(t, 2, "forge/release", wire.ForgeReleaseRequest{Node: wire.LineageNode{Kind: "release", Ref: "gitlab:group/app/release/v2.0.0"}}), &got)
	if deref(got.Previous) != "v1.9.0" || got.Commits != 2 || len(got.Pulls) != 1 || got.Pulls[0].Node.Ref != "gitlab:group/app!4" ||
		got.Pulls[0].Title != "Faster lists" || deref(got.CompareUrl) != "https://gitlab.com/Group/App/-/compare/v1.9.0...v2.0.0" {
		t.Fatalf("GitLab release: %+v", got)
	}

	for _, ref := range []string{"github:alexec/agents/release/v0.18.0", "github:alexec/agents/release/v0.16.0"} {
		got = wire.ForgeReleaseDetail{}
		json.Unmarshal(c.call(t, 3, "forge/release", wire.ForgeReleaseRequest{Node: wire.LineageNode{Kind: "release", Ref: ref}}), &got)
		if got.Previous != nil || got.Commits != 0 || got.Pulls == nil || len(got.Pulls) != 0 {
			t.Fatalf("%s: %+v", ref, got)
		}
	}

	for ref, words := range map[string]string{
		"github:alexec/agents/release/v9.9.9": "no release v9.9.9",
		"linear:eng/release/v1":               "Linear has no releases",
		"github:alexec/agents#12":             "not a release's node",
	} {
		kind := "release"
		if strings.Contains(ref, "#") {
			kind = "pr"
		}
		if err := c.callErr(t, 4, "forge/release", wire.ForgeReleaseRequest{Node: wire.LineageNode{Kind: kind, Ref: ref}}); !strings.Contains(err, words) {
			t.Errorf("%s: %v, want %q", ref, err, words)
		}
	}
}

// #4426: Forgejo's releases are its connected repository's, and a release's range is asked of it.
func TestForgeReleasesOnForgejo(t *testing.T) {
	_, c, fj, _ := forgejoDaemon(t)
	var list wire.ForgeReleases
	json.Unmarshal(c.call(t, 1, "forge/releases", wire.ForgeReleasesRequest{}), &list)
	var forgejo []wire.ForgeRelease
	for _, r := range list.Releases {
		if r.Forge == "forgejo" {
			forgejo = append(forgejo, r)
		}
	}
	if got := releaseTags(forgejo); got != "forgejo:walkalex/app/release/v0.2.0* forgejo:walkalex/app/release/v0.1.0" {
		t.Fatalf("Forgejo releases: %s (errors %+v)", got, list.Errors)
	}
	var got wire.ForgeReleaseDetail
	json.Unmarshal(c.call(t, 2, "forge/release", wire.ForgeReleaseRequest{Node: forgejo[0].Node}), &got)
	if deref(got.Previous) != "v0.1.0" || len(got.Pulls) != 1 || got.Pulls[0].Title != "Add a" ||
		deref(got.CompareUrl) != "http://localhost:3753/walkalex/App/compare/v0.1.0...v0.2.0" {
		t.Fatalf("Forgejo release: %+v", got)
	}
	if !strings.Contains(strings.Join(fj.asked, "\n"), "compare walkalex/App v0.1.0...v0.2.0") {
		t.Fatalf("asked: %q", fj.asked)
	}
}

// #4426: a forge with no releases says so as forgeNone, with its reason.
func TestForgeWithoutReleasesSaysWhy(t *testing.T) {
	for _, f := range []Forge{bitbucketForge{}, azureDevOpsForge{}, linearForge{}, jiraForge{}, azureBoardsForge{}} {
		_, err := f.Releases(context.Background(), nil, 1)
		if f.Caps().Releases || !errors.Is(err, errForgeCannot) || cannotReason(f, err) == "" || cannotReason(f, err) == "the forge cannot releases" {
			t.Errorf("%s: caps %v, %v %q", f.Name(), f.Caps().Releases, err, cannotReason(f, err))
		}
	}
}
