package browser

import (
	"bytes"
	"context"
	"encoding/json"
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
	"github.com/chromedp/cdproto/page"
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
	chrome   atomic.Int32
	profiles []string
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
	// No Google Chrome unless a test gives one (#5207): Chrome for Testing, as on Linux.
	f.m.chrome = func() string { return "" }
	f.m.launch = func(exe, profile string, env []string, how mode) (*process, error) {
		n := f.launches.Add(1)
		if how.chrome {
			f.chrome.Add(1)
			f.profiles = append(f.profiles, profile)
		}
		if how.headed {
			f.headed.Add(1)
		}
		if how.webauthn {
			f.webauthn.Add(1)
		}
		f.crash = make(chan struct{})
		return &process{endpoint: "ws://127.0.0.1:9222/devtools/browser/" + string(rune('a'+n-1)), pid: 1000 + int(n),
			done: f.crash, stop: func() { f.stops.Add(1) }, headed: how.headed, chrome: how.chrome, webauthn: how.webauthn}, nil
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

// With Google Chrome on the machine, the browser is that Chrome (#5207): headed, on its own
// profile, with nothing downloaded, for every site; a passkey still starts it again.
func TestGoogleChromeIsTheBrowser(t *testing.T) {
	f := newFake(t)
	f.m.chrome = func() string { return "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" }
	if !f.m.Installed() {
		t.Fatal("Google Chrome is a browser to start")
	}
	var said []string
	if _, err := f.m.Endpoint(func(s string) { said = append(said, s) }); err != nil {
		t.Fatal(err)
	}
	if strings.Join(said, "; ") != "Starting the browser" || f.chrome.Load() != 1 || f.headed.Load() != 1 {
		t.Fatal("not Google Chrome, headed, with no download:", said, f.chrome.Load(), f.headed.Load())
	}
	if f.profiles[0] != f.m.ChromeProfile() || f.m.ChromeProfile() == f.m.Profile {
		t.Fatal("not Google Chrome's own profile:", f.profiles)
	}
	if fi, err := os.Stat(f.m.ChromeProfile()); err != nil || fi.Mode().Perm() != 0o700 {
		t.Fatal("the profile is the person's alone", err)
	}
	if f.m.Headed() || f.stops.Load() != 0 {
		t.Fatal("a site that checks for bots started Google Chrome again")
	}
	if !f.m.Passkeys() {
		t.Fatal("a passkey did not start it again")
	}
	mustStart(t, f.m)
	if f.chrome.Load() != 2 || f.webauthn.Load() != 1 {
		t.Fatal(f.chrome.Load(), f.webauthn.Load())
	}
	// Stopped, the next start is Google Chrome again, with no Headed first.
	f.m.Stop()
	if f.m.Headed() {
		t.Fatal("Headed stopped a browser that is not running")
	}
	mustStart(t, f.m)
	if f.chrome.Load() != 3 || f.headed.Load() != 3 {
		t.Fatal(f.chrome.Load(), f.headed.Load())
	}
}

// A Google Chrome that does not start leaves Chrome for Testing, as with no Chrome.
func TestAFailedGoogleChromeStartsChromeForTesting(t *testing.T) {
	f := newFake(t)
	f.m.chrome = func() string { return "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" }
	launch := f.m.launch
	f.m.launch = func(exe, profile string, env []string, how mode) (*process, error) {
		if how.chrome {
			return nil, errors.New("no Chrome")
		}
		return launch(exe, profile, env, how)
	}
	if _, err := f.m.Endpoint(nil); err != nil || f.launches.Load() != 1 || f.headed.Load() != 0 {
		t.Fatal(err, f.launches.Load(), f.headed.Load())
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

// TestARealGoogleChrome starts the Google Chrome in AGENTS_TEST_GOOGLE_CHROME as the
// agents' browser (#5207) on a scratch profile, and checks that it says the Chrome it is,
// that its window is below every screen, that it has no test flags, and that a screencast
// (the chat tile, #4138) still paints from there.
func TestARealGoogleChrome(t *testing.T) {
	exe := os.Getenv("AGENTS_TEST_GOOGLE_CHROME")
	if exe == "" {
		t.Skip("set AGENTS_TEST_GOOGLE_CHROME to Google Chrome to start a real one")
	}
	p, err := launchChromium(exe, t.TempDir(), os.Environ(), mode{chrome: true, headed: true})
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		p.stop()
		<-p.done
		if p.display == "" {
			return
		}
		// Its Xvfb stops with it (#5227): the screen's socket goes.
		socket := "/tmp/.X11-unix/X" + strings.TrimPrefix(p.display, ":")
		for i := 0; i < 60; i++ {
			if _, err := os.Stat(socket); err != nil {
				return
			}
			time.Sleep(100 * time.Millisecond)
		}
		t.Errorf("Xvfb %s still runs after Chrome stopped", p.display)
	}()
	ctx := p.store.(cdpStore).ctx
	// userAgentData is only in a secure context, which about:blank is not.
	if _, err := chromedp.Run(ctx, chromedp.Navigate("https://example.com/")); err != nil {
		t.Fatal(err)
	}
	says, err := chromedp.Run(ctx, chromedp.Evaluate[[]any](`[navigator.userAgentData.brands.map(b => b.brand).join(","), navigator.webdriver, navigator.userAgent, typeof PublicKeyCredential]`))
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("it says %v", says)
	if cmd, err := exec.Command("ps", "-o", "command=", "-p", strconv.Itoa(p.pid)).Output(); err == nil {
		t.Logf("it runs as %s", cmd)
	}
	if !strings.Contains(says[0].(string), "Google Chrome") || says[1] != false || strings.Contains(says[2].(string), "Headless") || says[3] != "undefined" {
		t.Fatalf("not the Chrome it is, or WebAuthn on: %v", says)
	}
	where, err := chromedp.Run(ctx, chromedp.Evaluate[[]float64](`[window.screenX, window.screenY, window.outerWidth, screen.availLeft, screen.height]`))
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("the window is at %v", where)
	if p.display != "" {
		// A Linux machine with no display (#5227): an Xvfb screen of its own, which nobody sees.
		t.Logf("it runs on the Xvfb screen %s", p.display)
	} else if len(where) != 5 || where[0]+where[2]-where[3] > 1 && where[1] < where[4] {
		// At most one point across shows, at the screen's left edge, or none below it.
		t.Fatalf("the window is on the screen: %v", where)
	}
	out, err := exec.Command("ps", "-o", "command=", "-p", strconv.Itoa(p.pid)).Output()
	if err != nil {
		t.Fatal(err)
	}
	for _, flag := range []string{"use-mock-keychain", "password-store", "enable-automation", "disable-sync", "disable-extensions", "headless", "user-agent", "mute-audio", "hide-scrollbars"} {
		if strings.Contains(string(out), flag) {
			t.Errorf("it has the test flag %s: %s", flag, out)
		}
	}
	// The chat tile's screencast (#4138) paints from below the screen while the page changes.
	frames := chromedp.Events(ctx, page.ScreencastFrame)
	var painted atomic.Int32
	go func() {
		for ev, err := range frames {
			if err != nil {
				return
			}
			painted.Add(1)
			_, _ = chromedp.Call(ctx, page.ScreencastFrameAck, page.ScreencastFrameAckParams{SessionID: ev.SessionID})
		}
	}()
	if _, err := chromedp.Call(ctx, page.StartScreencast, page.StartScreencastParams{Format: page.StartScreencastFormatJpeg, EveryNthFrame: 1}); err != nil {
		t.Fatal(err)
	}
	if _, err := chromedp.Run(ctx, chromedp.Evaluate[any](`setInterval(() => document.body.style.background = '#' + Math.floor(Math.random() * 0xffffff).toString(16).padStart(6, '0'), 50)`)); err != nil {
		t.Fatal(err)
	}
	time.Sleep(3 * time.Second)
	t.Logf("the screencast painted %d frames in 3 s", painted.Load())
	if painted.Load() < 10 {
		t.Fatalf("the screencast painted %d frames in 3 s", painted.Load())
	}
	if url := os.Getenv("AGENTS_TEST_BOT_CHECK"); url != "" {
		// One page that checks, opened once: what it says after the check.
		if _, err := chromedp.Run(ctx, chromedp.Navigate(url)); err != nil {
			t.Fatal(err)
		}
		time.Sleep(15 * time.Second)
		said, err := chromedp.Run(ctx, chromedp.Evaluate[[]any](`[document.title, location.href, document.body.innerText.slice(0, 300)]`))
		t.Logf("%v (err %v)", said, err)
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

// TestARealWindowForThePerson (#5208) shows a real Google Chrome's window on the screen and
// brings it to the front with agents-drive's "front", then puts both back. It moves a window
// on this machine's screen: take the "screen" lease. AGENTS_TEST_GOOGLE_CHROME is Google
// Chrome, AGENTS_TEST_DRIVE an agents-drive built from Host/AgentsDrive.
func TestARealWindowForThePerson(t *testing.T) {
	exe, drive := os.Getenv("AGENTS_TEST_GOOGLE_CHROME"), os.Getenv("AGENTS_TEST_DRIVE")
	if exe == "" || drive == "" {
		t.Skip("set AGENTS_TEST_GOOGLE_CHROME and AGENTS_TEST_DRIVE to move a real window")
	}
	p, err := launchChromium(exe, t.TempDir(), os.Environ(), mode{chrome: true, headed: true})
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		p.stop()
		<-p.done
	}()
	m := &Machine{running: p}
	ctx := p.store.(cdpStore).ctx
	where := func() []float64 {
		at, err := chromedp.Run(ctx, chromedp.Evaluate[[]float64](`[window.screenX, window.screenY, screen.height]`))
		if err != nil {
			t.Fatal(err)
		}
		return at
	}
	front := func(pid int) int {
		cmd := exec.Command(drive)
		cmd.Stdin = strings.NewReader(`{"action":"front","pid":` + strconv.Itoa(pid) + "}\x00")
		out, err := cmd.Output()
		if err != nil {
			t.Fatal(err)
		}
		var a struct {
			OK       bool   `json:"ok"`
			Error    string `json:"error"`
			Previous int    `json:"previous"`
		}
		if err := json.Unmarshal(bytes.TrimRight(out, "\x00"), &a); err != nil || !a.OK {
			t.Fatalf("%s %v", out, err)
		}
		return a.Previous
	}
	t.Logf("below the screen: %v", where())
	pid, err := m.ShowWindow(context.Background(), "")
	if err != nil || pid != p.pid {
		t.Fatal(pid, err)
	}
	if at := where(); at[0] != onScreen || at[1] < 0 || at[1] > at[2] {
		t.Fatalf("not on the screen: %v", at)
	}
	before := front(pid)
	t.Logf("in front of pid %d", before)
	if again := front(pid); again != pid {
		t.Fatalf("Chrome is not in front: pid %d is", again)
	}
	if err := m.HideWindow(context.Background(), ""); err != nil {
		t.Fatal(err)
	}
	if back := front(before); back != pid {
		t.Fatalf("pid %d was in front, not Chrome", back)
	}
	if now := front(before); now != before {
		t.Fatalf("pid %d did not come back: %d is in front", before, now)
	}
	if at := where(); at[0] > -1000 && at[1] < at[2] {
		t.Fatalf("still on the screen: %v", at)
	}
}
