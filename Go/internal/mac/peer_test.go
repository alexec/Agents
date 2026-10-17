package mac

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fakeHelper writes a helper that begins with first and answers each token by what its
// first byte is, counting the questions it is asked in a file beside it.
func fakeHelper(t *testing.T, first string) (path, asked string) {
	t.Helper()
	dir := t.TempDir()
	asked = filepath.Join(dir, "asked")
	path = filepath.Join(dir, "agents-peer")
	script := "#!/bin/sh\necho '" + first + "'\nwhile read t; do echo x >> '" + asked + "'\n" +
		"case $t in 01*) echo control;; 02*) echo agent;; 03*) echo bogus;; *) echo stranger;; esac\ndone\n"
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return path, asked
}

func questions(t *testing.T, asked string) int {
	b, _ := os.ReadFile(asked)
	return strings.Count(string(b), "x")
}

func TestTokenHex(t *testing.T) {
	tok := Token{1, 501, 20, 501, 20, 1234, 100005, 7}
	h := tok.Hex()
	if len(h) != 64 || !strings.HasPrefix(h, "01000000f5010000") {
		t.Fatalf("hex %s", h)
	}
	if tok.UID() != 501 || tok.PID() != 1234 {
		t.Fatalf("uid %d pid %d", tok.UID(), tok.PID())
	}
}

func TestPeerCheckerAnswersOncePerToken(t *testing.T) {
	path, asked := fakeHelper(t, "team ABCDE12345")
	p := NewPeerChecker(path)
	defer p.Close()
	if team, err := p.Team(); err != nil || team != "ABCDE12345" {
		t.Fatalf("team %q %v", team, err)
	}
	app := Token{1, 501, 0, 0, 0, 10, 0, 1}
	helper := Token{2, 501, 0, 0, 0, 11, 0, 1}
	other := Token{9, 501, 0, 0, 0, 12, 0, 1}
	for i := 0; i < 3; i++ {
		if r, err := p.Role(app); err != nil || r != RoleControl {
			t.Fatalf("app: %q %v", r, err)
		}
	}
	if r, _ := p.Role(helper); r != RoleAgent {
		t.Fatalf("helper: %q", r)
	}
	if r, _ := p.Role(other); r != RoleStranger {
		t.Fatalf("other: %q", r)
	}
	if n := questions(t, asked); n != 3 {
		t.Fatalf("asked %d times, want once per token", n)
	}
}

func TestPeerCheckerRefusesAnAnswerItDoesNotKnow(t *testing.T) {
	path, _ := fakeHelper(t, "team ABCDE12345")
	p := NewPeerChecker(path)
	defer p.Close()
	if r, err := p.Role(Token{3}); err == nil {
		t.Fatalf("an unknown role was taken: %q", r)
	}
}

func TestPeerCheckerUnsigned(t *testing.T) {
	path, _ := fakeHelper(t, "unsigned")
	p := NewPeerChecker(path)
	defer p.Close()
	if _, err := p.Team(); err != ErrUnsigned {
		t.Fatalf("got %v", err)
	}
}

func TestPeerCheckerStartsAgainAfterTheHelperDies(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "agents-peer")
	// Answers one question and leaves.
	os.WriteFile(path, []byte("#!/bin/sh\necho 'team T'\nread t\necho control\n"), 0o755)
	p := NewPeerChecker(path)
	defer p.Close()
	if r, err := p.Role(Token{1}); err != nil || r != RoleControl {
		t.Fatalf("first: %q %v", r, err)
	}
	if _, err := p.Role(Token{2}); err == nil {
		t.Fatal("a helper that had gone answered")
	}
	if r, err := p.Role(Token{3}); err != nil || r != RoleControl {
		t.Fatalf("after a restart: %q %v", r, err)
	}
}

func TestPeerCheckerMissingHelper(t *testing.T) {
	p := NewPeerChecker(filepath.Join(t.TempDir(), "nothing"))
	if _, err := p.Role(Token{1}); err == nil {
		t.Fatal("no helper answered")
	}
}

func TestPeerCheckerCacheIsBounded(t *testing.T) {
	path, _ := fakeHelper(t, "team T")
	p := NewPeerChecker(path)
	defer p.Close()
	for i := 0; i < maxCached+10; i++ {
		p.Role(Token{9, 0, 0, 0, 0, uint32(i)})
	}
	if len(p.cached) > maxCached {
		t.Fatalf("%d cached", len(p.cached))
	}
}
