package browser

import (
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"syscall"
	"testing"
)

func TestChromePaths(t *testing.T) {
	if got, want := chromePaths("linux", "/home/a"), []string{"/usr/bin/google-chrome-stable", "/usr/bin/google-chrome", "/opt/google/chrome/chrome"}; !reflect.DeepEqual(got, want) {
		t.Errorf("linux: %v", got)
	}
	if got, want := chromePaths("darwin", "/Users/a"), []string{"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "/Users/a/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"}; !reflect.DeepEqual(got, want) {
		t.Errorf("darwin: %v", got)
	}
	if got := chromePaths("windows", "C:/"); got != nil {
		t.Errorf("windows: %v", got)
	}
}

// fakeXvfb is a program named Xvfb in a folder of its own that runs script, and the
// environment with only that folder on PATH.
func fakeXvfb(t *testing.T, script string) []string {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "Xvfb"), []byte("#!/bin/sh\n"+script+"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	return []string{"PATH=" + dir, "HOME=" + t.TempDir()}
}

func TestXvfbSaysItsDisplayAndStops(t *testing.T) {
	pidFile := filepath.Join(t.TempDir(), "pid")
	env := fakeXvfb(t, `case "$*" in *"-displayfd 3 -screen 0 1920x1080x24 -nolisten tcp -terminate"*) ;; *) exit 2;; esac
echo $$ > `+pidFile+`
echo 42 >&3
exec sleep 60`)
	x, err := startXvfb(env)
	if err != nil {
		t.Fatal(err)
	}
	if x.display != ":42" {
		t.Fatalf("display %q", x.display)
	}
	b, err := os.ReadFile(pidFile)
	if err != nil {
		t.Fatal(err)
	}
	pid, _ := strconv.Atoi(strings.TrimSpace(string(b)))
	x.stop()
	x.stop()
	if p, _ := os.FindProcess(pid); p.Signal(syscall.Signal(0)) == nil {
		t.Fatalf("Xvfb (pid %d) still runs", pid)
	}
}

func TestAnXvfbThatFailsSaysWhy(t *testing.T) {
	_, err := startXvfb(fakeXvfb(t, `echo "Fatal server error: no screens" >&2; exit 1`))
	if err == nil || !strings.Contains(err.Error(), "no screens") {
		t.Fatalf("err %v", err)
	}
}

func TestNoXvfbSaysSo(t *testing.T) {
	if lookPath("Xvfb", nil) != "" {
		t.Skip("this machine has an Xvfb in /usr/bin")
	}
	_, err := startXvfb([]string{"PATH=" + t.TempDir()})
	if err == nil || !strings.Contains(err.Error(), "no Xvfb") {
		t.Fatalf("err %v", err)
	}
}
