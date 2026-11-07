package browser

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// fake is a machine whose Node is a script that "installs" Chromium as an empty program,
// and whose launch counts starts and hands out a channel the test closes as a crash.
type fake struct {
	m        *Machine
	installs atomic.Int32
	launches atomic.Int32
	stops    atomic.Int32
	crash    chan struct{}
	busy     atomic.Bool
}

func newFake(t *testing.T) *fake {
	t.Helper()
	dir := t.TempDir()
	node := filepath.Join(dir, "node")
	// `node <cli.js> install chromium` makes $PLAYWRIGHT_BROWSERS_PATH/chrome.
	script := "#!/bin/sh\n[ \"$2\" = install ] && [ \"$3\" = chromium ] || exit 3\n" +
		"printf '#!/bin/sh\\n' > \"$PLAYWRIGHT_BROWSERS_PATH/chrome\" && chmod +x \"$PLAYWRIGHT_BROWSERS_PATH/chrome\"\n"
	if err := os.WriteFile(node, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	f := &fake{}
	f.m = New(filepath.Join(dir, "cache"), filepath.Join(dir, "root"),
		func(progress func(string)) (Toolset, error) {
			f.installs.Add(1)
			return Toolset{Node: node, Packages: filepath.Join(dir, "node_modules")}, nil
		},
		f.busy.Load, func() []string { return []string{"PATH=/usr/bin:/bin"} })
	f.m.locate = func(_ Toolset, env []string) (string, error) {
		for _, kv := range env {
			if v, ok := strings.CutPrefix(kv, "PLAYWRIGHT_BROWSERS_PATH="); ok {
				return filepath.Join(v, "chrome"), nil
			}
		}
		return "", errors.New("no PLAYWRIGHT_BROWSERS_PATH")
	}
	f.m.launch = func(exe, profile string, env []string) (*process, error) {
		n := f.launches.Add(1)
		f.crash = make(chan struct{})
		return &process{endpoint: "ws://127.0.0.1:9222/devtools/browser/" + string(rune('a'+n-1)), pid: 1000 + int(n),
			done: f.crash, stop: func() { f.stops.Add(1) }}, nil
	}
	t.Cleanup(f.m.Shutdown)
	return f
}

func TestTheFirstUseInstallsAndStartsIt(t *testing.T) {
	f := newFake(t)
	var said []string
	end, err := f.m.Endpoint(func(s string) { said = append(said, s) })
	if err != nil || end != "ws://127.0.0.1:9222/devtools/browser/a" {
		t.Fatal(end, err)
	}
	if strings.Join(said, "; ") != "Downloading Chromium; Starting the browser" {
		t.Fatal(said)
	}
	if fi, err := os.Stat(f.m.Profile); err != nil || fi.Mode().Perm() != 0o700 {
		t.Fatal("the profile is the person's alone", err)
	}
	// Up: the same browser, nothing installed or started again.
	if again, _ := f.m.Endpoint(nil); again != end || f.launches.Load() != 1 || !f.m.Running() {
		t.Fatal(again, f.launches.Load())
	}
	// Chromium installed already: no second download after a stop.
	f.m.Stop()
	said = nil
	if _, err := f.m.Endpoint(func(s string) { said = append(said, s) }); err != nil || strings.Join(said, "; ") != "Starting the browser" {
		t.Fatal(said, err)
	}
}

func TestACrashedBrowserStartsAgain(t *testing.T) {
	f := newFake(t)
	mustStart(t, f.m)
	close(f.crash)
	if f.m.Running() {
		t.Fatal("still running after the crash")
	}
	if end, err := f.m.Endpoint(nil); err != nil || end != "ws://127.0.0.1:9222/devtools/browser/b" || f.launches.Load() != 2 {
		t.Fatal(end, err)
	}
}

func TestItStopsWhenIdleAndNotLeased(t *testing.T) {
	f := newFake(t)
	mustStart(t, f.m)
	start := time.Now()
	if f.m.idle(start.Add(IdleAfter - time.Second)) {
		t.Fatal("stopped before the idle time")
	}
	f.busy.Store(true)
	if f.m.idle(start.Add(IdleAfter + time.Second)) {
		t.Fatal("stopped while an agent holds the lease")
	}
	f.busy.Store(false)
	if !f.m.idle(start.Add(IdleAfter+time.Second)) || f.m.Running() || f.stops.Load() != 1 {
		t.Fatal("not stopped when idle")
	}
	if _, err := os.Stat(f.m.pidFile()); !os.IsNotExist(err) {
		t.Fatal("pid file left", err)
	}
}

func TestNothingStartsAfterShutdown(t *testing.T) {
	f := newFake(t)
	mustStart(t, f.m)
	f.m.Shutdown()
	if f.stops.Load() != 1 {
		t.Fatal("not stopped")
	}
	if _, err := f.m.Endpoint(nil); err == nil {
		t.Fatal("started after shutdown")
	}
	var none *Machine
	none.Shutdown()
}

func TestAFailedDownloadSaysWhy(t *testing.T) {
	f := newFake(t)
	f.m.Install = func(func(string)) (Toolset, error) {
		return Toolset{Node: "/bin/sh", Packages: "/nowhere"}, nil
	}
	_, err := f.m.Endpoint(nil)
	if err == nil || !strings.HasPrefix(err.Error(), "downloading Chromium failed: ") || f.launches.Load() != 0 {
		t.Fatal(err)
	}
}

func TestAStartEmptiesTheCachesAndKeepsTheSignIns(t *testing.T) {
	f := newFake(t)
	profile := f.m.Profile
	write := func(rel string) string {
		path := filepath.Join(profile, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
		return path
	}
	cache := write("Default/Cache/Cache_Data/data_0")
	code := write("Default/Code Cache/js/index")
	workers := write("Default/Service Worker/CacheStorage/abc/index")
	cookies := write("Default/Cookies")
	storage := write("Default/Local Storage/leveldb/000003.log")
	if _, err := f.m.Endpoint(nil); err != nil {
		t.Fatal(err)
	}
	for _, gone := range []string{cache, code, workers} {
		if _, err := os.Stat(gone); !os.IsNotExist(err) {
			t.Errorf("%s is still there after a start (%v)", gone, err)
		}
	}
	for _, kept := range []string{cookies, storage} {
		if _, err := os.Stat(kept); err != nil {
			t.Errorf("a start removed the sign-in %s: %v", kept, err)
		}
	}
}

func TestActivePort(t *testing.T) {
	dir := t.TempDir()
	for _, c := range []struct{ file, want, err string }{
		{"41234\n/devtools/browser/0b1c\n", "ws://127.0.0.1:41234/devtools/browser/0b1c", ""},
		{"41234\n", "", "not whole"},
		{"x\n/devtools/browser/0b1c\n", "", "no port"},
		{"41234\n/json\n", "", "no browser path"},
	} {
		if err := os.WriteFile(filepath.Join(dir, "DevToolsActivePort"), []byte(c.file), 0o600); err != nil {
			t.Fatal(err)
		}
		got, err := activePort(dir)
		if got != c.want || (c.err == "") != (err == nil) || err != nil && !strings.Contains(err.Error(), c.err) {
			t.Fatalf("%q: %q %v", c.file, got, err)
		}
	}
}

// TestARealChromium starts the Chromium in AGENTS_TEST_CHROMIUM, when it is set, with
// chromedp, and checks that its debugging port is on 127.0.0.1 and the profile is kept.
func TestARealChromium(t *testing.T) {
	exe := os.Getenv("AGENTS_TEST_CHROMIUM")
	if exe == "" {
		t.Skip("set AGENTS_TEST_CHROMIUM to a Chromium to start a real one")
	}
	profile := t.TempDir()
	p, err := launchChromium(exe, profile, os.Environ())
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(p.endpoint, "ws://127.0.0.1:") || !strings.Contains(p.endpoint, "/devtools/browser/") {
		t.Fatal(p.endpoint)
	}
	if out, _ := exec.Command("lsof", "-a", "-p", strconv.Itoa(p.pid), "-iTCP", "-sTCP:LISTEN", "-nP").Output(); strings.Contains(string(out), "*:") {
		t.Fatalf("listens beyond 127.0.0.1:\n%s", out)
	}
	p.stop()
	select {
	case <-p.done:
	case <-time.After(10 * time.Second):
		t.Fatal("still running after stop")
	}
	if _, err := os.Stat(filepath.Join(profile, "Default")); err != nil {
		t.Fatal("the profile was not kept", err)
	}
}


func mustStart(t *testing.T, m *Machine) {
	t.Helper()
	if _, err := m.Endpoint(nil); err != nil {
		t.Fatal(err)
	}
}
