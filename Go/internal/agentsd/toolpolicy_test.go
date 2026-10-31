package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/agentsd/acp"
)

// Ports ToolPolicyCatalogTests' levers (#1445): each runtime's tool policy rides on its
// launch or its session as ToolPolicyCatalog.swift says.

// launchOf is the launch a daemon on a fresh root gives a runtime, and the root.
func launchOf(t *testing.T, runtimeID string) (acp.Launch, string) {
	t.Helper()
	fakeRuntimes(t)
	root := t.TempDir()
	d, _ := start(t, root)
	t.Cleanup(d.Shutdown)
	l, err := d.launchFor(runtimeByID(runtimeID), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return l, root
}

// envValue is name's value in env, and whether it is there once.
func envValue(env []string, name string) (string, bool) {
	var found []string
	for _, kv := range env {
		if v, ok := strings.CutPrefix(kv, name+"="); ok {
			found = append(found, v)
		}
	}
	if len(found) != 1 {
		return "", false
	}
	return found[0], true
}

// Grok takes a deny list, as a profile in _meta, and reads its switches from a file of
// the app's own, the person's GROK_CONFIG_PATH replaced.
func TestGroksToolPolicy(t *testing.T) {
	meta := sessionMeta("grok")
	delete(meta, "rules") // grokRules, in brief_test.go
	b, _ := json.Marshal(meta)
	want := `{"agentProfile":{"description":"An agent hosted by the Agents app.","disallowedTools":["scheduler_create","scheduler_delete","scheduler_list","workflow","monitor","send_feedback"],"name":"agents-app"}}`
	if string(b) != want {
		t.Fatalf("%s", b)
	}
	t.Setenv("GROK_CONFIG_PATH", "/the/persons/own.toml")
	l, root := launchOf(t, "grok")
	file := filepath.Join(root, "runtimes", "grok-overlay.toml")
	if v, ok := envValue(l.Env, "GROK_CONFIG_PATH"); !ok || v != file {
		t.Fatalf("%q", l.Env)
	}
	if text, _ := os.ReadFile(file); !strings.Contains(string(text), "[features]\nimage_gen = false\nvideo_gen = false\n") {
		t.Fatalf("%s", text)
	}
}

// Copilot is launched without the person's software-factory server or its built-in MCP
// servers, and without session_store_sql; it has no _meta.
func TestCopilotsToolPolicy(t *testing.T) {
	l, _ := launchOf(t, "copilot")
	want := []string{"--disable-mcp-server", "software-factory", "--disable-builtin-mcps", "--excluded-tools", "session_store_sql"}
	if !slices.Equal(l.Args, want) {
		t.Fatalf("%q", l.Args)
	}
	if sessionMeta("copilot") != nil {
		t.Fatal(sessionMeta("copilot"))
	}
	// The catalog's own arguments are not appended to in place.
	if !slices.Equal(runtimeByID("copilot").Arguments, []string{"--acp"}) {
		t.Fatal(runtimeByID("copilot").Arguments)
	}
}

// Antigravity's lever is _meta.agy.disabledTools, and nothing is denied since its
// sub-agents came back: no _meta at all rather than an empty list, and nothing at launch.
func TestAntigravitysToolPolicy(t *testing.T) {
	if m := sessionMeta("antigravity"); m != nil {
		t.Fatal(m)
	}
	l, _ := launchOf(t, "antigravity")
	if len(l.Args) != 0 {
		t.Fatalf("%q", l.Args)
	}
}

// OpenCode's configuration rides in OPENCODE_CONFIG_CONTENT, the person's own replaced: it
// asks before an edit, a command or a fetch, and never updates itself or shares.
func TestOpenCodesToolPolicy(t *testing.T) {
	t.Setenv("OPENCODE_CONFIG_CONTENT", `{"permission":"allow"}`)
	l, _ := launchOf(t, "opencode")
	v, ok := envValue(l.Env, "OPENCODE_CONFIG_CONTENT")
	if want := `{"autoupdate":false,"permission":{"bash":"ask","edit":"ask","webfetch":"ask"},"share":"disabled"}`; !ok || v != want {
		t.Fatalf("%q", l.Env)
	}
	if sessionMeta("opencode") != nil || len(l.Args) != 0 {
		t.Fatalf("%v %q", sessionMeta("opencode"), l.Args)
	}
}

// Codex's switches ride in CODEX_CONFIG on every launch (#1432), and Cursor, with no
// lever, is launched as it is.
func TestCodexAndCursorsToolPolicy(t *testing.T) {
	l, _ := launchOf(t, "codex")
	if v, ok := envValue(l.Env, "CODEX_CONFIG"); !ok || !strings.Contains(v, `"default_mode_request_user_input":true`) {
		t.Fatalf("%q", l.Env)
	}
	l, _ = launchOf(t, "cursor")
	if len(l.Args) != 0 || sessionMeta("cursor") != nil {
		t.Fatalf("%q", l.Args)
	}
}
