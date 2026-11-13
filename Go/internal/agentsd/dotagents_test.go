package agentsd

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

// readyMadeFixtureDir is a copy of agentloops-dev/dotagents at the pinned tag (#5091), in its
// layout: scripts/dotagents.sh pin writes it with the pin, and check says when it differs.
const readyMadeFixtureDir = "testdata/dotagents"

// readyMadeFixtureCommit is the commit the fixture says it is, and the tests' pin.
const readyMadeFixtureCommit = "0000000000000000000000000000000000f1x7"

var readyMadeFixtureSet *readyMadeSet

// readyMadeFixture is the fixture, read once.
func readyMadeFixture() *readyMadeSet {
	if readyMadeFixtureSet == nil {
		set, err := readReadyMadeDir(readyMadeFixtureDir)
		if err != nil {
			panic(err)
		}
		set.Tag, set.Commit = readyMadeTag, readyMadeFixtureCommit
		readyMadeFixtureSet = set
	}
	return readyMadeFixtureSet
}

// useReadyMadeFixture makes every test's daemon fetch the fixture, at once, with no network.
func useReadyMadeFixture() {
	readyMadeCommit = readyMadeFixtureCommit
	readyMadeFetchInline = true
	readyMadeFetch = func(repo, tag, commit string) (*readyMadeSet, error) { return readyMadeFixture(), nil }
}

func readyMadeIDs() []string                   { return readyMadeFixture().ids() }
func readyMadeSkillIDs() []string              { return readyMadeFixture().skillIDs() }
func readyMadeText(id string) (string, string) { return readyMadeFixture().text(id) }

// dotagentsGit runs git in dir for a test, with no global config.
func dotagentsGit(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null",
		"GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@example.com", "GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@example.com")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v: %s", args, err, out)
	}
	return strings.TrimSpace(string(out))
}

// dotagentsRepo is a bare repository of the fixture under base, as owner/name, tagged tag, and
// the tag's commit.
func dotagentsRepo(t *testing.T, base, repo, tag string) string {
	t.Helper()
	work := t.TempDir()
	if err := os.CopyFS(work, os.DirFS(readyMadeFixtureDir)); err != nil {
		t.Fatal(err)
	}
	dotagentsGit(t, work, "init", "-q", "-b", "main")
	dotagentsGit(t, work, "add", "-A")
	dotagentsGit(t, work, "commit", "-q", "-m", "ready-made")
	dotagentsGit(t, work, "tag", tag)
	bare := filepath.Join(base, repo+".git")
	if err := os.MkdirAll(filepath.Dir(bare), 0o755); err != nil {
		t.Fatal(err)
	}
	dotagentsGit(t, base, "clone", "-q", "--bare", work, bare)
	return dotagentsGit(t, work, "rev-parse", "HEAD")
}

// #5091: the ready-made workflows come from a tag of a repository, a shallow clone, and a
// commit other than the pinned one is refused, so a moved tag installs nothing.
func TestReadyMadeWorkflowsComeFromThePinnedTag(t *testing.T) {
	base := t.TempDir()
	commit := dotagentsRepo(t, base, "o/dotagents", "v9")
	old := readyMadeGitBase
	readyMadeGitBase = "file://" + base
	defer func() { readyMadeGitBase = old }()

	set, err := fetchReadyMadeFromGit("o/dotagents", "v9", commit)
	if err != nil {
		t.Fatal(err)
	}
	if set.Tag != "v9" || set.Commit != commit || !slices.Equal(set.ids(), readyMadeIDs()) || !slices.Equal(set.skillIDs(), []string{"map-a-docs-server", "start-a-new-app"}) {
		t.Fatalf("%+v", set)
	}
	if w, s := set.text("work-an-issue"); w == "" || !strings.Contains(s, "\nname: work-an-issue\n") {
		t.Fatalf("work-an-issue: %q", s)
	}
	if _, err := fetchReadyMadeFromGit("o/dotagents", "v9", strings.Repeat("a", 40)); err == nil || !strings.Contains(err.Error(), "not the pinned") {
		t.Fatalf("another commit: %v", err)
	}
	if _, err := fetchReadyMadeFromGit("o/dotagents", "v10", ""); err == nil {
		t.Fatal("a tag that is not there was fetched")
	}
}

// With no network and no copy yet, a daemon installs nothing, and tries again later; once a
// fetch works, it installs the copy, keeps it, and approves only the pinned text.
func TestReadyMadeWorkflowsWaitForAFetch(t *testing.T) {
	oldFetch, oldInline := readyMadeFetch, readyMadeFetchInline
	defer func() { readyMadeFetch, readyMadeFetchInline = oldFetch, oldInline }()
	offline := true
	tries := 0
	readyMadeFetch = func(repo, tag, commit string) (*readyMadeSet, error) {
		tries++
		if offline {
			return nil, errors.New("no network")
		}
		return readyMadeFixture(), nil
	}
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	home := t.TempDir()
	d.PersonalHome = home
	c.call(t, 1, "workflows/list", map[string]any{"scope": "user"})
	c.call(t, 2, "workflows/list", map[string]any{"scope": "user"})
	if ids := workflowIDs(home); len(ids) != 0 || tries != 1 {
		t.Fatalf("offline: %v, %d tries", ids, tries)
	}
	if _, err := os.Stat(readyMadeCopyPath(home)); err == nil {
		t.Fatal("a copy was kept with no fetch")
	}
	// Ten minutes on, the network is back.
	offline = false
	d.readyMadeMu.Lock()
	d.readyMadeFailed = time.Now().Add(-readyMadeRetry)
	d.readyMadeMu.Unlock()
	c.call(t, 3, "workflows/list", map[string]any{"scope": "user"})
	if ids := workflowIDs(home); len(ids) != len(readyMadeIDs()) || tries != 2 {
		t.Fatalf("online: %v, %d tries", ids, tries)
	}
	if set := loadReadyMade(home); !set.pinned() || !slices.Equal(set.ids(), readyMadeIDs()) {
		t.Fatalf("the copy kept: %+v", set)
	}
	// The copy is the pin: no more fetches.
	c.call(t, 4, "workflows/list", map[string]any{"scope": "user"})
	if tries != 2 {
		t.Fatalf("%d tries", tries)
	}
	if s, err := d.oneWorkflow(home, "work-an-issue"); err != nil || s.AwaitingApproval != nil {
		t.Fatalf("the pinned text is not approved: %+v, %v", s, err)
	}
}

// A copy that is not the pin (fetched while the release had no commit to check) is installed,
// but its text waits for the person: only the release's own commit is approved.
func TestAnUnpinnedCopyWaitsForApproval(t *testing.T) {
	oldFetch, oldCommit := readyMadeFetch, readyMadeCommit
	defer func() { readyMadeFetch, readyMadeCommit = oldFetch, oldCommit }()
	readyMadeCommit = ""
	offline := true
	readyMadeFetch = func(repo, tag, commit string) (*readyMadeSet, error) {
		if offline {
			return nil, errors.New("no network")
		}
		set := *readyMadeFixture()
		set.Commit = "1111111111111111111111111111111111111111"
		return &set, nil
	}
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	home := t.TempDir()
	d.PersonalHome = home
	// The first scan of a person's folder approves every file as it stands: here, none.
	c.call(t, 1, "workflows/list", map[string]any{"scope": "user"})
	offline = false
	d.readyMadeMu.Lock()
	d.readyMadeFailed = time.Time{}
	d.readyMadeMu.Unlock()
	c.call(t, 2, "workflows/list", map[string]any{"scope": "user"})
	if ids := workflowIDs(home); len(ids) != len(readyMadeIDs()) {
		t.Fatalf("not installed: %v", ids)
	}
	if s, err := d.oneWorkflow(home, "work-an-issue"); err != nil || s.AwaitingApproval == nil {
		t.Fatalf("an unpinned copy was approved: %+v, %v", s, err)
	}
}
