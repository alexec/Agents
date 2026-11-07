package agentsd

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/githubmcp"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

func (f *fakeForgeGitHub) MakeRepository(_ context.Context, owner, name, _ string) (githubmcp.Repository, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if owner == "" {
		owner = "alexec"
	}
	full := owner + "/" + name
	made := !slices.Contains(f.made, full)
	if made {
		f.made = append(f.made, full)
	}
	return githubmcp.Repository{FullName: full, CloneURL: f.bare, Login: "alexec", UserID: 1142830}, made, nil
}

// #3708: make_app_repository makes the repository, pushes the starter with its values as the
// first commit on main, clones it and adds it as a folder; called again, it skips each step;
// and it refuses a starter's missing values before it asks GitHub for anything.
func TestMakeAppRepositoryPushesTheStarterAndAddsTheFolder(t *testing.T) {
	d, _, gh, _ := forgeDaemon(t)
	parent := t.TempDir()
	t.Setenv("AGENTS_CLONE_PARENT", parent)
	bare := filepath.Join(t.TempDir(), "tide-log.git")
	if out, err := exec.Command("git", "init", "-q", "--bare", "--initial-branch=trunk", bare).CombinedOutput(); err != nil {
		t.Fatalf("%v %s", err, out)
	}
	gh.bare = "file://" + bare
	a := seeded(t, d, gitFolder(t, "git@github.com:alexec/agents.git"), func(a *wire.Agent) { a.State, a.EndedReason = wire.AgentStateRunning, nil })
	if !appToolServed("make_app_repository") {
		t.Fatal("make_app_repository is not served")
	}

	if _, err := d.makeAppRepository(a.ID, ciArgs("name", "tide-log", "starter", "web-service", "values", map[string]string{"APP_NAME": "Tide Log"})); err == nil ||
		!strings.Contains(err.Error(), "GCP_PROJECT") || strings.Contains(err.Error(), "GITHUB_REPO") || len(gh.made) != 0 {
		t.Fatalf("missing values: %v, made %v", err, gh.made)
	}
	if _, err := d.makeAppRepository(a.ID, ciArgs("name", "../x", "starter", "web-service")); err == nil {
		t.Fatal("../x was taken as a name")
	}

	values := map[string]string{"APP_NAME": "Tide Log", "SERVICE": "tidelog", "GCP_PROJECT": "tidelog-1", "GCP_REGION": "us-central1"}
	got, err := d.makeAppRepository(a.ID, ciArgs("name", "tide-log", "starter", "web-service", "values", values))
	if err != nil || !strings.Contains(got, "Made alexec/tide-log on GitHub, private") || !strings.Contains(got, "pushed the web-service starter") ||
		!strings.Contains(got, "added it as a folder") || strings.Contains(got, "ghu_secret") {
		t.Fatalf("%q %v", got, err)
	}
	dest := filepath.Join(parent, "tide-log")
	if log, err := exec.Command("git", "-C", bare, "log", "--format=%an <%ae> %s", "main").CombinedOutput(); err != nil ||
		strings.TrimSpace(string(log)) != "alexec <1142830+alexec@users.noreply.github.com> The starter" {
		t.Fatalf("pushed: %s %v", log, err)
	}
	deploy, _ := os.ReadFile(filepath.Join(dest, ".github/workflows/deploy.yml"))
	if !strings.Contains(string(deploy), "tidelog") || strings.Contains(string(deploy), "__") {
		t.Errorf("deploy.yml is not filled:\n%s", deploy)
	}
	if fi, err := os.Stat(filepath.Join(dest, "setup-gcp.sh")); err != nil || fi.Mode()&0o100 == 0 {
		t.Errorf("setup-gcp.sh cannot be run: %v", err)
	}
	if cfg, _ := os.ReadFile(filepath.Join(dest, ".git/config")); strings.Contains(string(cfg), "extraheader") {
		t.Errorf("the token's header is in the clone's config:\n%s", cfg)
	}
	if !slices.ContainsFunc(d.Store.Folders(), func(f wire.Folder) bool { return store.FolderPath(f.Folder) == canonical(dest) }) {
		t.Fatalf("%s is not a folder", dest)
	}

	again, err := d.makeAppRepository(a.ID, ciArgs("name", "tide-log", "starter", "web-service", "values", values))
	if err != nil || !strings.Contains(again, "was on GitHub already") || !strings.Contains(again, "was cloned already") {
		t.Fatalf("again: %q %v", again, err)
	}
	if n, _ := exec.Command("git", "-C", bare, "rev-list", "--count", "main").Output(); strings.TrimSpace(string(n)) != "1" {
		t.Errorf("again pushed: %s commits", n)
	}

	// The folder gone but the repository there: it is cloned again, with what is in it.
	os.RemoveAll(dest)
	kept, err := d.makeAppRepository(a.ID, ciArgs("name", "tide-log", "starter", "web-service", "values", values))
	if err != nil || !strings.Contains(kept, "kept what was in it") {
		t.Fatalf("kept: %q %v", kept, err)
	}
}
