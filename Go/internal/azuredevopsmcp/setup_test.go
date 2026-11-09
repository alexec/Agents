package azuredevopsmcp

import (
	"context"
	"net/http"
	"os/exec"
	"testing"
)

// The set-up's reads (#3802): the newest pull request and the newest build, nil when there is
// none, and a refusal is Refused.
func TestTheSetUpReads(t *testing.T) {
	f := newFake(t)
	ado := f.azureDevOps()
	ctx := context.Background()
	for name, read := range map[string]func(context.Context, string) (*Newest, error){"pull": ado.NewestPull, "checks": ado.LastChecks} {
		if n, err := read(ctx, repo); n != nil || err != nil {
			t.Fatalf("%s of an empty repository: %+v %v", name, n, err)
		}
	}
	f.set(func() {
		f.pulls = []obj{pull(8, "fix", dev, obj{"status": "completed"})}
		f.builds = []obj{build(30, 8, "sha8", "CI", "succeeded", 1), build(31, 8, "sha8", "CI", "failed", 2)}
	})
	if n, err := ado.NewestPull(ctx, repo); err != nil || n.Number != 8 || n.Title != "PR 8" || n.URL != f.server.URL+web+"/pullrequest/8" {
		t.Fatalf("pull: %+v %v", n, err)
	}
	if n, err := ado.LastChecks(ctx, repo); err != nil || n.Number != 31 || n.Title != "CI 2026.11.31" || n.Outcome != "failed" || n.URL == "" {
		t.Fatalf("checks: %+v %v", n, err)
	}
	f.set(func() { f.builds = append(f.builds, obj{"id": 32, "buildNumber": "2026.11.32", "status": "inProgress", "queueTime": at(3),
		"definition": obj{"name": "CI"}, "repository": obj{"id": "repo-guid"}}) })
	if n, err := ado.LastChecks(ctx, repo); err != nil || n.Outcome != "running" || n.At != at(3) ||
		n.URL != f.server.URL+"/acme/Web%20App/_build/results?buildId=32" {
		t.Fatalf("a running build: %+v %v", n, err)
	}
	f.set(func() { f.status = http.StatusForbidden })
	if _, err := ado.NewestPull(ctx, repo); !Refused(err) {
		t.Fatalf("a refusal: %v", err)
	}
}

// RepoAt (#3802): the remote of the Azure DevOps at base, origin first; no other host.
func TestRepoAt(t *testing.T) {
	folder := func(remotes ...string) string {
		dir := t.TempDir()
		cmds := [][]string{{"init", "-q"}}
		for i, r := range remotes {
			name := "origin"
			if i > 0 {
				name = "other"
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
	if got, ok := RepoAt(ctx, folder("git@ssh.dev.azure.com:v3/acme/Web/app", "https://github.com/a/b"), DefaultBase); !ok || got != "acme/Web/app" {
		t.Fatalf("dev.azure.com: %q %v", got, ok)
	}
	if got, ok := RepoAt(ctx, folder("https://github.com/a/b", "https://tfs.acme.test/tfs/Main/Web/_git/app"), "https://tfs.acme.test/tfs/"); !ok || got != "Main/Web/app" {
		t.Fatalf("a server, not origin: %q %v", got, ok)
	}
	if _, ok := RepoAt(ctx, folder("https://github.com/a/b"), DefaultBase); ok {
		t.Fatal("GitHub is not Azure DevOps")
	}
}
