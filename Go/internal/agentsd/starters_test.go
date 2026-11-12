package agentsd

import (
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// The starters' own checks (their workflows, the icon, asc-key.sh, setup-gcp.sh) are in their
// template repositories' CI (#4561). These test fetching, ignoring and filling, with a
// template repository of their own.

// starterTemplate makes repo (owner/name) as a bare repository with files on its default
// branch, under a folder that stands in for GitHub for the rest of the test.
func starterTemplate(t *testing.T, repo string, files map[string]string) {
	t.Helper()
	base := t.TempDir()
	work := t.TempDir()
	for p, s := range files {
		full := filepath.Join(work, filepath.FromSlash(p))
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(s), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	bare := filepath.Join(base, filepath.FromSlash(repo)+".git")
	for _, args := range [][]string{
		{"-C", work, "init", "-q", "--initial-branch=main"},
		{"-C", work, "add", "-A"},
		{"-C", work, "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "template"},
		{"init", "-q", "--bare", "--initial-branch=main", bare},
		{"-C", work, "push", "-q", bare, "main"},
	} {
		if out, err := exec.Command("git", args...).CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v %s", args, err, out)
		}
	}
	old := starterGitBase
	starterGitBase = "file://" + base
	t.Cleanup(func() { starterGitBase = old })
}

// A small web-service-like template: its own README and CI under .starterignore, a binary
// file that is not filled.
var webTemplate = map[string]string{
	".starterignore":                 "# the template's own\n.github/README.md\n.github/template/\n.github/workflows/template.yml\n",
	".github/README.md":              "A template; __UNFILLED__ is a placeholder.\n",
	".github/template/fill.py":       "SAMPLE = {'__ALSO_UNFILLED__': 1}\n",
	".github/workflows/template.yml": "name: template # __ALSO_UNFILLED__\n",
	".github/workflows/deploy.yml":   "env:\n  SERVICE: __SERVICE__\n  PROJECT: __GCP_PROJECT__\n  REGION: __GCP_REGION__\n",
	"README.md":                      "# __APP_NAME__\n",
	"setup-gcp.sh":                   "#!/usr/bin/env bash\nrepo=__GITHUB_REPO__\n",
	"icon.bin":                       "\x00__APP_NAME__\x00",
}

func TestStarterRepo(t *testing.T) {
	for in, want := range map[string]string{
		"iphone-app": "alexec/iphone-app-starter", "web-service": "alexec/web-service-starter",
		"someone/my-starter": "someone/my-starter",
	} {
		if got, ok := starterRepo(in); !ok || got != want {
			t.Errorf("starterRepo(%q) = %q %v, want %q", in, got, ok, want)
		}
	}
	for _, bad := range []string{"", "android-app", "../x", "a/b/c", "a/../b", "../..", "a/.."} {
		if _, ok := starterRepo(bad); ok {
			t.Errorf("starterRepo(%q) took it", bad)
		}
	}
}

func TestFetchStarterLeavesOutTheTemplatesOwnFiles(t *testing.T) {
	starterTemplate(t, "someone/web-starter", webTemplate)
	files, err := fetchStarter("someone/web-starter", "")
	if err != nil {
		t.Fatal(err)
	}
	var paths []string
	for p := range files {
		paths = append(paths, p)
	}
	want := []string{".github/workflows/deploy.yml", "README.md", "icon.bin", "setup-gcp.sh"}
	if !sameSet(paths, want) {
		t.Fatalf("paths = %v, want %v", paths, want)
	}
	if got, want := starterPlaceholders(files), []string{"APP_NAME", "GCP_PROJECT", "GCP_REGION", "GITHUB_REPO", "SERVICE"}; !reflect.DeepEqual(got, want) {
		t.Errorf("placeholders = %v, want %v", got, want)
	}

	if _, err := fetchStarter("someone/no-such-starter", ""); err == nil || !strings.Contains(err.Error(), "could not fetch the starter someone/no-such-starter") {
		t.Errorf("a missing template: %v", err)
	}
}

func TestFillStarterFillsEveryPlaceholder(t *testing.T) {
	starterTemplate(t, "someone/web-starter", webTemplate)
	files, err := fetchStarter("someone/web-starter", "")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := fillStarter(files, map[string]string{"APP_NAME": "Tide Log"}); err == nil || !strings.Contains(err.Error(), "GCP_PROJECT") {
		t.Fatalf("missing values: %v", err)
	}
	filled, err := fillStarter(files, map[string]string{"APP_NAME": "Tide Log", "SERVICE": "tidelog", "GCP_PROJECT": "tidelog-1",
		"GCP_REGION": "us-central1", "GITHUB_REPO": "someone/tidelog"})
	if err != nil {
		t.Fatal(err)
	}
	for p, b := range filled {
		if m := starterPlaceholder.Find(b); m != nil && starterText(b) {
			t.Errorf("%s still says %s", p, m)
		}
	}
	if got := string(filled["setup-gcp.sh"]); !strings.Contains(got, "repo=someone/tidelog\n") {
		t.Errorf("setup-gcp.sh = %q", got)
	}
	if got := string(filled["icon.bin"]); got != webTemplate["icon.bin"] {
		t.Errorf("a binary file was filled: %q", got)
	}
	if string(files["README.md"]) != "# __APP_NAME__\n" {
		t.Error("fillStarter changed the files it was given")
	}
}

func TestWithoutStarterIgnoredWithNoIgnoreFile(t *testing.T) {
	files := map[string][]byte{"a": nil, ".github/README.md": nil}
	if got := withoutStarterIgnored(files); len(got) != 2 {
		t.Errorf("got %v", got)
	}
}

func sameSet(a, b []string) bool {
	m := map[string]int{}
	for _, s := range a {
		m[s]++
	}
	for _, s := range b {
		m[s]--
	}
	for _, n := range m {
		if n != 0 {
			return false
		}
	}
	return len(a) == len(b)
}
