package forgejomcp

import (
	"context"
	"errors"
	"os/exec"
	"testing"
)

// The set-up's reads (#3752): the newest issue and pull request, and the default branch's
// combined status; nil when there is none, and a refusal is Refused.
func TestTheSetUpReads(t *testing.T) {
	f := newFake(t)
	fj := f.forgejo(nil)
	ctx := context.Background()
	for name, read := range map[string]func(context.Context, string) (*Newest, error){"issue": fj.NewestIssue, "pull": fj.NewestPull, "checks": fj.LastChecks} {
		if n, err := read(ctx, repo); n != nil || err != nil {
			t.Fatalf("%s of an empty repository: %+v %v", name, n, err)
		}
	}
	f.set(func() {
		f.issues = []obj{issue(9, alex, nil)}
		f.pulls = []obj{pull(8, "fix", dev, nil)}
		f.statuses["main"] = obj{"state": "failure", "sha": "abc", "statuses": []obj{
			{"id": 1, "context": "ci/build", "status": "success", "target_url": "https://ci.test/1", "updated_at": at(1)},
			{"id": 2, "context": "ci/test", "status": "failure", "target_url": "https://ci.test/2", "updated_at": at(2)},
		}}
	})
	if n, err := fj.NewestIssue(ctx, repo); err != nil || n.Number != 9 || n.Title != "Issue 9" || n.URL == "" {
		t.Fatalf("issue: %+v %v", n, err)
	}
	if n, err := fj.NewestPull(ctx, repo); err != nil || n.Number != 8 || n.Title != "PR 8" {
		t.Fatalf("pull: %+v %v", n, err)
	}
	if n, err := fj.LastChecks(ctx, repo); err != nil || n.Title != "Checks on main" || n.Outcome != "failed" || n.URL != "https://ci.test/2" {
		t.Fatalf("checks: %+v %v", n, err)
	}
	f.set(func() { f.status = 403 })
	var fe *ForgejoError
	if _, err := fj.NewestIssue(ctx, repo); !errors.As(err, &fe) || !fe.Refused {
		t.Fatalf("a refusal: %v", err)
	}
}

// RepoAt (#3752): a remote on one of the roots, origin first, else a host named forgejo,
// gitea or codeberg; no other host.
func TestRepoAt(t *testing.T) {
	folder := func(remotes ...string) string {
		dir := t.TempDir()
		cmds := [][]string{{"init", "-q"}}
		for i, r := range remotes {
			name := "origin"
			if i > 0 {
				name = "other" + string(rune('a'+i))
			}
			cmds = append(cmds, []string{"remote", "add", name, r})
		}
		for _, args := range cmds {
			if out, err := exec.Command("git", append([]string{"-C", dir}, args...)...).CombinedOutput(); err != nil {
				t.Fatalf("git %v: %v %s", args, err, out)
			}
		}
		return dir
	}
	ctx := context.Background()
	for _, c := range []struct {
		dir, root, repo string
		roots           []string
	}{
		{folder("git@codeberg.org:alex/app.git"), DefaultBase, "alex/app", []string{DefaultBase}},
		{folder("https://git.example.com/team/app"), "https://git.example.com/", "team/app", []string{"https://git.example.com/", DefaultBase}},
		{folder("ssh://git@try.gitea.io:2222/team/app.git"), "https://try.gitea.io/", "team/app", []string{DefaultBase}},
		{folder("https://forgejo.example.net/a/b.git"), "https://forgejo.example.net/", "a/b", nil},
	} {
		if root, r, ok := RepoAt(ctx, c.dir, c.roots); !ok || root != c.root || r != c.repo {
			t.Errorf("%v: %q %q %v", c.roots, root, r, ok)
		}
	}
	if _, _, ok := RepoAt(ctx, folder("https://git.example.com/team/app"), []string{DefaultBase}); ok {
		t.Error("an unknown host named a Forgejo")
	}
	if _, _, ok := RepoAt(ctx, folder("git@github.com:alex/app.git"), []string{DefaultBase}); ok {
		t.Error("GitHub named a Forgejo")
	}
}
