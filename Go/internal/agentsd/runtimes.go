package agentsd

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/acp"
	"github.com/alexec/agents/Go/wire"
)

// runtimeDef is a RuntimeCatalog entry, and what RuntimeLaunch passes it.
type runtimeDef struct {
	wire.Runtime
	// passed is the variables, beyond the allow-list, this runtime is given (a trailing _
	// is a prefix).
	passed []string
}

func runtime(id, name, exe string, args []string, page string, appCopyOnly bool, passed ...string) runtimeDef {
	if args == nil {
		args = []string{}
	}
	return runtimeDef{Runtime: wire.Runtime{ID: id, Name: name, Executable: exe, Arguments: args,
		InstallPage: wire.URL(page), UsesAppCopyOnly: appCopyOnly}, passed: passed}
}

// catalog is RuntimeCatalog.builtIn, sorted by name. A server is given no installer
// (install is nil there).
var catalog = func() []runtimeDef {
	c := []runtimeDef{
		runtime("claude", "Claude", "npx", []string{"-y", "@agentclientprotocol/claude-agent-acp"}, "https://code.claude.com/docs/en/setup", false, "ANTHROPIC_", "CLAUDE_CONFIG_DIR"),
		runtime("grok", "Grok", "grok", []string{"--permission-mode", "default", "agent", "stdio"}, "https://x.ai/cli", false, "GROK_", "XAI_"),
		runtime("copilot", "Copilot", "copilot", []string{"--acp"}, "https://docs.github.com/en/copilot/how-tos/set-up/install-copilot-cli", false, "COPILOT_", "GH_TOKEN", "GITHUB_TOKEN"),
		runtime("cursor", "Cursor", "cursor-agent", []string{"acp"}, "https://cursor.com/docs/cli/installation", false, "CURSOR_"),
		runtime("codex", "Codex", "codex-acp", nil, "https://github.com/agentclientprotocol/codex-acp", true, "OPENAI_", "CODEX_HOME"),
		runtime("gemini", "Gemini", "gemini", []string{"--acp", "--skip-trust"}, "https://github.com/google-gemini/gemini-cli", true, "GEMINI_", "GOOGLE_"),
		runtime("antigravity", "Antigravity", "agy_acp_server", nil, "https://antigravity.google/docs/ide/extensions", true),
		runtime("opencode", "OpenCode", "opencode", []string{"acp"}, "https://opencode.ai/docs/", true, "OPENCODE_"),
	}
	sort.Slice(c, func(i, j int) bool { return c[i].Name < c[j].Name })
	return c
}()

func runtimeByID(id string) *runtimeDef {
	for i := range catalog {
		if catalog[i].ID == id {
			return &catalog[i]
		}
	}
	return nil
}

// toolsetFolder is Toolset.serverFolder: ~/.agents-server/tools/<id>.
func toolsetFolder(id string) string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".agents-server", "tools", id)
}

// locate is RuntimeDiscovery.locate on a server: the installed toolset's shim, then (for
// a runtime that may be the person's own copy) the login shell's PATH.
func (r *runtimeDef) locate() (path string, args []string, lookedIn []string) {
	cur := filepath.Join(toolsetFolder(r.ID), "current")
	if _, err := os.Stat(filepath.Join(cur, "ok")); err == nil {
		// bin/<executable>, which runs the pinned package with the toolset's own Node
		// whatever it is passed (Toolset.shimName).
		shim := filepath.Join(cur, "bin", r.Executable)
		if fi, err := os.Stat(shim); err == nil && fi.Mode()&0o111 != 0 {
			return shim, r.Arguments, nil
		}
	}
	if r.UsesAppCopyOnly {
		return "", nil, []string{}
	}
	if strings.Contains(r.Executable, "/") {
		if fi, err := os.Stat(r.Executable); err == nil && fi.Mode()&0o111 != 0 {
			return r.Executable, r.Arguments, nil
		}
		return "", nil, []string{r.Executable}
	}
	dirs := searchPaths()
	for _, d := range dirs {
		p := filepath.Join(d, r.Executable)
		if fi, err := os.Stat(p); err == nil && !fi.IsDir() && fi.Mode()&0o111 != 0 {
			return p, r.Arguments, nil
		}
	}
	return "", nil, dirs
}

// searchPaths is LoginShellPath.directories: the login shell's PATH, then the usual places.
func searchPaths() []string {
	var dirs []string
	shell := os.Getenv("SHELL")
	if shell == "" {
		shell = "/bin/sh"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if out, err := exec.CommandContext(ctx, shell, "-lc", `printf %s "$PATH"`).Output(); err == nil {
		dirs = strings.Split(string(out), ":")
	}
	home, _ := os.UserHomeDir()
	dirs = append(dirs, "/opt/homebrew/bin", "/usr/local/bin", filepath.Join(home, ".local/bin"), filepath.Join(home, ".grok/bin"),
		filepath.Join(home, ".bun/bin"), "/usr/bin", "/bin", "/usr/sbin", "/sbin")
	seen := map[string]bool{}
	var out []string
	for _, d := range dirs {
		if d != "" && !seen[d] {
			seen[d] = true
			out = append(out, d)
		}
	}
	return out
}

func (d *Daemon) runtimeStatuses() []wire.RuntimeStatus {
	out := []wire.RuntimeStatus{}
	for i := range catalog {
		r := &catalog[i]
		path, _, looked := r.locate()
		s := wire.RuntimeStatus{Runtime: r.Runtime, CheckedAt: now()}
		if path != "" {
			s.Availability.Available = &wire.RuntimeAvailabilityAvailable{Path: path}
		} else {
			if looked == nil {
				looked = []string{}
			}
			s.Availability.Missing = &wire.RuntimeAvailabilityMissing{LookedIn: looked}
		}
		out = append(out, s)
	}
	return out
}

// allowed is RuntimeEnvironment.allowed: a runtime gets these and its own, never this
// process's whole environment. A trailing _ is a prefix.
var allowed = []string{"PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "TZ", "LANG", "LANGUAGE", "LC_", "TERM",
	"COLORTERM", "XDG_", "EDITOR", "VISUAL", "PAGER", "SSH_AUTH_SOCK", "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "ALL_PROXY",
	"http_proxy", "https_proxy", "no_proxy", "all_proxy", "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS",
	"REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE", "JAVA_HOME", "GOPATH", "GOROOT", "CARGO_HOME", "RUSTUP_HOME", "PYENV_ROOT",
	"NVM_DIR", "AGENTS_"}

func environment(r *runtimeDef, from []string) []string {
	names := append(append([]string{}, allowed...), r.passed...)
	var env []string
	for _, kv := range from {
		name, _, _ := strings.Cut(kv, "=")
		for _, a := range names {
			if name == a || strings.HasSuffix(a, "_") && strings.HasPrefix(name, a) {
				env = append(env, kv)
				break
			}
		}
	}
	return env
}

// locateFor finds a runtime; a test sets it to start a fake one.
var locateFor = func(r *runtimeDef) (string, []string, []string) { return r.locate() }

func (d *Daemon) launchFor(r *runtimeDef, dir string) (acp.Launch, error) {
	path, args, looked := locateFor(r)
	if path == "" {
		return acp.Launch{}, &Error{Code: CodeRuntimeNotFound, Message: r.Name + " is not installed on this host (looked in " + strings.Join(looked, ", ") + ")"}
	}
	env := environment(r, os.Environ())
	// The shipped MCP servers sit beside agentsd (~/.agents-server/bin), last on PATH.
	if self, err := os.Executable(); err == nil {
		env = appendPath(env, filepath.Dir(self))
	}
	root := d.Store.Loc.Root
	switch r.ID {
	case "claude":
		if rl := d.relayFor("claude"); rl != nil {
			env = without(env, "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX",
				"ANTHROPIC_BASE_URL", "CLAUDE_CODE_OAUTH_TOKEN", "NODE_EXTRA_CA_CERTS")
			env = append(env, "ANTHROPIC_BASE_URL=https://127.0.0.1:"+strconv.Itoa(rl.port), "CLAUDE_CODE_OAUTH_TOKEN="+rl.standIn,
				"NODE_EXTRA_CA_CERTS="+rl.caFile)
		}
	case "codex":
		if rl := d.relayFor("codex"); rl != nil {
			env = without(env, "OPENAI_API_KEY", "CODEX_HOME", "CODEX_CA_CERTIFICATE")
			env = append(env, "CODEX_HOME="+filepath.Join(root, "runtimes", "codex-relay-home"), "CODEX_CA_CERTIFICATE="+rl.caFile)
		}
		env = append(env, "NO_BROWSER=1")
	}
	return acp.Launch{Command: path, Args: args, Env: env, Dir: dir}, nil
}

func appendPath(env []string, dir string) []string {
	for i, kv := range env {
		if strings.HasPrefix(kv, "PATH=") {
			env[i] = kv + ":" + dir
			return env
		}
	}
	return append(env, "PATH=/usr/bin:/bin:"+dir)
}

func without(env []string, names ...string) []string {
	var out []string
outer:
	for _, kv := range env {
		for _, n := range names {
			if strings.HasPrefix(kv, n+"=") {
				continue outer
			}
		}
		out = append(out, kv)
	}
	return out
}

// needsSignIn is the -32036 credentialWanted the window answers by lending this Mac's
// sign-in (Lending.swift), for Claude and Codex on a host that has none of its own.
func (d *Daemon) needsSignIn(runtimeID string) error {
	if d.Tunneler == nil || d.relayFor(runtimeID) != nil {
		return nil
	}
	switch runtimeID {
	case "claude":
		if ownClaudeSignIn() {
			return nil
		}
	case "codex":
		if ownCodexSignIn() {
			return nil
		}
	default:
		return nil
	}
	r := runtimeByID(runtimeID)
	return &Error{Code: CodeCredentialWanted, Message: r.Name + " on this server needs a key.",
		Data: map[string]any{"runtime": runtimeID, "offered": false}}
}

// sessionMeta is the _meta on session/new: Claude's tools the app takes away
// (ToolPolicyCatalog.swift).
func sessionMeta(runtimeID string) map[string]any {
	if runtimeID != "claude" {
		return nil
	}
	return map[string]any{"claudeCode": map[string]any{"options": map[string]any{"disallowedTools": []string{
		"Workflow", "CronCreate", "CronList", "CronDelete", "ScheduleWakeup", "Monitor", "RemoteTrigger", "PushNotification",
		"EnterWorktree", "ExitWorktree"}}}}
}
