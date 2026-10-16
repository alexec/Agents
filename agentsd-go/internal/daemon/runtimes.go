package daemon

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"

	acp "github.com/coder/acp-go-sdk"

	"github.com/alexec/agents/agentsd-go/internal/runtime"
)

// RuntimeDef is a catalogue entry (RuntimeCatalog.swift), with the names and ids the
// window knows.
type RuntimeDef struct {
	ID              string   `json:"id"`
	Name            string   `json:"name"`
	Executable      string   `json:"executable"`
	Arguments       []string `json:"arguments"`
	InstallPage     string   `json:"installPage"`
	UsesAppCopyOnly bool     `json:"usesAppCopyOnly"`
	// Not on the wire: the names it is also found as on PATH, and the env it is passed.
	also   []string
	passed []string
}

var catalog = []RuntimeDef{
	{ID: "claude", Name: "Claude", Executable: "npx", Arguments: []string{"-y", "@agentclientprotocol/claude-agent-acp"},
		InstallPage: "https://code.claude.com/docs/en/setup", also: []string{"claude-agent-acp"},
		passed: []string{"ANTHROPIC_", "CLAUDE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN"}},
	{ID: "codex", Name: "Codex", Executable: "codex-acp", Arguments: []string{},
		InstallPage: "https://github.com/zed-industries/codex-acp", passed: []string{"OPENAI_", "CODEX_HOME"}},
}

func (d *Daemon) catalog(id string) *RuntimeDef {
	for i := range catalog {
		if catalog[i].ID == id {
			return &catalog[i]
		}
	}
	return nil
}

// find is RuntimeDiscovery.swift: the toolset the app installed, then PATH.
func (r *RuntimeDef) find() (path string, args []string, lookedIn []string) {
	home, _ := os.UserHomeDir()
	for _, tools := range []string{filepath.Join(home, ".agents-go", "tools"), filepath.Join(home, ".agents-server", "tools")} {
		cur := filepath.Join(tools, r.ID, "current")
		lookedIn = append(lookedIn, cur)
		if _, err := os.Stat(filepath.Join(cur, "ok")); err == nil {
			exe := filepath.Join(cur, "bin", r.Executable)
			if _, err := os.Stat(exe); err == nil {
				return exe, r.Arguments, lookedIn
			}
		}
	}
	for _, name := range append(r.also, r.Executable) {
		if p, err := exec.LookPath(name); err == nil {
			if name == r.Executable {
				return p, r.Arguments, lookedIn
			}
			return p, nil, lookedIn
		}
	}
	return "", nil, append(lookedIn, "PATH")
}

func (d *Daemon) runtimesList() []map[string]any {
	var out []map[string]any
	for i := range catalog {
		r := &catalog[i]
		path, _, looked := r.find()
		var availability any
		if path != "" {
			availability = map[string]any{"available": map[string]any{"path": path, "supportsResume": true}}
		} else {
			availability = map[string]any{"missing": map[string]any{"lookedIn": looked}}
		}
		out = append(out, map[string]any{"runtime": r, "availability": availability, "checkedAt": Now(), "outdated": false})
	}
	return out
}

var baseEnv = []string{"PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "TZ", "LANG", "LANGUAGE", "LC_", "TERM",
	"COLORTERM", "XDG_", "EDITOR", "VISUAL", "PAGER", "SSH_AUTH_SOCK", "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY",
	"http_proxy", "https_proxy", "no_proxy", "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS", "AGENTS_"}

// environment is RuntimeEnvironment.swift: an allow list, never this process's whole env.
func (d *Daemon) environment(r *RuntimeDef) []string {
	allowed := append(append([]string{}, baseEnv...), r.passed...)
	var env []string
	for _, kv := range os.Environ() {
		name := kv[:strings.IndexByte(kv, '=')]
		if strings.HasPrefix(name, "CLAUDE_CODE_") && name != "CLAUDE_CODE_OAUTH_TOKEN" || name == "CLAUDECODE" {
			continue
		}
		for _, a := range allowed {
			if name == a || strings.HasSuffix(a, "_") && strings.HasPrefix(name, a) {
				env = append(env, kv)
				break
			}
		}
	}
	return env
}

func (d *Daemon) launchFor(r *RuntimeDef, dir string) (runtime.Launch, error) {
	path, args, looked := r.find()
	if path == "" {
		return runtime.Launch{}, &RPCError{Code: -32003, Message: r.Name + " is not installed on this host (looked in " + strings.Join(looked, ", ") + ")"}
	}
	env := d.environment(r)
	if r.ID == "claude" {
		if rl := d.relayFor("claude"); rl != nil {
			env = without(env, "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX",
				"ANTHROPIC_BASE_URL", "CLAUDE_CODE_OAUTH_TOKEN", "NODE_EXTRA_CA_CERTS")
			env = append(env, "ANTHROPIC_BASE_URL=https://127.0.0.1:"+strconv.Itoa(rl.port), "CLAUDE_CODE_OAUTH_TOKEN="+rl.standIn,
				"NODE_EXTRA_CA_CERTS="+rl.caFile)
		}
	}
	if r.ID == "codex" {
		env = append(env, "NO_BROWSER=1",
			`CODEX_CONFIG={"features":{"apps":false,"default_mode_request_user_input":true,"goals":true,"in_app_local_automation":false,"multi_agent":true,"sleep_tool":false}}`)
	}
	l := runtime.Launch{Command: path, Args: args, Env: env, Dir: dir}
	if d.Sandbox != nil {
		l.Wrap = func(argv []string) []string { return d.Sandbox(r.ID, dir, argv) }
	}
	return l, nil
}

// needsSignIn is the -32036 credentialWanted the window answers by lending its own (Lending.swift).
func (d *Daemon) needsSignIn(runtimeID string) error {
	if runtimeID != "claude" || ownClaudeSignIn() || d.relayFor("claude") != nil || d.tunneler == nil {
		return nil
	}
	return &RPCError{Code: -32036, Message: "Claude on this server needs a key.", Data: map[string]any{"runtime": "claude", "offered": false}}
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

// sessionMeta is the _meta on session/new: Claude's tools the app takes away (ToolPolicyCatalog.swift).
func (d *Daemon) sessionMeta(runtimeID string) map[string]any {
	if runtimeID != "claude" {
		return nil
	}
	return map[string]any{"claudeCode": map[string]any{"options": map[string]any{"disallowedTools": []string{
		"Workflow", "CronCreate", "CronList", "CronDelete", "ScheduleWakeup", "Monitor", "RemoteTrigger", "PushNotification",
		"EnterWorktree", "ExitWorktree"}}}}
}

// mcpServersFor is the servers a session is given: the app's own tools when served.
func (d *Daemon) mcpServersFor(agentID string) []acp.McpServer {
	if d.appTools == nil {
		return nil
	}
	return d.appTools(agentID)
}
