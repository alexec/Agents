// Package browser is the machine's browser (#3533, spike #3527): one Chromium per
// machine, which agentsd downloads on first use, starts with no window and a kept profile,
// listening on 127.0.0.1 only, and stops when nobody has used it for a while. Agents drive
// it through Playwright (#3534, agentsd's browsertools.go); clients watch it by a screencast
// (screencast.go, #3528).
//
// The Chromium is Playwright's own build, installed by Playwright's own installer
// (`playwright-core install chromium`) from the pinned @playwright/mcp toolset, so the
// browser and the tools that drive it always match. chromedp starts it and speaks CDP.
package browser

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
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
	// Profile is the kept profile: the sign-ins that agents on this machine share.
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

	// launch starts Chromium and says how to reach it; a test gives its own.
	launch func(exe, profile string, env []string) (*process, error)
	// locate is the Chromium that the toolset installed; a test gives its own.
	locate func(t Toolset, env []string) (string, error)

	mu       sync.Mutex
	running  *process
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
	// store is its cookies, for Settings ▸ Browser (sites.go).
	store cookieStore
}

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
	}
}

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
	exe, err := m.locate(t, env)
	if err != nil || !executable(exe) {
		progress("Downloading Chromium")
		if err := m.installChromium(t, env); err != nil {
			return "", err
		}
		if exe, err = m.locate(t, env); err != nil {
			return "", err
		}
		if !executable(exe) {
			return "", fmt.Errorf("Playwright installed no Chromium at %s", exe)
		}
	}
	if err := os.MkdirAll(m.Profile, 0o700); err != nil {
		return "", err
	}
	m.endLeftover()
	dropCaches(m.Profile)
	progress("Starting the browser")
	p, err := m.launch(exe, m.Profile, env)
	if err != nil {
		return "", fmt.Errorf("the browser did not start: %w", err)
	}
	if err := os.WriteFile(m.pidFile(), []byte(strconv.Itoa(p.pid)), 0o600); err != nil {
		log.Printf("browser: couldn't write down Chromium's pid: %v", err)
	}
	m.running = p
	m.startLoop()
	m.changed(true)
	log.Printf("browser: Chromium (pid %d) started with the profile in %s", p.pid, m.Profile)
	return p.endpoint, nil
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
// HeadlessChrome (#4060). It has no WebAuthn, as it cannot do passkeys (#4084).
func launchChromium(exe, profile string, env []string) (*process, error) {
	if ua, ok := userAgents.Load(exe); ok {
		p, _, err := startChromium(exe, profile, env, ua.(string))
		return p, err
	}
	p, ua, err := startChromium(exe, profile, env, "")
	if err != nil || !strings.Contains(ua, "HeadlessChrome/") {
		return p, err
	}
	// The first start of this Chromium learns its user agent; the next starts use it.
	headed := headedUserAgent(ua)
	userAgents.Store(exe, headed)
	p.stop()
	<-p.done
	p, _, err = startChromium(exe, profile, env, headed)
	return p, err
}

// userAgents is each Chromium's user agent as a headed Chrome, by its executable.
var userAgents sync.Map

// headedUserAgent is a headless Chromium's user agent as a headed Chrome says it. A
// checkout's bot check (Paddle's /pay, #4019) refuses HeadlessChrome; Sec-CH-UA and
// navigator.webdriver say nothing of headless already.
func headedUserAgent(ua string) string {
	return strings.Replace(ua, "HeadlessChrome/", "Chrome/", 1)
}

// startChromium starts Chromium, with userAgent when it is not empty, and says the user
// agent it has.
func startChromium(exe, profile string, env []string, userAgent string) (*process, string, error) {
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
		// The agents' browser has no passkeys (#4084): headless, it has no window for the
		// passkey dialog and no Touch ID. With WebAuthn off in Blink, PublicKeyCredential
		// is not there, so a page does not wait on a dialog nobody sees; agents use a
		// password and TOTP (#3908). Only the flag, no script in pages.
		chromedp.Flag("disable-blink-features", "WebAuth"),
	)
	if userAgent != "" {
		opts = append(opts, chromedp.UserAgent(userAgent))
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
	version, err := chromedp.CallBrowser(ctx, cdpbrowser.GetVersion, cdp.Empty{})
	if err != nil {
		stop()
		return nil, "", err
	}
	endpoint, err := activePort(profile)
	if err != nil {
		stop()
		return nil, "", err
	}
	return &process{endpoint: endpoint, pid: b.Process().Pid, done: ctx.Done(), stop: stop, store: cdpStore{ctx}}, version.UserAgent, nil
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

// endLeftover ends a Chromium that a host which stopped without closing it left on the
// profile: a second one on the same profile hands its window to the first and exits.
// Chromium names its holder in SingletonLock ("<host>-<pid>"); only that pid, and only
// when it is the one this machine wrote down, is ended.
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
	lock, err := os.Readlink(filepath.Join(m.Profile, "SingletonLock"))
	if err != nil || !strings.HasSuffix(lock, "-"+strconv.Itoa(pid)) {
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
