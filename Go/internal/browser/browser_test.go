package browser

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	cdpbrowser "github.com/chromedp/cdproto/browser"
	"github.com/chromedp/cdproto/cdp"
	"github.com/chromedp/chromedp"
)

// fake is a machine whose Node is a script that "installs" Chromium as an empty program,
// and whose launch counts starts and hands out a channel the test closes as a crash.
type fake struct {
	m        *Machine
	installs atomic.Int32
	launches atomic.Int32
	headed   atomic.Int32
	webauthn atomic.Int32
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
	f.m.launch = func(exe, profile string, env []string, how mode) (*process, error) {
		n := f.launches.Add(1)
		if how.headed {
			f.headed.Add(1)
		}
		if how.webauthn {
			f.webauthn.Add(1)
		}
		f.crash = make(chan struct{})
		return &process{endpoint: "ws://127.0.0.1:9222/devtools/browser/" + string(rune('a'+n-1)), pid: 1000 + int(n),
			done: f.crash, stop: func() { f.stops.Add(1) }, headed: how.headed, webauthn: how.webauthn}, nil
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

// A site that checks for bots starts the browser again with a window (#4272), with no
// second start while it is headed, and the start after it stops is headless again.
func TestHeadedStartsItAgainWithAWindow(t *testing.T) {
	f := newFake(t)
	if runtime.GOOS != "darwin" {
		f.m.Env = func() []string { return []string{"PATH=/usr/bin:/bin", "DISPLAY=:0"} }
	}
	mustStart(t, f.m)
	if !f.m.Headed() || f.m.Running() || f.stops.Load() != 1 {
		t.Fatal("the headless browser did not stop")
	}
	end, err := f.m.Endpoint(nil)
	if err != nil || end != "ws://127.0.0.1:9222/devtools/browser/b" || f.headed.Load() != 1 {
		t.Fatal(end, err, f.headed.Load())
	}
	if f.m.Headed() || f.stops.Load() != 1 {
		t.Fatal("a headed browser started again")
	}
	f.m.Stop()
	mustStart(t, f.m)
	if f.launches.Load() != 3 || f.headed.Load() != 1 {
		t.Fatal("the start after a stop was not headless", f.headed.Load())
	}
}

// A software passkey starts the browser again with WebAuthn (#4085), with no second start
// while it has it; a window it has stays; the start after it stops has none again.
func TestPasskeysStartsItAgainWithWebAuthn(t *testing.T) {
	f := newFake(t)
	if runtime.GOOS != "darwin" {
		f.m.Env = func() []string { return []string{"PATH=/usr/bin:/bin", "DISPLAY=:0"} }
	}
	f.m.Headed()
	mustStart(t, f.m)
	if !f.m.Passkeys() || f.m.Running() || f.stops.Load() != 1 {
		t.Fatal("the browser with no WebAuthn did not stop")
	}
	end, err := f.m.Endpoint(nil)
	if err != nil || end != "ws://127.0.0.1:9222/devtools/browser/b" || f.webauthn.Load() != 1 || f.headed.Load() != 2 {
		t.Fatal(end, err, f.webauthn.Load(), f.headed.Load())
	}
	if f.m.Passkeys() || f.m.Headed() || f.stops.Load() != 1 {
		t.Fatal("a browser with WebAuthn started again")
	}
	f.m.Stop()
	mustStart(t, f.m)
	if f.launches.Load() != 3 || f.webauthn.Load() != 1 || f.headed.Load() != 2 {
		t.Fatal("the start after a stop had WebAuthn", f.webauthn.Load(), f.headed.Load())
	}
}

// A site that checks for bots keeps WebAuthn when it starts the browser again headed.
func TestHeadedKeepsWebAuthn(t *testing.T) {
	f := newFake(t)
	if runtime.GOOS != "darwin" {
		f.m.Env = func() []string { return []string{"PATH=/usr/bin:/bin", "DISPLAY=:0"} }
	}
	f.m.Passkeys()
	mustStart(t, f.m)
	if !f.m.Headed() {
		t.Fatal("the headless browser did not stop")
	}
	mustStart(t, f.m)
	if f.webauthn.Load() != 2 || f.headed.Load() != 1 {
		t.Fatal(f.webauthn.Load(), f.headed.Load())
	}
}

// With no display, there is no window: the browser stays as it is.
func TestHeadedNeedsADisplay(t *testing.T) {
	if runtime.GOOS == "darwin" {
		t.Skip("a Mac always has a window server")
	}
	f := newFake(t)
	mustStart(t, f.m)
	if f.m.Headed() || !f.m.Running() {
		t.Fatal("stopped with no display")
	}
}

// A headed start that fails starts it headless.
func TestAFailedHeadedStartIsHeadless(t *testing.T) {
	f := newFake(t)
	f.m.Env = func() []string { return []string{"PATH=/usr/bin:/bin", "DISPLAY=:0"} }
	launch := f.m.launch
	f.m.launch = func(exe, profile string, env []string, how mode) (*process, error) {
		if how.headed {
			return nil, errors.New("no window")
		}
		return launch(exe, profile, env, how)
	}
	f.m.Headed()
	if _, err := f.m.Endpoint(nil); err != nil || f.launches.Load() != 1 {
		t.Fatal(err, f.launches.Load())
	}
}

func TestChecksBots(t *testing.T) {
	for url, want := range map[string]bool{
		"https://dash.cloudflare.com/login":        true,
		"https://signup.live.com/":                 true,
		"https://login.microsoftonline.com/common": true,
		"https://sandbox-buy.paddle.com/checkout":  true,
		"dash.cloudflare.com/login":                true,
		"https://DASH.Cloudflare.COM":              true,
		"https://example.com/?next=cloudflare.com": false,
		"https://notcloudflare.com/":               false,
		"https://github.com/":                      false,
		"about:blank":                              false,
		"":                                         false,
	} {
		if ChecksBots(url) != want {
			t.Errorf("%q: want %v", url, want)
		}
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
	p, err := launchChromium(exe, profile, os.Environ(), mode{})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(p.endpoint, "ws://127.0.0.1:") || !strings.Contains(p.endpoint, "/devtools/browser/") {
		t.Fatal(p.endpoint)
	}
	// A checkout refuses HeadlessChrome (#4060).
	v, err := chromedp.CallBrowser(p.store.(cdpStore).ctx, cdpbrowser.GetVersion, cdp.Empty{})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(v.UserAgent, "Headless") {
		t.Fatal(v.UserAgent)
	}
	// It has no passkeys, so a page sees no WebAuthn (#4084).
	webAuthn, err := chromedp.Run(p.store.(cdpStore).ctx, chromedp.Evaluate[string](`typeof PublicKeyCredential`))
	if err != nil {
		t.Fatal(err)
	}
	if webAuthn != "undefined" {
		t.Fatal(webAuthn)
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

// TestARealHeadedChromium starts the Chromium in AGENTS_TEST_CHROMIUM headed (#4272), and
// checks that its window is off every screen and that it says the Chrome it is.
func TestARealHeadedChromium(t *testing.T) {
	exe := os.Getenv("AGENTS_TEST_CHROMIUM")
	if exe == "" {
		t.Skip("set AGENTS_TEST_CHROMIUM to a Chromium to start a real one")
	}
	p, err := launchChromium(exe, t.TempDir(), os.Environ(), mode{headed: true})
	if err != nil {
		t.Fatal(err)
	}
	defer p.stop()
	ctx := p.store.(cdpStore).ctx
	v, err := chromedp.CallBrowser(ctx, cdpbrowser.GetVersion, cdp.Empty{})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(v.UserAgent, "Headless") || !p.headed {
		t.Fatal(v.UserAgent)
	}
	if url := os.Getenv("AGENTS_TEST_BOT_CHECK"); url != "" {
		// One page that checks, opened once, with no sign-in: its title after the check.
		// A 403 with a challenge still loads; only a page that does not load fails here.
		if _, err := chromedp.Run(ctx, chromedp.Navigate(url)); err != nil {
			t.Fatal(err)
		}
		time.Sleep(15 * time.Second)
		page, err := chromedp.Run(ctx, chromedp.Evaluate[[]any](`[document.title, location.href, navigator.webdriver, document.body.innerText.slice(0, 300)]`))
		t.Logf("%s: %v (err %v)", url, page, err)
	}
	where, err := chromedp.Run(ctx, chromedp.Evaluate[[]float64](`[window.screenX, window.screenY, window.outerWidth]`))
	if err != nil {
		t.Fatal(err)
	}
	if len(where) != 3 || where[0] > -1000 && where[1] > -1000 || where[2] < 1000 {
		t.Fatalf("the window is not off-screen: %v", where)
	}
}

func TestHeadedUserAgent(t *testing.T) {
	const ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) %s/156.0.0.0 Safari/537.36"
	if got, want := headedUserAgent(fmt.Sprintf(ua, "HeadlessChrome")), fmt.Sprintf(ua, "Chrome"); got != want {
		t.Fatal(got)
	}
}

func mustStart(t *testing.T, m *Machine) {
	t.Helper()
	if _, err := m.Endpoint(nil); err != nil {
		t.Fatal(err)
	}
}
