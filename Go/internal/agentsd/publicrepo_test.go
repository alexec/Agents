package agentsd

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/agentloops-dev/agents/Go/wire"
)

// publicCard waits for make_public_repository's card and answers it with answer.
func publicCard(t *testing.T, c *conn, id int, answer string) wire.ElicitationRequest {
	t.Helper()
	var pending []wire.ElicitationRequest
	waitFor(t, "the card", func() bool {
		json.Unmarshal(c.call(t, id, "elicitations/pending", nil), &pending)
		return len(pending) == 1
	})
	c.call(t, id+1, "elicitations/answer", map[string]any{"requestID": pending[0].ID, "action": "accept", "content": map[string]any{"go": answer}})
	return pending[0]
}

// #4921: make_public_repository makes and pushes nothing until the person says yes on its
// card, which names the repository, the folder and its files; a yes pushes the files the card
// counted, with .git left out and a script still one that runs, and keeps no clone; a
// private repository there already is left as it is; and keys, links and the home folder are
// refused before anyone is asked.
func TestMakePublicRepositoryWaitsForThePersonsYes(t *testing.T) {
	d, c, gh, _ := forgeDaemon(t)
	bare := filepath.Join(t.TempDir(), "starter.git")
	if out, err := exec.Command("git", "init", "-q", "--bare", "--initial-branch=trunk", bare).CombinedOutput(); err != nil {
		t.Fatalf("%v %s", err, out)
	}
	gh.bare = "file://" + bare
	title := "starters"
	a := seeded(t, d, gitFolder(t, "git@github.com:alexec/agents.git"), func(a *wire.Agent) {
		a.State, a.EndedReason, a.RuntimeID, a.Title = wire.AgentStateRunning, nil, "claude", &title
	})
	if !appToolServed("make_public_repository") {
		t.Fatal("make_public_repository is not served")
	}
	l := d.live(a.ID)
	l.mu.Lock()
	l.inTurn = true
	l.mu.Unlock()

	src := t.TempDir()
	os.MkdirAll(filepath.Join(src, ".github", "workflows"), 0o755)
	os.MkdirAll(filepath.Join(src, ".git"), 0o755)
	os.WriteFile(filepath.Join(src, "README.md"), []byte("# A starter\n"), 0o644)
	os.WriteFile(filepath.Join(src, "setup.sh"), []byte("#!/bin/sh\n"), 0o755)
	os.WriteFile(filepath.Join(src, ".github", "workflows", "ci.yml"), []byte("on: push\n"), 0o644)
	os.WriteFile(filepath.Join(src, ".git", "config"), []byte("[core]\n"), 0o644)
	args := ciArgs("name", "app-starter", "folder", src, "template", true, "about", "A starter")

	// A no makes nothing.
	said := make(chan string, 1)
	go func() { text, _ := d.makePublicRepository(a.ID, args); said <- text }()
	card := publicCard(t, c, 1, "no")
	if *card.Message != "Claude (starters) wants to make a public repository" {
		t.Fatalf("title %q", *card.Message)
	}
	q := *card.Mode.Form.Value.Properties[0].Title
	if !strings.Contains(q, "a public template repository, app-starter on your GitHub account, with the 3 files in") ||
		!strings.Contains(q, "(.github/, README.md, setup.sh)") || strings.Contains(q, ".git/") || !strings.Contains(q, "Anyone can see it") {
		t.Fatalf("question %q", q)
	}
	if text := <-said; !strings.HasPrefix(text, "Nothing was made or pushed: the person said no") || len(gh.public) != 0 {
		t.Fatalf("no: %q, asked GitHub %v", text, gh.public)
	}

	// A yes pushes the files read before the card, not one added while it was open.
	go func() { text, _ := d.makePublicRepository(a.ID, args); said <- text }()
	var pending []wire.ElicitationRequest
	waitFor(t, "the second card", func() bool {
		json.Unmarshal(c.call(t, 3, "elicitations/pending", nil), &pending)
		return len(pending) == 1
	})
	os.WriteFile(filepath.Join(src, "late.txt"), []byte("not on the card\n"), 0o644)
	c.call(t, 4, "elicitations/answer", map[string]any{"requestID": pending[0].ID, "action": "accept", "content": map[string]any{"go": "yes"}})
	text := <-said
	if !strings.Contains(text, "Made alexec/app-starter on GitHub, public, a template repository") || !strings.Contains(text, "pushed the 3 files") ||
		!strings.Contains(text, "https://github.com/alexec/app-starter") || len(gh.public) != 1 || gh.public[0] != "alexec/app-starter template=true" {
		t.Fatalf("yes: %q, %v", text, gh.public)
	}
	files, _ := exec.Command("git", "-C", bare, "ls-tree", "-r", "--format=%(objectmode) %(path)", "main").Output()
	if got := strings.TrimSpace(string(files)); got != "100644 .github/workflows/ci.yml\n100644 README.md\n100755 setup.sh" {
		t.Fatalf("pushed:\n%s", got)
	}
	if log, _ := exec.Command("git", "-C", bare, "log", "--format=%an <%ae> %s", "main").Output(); strings.TrimSpace(string(log)) !=
		"alexec <1142830+alexec@users.noreply.github.com> The first commit" {
		t.Fatalf("commit: %s", log)
	}
	if left, _ := os.ReadDir(filepath.Join(d.Store.Loc.Root, "Clones")); len(left) != 0 {
		t.Fatalf("a clone was kept: %v", left)
	}

	// Again, with a yes: the repository has its commit, so nothing more is pushed.
	go func() {
		text, _ := d.makePublicRepository(a.ID, ciArgs("name", "app-starter", "folder", src))
		said <- text
	}()
	publicCard(t, c, 5, "yes")
	if text := <-said; !strings.Contains(text, "was on GitHub already, public") || !strings.Contains(text, "pushed nothing") {
		t.Fatalf("again: %q", text)
	}

	// A private one there already is not made public, nor pushed to.
	gh.private = []string{"alexec/hidden"}
	go func() {
		_, err := d.makePublicRepository(a.ID, ciArgs("name", "hidden", "folder", src))
		if err != nil {
			said <- err.Error()
		} else {
			said <- ""
		}
	}()
	publicCard(t, c, 7, "yes")
	if text := <-said; !strings.Contains(text, "alexec/hidden is on GitHub already, and private") {
		t.Fatalf("private: %q", text)
	}

	// Refused before the card: no folder, the home folder, keys, a link.
	home := t.TempDir()
	t.Setenv("HOME", home)
	os.MkdirAll(filepath.Join(home, ".ssh"), 0o700)
	linked := t.TempDir()
	os.Symlink(filepath.Join(home, ".ssh"), filepath.Join(linked, "keys"))
	for folder, want := range map[string]string{
		"":                            "folder is the folder",
		"relative/path":               "folder is the folder",
		home:                          "is the home folder or above it",
		filepath.Dir(home):            "is the home folder or above it",
		filepath.Join(home, ".ssh"):   "holds keys or secrets",
		"~/.ssh":                      "holds keys or secrets",
		linked:                        "keys is a link or a special file",
		filepath.Join(src, "missing"): "is not a folder",
	} {
		if _, err := d.makePublicRepository(a.ID, ciArgs("name", "x", "folder", folder)); err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("%q: %v, want %q", folder, err, want)
		}
	}
	if _, err := d.makePublicRepository(a.ID, ciArgs("name", "../x", "folder", src)); err == nil {
		t.Error("../x was taken as a name")
	}
	if len(gh.public) != 3 {
		t.Errorf("GitHub was asked %v", gh.public)
	}
}
