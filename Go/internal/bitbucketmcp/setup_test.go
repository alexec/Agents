package bitbucketmcp

import (
	"context"
	"errors"
	"os/exec"
	"testing"
)

// The set-up's reads (#3785): the newest issue and pull request, and the main branch's
// statuses as one; nil when there is none, a refusal is Refused, and a tracker that is off
// says so.
func TestTheSetUpReads(t *testing.T) {
	f := newFake(t)
	bb := f.bitbucket()
	ctx := context.Background()
	for name, read := range map[string]func(context.Context, string) (*Newest, error){"issue": bb.NewestIssue, "pull": bb.NewestPull, "checks": bb.LastChecks} {
		if n, err := read(ctx, repo); n != nil || err != nil {
			t.Fatalf("%s of an empty repository: %+v %v", name, n, err)
		}
	}
	f.set(func() {
		f.issues = []obj{issue(9, alex, nil)}
		f.pulls = []obj{pull(8, "fix", dev, obj{"state": "MERGED"})}
		f.branches["main"] = "abc"
		f.statuses["abc"] = []obj{
			{"key": "build", "state": "SUCCESSFUL", "url": "https://ci.test/1", "updated_on": at(1)},
			{"key": "test", "state": "FAILED", "url": "https://ci.test/2", "updated_on": at(2)},
		}
	})
	if n, err := bb.NewestIssue(ctx, repo); err != nil || n.Number != 9 || n.Title != "Issue 9" || n.URL == "" {
		t.Fatalf("issue: %+v %v", n, err)
	}
	if n, err := bb.NewestPull(ctx, repo); err != nil || n.Number != 8 || n.Title != "PR 8" {
		t.Fatalf("pull: %+v %v", n, err)
	}
	if n, err := bb.LastChecks(ctx, repo); err != nil || n.Title != "Checks on main" || n.Outcome != "failed" || n.URL != "https://ci.test/2" {
		t.Fatalf("checks: %+v %v", n, err)
	}
	f.set(func() { f.noTracker = true })
	var off *NoTrackerError
	if _, err := bb.NewestIssue(ctx, repo); !errors.As(err, &off) || off.Repo != repo {
		t.Fatalf("a tracker that is off: %v", err)
	}
	f.set(func() { f.noTracker, f.status = false, 403 })
	var be *BitbucketError
	if _, err := bb.NewestIssue(ctx, repo); !errors.As(err, &be) || !be.Refused {
		t.Fatalf("a refusal: %v", err)
	}
}

// RepoAt (#3785): a bitbucket.org remote, origin first; no other host.
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
	for dir, want := range map[string]string{
		folder("git@bitbucket.org:acme/app.git"):                                "acme/app",
		folder("https://alex@bitbucket.org/acme/web"):                           "acme/web",
		folder("https://github.com/acme/app", "ssh://git@bitbucket.org/acme/b"): "acme/b",
	} {
		if got, ok := RepoAt(ctx, dir); !ok || got != want {
			t.Errorf("%s: %q %v, want %q", dir, got, ok, want)
		}
	}
	if _, ok := RepoAt(ctx, folder("https://bitbucket.example.com/scm/acme/app.git")); ok {
		t.Error("a Bitbucket Data Center named a Bitbucket Cloud repository")
	}
}
