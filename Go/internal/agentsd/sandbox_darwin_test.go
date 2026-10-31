package agentsd

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// The command sandbox on a Mac (#1138, slice I). The Swift host writes no sandbox-exec
// profile of its own: 064 switches each runtime's own sandbox (sandbox.go), and on a Mac
// that sandbox is Seatbelt, which does not nest. So the Go host writes none either. These
// say why, on the Mac CI runs on: Seatbelt confines a process, and a runtime's own
// sandbox-exec inside a host's fails with the words sandboxfailure.go knows.

func underSeatbelt(t *testing.T, profile string, argv ...string) (string, error) {
	t.Helper()
	out, err := exec.Command("/usr/bin/sandbox-exec", append([]string{"-p", profile}, argv...)...).CombinedOutput()
	return string(out), err
}

func writesOnlyUnder(dir string) string {
	return `(version 1)(allow default)(deny file-write*)(allow file-write* (subpath "` + dir + `") (literal "/dev/null"))`
}

func TestSeatbeltConfinesWrites(t *testing.T) {
	dir, _ := filepath.EvalSymlinks(t.TempDir())
	in, out := filepath.Join(dir, "in"), filepath.Join(dir, "out")
	os.Mkdir(in, 0o755)
	os.Mkdir(out, 0o755)
	said, err := underSeatbelt(t, writesOnlyUnder(in), "/bin/sh", "-c", `echo a > "$0/x" && { echo b > "$1/y" || echo refused; }`, in, out)
	if err != nil && strings.Contains(said, "sandbox_apply") {
		t.Skipf("this Mac runs the tests inside a sandbox already: %s", said)
	}
	if _, err := os.Stat(filepath.Join(in, "x")); err != nil || !strings.Contains(said, "refused") {
		t.Fatalf("%v: %s", err, said)
	}
	if _, err := os.Stat(filepath.Join(out, "y")); err == nil {
		t.Fatal("a write outside the profile was let through")
	}
}

func TestARuntimesOwnSeatbeltCannotNest(t *testing.T) {
	dir, _ := filepath.EvalSymlinks(t.TempDir())
	said, err := underSeatbelt(t, writesOnlyUnder(dir), "/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)", "/usr/bin/true")
	if err == nil {
		t.Fatal("a sandbox-exec nested in another started: a host profile would not break the runtimes' own")
	}
	for _, runtime := range []string{"claude", "codex"} {
		if sandboxMatch(runtime, said) == "" {
			t.Errorf("%s's failure is not recognised: %q", runtime, said)
		}
	}
}
