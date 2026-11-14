// Package browser is the machine's browser (#3533, spike #3527): one Chromium per
// machine, which agentsd downloads on first use, starts with no window and a kept profile,
// listening on 127.0.0.1 only, and stops when nobody has used it for a while. Agents drive
// it through Playwright (#3534, agentsd's browsertools.go); clients watch it by a screencast
// (screencast.go, #3528).
//
// With Google Chrome installed, it is that Chrome (#5207, spike #5127): Google Chrome
// stable, in a profile of its own, headed and with none of the test flags, for every site.
// A site's check sees the real Chrome it is, which Google's sign-in needs (#4837). On a Mac
// its window is just below the screen; on a Linux machine with no display it is on an Xvfb
// screen of its own, which agentsd starts and stops with it (xvfb.go, #5227, spike #5209).
// Elsewhere, the Chromium is Playwright's own build (Chrome for
// Testing), installed by Playwright's own installer (`playwright-core install chromium`)
// from the pinned @playwright/mcp toolset, so the browser and the tools that drive it
// always match. chromedp starts it and speaks CDP.
package browser

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	cdpbrowser "github.com/chromedp/cdproto/browser"
	"github.com/chromedp/cdproto/cdp"
	"github.com/chromedp/chromedp"
	"github.com/chromedp/chromedp/remote"
)

// Resource is the lease that one agent at a time holds while it drives the browser.
const Resource = "browser:agents"

// DisplayName is how the lease and the app's words name it.
const DisplayName = "This machine's browser"

// IdleAfter is how long the browser runs with no use and no lease before it stops.
const IdleAfter = 15 * time.Minute

// Toolset is Node and the pinned @playwright/mcp, installed: Node's binary and the
// node_modules folder that holds @playwright/mcp and playwright-core.
type Toolset struct {
	Node     string
	Packages string
}

// CLI is playwright-core's command line in the toolset.
func (t Toolset) CLI() string { return filepath.Join(t.Packages, "playwright-core", "cli.js") }

// MCP is @playwright/mcp's command line in the toolset, which agentsd starts per session.
func (t Toolset) MCP() string { return filepath.Join(t.Packages, "@playwright", "mcp", "cli.js") }

// Machine is this machine's browser. Make one with New; it starts nothing until Endpoint.
type Machine struct {
	// Binaries is where Playwright puts Chromium (PLAYWRIGHT_BROWSERS_PATH): in the
	// cache, as it can be downloaded again.
	Binaries string
	// Profile is the kept profile: the sign-ins that agents on this machine share. Google
	// Chrome keeps its own beside it (ChromeProfile).
	Profile string
	// Install puts Node and the pinned packages on this machine, or says why it cannot.
	Install func(progress func(string)) (Toolset, error)
	// Busy is whether an agent holds or waits for the lease: the browser is not idle then.
	Busy func() bool
	// Env is the environment Node and Chromium run with.
	Env func() []string
	// Filter is what every browser tool's result goes through (#3534): the values filled
	// into its pages come out, and its images are masked.
	Filter Filter
	// Changed hears that Chromium started (true) or stopped (false), off the machine's
	// lock: the clients that watch the page are told (#3528).
	Changed func(running bool)

	// launch starts Chromium as how says, and says how to reach it; a test gives its own.
	launch func(exe, profile string, env []string, how mode) (*process, error)
	// locate is the Chromium that the toolset installed; a test gives its own.
	locate func(t Toolset, env []string) (string, error)
	// chrome is Google Chrome stable on this machine, or "" (#5207); a test gives its own.
	chrome func() string

	mu      sync.Mutex
	running *process
	// headed is whether the next start has a window (Headed): until the browser stops.
	headed bool
	// webauthn is whether the next start has WebAuthn (Passkeys): until the browser stops.
	webauthn bool
	toolset  Toolset
	lastUsed time.Time
	stopLoop chan struct{}
	loopDone chan struct{}
	stopped  bool
}

// process is a running Chromium.
type process struct {
	endpoint string
	pid      int
	done     <-chan struct{}
	stop     func()
	// headed is whether it has a window (off-screen), not headless.
	headed bool
	// display is the Xvfb screen agentsd started for it (":<n>"), or "" (#5227).
	display string
	// chrome is whether it is Google Chrome stable (#5207), not Chrome for Testing.
	chrome bool
	// webauthn is whether its pages have WebAuthn, for a software passkey (#4085).
	webauthn bool
	// store is its cookies, for Settings ▸ Browser (sites.go).
	store cookieStore
}

// mode is how Chromium starts: Google Chrome stable (#5207), always with a window; with a
// window, off-screen (#4272); and with WebAuthn, for a software passkey (#4085). The zero
// mode is Chrome for Testing, headless with no WebAuthn.
type mode struct{ chrome, headed, webauthn bool }

// New is the machine's browser with its binaries under cache and its profile under root.
func New(cache, root string, install func(func(string)) (Toolset, error), busy func() bool, env func() []string) *Machine {
	return &Machine{
		Binaries: filepath.Join(cache, "browser", "chromium"),
		Profile:  filepath.Join(root, "browser", "profile"),
		Install:  install,
		Busy:     busy,
		Env:      env,
		launch:   launchChromium,
		locate:   locateChromium,
		chrome:   FindChrome,
	}
}

// FindChrome is how New finds Google Chrome stable on this machine (findChrome). A test of
// another package that must not start the machine's own Chrome sets it to return "" before
// it makes a Machine: GitHub's Linux runners have Chrome and Xvfb (#5227).
var FindChrome = findChrome

// Endpoint is the browser's CDP address (ws://127.0.0.1:<port>/devtools/browser/<id>),
// after it installs and starts it when it must. Each call counts as use, so the browser
// stays up while it is driven. progress hears each step of a first install.
func (m *Machine) Endpoint(progress func(string)) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.stopped {
		return "", errors.New("the host is stopping, so the browser was not started")
	}
	m.lastUsed = time.Now()
	if m.running != nil {
		select {
		case <-m.running.done:
			log.Printf("browser: Chromium (pid %d) exited; starting it again", m.running.pid)
			m.running = nil
			m.Filter.Forget()
		default:
			return m.running.endpoint, nil
		}
	}
	if progress == nil {
		progress = func(string) {}
	}
	if m.Install == nil {
		return "", errors.New("this machine cannot install the browser")
	}
	t, err := m.Install(progress)
	if err != nil {
		return "", err
	}
	m.toolset = t
	env := m.environment()
	m.endLeftover()
	var p *process
	if exe := m.chromeExe(); exe != "" {
		// Google Chrome stable, headed, for every site (#5207).
		if p, err = m.start(exe, m.ChromeProfile(), env, mode{chrome: true, headed: true, webauthn: m.webauthn}, progress); err != nil {
			log.Printf("browser: Google Chrome did not start (%v); starting Chrome for Testing", err)
		}
	}
	if p == nil {
		if p, err = m.startForTesting(t, env, progress); err != nil {
			return "", err
		}
	}
	if err := os.WriteFile(m.pidFile(), []byte(strconv.Itoa(p.pid)), 0o600); err != nil {
		log.Printf("browser: couldn't write down Chromium's pid: %v", err)
	}
	m.running = p
	m.startLoop()
	m.changed(true)
	started := "headless"
	if p.chrome && p.display != "" {
		started = "as Google Chrome, on the Xvfb screen " + p.display
	} else if p.chrome {
		started = "as Google Chrome, with a window below the screen"
	} else if p.headed {
		started = "with a window off-screen"
	}
	if p.webauthn {
		started += ", with WebAuthn for a software passkey"
	}
	log.Printf("browser: Chromium (pid %d) started %s, with the profile in %s", p.pid, started, m.profileOf(p))
	return p.endpoint, nil
}

// profileOf is the profile p runs on.
func (m *Machine) profileOf(p *process) string {
	if p.chrome {
		return m.ChromeProfile()
	}
	return m.Profile
}

// chromeExe is Google Chrome stable on this machine, or "" when it has none.
func (m *Machine) chromeExe() string {
	if m.chrome == nil {
		return ""
	}
	return m.chrome()
}

// ChromeProfile is Google Chrome's kept profile (#5207), beside Chrome for Testing's: Chrome
// keeps its cookies sealed by the Keychain, where Chrome for Testing has a mock one, so
// neither reads the other's sign-ins.
func (m *Machine) ChromeProfile() string {
	return filepath.Join(filepath.Dir(m.Profile), "chrome-profile")
}

// start makes profile, empties its caches and starts exe on it as how says.
func (m *Machine) start(exe, profile string, env []string, how mode, progress func(string)) (*process, error) {
	if err := os.MkdirAll(profile, 0o700); err != nil {
		return nil, err
	}
	dropCaches(profile)
	progress("Starting the browser")
	return m.launch(exe, profile, env, how)
}

// startForTesting starts Chrome for Testing, after it downloads it when it must: headless,
// or headed when a site asked for it (Headed) and a window can open.
func (m *Machine) startForTesting(t Toolset, env []string, progress func(string)) (*process, error) {
	exe, err := m.locate(t, env)
	if err != nil || !executable(exe) {
		progress("Downloading Chromium")
		if err := m.installChromium(t, env); err != nil {
			return nil, err
		}
		if exe, err = m.locate(t, env); err != nil {
			return nil, err
		}
		if !executable(exe) {
			return nil, fmt.Errorf("Playwright installed no Chromium at %s", exe)
		}
	}
	how := mode{headed: m.headed && canHead(env), webauthn: m.webauthn}
	p, err := m.start(exe, m.Profile, env, how, progress)
	if err != nil && how.headed {
		// A window it cannot open is no reason to have no browser: headless, as always.
		log.Printf("browser: Chromium did not start with a window (%v); starting it headless", err)
		m.headed, how.headed = false, false
		p, err = m.launch(exe, m.Profile, env, how)
	}
	if err != nil {
		return nil, fmt.Errorf("the browser did not start: %w", err)
	}
	return p, nil
}

// Headed makes Chrome for Testing have a window, off-screen, until it stops (#4272): a site
// whose bot check refuses headless Chrome (ChecksBots). A headless Chromium that runs now
// stops, with its cookies kept, and the next Endpoint starts it headed, at a new address. It
// says whether it stopped one. Where no window can open (a Linux machine with no display),
// the browser stays headless. Google Chrome (#5207) always has a window, so it does nothing
// there.
func (m *Machine) Headed() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.stopped || !canHead(m.environment()) || m.running == nil && m.chromeExe() != "" {
		return false
	}
	restarted := false
	if m.running != nil && !m.running.headed {
		m.restartLocked()
		restarted = true
	}
	m.headed = true
	return restarted
}

// Passkeys gives the browser's pages WebAuthn until it stops (#4085), for a software
// passkey on a tab (Tabs.Passkey): it starts with none, as it has no passkeys of its own
// (#4084). A Chromium that runs with none stops now, with its cookies kept, and the next
// Endpoint starts it with WebAuthn, at a new address; its tabs close. It says whether it
// stopped one. A window it has (Headed) it keeps.
func (m *Machine) Passkeys() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.stopped {
		return false
	}
	restarted := false
	if m.running != nil && !m.running.webauthn {
		m.restartLocked()
		restarted = true
	}
	m.webauthn = true
	return restarted
}

// restartLocked stops Chromium for a start in another mode, which keeps the mode it has.
func (m *Machine) restartLocked() {
	headed, webauthn := m.headed, m.webauthn
	m.stopLocked()
	m.headed, m.webauthn = headed, webauthn
}

// canHead is whether Chromium can open a window here: a Mac, or a display in env.
func canHead(env []string) bool {
	if runtime.GOOS == "darwin" {
		return true
	}
	for _, kv := range env {
		if v, ok := strings.CutPrefix(kv, "DISPLAY="); ok && v != "" {
			return true
		}
		if v, ok := strings.CutPrefix(kv, "WAYLAND_DISPLAY="); ok && v != "" {
			return true
		}
	}
	return false
}

// Toolset is Node and @playwright/mcp as the last start installed them: what drives the
// browser at Endpoint's address. Empty before the first start.
func (m *Machine) Toolset() Toolset {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.toolset
}

// Running is whether Chromium is up now.
func (m *Machine) Running() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.running == nil {
		return false
	}
	select {
	case <-m.running.done:
		return false
	default:
		return true
	}
}

// Touch counts as use without starting anything: a client that watches the page.
func (m *Machine) Touch() {
	m.mu.Lock()
	m.lastUsed = time.Now()
	m.mu.Unlock()
}

// Stop closes Chromium, if it runs, and keeps the machine usable.
func (m *Machine) Stop() {
	m.mu.Lock()
	m.stopLocked()
	m.mu.Unlock()
}

// Shutdown closes Chromium and ends the idle loop for good: the host is stopping. A nil
// machine (a host made without New) has nothing to stop.
func (m *Machine) Shutdown() {
	if m == nil {
		return
	}
	m.mu.Lock()
	m.stopped = true
	m.stopLocked()
	stop, done := m.stopLoop, m.loopDone
	m.stopLoop, m.loopDone = nil, nil
	m.mu.Unlock()
	if stop != nil {
		close(stop)
		<-done
	}
}

func (m *Machine) stopLocked() {
	if m.running == nil {
		return
	}
	m.running.stop()
	log.Printf("browser: Chromium (pid %d) stopped", m.running.pid)
	m.running = nil
	// The next start is headless again, unless a site asks for a window (Headed), and has
	// no WebAuthn, unless an agent asks for a software passkey (Passkeys).
	m.headed, m.webauthn = false, false
	// The pages are gone, and every value filled into them with the pages.
	m.Filter.Forget()
	os.Remove(m.pidFile())
	m.changed(false)
}

// changed tells Changed, on its own goroutine, as mu is held.
func (m *Machine) changed(running bool) {
	if m.Changed != nil {
		go m.Changed(running)
	}
}

// idle stops Chromium when it has not been used for IdleAfter and no agent holds or waits
// for its lease. It says whether it stopped it.
func (m *Machine) idle(now time.Time) bool {
	quiet := func() bool { return m.running != nil && now.Sub(m.lastUsed) >= IdleAfter }
	m.mu.Lock()
	ok := quiet()
	m.mu.Unlock()
	// Busy takes the lease book's lock, so it is asked with mu free.
	if !ok || m.Busy != nil && m.Busy() {
		return false
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if !quiet() {
		return false
	}
	m.stopLocked()
	return true
}

// startLoop runs the idle check once a minute while the machine lives. Under mu.
func (m *Machine) startLoop() {
	if m.stopLoop != nil {
		return
	}
	stop, done := make(chan struct{}), make(chan struct{})
	m.stopLoop, m.loopDone = stop, done
	go func() {
		defer close(done)
		tick := time.NewTicker(time.Minute)
		defer tick.Stop()
		for {
			select {
			case <-stop:
				return
			case now := <-tick.C:
				m.idle(now)
			}
		}
	}()
}

func (m *Machine) environment() []string {
	env := os.Environ()
	if m.Env != nil {
		env = m.Env()
	}
	return append(withoutKey(env, "PLAYWRIGHT_BROWSERS_PATH"), "PLAYWRIGHT_BROWSERS_PATH="+m.Binaries)
}

// installChromium is `playwright-core install chromium` with the toolset's own Node, into
// Binaries. It needs no root: a Linux machine that lacks Chromium's libraries says so when
// it starts, and the person installs them (`playwright install-deps` needs sudo).
func (m *Machine) installChromium(t Toolset, env []string) error {
	if err := os.MkdirAll(m.Binaries, 0o755); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, t.Node, t.CLI(), "install", "chromium")
	cmd.Env = env
	out, err := cmd.CombinedOutput()
	switch {
	case ctx.Err() == context.DeadlineExceeded:
		return errors.New("downloading Chromium took more than ten minutes, so it was stopped")
	case strings.Contains(string(out), "No space left on device") || strings.Contains(string(out), "ENOSPC"):
		return syscall.ENOSPC
	case err != nil:
		return fmt.Errorf("downloading Chromium failed: %s", lastLine(string(out)))
	}
	return nil
}

// locateChromium asks playwright-core where its Chromium is, with the same
// PLAYWRIGHT_BROWSERS_PATH, so nothing here knows its folder layout.
func locateChromium(t Toolset, env []string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, t.Node, "-e",
		`process.stdout.write(require(process.argv[1]).chromium.executablePath())`,
		filepath.Join(t.Packages, "playwright-core"))
	cmd.Env = env
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("couldn't find Playwright's Chromium: %w", err)
	}
	return strings.TrimSpace(string(out)), nil
}

// launchChromium starts Chromium with chromedp: headless, the kept profile, its debugging
// port on 127.0.0.1 and a port the system picks, so only this machine reaches it and the
// address has the browser's random id in its path. Its user agent says Chrome, not
// HeadlessChrome (#4060). It has no WebAuthn, as it cannot do passkeys (#4084), unless
// how asks for it, for a software passkey (#4085). Headed (#4272), it has a window
// off-screen instead, and its own user agent.
func launchChromium(exe, profile string, env []string, how mode) (*process, error) {
	if how.chrome {
		return launchChrome(exe, profile, env, how)
	}
	if how.headed {
		p, _, err := startChromium(exe, profile, env, "", how)
		return p, err
	}
	if ua, ok := userAgents.Load(exe); ok {
		p, _, err := startChromium(exe, profile, env, ua.(string), how)
		return p, err
	}
	p, ua, err := startChromium(exe, profile, env, "", how)
	if err != nil || !strings.Contains(ua, "HeadlessChrome/") {
		return p, err
	}
	// The first start of this Chromium learns its user agent; the next starts use it.
	asChrome := headedUserAgent(ua)
	userAgents.Store(exe, asChrome)
	p.stop()
	<-p.done
	p, _, err = startChromium(exe, profile, env, asChrome, how)
	return p, err
}

// findChrome is Google Chrome stable on this machine, or "" (#5207, #5227).
func findChrome() string {
	home, _ := os.UserHomeDir()
	for _, exe := range chromePaths(runtime.GOOS, home) {
		if executable(exe) {
			return exe
		}
	}
	return ""
}

// chromePaths are where Google Chrome stable can be on goos, in the order they are tried:
// on a Mac, /Applications and ~/Applications (#5207); on Linux, where Google's .deb and .rpm
// put it (#5227). Google ships no Chrome for Linux on arm64, so there it is not found, and
// the browser is Chrome for Testing.
func chromePaths(goos, home string) []string {
	switch goos {
	case "darwin":
		paths := []string{"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"}
		if home != "" {
			paths = append(paths, filepath.Join(home, "Applications", "Google Chrome.app", "Contents", "MacOS", "Google Chrome"))
		}
		return paths
	case "linux":
		return []string{"/usr/bin/google-chrome-stable", "/usr/bin/google-chrome", "/opt/google/chrome/chrome"}
	}
	return nil
}

// launchChrome starts Google Chrome stable (#5207): headed, on the kept profile, its
// debugging port on 127.0.0.1 and a free port agentsd picks, and none of chromedp's test
// defaults (no mock keychain, no basic password store, sync and extensions as Chrome has
// them), so a site sees the Chrome it is, except that a covered window's pages stay
// visible. Its user agent is its own. WebAuthn is off unless
// how asks for it (#4085), as for Chrome for Testing. Its window goes just below the screen
// before the first page opens.
//
// Where no window can open (a Linux server: no DISPLAY or WAYLAND_DISPLAY), it runs on an
// Xvfb screen that agentsd starts for it alone (#5227), which stops when Chrome does. Nobody
// sees that screen, so its window stays where Chrome puts it. With no Xvfb, or one that does
// not start, it says why, and the browser is Chrome for Testing, headless.
//
// The port is not 0: Google Chrome with --remote-debugging-port=0 sets navigator.webdriver
// on every page, where a port of its own leaves it false, as a person's Chrome has it
// (measured on Chrome 157, #5207). A port another program takes between the pick and the
// start is tried again on a new one.
func launchChrome(exe, profile string, env []string, how mode) (*process, error) {
	if canHead(env) {
		return launchChromeOn(exe, profile, env, how, moveBelowScreen)
	}
	x, err := startXvfb(env)
	if err != nil {
		return nil, err
	}
	p, err := launchChromeOn(exe, profile, append(withoutKey(env, "DISPLAY"), "DISPLAY="+x.display), how, func(context.Context) {})
	if err != nil {
		x.stop()
		return nil, err
	}
	p.display = x.display
	go func() {
		// Xvfb ends with Chrome: a stop, an idle stop or a crash.
		<-p.done
		x.stop()
	}()
	return p, nil
}

// launchChromeOn is launchChrome on the display env names, with place for its window.
func launchChromeOn(exe, profile string, env []string, how mode, place func(context.Context)) (*process, error) {
	var err error
	for range 3 {
		var port int
		if port, err = freePort(); err != nil {
			return nil, err
		}
		opts := []chromedp.ExecAllocatorOption{
			chromedp.ExecPath(exe),
			chromedp.UserDataDir(profile),
			chromedp.NoInheritEnv,
			chromedp.Env(env...),
			remote.WebSocket,
			chromedp.Flag("remote-debugging-address", "127.0.0.1"),
			chromedp.Flag("remote-debugging-port", strconv.Itoa(port)),
			chromedp.Flag("disk-cache-size", strconv.Itoa(diskCacheBytes)),
			chromedp.NoFirstRun,
			chromedp.NoDefaultBrowserCheck,
			chromedp.WindowSize(windowWidth, windowHeight),
			// A window that macOS says is covered (by another window, or below the
			// screen with its strip under the Dock) has hidden pages: they run no
			// requestAnimationFrame, so Playwright's clicks wait for ever and a sign-in
			// page stops after its first step (#5230). A page cannot see this flag.
			chromedp.Flag("disable-backgrounding-occluded-windows", true),
		}
		var p *process
		at := func() (string, error) { return listening(port) }
		if p, _, err = run(opts, how, place, at); err == nil {
			return p, nil
		}
	}
	return nil, err
}

// listening is the CDP address of the browser whose debugging port is port, as it says at
// /json/version: Chrome writes no DevToolsActivePort for a port it did not pick.
func listening(port int) (string, error) {
	c := http.Client{Timeout: 5 * time.Second}
	res, err := c.Get("http://127.0.0.1:" + strconv.Itoa(port) + "/json/version")
	if err != nil {
		return "", err
	}
	defer res.Body.Close()
	var v struct {
		WebSocketDebuggerURL string `json:"webSocketDebuggerUrl"`
	}
	if err := json.NewDecoder(res.Body).Decode(&v); err != nil {
		return "", err
	}
	if !strings.HasPrefix(v.WebSocketDebuggerURL, "ws://127.0.0.1:"+strconv.Itoa(port)+"/devtools/browser/") {
		return "", fmt.Errorf("the browser on port %d says no address of its own: %q", port, v.WebSocketDebuggerURL)
	}
	return v.WebSocketDebuggerURL, nil
}

// freePort is a TCP port on 127.0.0.1 that nothing listens on now.
func freePort() (int, error) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port, nil
}

// userAgents is each Chromium's user agent as a headed Chrome, by its executable.
var userAgents sync.Map

// headedUserAgent is a headless Chromium's user agent as a headed Chrome says it. A
// checkout's bot check (Paddle's /pay, #4019) refuses HeadlessChrome; Sec-CH-UA and
// navigator.webdriver say nothing of headless already.
func headedUserAgent(ua string) string {
	return strings.Replace(ua, "HeadlessChrome/", "Chrome/", 1)
}

// startChromium starts Chromium, with userAgent when it is not empty, as how says, and says
// the user agent it has.
func startChromium(exe, profile string, env []string, userAgent string, how mode) (*process, string, error) {
	opts := append(chromedp.DefaultExecAllocatorOptions[:],
		chromedp.ExecPath(exe),
		chromedp.UserDataDir(profile),
		chromedp.NoInheritEnv,
		chromedp.Env(env...),
		remote.WebSocket,
		chromedp.Flag("remote-debugging-address", "127.0.0.1"),
		chromedp.Flag("remote-debugging-port", "0"),
		// The browser is for people's sign-ins, not a test run: it keeps history and
		// does not say it is automated in every page.
		chromedp.Flag("enable-automation", false),
		// The profile's bound (#3727): the HTTP cache stays under this while it runs, and
		// dropCaches empties every cache before the next start.
		chromedp.Flag("disk-cache-size", strconv.Itoa(diskCacheBytes)),
	)
	if userAgent != "" {
		opts = append(opts, chromedp.UserAgent(userAgent))
	}
	if how.headed {
		opts = append(opts, headedOptions...)
	}
	return run(opts, how, func(ctx context.Context) {
		if how.headed {
			moveOffScreen(ctx)
		}
	}, func() (string, error) { return activePort(profile) })
}

// run starts a browser with opts, and, after its first tab opens, places its window. It says
// the user agent it has. With WebAuthn off (how), Blink has none.
func run(opts []chromedp.ExecAllocatorOption, how mode, place func(context.Context), at func() (string, error)) (*process, string, error) {
	if !how.webauthn {
		// The agents' browser has no passkeys of its own (#4084): headless, it has no
		// window for the passkey dialog and no Touch ID. With WebAuthn off in Blink,
		// PublicKeyCredential is not there, so a page does not wait on a dialog nobody
		// sees; agents use a password and TOTP (#3908). Only the flag, no script in pages.
		// A software passkey (#4085) starts it without the flag, and puts an authenticator
		// on the agent's tab, which answers with no dialog (passkey.go).
		opts = append(opts, chromedp.Flag("disable-blink-features", "WebAuth"))
	}
	allocCtx, cancelAlloc := chromedp.NewExecAllocator(context.Background(), opts...)
	ctx, cancelCtx := chromedp.NewContext(allocCtx)
	stop := func() {
		// A graceful close first, so the profile's cookies are written; then the process.
		closing, cancel := context.WithTimeout(ctx, 10*time.Second)
		defer cancel()
		_ = chromedp.Cancel(closing)
		cancelCtx()
		cancelAlloc()
	}
	// The first Run starts the browser and opens its first tab; it does nothing else.
	started := func(context.Context, *chromedp.Target) (chromedp.Void, error) { return chromedp.Void{}, nil }
	if _, err := chromedp.Run(ctx, chromedp.Action[chromedp.Void](started)); err != nil {
		stop()
		return nil, "", err
	}
	b := chromedp.FromContext(ctx).Browser
	if b == nil || b.Process() == nil {
		stop()
		return nil, "", errors.New("chromedp has no browser process")
	}
	place(ctx)
	version, err := chromedp.CallBrowser(ctx, cdpbrowser.GetVersion, cdp.Empty{})
	if err != nil {
		stop()
		return nil, "", err
	}
	endpoint, err := at()
	if err != nil {
		stop()
		return nil, "", err
	}
	return &process{endpoint: endpoint, pid: b.Process().Pid, done: ctx.Done(), stop: stop, headed: how.headed, chrome: how.chrome, webauthn: how.webauthn, store: cdpStore{ctx}}, version.UserAgent, nil
}

// moveOffScreen puts the first tab's window far off every screen. A Mac moves a window that
// opens off-screen back onto it (window-position is not enough there), but not one moved
// after it opened. A window that does not move stays where it is: it says so in the log.
func moveOffScreen(ctx context.Context) {
	w, err := chromedp.Call(ctx, cdpbrowser.GetWindowForTarget, cdpbrowser.GetWindowForTargetParams{})
	if err == nil {
		far := int64(offScreen)
		_, err = chromedp.CallBrowser(ctx, cdpbrowser.SetWindowBounds,
			cdpbrowser.SetWindowBoundsParams{WindowID: w.WindowID, Bounds: &cdpbrowser.Bounds{Left: &far, Top: &far}})
	}
	if err != nil {
		log.Printf("browser: couldn't move the window off-screen: %v", err)
	}
}

// offScreen is where a headed window goes, left and top: beyond any screen.
const offScreen = -32000

// moveBelowScreen puts Google Chrome's window just below the screen (#5207). macOS keeps
// part of a window on a screen: 40 points across when it is moved further left (spike
// #5127: -32000, -32000 became -1240, 33), but only one at x = -(width-1); and down, it
// stops at the bottom of the lowest display or a little above it (a 2560×1440 display
// kept 129 points, -1279, 32000 became -1279, 1311). So the window goes all but one point
// to the left, and down as far as macOS lets it: at most a line one point wide shows, at
// the screen's left edge.
func moveBelowScreen(ctx context.Context) {
	w, err := chromedp.Call(ctx, cdpbrowser.GetWindowForTarget, cdpbrowser.GetWindowForTargetParams{})
	if err == nil {
		left, top := int64(-(windowWidth - 1)), int64(belowScreen)
		_, err = chromedp.CallBrowser(ctx, cdpbrowser.SetWindowBounds,
			cdpbrowser.SetWindowBoundsParams{WindowID: w.WindowID, Bounds: &cdpbrowser.Bounds{Left: &left, Top: &top}})
	}
	if err != nil {
		log.Printf("browser: couldn't move the window below the screen: %v", err)
	}
}

// belowScreen is how far down Google Chrome's window is asked to go: past any display.
const belowScreen = 32000

// windowWidth and windowHeight are a headed window's size.
const (
	windowWidth  = 1280
	windowHeight = 800
)

// headedOptions are a headed Chromium's (#4272): a real window, so a bot check sees no
// headless difference, placed far off every screen, so nobody sees it on this machine's
// screen; people watch it by the screencast, as before. The browser still says it is
// automated: no flag here hides navigator.webdriver or changes the user agent. The
// default options already keep an occluded window painting at full speed.
var headedOptions = []chromedp.ExecAllocatorOption{
	chromedp.Flag("headless", false),
	chromedp.Flag("hide-scrollbars", false),
	chromedp.Flag("window-position", fmt.Sprintf("%d,%d", offScreen, offScreen)),
	chromedp.WindowSize(windowWidth, windowHeight),
}

// activePort is the CDP address Chromium wrote in its profile's DevToolsActivePort:
// the port on the first line, the browser's path on the second.
func activePort(profile string) (string, error) {
	b, err := os.ReadFile(filepath.Join(profile, "DevToolsActivePort"))
	if err != nil {
		return "", fmt.Errorf("Chromium wrote no DevToolsActivePort: %w", err)
	}
	lines := strings.Split(strings.TrimSpace(string(b)), "\n")
	if len(lines) < 2 {
		return "", fmt.Errorf("Chromium's DevToolsActivePort is not whole: %q", string(b))
	}
	port, err := strconv.Atoi(strings.TrimSpace(lines[0]))
	if err != nil || port <= 0 {
		return "", fmt.Errorf("Chromium's DevToolsActivePort has no port: %q", lines[0])
	}
	path := strings.TrimSpace(lines[1])
	if !strings.HasPrefix(path, "/devtools/browser/") {
		return "", fmt.Errorf("Chromium's DevToolsActivePort has no browser path: %q", path)
	}
	return "ws://127.0.0.1:" + strconv.Itoa(port) + path, nil
}

// diskCacheBytes is the most the HTTP cache holds while Chromium runs.
const diskCacheBytes = 64 << 20

// cacheDirs are the profile's caches, relative to it: what Chromium makes again, and
// what grows with each site an agent opens. Sign-ins (cookies, Local Storage,
// IndexedDB) are not in them; Settings ▸ Browser clears those by site.
var cacheDirs = []string{
	"Default/Cache",
	"Default/Code Cache",
	"Default/GPUCache",
	"Default/DawnGraphiteCache",
	"Default/DawnWebGPUCache",
	"Default/Service Worker/CacheStorage",
	"Default/Service Worker/ScriptCache",
	"GrShaderCache",
	"GraphiteDawnCache",
	"ShaderCache",
	"component_crx_cache",
}

// dropCaches empties the profile's caches before Chromium starts, so the profile keeps
// only its sign-ins from one start to the next (#3727). Chromium is not running then.
func dropCaches(profile string) {
	for _, dir := range cacheDirs {
		if err := os.RemoveAll(filepath.Join(profile, filepath.FromSlash(dir))); err != nil {
			log.Printf("browser: couldn't empty %s: %v", dir, err)
		}
	}
}

func (m *Machine) pidFile() string { return filepath.Join(filepath.Dir(m.Profile), "chromium.pid") }

// endLeftover ends a Chromium that a host which stopped without closing it left on a
// profile: a second one on the same profile hands its window to the first and exits.
// Chromium names its holder in SingletonLock ("<host>-<pid>"); only that pid, and only
// when it is the one this machine wrote down, is ended. Either profile (Chrome for
// Testing's or Google Chrome's) can hold it.
func (m *Machine) endLeftover() {
	b, err := os.ReadFile(m.pidFile())
	if err != nil {
		return
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(b)))
	os.Remove(m.pidFile())
	if err != nil || pid <= 1 {
		return
	}
	held := func(profile string) bool {
		lock, err := os.Readlink(filepath.Join(profile, "SingletonLock"))
		return err == nil && strings.HasSuffix(lock, "-"+strconv.Itoa(pid))
	}
	if !held(m.Profile) && !held(m.ChromeProfile()) {
		return
	}
	if p, err := os.FindProcess(pid); err == nil && p.Signal(syscall.Signal(0)) == nil {
		log.Printf("browser: ending the Chromium (pid %d) a stopped host left running", pid)
		_ = p.Signal(syscall.SIGTERM)
		for i := 0; i < 50 && p.Signal(syscall.Signal(0)) == nil; i++ {
			time.Sleep(100 * time.Millisecond)
		}
		_ = p.Signal(syscall.SIGKILL)
	}
}

func executable(path string) bool {
	fi, err := os.Stat(path)
	return err == nil && !fi.IsDir() && fi.Mode()&0o111 != 0
}

func withoutKey(env []string, key string) []string {
	out := make([]string, 0, len(env)+1)
	for _, kv := range env {
		if !strings.HasPrefix(kv, key+"=") {
			out = append(out, kv)
		}
	}
	return out
}

func lastLine(out string) string {
	lines := strings.Split(strings.TrimSpace(out), "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		if l := strings.TrimSpace(lines[i]); l != "" {
			return l
		}
	}
	return "it said nothing"
}
