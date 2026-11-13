package agentsd

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
	"github.com/creack/pty"
)

// Signing Claude or Codex in on a machine with no browser (#3349), from a client: the
// runtime's own sign-in for a headless machine runs here, and its link and code go to the
// client, which opens them in a browser of its own.
//   - Claude: `claude setup-token`, in a terminal (it is an Ink app). It gives a link; the
//     page there gives a code, which is typed back; the token it then prints is kept in the
//     root and given to Claude as CLAUDE_CODE_OAUTH_TOKEN.
//   - Codex: `codex login --device-auth`. It gives a link and a code to type there, and keeps
//     the sign-in in its own auth.json when the person has.
//   - An API key, for either: kept in the root for Claude, given to `codex login
//     --with-api-key` for Codex.
//
// A Mac signs its runtimes in in Runtimes, and lends servers its sign-in (056): none of this
// is served there.

// headlessSignInTime is how long a sign-in waits for the person before it is stopped.
const headlessSignInTime = 15 * time.Minute

// codexFinishWait is how long Done waits for Codex to see the code typed; a test shortens it.
var codexFinishWait = 20 * time.Second

// headlessRuntimes are the runtimes a client signs in on a machine this way.
var headlessRuntimes = map[string]bool{"claude": true, "codex": true}

type headlessSignInState struct {
	headlessMu sync.Mutex
	headless   map[string]*headlessSignIn
}

// headlessSignIn is one runtime's sign-in, running.
type headlessSignIn struct {
	id, runtimeID, url string
	cmd                *exec.Cmd
	tty                *os.File // Claude's terminal; nil for Codex
	copied             chan struct{}
	out                *signInOutput
	done               chan struct{}
	waitErr            error
	stop               context.CancelFunc
}

// signInOutput is what a sign-in has printed, the last 64 KiB of it.
type signInOutput struct {
	mu sync.Mutex
	b  []byte
}

func (o *signInOutput) Write(p []byte) (int, error) {
	o.mu.Lock()
	defer o.mu.Unlock()
	o.b = append(o.b, p...)
	if over := len(o.b) - 64<<10; over > 0 {
		o.b = o.b[over:]
	}
	return len(p), nil
}

// text is the output with a terminal's escapes taken out. A link in an OSC 8 escape keeps
// its address, which ends at the escape's BEL or ESC.
func (o *signInOutput) text() string {
	o.mu.Lock()
	defer o.mu.Unlock()
	// Ink moves the cursor between words: each move is a space.
	return terminalEscape.ReplaceAllString(cursorMove.ReplaceAllString(string(o.b), " "), "")
}

var (
	terminalEscape = regexp.MustCompile(`\x1b\[[0-9;?>]*[ -/]*[@-~]`)
	cursorMove     = regexp.MustCompile(`\x1b\[[0-9]*[CG]`)
	signInError    = regexp.MustCompile(`(?i)[^\r\n]*\berror:[^\r\n]*`)
	signInLink     = regexp.MustCompile(`https://[^\s\x07\x1b"'<>]+`)
	deviceCode     = regexp.MustCompile(`\b[A-Z0-9]{4,}-[A-Z0-9]{4,}\b`)
	claudeToken    = regexp.MustCompile(`sk-ant-oat[0-9A-Za-z_-]+`)
)

func (d *Daemon) registerHeadlessSignIn() {
	On(d, wire.CallRuntimesSignInStart, func(ctx context.Context, c *Client, r wire.RuntimeRequest) (wire.RuntimeSignInStep, error) {
		return d.startHeadlessSignIn(ctx, r.RuntimeID)
	})
	On(d, wire.CallRuntimesSignInFinish, func(ctx context.Context, c *Client, r wire.RuntimeSignInFinish) (wire.RuntimeStatus, error) {
		return d.finishHeadlessSignIn(ctx, r)
	})
	On(d, wire.CallRuntimesSignInKey, func(ctx context.Context, c *Client, r wire.RuntimeSignInKey) (wire.RuntimeStatus, error) {
		return d.signInWithKey(ctx, r.RuntimeID, strings.TrimSpace(r.Key))
	})
}

// headlessRuntime is the runtime a client may sign in here, or why not.
func headlessRuntime(id string) (*runtimeDef, error) {
	if macToolsHome != "" {
		return nil, &Error{Code: CodeNotSupported, Message: "Sign this Mac's runtimes in on the Mac, in Runtimes."}
	}
	rt := runtimeByID(id)
	if rt == nil {
		return nil, &Error{Code: CodeRuntimeNotFound, Message: "There is no runtime called " + id + "."}
	}
	if !headlessRuntimes[id] {
		return nil, &Error{Code: CodeNotSupported, Message: rt.Name + " signs in on this machine from a terminal."}
	}
	return rt, nil
}

func (d *Daemon) startHeadlessSignIn(ctx context.Context, runtimeID string) (wire.RuntimeSignInStep, error) {
	rt, err := headlessRuntime(runtimeID)
	if err != nil {
		return wire.RuntimeSignInStep{}, err
	}
	if err := noticeRefusal(d.orgPolicy(), runtimeID); err != nil {
		return wire.RuntimeSignInStep{}, err
	}
	env := d.signInEnvironment(rt)
	var args []string
	if runtimeID == "claude" {
		args = []string{"setup-token"}
	} else {
		args = []string{"login", "--device-auth"}
	}
	cmd, err := runtimeTool(runtimeID, env, args...)
	if err != nil {
		return wire.RuntimeSignInStep{}, err
	}
	d.stopHeadlessFor(runtimeID)

	life, stop := context.WithTimeout(d.ctx, headlessSignInTime)
	s := &headlessSignIn{id: newSignInID(), runtimeID: runtimeID, cmd: cmd, out: &signInOutput{}, done: make(chan struct{}), stop: stop}
	if runtimeID == "claude" {
		// Wide, so Ink does not break the link or the token over lines.
		s.tty, err = pty.StartWithSize(cmd, &pty.Winsize{Rows: 50, Cols: 2000})
		if err == nil {
			copied := make(chan struct{})
			s.copied = copied
			safe.Go("claude sign-in output", func() { _, _ = io.Copy(s.out, s.tty); close(copied) })
		}
	} else {
		cmd.Stdout, cmd.Stderr = s.out, s.out
		err = cmd.Start()
	}
	if err != nil {
		stop()
		return wire.RuntimeSignInStep{}, &Error{Code: CodeRuntimeWillNotStart, Message: rt.Name + "'s sign-in did not start: " + err.Error()}
	}
	safe.Go("runtime sign-in", func() {
		err := cmd.Wait()
		// What it printed last is read from its terminal after it has gone.
		if s.copied != nil {
			select {
			case <-s.copied:
			case <-time.After(2 * time.Second):
			}
		}
		s.waitErr = err
		close(s.done)
	})
	safe.Go("runtime sign-in time", func() {
		<-life.Done()
		s.end()
		d.dropHeadless(s)
	})
	d.headlessMu.Lock()
	if d.headless == nil {
		d.headless = map[string]*headlessSignIn{}
	}
	d.headless[s.id] = s
	d.headlessMu.Unlock()

	// The link comes in a second or two; Codex's code is printed under it.
	step := wire.RuntimeSignInStep{SignInID: s.id, RuntimeID: runtimeID, WantsCode: runtimeID == "claude"}
	found := s.await(ctx, 60*time.Second, func(text string) bool {
		link := signInLink.FindString(text)
		// Claude's is its authorize page, whatever else it links to.
		for _, l := range signInLink.FindAllString(text, -1) {
			if strings.Contains(l, "authorize") {
				link = l
			}
		}
		if link == "" {
			return false
		}
		if runtimeID == "codex" {
			code := deviceCode.FindString(text[strings.Index(text, link)+len(link):])
			if code == "" {
				return false
			}
			step.UserCode = &code
		}
		s.url, step.URL = link, wire.URL(link)
		return true
	})
	if !found {
		s.end()
		d.dropHeadless(s)
		return wire.RuntimeSignInStep{}, &Error{Code: CodeServer, Message: rt.Name + " gave no link to sign in with" + lastLine(s.out.text())}
	}
	return step, nil
}

func (d *Daemon) finishHeadlessSignIn(ctx context.Context, r wire.RuntimeSignInFinish) (wire.RuntimeStatus, error) {
	d.headlessMu.Lock()
	s := d.headless[r.SignInID]
	d.headlessMu.Unlock()
	if s == nil {
		return wire.RuntimeStatus{}, Invalid("That sign-in has stopped. Start it again.")
	}
	rt := runtimeByID(s.runtimeID)
	if r.Cancel != nil && *r.Cancel {
		s.end()
		d.dropHeadless(s)
		return d.statusOf(rt), nil
	}
	if s.runtimeID == "claude" {
		code := ""
		if r.Code != nil {
			code = strings.TrimSpace(*r.Code)
		}
		if code == "" {
			return wire.RuntimeStatus{}, Invalid("Paste the code the sign-in page gave.")
		}
		before := len(s.out.text())
		// The code, then Enter by itself once Claude shows the code (#5202). Ink takes a
		// long write as a paste and drops an Enter in it: with code+"\r" in one write, a
		// real code (92 characters) waited at the prompt until the sign-in ran out.
		_, err := io.WriteString(s.tty, code)
		if err == nil {
			s.await(ctx, 2*time.Second, func(text string) bool { return len(text) > before })
			_, err = io.WriteString(s.tty, "\r")
		}
		if err != nil {
			d.dropHeadless(s)
			return wire.RuntimeStatus{}, &Error{Code: CodeServer, Message: "Claude's sign-in has stopped. Start it again."}
		}
		var token, refused string
		s.await(ctx, 90*time.Second, func(text string) bool {
			token = claudeToken.FindString(text)
			// A code it does not take is said, and then it waits for Enter to start again.
			refused = signInError.FindString(text[min(before, len(text)):])
			return token != "" || refused != ""
		})
		if token == "" && refused != "" {
			s.end()
			d.dropHeadless(s)
			return wire.RuntimeStatus{}, &Error{Code: wire.FailureNeedsSignIn, Message: "Claude did not take that code: " +
				strings.TrimSpace(refused)}
		}
		if token == "" {
			select {
			case <-s.done:
				d.dropHeadless(s)
				return wire.RuntimeStatus{}, &Error{Code: wire.FailureNeedsSignIn, Message: "Claude did not sign in" + lastLine(s.out.text()[min(before, len(s.out.text())):])}
			default:
				return wire.RuntimeStatus{}, &Error{Code: wire.FailureNeedsSignIn, Message: "Claude did not take that code" + lastLine(s.out.text()[min(before, len(s.out.text())):])}
			}
		}
		s.end()
		d.dropHeadless(s)
		if err := d.keepClaudeSignIn("CLAUDE_CODE_OAUTH_TOKEN", token); err != nil {
			return wire.RuntimeStatus{}, err
		}
		return d.signedInHere(rt), nil
	}
	// Codex has been waiting for the person to type the code; it ends when they have.
	select {
	case <-s.done:
	case <-time.After(codexFinishWait):
		return wire.RuntimeStatus{}, &Error{Code: wire.FailureNeedsSignIn,
			Message: "Codex is still waiting. Type the code at " + s.url + ", then choose Done again."}
	case <-ctx.Done():
		return wire.RuntimeStatus{}, ctx.Err()
	}
	d.dropHeadless(s)
	if s.waitErr != nil || !ownCodexSignIn() {
		return wire.RuntimeStatus{}, &Error{Code: wire.FailureNeedsSignIn, Message: "Codex did not sign in" + lastLine(s.out.text())}
	}
	return d.signedInHere(rt), nil
}

// signInWithKey is runtimes/signInKey: an API key for Claude (or a token from `claude
// setup-token` on another computer), or for Codex.
func (d *Daemon) signInWithKey(ctx context.Context, runtimeID, key string) (wire.RuntimeStatus, error) {
	rt, err := headlessRuntime(runtimeID)
	if err != nil {
		return wire.RuntimeStatus{}, err
	}
	if err := noticeRefusal(d.orgPolicy(), runtimeID); err != nil {
		return wire.RuntimeStatus{}, err
	}
	if key == "" || strings.ContainsAny(key, " \t\r\n") {
		return wire.RuntimeStatus{}, Invalid("Paste the key, with nothing around it.")
	}
	if runtimeID == "claude" {
		variable := "ANTHROPIC_API_KEY"
		if strings.HasPrefix(key, "sk-ant-oat") {
			variable = "CLAUDE_CODE_OAUTH_TOKEN"
		}
		if err := d.keepClaudeSignIn(variable, key); err != nil {
			return wire.RuntimeStatus{}, err
		}
		return d.signedInHere(rt), nil
	}
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	cmd, err := runtimeTool(runtimeID, d.signInEnvironment(rt), "login", "--with-api-key")
	if err != nil {
		return wire.RuntimeStatus{}, err
	}
	cmd.Stdin = strings.NewReader(key + "\n")
	out := &signInOutput{}
	cmd.Stdout, cmd.Stderr = out, out
	if err := cmd.Start(); err != nil {
		return wire.RuntimeStatus{}, &Error{Code: CodeRuntimeWillNotStart, Message: "Codex's sign-in did not start: " + err.Error()}
	}
	stop := context.AfterFunc(ctx, func() { _ = cmd.Process.Kill() })
	defer stop()
	if err := cmd.Wait(); err != nil {
		return wire.RuntimeStatus{}, &Error{Code: wire.FailureNeedsSignIn, Message: "Codex did not take that key" + lastLine(out.text())}
	}
	return d.signedInHere(rt), nil
}

// signedInHere is the runtime's status once it has signed in, told to every client.
func (d *Daemon) signedInHere(rt *runtimeDef) wire.RuntimeStatus {
	d.updateAccount(rt.ID, func(a *wire.RuntimeAccount) { a.State, a.CheckedAt = wire.RuntimeAccountStateReady, now() })
	s := d.statusOf(rt)
	Broadcast(d, wire.NotifyRuntimeChanged, s)
	return s
}

// await waits until test says yes to the output, or the sign-in ends, or the time is up.
func (s *headlessSignIn) await(ctx context.Context, limit time.Duration, test func(string) bool) bool {
	deadline := time.Now().Add(limit)
	for {
		if test(s.out.text()) {
			return true
		}
		select {
		case <-s.done:
			// What it printed last may have come with its end.
			return test(s.out.text())
		case <-ctx.Done():
			return false
		case <-time.After(100 * time.Millisecond):
		}
		if time.Now().After(deadline) {
			return false
		}
	}
}

// end stops the sign-in's process, if it still runs.
func (s *headlessSignIn) end() {
	s.stop()
	select {
	case <-s.done:
	default:
		if s.cmd.Process != nil {
			_ = s.cmd.Process.Kill()
		}
	}
	if s.tty != nil {
		_ = s.tty.Close()
	}
}

func (d *Daemon) dropHeadless(s *headlessSignIn) {
	d.headlessMu.Lock()
	if d.headless[s.id] == s {
		delete(d.headless, s.id)
	}
	d.headlessMu.Unlock()
}

// stopHeadlessFor stops a runtime's sign-in that is running: a new one takes its place.
func (d *Daemon) stopHeadlessFor(runtimeID string) {
	d.headlessMu.Lock()
	var old []*headlessSignIn
	for _, s := range d.headless {
		if s.runtimeID == runtimeID {
			old = append(old, s)
		}
	}
	d.headlessMu.Unlock()
	for _, s := range old {
		s.end()
		d.dropHeadless(s)
	}
}

func newSignInID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// lastLine is ": " and the last line a sign-in printed, or "." when it printed nothing.
func lastLine(text string) string {
	lines := strings.Split(strings.ReplaceAll(text, "\r", "\n"), "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		if l := strings.TrimSpace(terminalOSC.ReplaceAllString(lines[i], "")); l != "" {
			if len(l) > 200 {
				l = l[:200] + "…"
			}
			return ": " + l
		}
	}
	return "."
}

var terminalOSC = regexp.MustCompile(`\x1b\][^\x07\x1b]*(\x07|\x1b\\)?|[\x00-\x08\x0b-\x1f\x7f]`)

// signInEnvironment is the runtime's launch environment without the sign-in a sign-in
// replaces, and with a terminal for Claude's.
func (d *Daemon) signInEnvironment(rt *runtimeDef) []string {
	env := without(loginEnvironment(),
		"CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "OPENAI_API_KEY", "TERM", "BROWSER")
	return append(env, "TERM=xterm-256color", "BROWSER=true")
}

// runtimeTool is the runtime's own command line on this machine: the one its toolset
// carries (Claude's native binary in the agent SDK, Codex's codex.js run by the toolset's
// Node), else the person's own on PATH.
func runtimeTool(runtimeID string, env []string, args ...string) (*exec.Cmd, error) {
	folder := filepath.Join(toolsetFolder(runtimeID), "current")
	modules := filepath.Join(folder, "lib", "node_modules")
	switch runtimeID {
	case "claude":
		if bin := findInModules(modules, func(path string, d fs.DirEntry) bool {
			return d.Name() == "claude" && strings.HasPrefix(filepath.Base(filepath.Dir(path)), "claude-agent-sdk-linux-")
		}); bin != "" {
			return commandWith(env, bin, args...), nil
		}
	case "codex":
		if script := findInModules(modules, func(path string, d fs.DirEntry) bool {
			return d.Name() == "codex.js" && strings.HasSuffix(filepath.Dir(path), filepath.Join("@openai", "codex", "bin"))
		}); script != "" {
			return commandWith(env, filepath.Join(folder, "node", "bin", "node"), append([]string{script}, args...)...), nil
		}
	}
	if path := onPath(env, runtimeID); path != "" {
		return commandWith(env, path, args...), nil
	}
	return nil, &Error{Code: CodeRuntimeNotFound, Message: runtimeByID(runtimeID).Name + "'s own command line is not on this machine, so it cannot sign in here. Install " +
		runtimeByID(runtimeID).Name + " on it first."}
}

// hasVariable says whether env sets any of names to something.
func hasVariable(env []string, names ...string) bool {
	for _, kv := range env {
		for _, n := range names {
			if strings.HasPrefix(kv, n+"=") && len(kv) > len(n)+1 {
				return true
			}
		}
	}
	return false
}

func commandWith(env []string, name string, args ...string) *exec.Cmd {
	cmd := exec.Command(name, args...)
	cmd.Env = env
	if home, err := os.UserHomeDir(); err == nil {
		cmd.Dir = home
	}
	return cmd
}

// findInModules is the first file under dir that match says is the one, and can be run
// or read; "" with none.
func findInModules(dir string, match func(string, fs.DirEntry) bool) string {
	found := ""
	_ = filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil || found != "" {
			return fs.SkipDir
		}
		if !d.IsDir() && match(path, d) {
			found = path
			return fs.SkipAll
		}
		return nil
	})
	return found
}

// onPath is name in env's PATH, as a shell finds it; "" when it is not there.
func onPath(env []string, name string) string {
	for _, kv := range env {
		if dirs, ok := strings.CutPrefix(kv, "PATH="); ok {
			for _, dir := range strings.Split(dirs, ":") {
				p := filepath.Join(dir, name)
				if fi, err := os.Stat(p); dir != "" && err == nil && !fi.IsDir() && fi.Mode()&0o111 != 0 {
					return p
				}
			}
		}
	}
	return ""
}

// claudeSignInFile is where a sign-in made here keeps Claude's token or key: one line,
// VARIABLE=value, read only by this account.
func (d *Daemon) claudeSignInFile() string {
	return filepath.Join(d.Store.Loc.Root, "runtimes", "claude-sign-in")
}

func (d *Daemon) keepClaudeSignIn(variable, value string) error {
	file := d.claudeSignInFile()
	if err := os.MkdirAll(filepath.Dir(file), 0o700); err != nil {
		return err
	}
	return os.WriteFile(file, []byte(variable+"="+value+"\n"), 0o600)
}

// storedClaudeSignIn is the VARIABLE=value a sign-in made here kept, or "".
func (d *Daemon) storedClaudeSignIn() string {
	b, err := os.ReadFile(d.claudeSignInFile())
	if err != nil {
		return ""
	}
	kv := strings.TrimSpace(string(b))
	if name, value, ok := strings.Cut(kv, "="); !ok || value == "" || (name != "CLAUDE_CODE_OAUTH_TOKEN" && name != "ANTHROPIC_API_KEY") {
		return ""
	}
	return kv
}

// noteSignIn says on a server's Claude or Codex whether it is signed in on the machine.
func (d *Daemon) noteSignIn(s *wire.RuntimeStatus) {
	if macToolsHome != "" || s.Availability.Available == nil || !headlessRuntimes[s.Runtime.ID] {
		return
	}
	var in wire.RuntimeSignIn
	switch s.Runtime.ID {
	case "claude":
		in.SignedIn = ownClaudeSignIn() || d.storedClaudeSignIn() != ""
	case "codex":
		in.SignedIn = ownCodexSignIn()
	}
	if d.relayFor(s.Runtime.ID) != nil {
		relayed := true
		in.Relayed = &relayed
	}
	s.SignIn = &in
}
