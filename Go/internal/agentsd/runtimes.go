package agentsd

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
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
	r := wire.Runtime{ID: id, Name: name, Executable: exe, Arguments: args, InstallPage: wire.URL(page), UsesAppCopyOnly: appCopyOnly}
	// A runtime whose sign-in is a folder can have more than one account (#840).
	if k, ok := accountKinds[id]; ok {
		v := k.variable
		r.AccountFolderVariable = &v
	}
	return runtimeDef{Runtime: r, passed: passed}
}

// catalog is RuntimeCatalog.builtIn, sorted by name. A server is given no installer
// (install is nil there).
var catalog = func() []runtimeDef {
	c := []runtimeDef{
		runtime("claude", "Claude", "npx", []string{"--prefer-offline", "-y", "@agentclientprotocol/claude-agent-acp"}, "https://code.claude.com/docs/en/setup", false, "ANTHROPIC_", "CLAUDE_CONFIG_DIR"),
		runtime("grok", "Grok", "grok", []string{"--permission-mode", "default", "agent", "stdio"}, "https://x.ai/cli", false, "GROK_", "XAI_"),
		runtime("copilot", "Copilot", "copilot", []string{"--acp"}, "https://docs.github.com/en/copilot/how-tos/set-up/install-copilot-cli", false, "COPILOT_", "GH_TOKEN", "GITHUB_TOKEN"),
		runtime("cursor", "Cursor", "cursor-agent", []string{"acp"}, "https://cursor.com/docs/cli/installation", false, "CURSOR_"),
		runtime("codex", "Codex", "codex-acp", nil, "https://github.com/agentclientprotocol/codex-acp", true, "OPENAI_", "CODEX_HOME"),
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

// macToolsHome is a Mac host's own toolsets, <cache>/tools (StoreLocations.tools, 048),
// set as the host starts; "" on a server, which looks in ~/.agents-server/tools.
var macToolsHome string

// toolsetFolder is Toolset.serverFolder: ~/.agents-server/tools/<id>.
func toolsetFolder(id string) string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".agents-server", "tools", id)
}

// toolsetShim is a whole toolset's bin/<executable> in folder (<tools>/<id>), which runs
// the pinned package with the toolset's own Node whatever it is passed (Toolset.shimName);
// "" unless current/ok says it is whole.
func toolsetShim(folder, executable string) string {
	cur := filepath.Join(folder, "current")
	if _, err := os.Stat(filepath.Join(cur, "ok")); err != nil {
		return ""
	}
	shim := filepath.Join(cur, "bin", executable)
	if fi, err := os.Stat(shim); err == nil && fi.Mode()&0o111 != 0 {
		return shim
	}
	return ""
}

// locate is RuntimeDiscovery.locate. On a server: the installed toolset's shim, then (for
// a runtime that may be the person's own copy) the login shell's PATH. On a Mac (#1138):
// the app's own toolset in the root's cache (macToolsHome) is the only copy of a runtime
// that uses the app's copy, and is looked for after the person's PATH for the others.
func (r *runtimeDef) locate() (path string, args []string, lookedIn []string) {
	mac := macToolsHome != ""
	if !mac {
		if shim := toolsetShim(toolsetFolder(r.ID), r.Executable); shim != "" {
			return shim, r.Arguments, nil
		}
	}
	appCopy := func() string {
		if !mac {
			return ""
		}
		return toolsetShim(filepath.Join(macToolsHome, r.ID), r.Executable)
	}
	if r.UsesAppCopyOnly {
		if shim := appCopy(); shim != "" {
			return shim, r.Arguments, nil
		}
		if mac {
			return "", nil, []string{filepath.Join(macToolsHome, r.ID, "current", "bin")}
		}
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
	if shim := appCopy(); shim != "" {
		return shim, r.Arguments, nil
	}
	return "", nil, dirs
}

// searchPaths is LoginShellPath.directories: the login shell's PATH, then the usual places.
// The login shell's PATH is kept for shellPathTTL, so a broadcast that locates each runtime
// starts one shell at most, not one a row (#2251).
func searchPaths() []string {
	shell := os.Getenv("SHELL")
	if shell == "" {
		shell = "/bin/sh"
	}
	home, _ := os.UserHomeDir()
	key := shell + "\x00" + home
	shellPath.Lock()
	if shellPath.key != key || time.Since(shellPath.at) >= shellPathTTL {
		shellPath.key, shellPath.dirs, shellPath.at = key, loginShellPath(shell), time.Now()
	}
	dirs := slices.Clone(shellPath.dirs)
	shellPath.Unlock()
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

// shellPathTTL is how long searchPaths keeps the login shell's PATH.
const shellPathTTL = 60 * time.Second

// shellPath is the one PATH searchPaths keeps, for the shell and home it was read with.
var shellPath struct {
	sync.Mutex
	key  string
	dirs []string
	at   time.Time
}

// loginShellPath is the PATH the login shell sets, or nothing when it fails; a test
// replaces it to count the shells.
var loginShellPath = func(shell string) []string {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, shell, "-lc", `printf %s "$PATH"`).Output()
	if err != nil {
		return nil
	}
	return strings.Split(string(out), ":")
}

// loginEnvironment is LoginShellPath.environment: this process's, with the login shell's
// PATH and the system's folders. launchd starts agentsd with the system's folders only, so
// a runtime's `#!/usr/bin/env node` or an `npx` MCP server needs the person's (#1382).
func loginEnvironment() []string {
	path := searchPaths()
	for _, s := range []string{"/usr/bin", "/bin", "/usr/sbin", "/sbin"} {
		found := false
		for _, p := range path {
			found = found || p == s
		}
		if !found {
			path = append(path, s)
		}
	}
	return append(without(os.Environ(), "PATH"), "PATH="+strings.Join(path, ":"))
}

// mcpServerEnvironment is RuntimeEnvironment.forMCPServers: the login environment with the
// shipped servers' folder (beside agentsd) first on PATH, so `.agents/mcp.json` names one
// by its bare name ("github-mcp") on a Mac and a server alike, and a stale copy elsewhere
// on PATH never answers for it (#1389).
func mcpServerEnvironment() []string {
	env := loginEnvironment()
	self, err := os.Executable()
	if err != nil {
		return env
	}
	return prependPath(env, filepath.Dir(self))
}

func prependPath(env []string, dir string) []string {
	for i, kv := range env {
		if dirs, ok := strings.CutPrefix(kv, "PATH="); ok {
			rest := []string{dir}
			for _, d := range strings.Split(dirs, ":") {
				if d != dir {
					rest = append(rest, d)
				}
			}
			env[i] = "PATH=" + strings.Join(rest, ":")
			return env
		}
	}
	return append(env, "PATH="+dir+":/usr/bin:/bin")
}

// loginCommand is exec.Command with env's PATH, not this process's, finding a bare name.
func loginCommand(env []string, name string, args ...string) *exec.Cmd {
	if !strings.Contains(name, "/") {
		for _, kv := range env {
			if dirs, ok := strings.CutPrefix(kv, "PATH="); ok {
				for _, d := range strings.Split(dirs, ":") {
					p := filepath.Join(d, name)
					if fi, err := os.Stat(p); d != "" && err == nil && !fi.IsDir() && fi.Mode()&0o111 != 0 {
						name = p
						break
					}
				}
			}
		}
	}
	cmd := exec.Command(name, args...)
	cmd.Env = env
	return cmd
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
		d.overlay(&s)
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

// environment is the launch environment: the built-in allowlist, the runtime's own names,
// and the person's own pass-through names (passthrough.go), as the policy allows them.
func environment(r *runtimeDef, from []string, person ...string) []string {
	names := append(append([]string{}, allowed...), r.passed...)
	var env []string
	for _, kv := range from {
		name, _, _ := strings.Cut(kv, "=")
		if passedThrough(person, name) {
			env = append(env, kv)
			continue
		}
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
	return d.launchAs(r, dir, nil)
}

// launchAs is launchFor on an added account (#840), nil for the runtime's own sign-in. An
// added account is the folder's own sign-in, so a relayed one is not used for it.
func (d *Daemon) launchAs(r *runtimeDef, dir string, account *wire.AccountProfile) (acp.Launch, error) {
	return d.launchOn(r, dir, account, "")
}

// launchOn is launchAs for a session: an org account's relay counts the session's tokens
// (#999). An org account is reached through the model relay, never the 056 relay (D8).
func (d *Daemon) launchOn(r *runtimeDef, dir string, account *wire.AccountProfile, agent wire.UUID) (acp.Launch, error) {
	path, args, looked := locateFor(r)
	if path == "" {
		return acp.Launch{}, &Error{Code: CodeRuntimeNotFound, Message: r.Name + " is not installed on this machine (looked in " + strings.Join(looked, ", ") + ")"}
	}
	env := environment(r, loginEnvironment(), d.passThrough(r.ID)...)
	// Under "the org path only", nothing of the person's own way to the model reaches the
	// runtime (#999, D9), also for a handshake on the own sign-in.
	if account == nil && d.signInRefusedHere(r.ID) {
		env = withoutRuntimeVariables(env)
	}
	// The shipped MCP servers sit beside agentsd (~/.agents-server/bin), last on PATH.
	if self, err := os.Executable(); err == nil {
		env = appendPath(env, filepath.Dir(self))
	}
	root := d.Store.Loc.Root
	switch r.ID {
	case "claude":
		if rl := d.relayFor("claude"); rl != nil && account == nil {
			env = without(env, "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX",
				"ANTHROPIC_BASE_URL", "CLAUDE_CODE_OAUTH_TOKEN", "NODE_EXTRA_CA_CERTS")
			env = append(env, "ANTHROPIC_BASE_URL=https://127.0.0.1:"+strconv.Itoa(rl.port), "CLAUDE_CODE_OAUTH_TOKEN="+rl.standIn,
				"NODE_EXTRA_CA_CERTS="+rl.caFile)
		}
	case "codex":
		if rl := d.relayFor("codex"); rl != nil && account == nil {
			env = without(env, "OPENAI_API_KEY", "CODEX_HOME", "CODEX_CA_CERTIFICATE")
			env = append(env, "CODEX_HOME="+filepath.Join(root, "runtimes", "codex-relay-home"), "CODEX_CA_CERTIFICATE="+rl.caFile)
		}
		env = append(env, "NO_BROWSER=1")
	case "antigravity":
		// RuntimeLaunch.antigravity (049 D8): its own home in the root, never the person's
		// ~/.gemini; the agent's folder trusted for this process; the Google sign-in as a
		// file under that home, not a Keychain item. Neither Gemini key is in env.
		env = append(env, "GEMINI_HOME="+d.appHomes()["antigravity"], "AGY_ACP_DISABLE_WORKSPACE_TRUST=1",
			"AGY_ACP_FORCE_FILE_STORAGE=1")
	}
	if isOrgAccount(account) {
		var err error
		if env, err = d.withOrgAccount(env, r.ID, account, agent); err != nil {
			return acp.Launch{}, err
		}
	} else if account != nil {
		d.linkShared(*account)
		env = withAccount(env, account)
	}
	l := withToolPolicy(acp.Launch{Command: path, Args: args, Env: env, Dir: dir, Name: r.Name}, r.ID)
	for _, f := range toolPolicyFiles[r.ID] {
		file := filepath.Join(root, "runtimes", f.name)
		if err := os.MkdirAll(filepath.Dir(file), 0o700); err != nil {
			return acp.Launch{}, err
		}
		if err := os.WriteFile(file, []byte(f.contents), 0o600); err != nil {
			return acp.Launch{}, err
		}
		if f.variable != "" {
			l.Env = append(without(l.Env, f.variable), f.variable+"="+file)
		} else {
			l.Args = append(slices.Clone(l.Args), f.argument, file)
		}
	}
	return l, nil
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
	// A Mac's own agents use the Mac's own sign-in (in the Keychain for Claude): nothing is
	// lent to them, and nothing is wanted (DaemonCore+Credentials, onServer false; #1138).
	if d.Tunneler == nil || macToolsHome != "" || d.relayFor(runtimeID) != nil {
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

// The tool policy is ToolPolicyCatalog.swift's levers, one per runtime, measured in 015
// and kept up there since: what each runtime's own tools would do that the app does (its
// standing arrangements, artefacts and the like) is taken away, and its question tool is
// kept. Cursor has no lever (its permission vocabulary names no tool), and Antigravity has
// nothing to take away since sub-agents and task lists came back (2026-09-29): an empty deny
// list or policy file is not sent, as Swift did not send one.

// toolPolicyEnv is the environmentJSON lever: JSON in a variable the runtime reads at
// start, compact with sorted keys, the person's own replaced.
//   - Codex's feature switches in CODEX_CONFIG, which its adapter merges into every
//     thread's config (047). They take sleep, automations and apps away, and let
//     request_user_input ask outside plan mode, so Codex's own question reaches the app as
//     a form (#1432).
//   - OpenCode's own configuration in OPENCODE_CONFIG_CONTENT, merged over the person's
//     opencode.json for this process (049 D4): it asks before an edit, a command or a fetch
//     (its own default is to allow all three), and never updates itself or shares (#1445).
var toolPolicyEnv = map[string]map[string]any{
	"codex": {"CODEX_CONFIG": map[string]any{"features": map[string]any{
		"sleep_tool": false, "goals": true, "in_app_local_automation": false, "apps": false,
		"multi_agent": true, "default_mode_request_user_input": true}}},
	"opencode": {"OPENCODE_CONFIG_CONTENT": map[string]any{"autoupdate": false,
		"permission": map[string]any{"bash": "ask", "edit": "ask", "webfetch": "ask"}, "share": "disabled"}},
}

// toolPolicyArgs is the launchArguments lever (#1445): Copilot is not given the person's
// software-factory server (a second copy of the app's whole remit) or its built-in MCP
// servers, and session_store_sql is excluded.
var toolPolicyArgs = map[string][]string{
	"copilot": {"--disable-mcp-server", "software-factory", "--disable-builtin-mcps", "--excluded-tools", "session_store_sql"},
}

// withToolPolicy is the launch with the runtime's tool policy in its arguments and
// environment.
func withToolPolicy(l acp.Launch, runtimeID string) acp.Launch {
	l.Args = append(slices.Clone(l.Args), toolPolicyArgs[runtimeID]...)
	for k, v := range toolPolicyEnv[runtimeID] {
		b, _ := json.Marshal(v)
		l.Env = append(without(l.Env, k), k+"="+string(b))
	}
	return l
}

// policyFile is ToolPolicy's EnvironmentFile: written whole to <root>/runtimes/<name> on
// every launch, and pointed at by a variable or, after an argument, by its path.
type policyFile struct {
	name, contents, variable, argument string
}

// toolPolicyFiles is each runtime's files (#1445).
//   - Grok reads its feature switches only from a file of its own (GROK_CONFIG in line is
//     ignored), never the person's ~/.grok/config.toml: no image or video generation.
var toolPolicyFiles = map[string][]policyFile{
	"grok": {{name: "grok-overlay.toml", variable: "GROK_CONFIG_PATH",
		contents: "# Written by the Agents app. Do not edit: rebuilt on every launch.\n[features]\nimage_gen = false\nvideo_gen = false\n"}},
}

// grokRemoved is Grok's deny list, a profile's disallowedTools: its scheduler, workflow,
// monitor and send_feedback. It was an allow list until Grok 1.0.52 stopped giving the
// sub-agent tools it named (#1447). The profile needs its name and description, or Grok
// falls back to its stock profile and every tool comes back.
var grokRemoved = []string{"scheduler_create", "scheduler_delete", "scheduler_list", "workflow", "monitor", "send_feedback"}

// sessionMeta is the _meta on session/new, session/load and session/fork: Claude's tools
// and Grok's tools the app takes away, Grok's as a profile (ToolPolicyCatalog.swift), and
// Grok's rules with the app's tools written out (grokRules).
func sessionMeta(runtimeID string) map[string]any {
	switch runtimeID {
	case "claude":
		return map[string]any{"claudeCode": map[string]any{"options": map[string]any{"disallowedTools": []string{
			"Workflow", "CronCreate", "CronList", "CronDelete", "ScheduleWakeup", "Monitor", "RemoteTrigger", "PushNotification",
			"EnterWorktree", "ExitWorktree"}}}}
	case "grok":
		return map[string]any{"agentProfile": map[string]any{"disallowedTools": grokRemoved, "name": "agents-app",
			"description": "An agent hosted by the Agents app."}, "rules": grokRules()}
	}
	return nil
}
