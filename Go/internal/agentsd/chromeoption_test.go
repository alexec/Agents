package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// Use Chrome (#1837): Claude's sessions get `--chrome` only when asked, the option is
// offered beside Claude's own, and a chat's switch is kept without asking Claude.

func TestChromeIsAskedForOnlyByTrue(t *testing.T) {
	raw := func(s string) map[string]wire.JSONValue { return map[string]wire.JSONValue{"chrome": wire.JSONValue(s)} }
	for _, tc := range []struct {
		values map[string]wire.JSONValue
		want   bool
	}{{nil, false}, {raw(`true`), true}, {raw(`false`), false}, {raw(`"true"`), true}, {raw(`"no"`), false}} {
		if got := chromeOn(tc.values); got != tc.want {
			t.Errorf("%s: %v", tc.values["chrome"], got)
		}
	}
}

func TestOnlyAClaudeSessionAskedForChromeGetsTheFlag(t *testing.T) {
	a := &wire.Agent{RuntimeID: "claude", StartOptions: wire.StartOptions{Values: map[string]wire.JSONValue{}}}
	if b, _ := json.Marshal(agentSessionMeta(a)); strings.Contains(string(b), "extraArgs") {
		t.Fatalf("Chrome without asking: %s", b)
	}
	a.StartOptions.Values["chrome"] = wire.JSONValue(`true`)
	b, _ := json.Marshal(agentSessionMeta(a))
	if !strings.Contains(string(b), `"extraArgs":{"chrome":null}`) || !strings.Contains(string(b), `"disallowedTools"`) {
		t.Fatalf("no --chrome, or the tools the app takes away lost: %s", b)
	}
	// The plain sessionMeta is not changed under another agent.
	if b, _ := json.Marshal(sessionMeta("claude")); strings.Contains(string(b), "extraArgs") {
		t.Fatalf("sessionMeta itself changed: %s", b)
	}
	g := &wire.Agent{RuntimeID: "grok", StartOptions: wire.StartOptions{Values: map[string]wire.JSONValue{"chrome": wire.JSONValue(`true`)}}}
	if b, _ := json.Marshal(agentSessionMeta(g)); strings.Contains(string(b), "chrome") {
		t.Fatalf("a runtime that is not Claude given Chrome: %s", b)
	}
}

func TestUseChromeIsOfferedBesideClaudesOwnOptions(t *testing.T) {
	model := wire.ConfigOption{ID: "model", Name: "Model", Type: "select"}
	opts := withAppOptions("claude", nil, []wire.ConfigOption{model})
	if len(opts) != 2 || opts[1].ID != "chrome" || string(opts[1].CurrentValue) != "false" {
		t.Fatalf("%+v", opts)
	}
	// Offered once, whatever is offered again.
	opts = withAppOptions("claude", map[string]wire.JSONValue{"chrome": wire.JSONValue(`true`)}, opts)
	if len(opts) != 2 || string(opts[1].CurrentValue) != "true" {
		t.Fatalf("%+v", opts)
	}
	if opts := withAppOptions("codex", nil, []wire.ConfigOption{model}); len(opts) != 1 {
		t.Fatalf("offered on Codex: %+v", opts)
	}
}

func TestAChatsUseChromeIsKeptWithoutAskingClaude(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	a := seeded(t, d, t.TempDir(), nil)
	var opts []wire.ConfigOption
	json.Unmarshal(c.call(t, 1, "agents/setOption", map[string]any{"agentID": a.ID, "optionID": "chrome", "value": true}), &opts)
	if len(opts) == 0 || opts[len(opts)-1].ID != "chrome" || string(opts[len(opts)-1].CurrentValue) != "true" {
		t.Fatalf("%+v", opts)
	}
	if got := d.Store.Agent(a.ID); !chromeOn(got.StartOptions.Values) {
		t.Fatalf("not kept: %+v", got.StartOptions.Values)
	}
}

// The Runtimes page's note (#1946) looks for Claude Code's own host, not the desktop app's.
func TestHasClaudeCodeHost(t *testing.T) {
	dir := t.TempDir()
	if hasClaudeCodeHost(dir) {
		t.Fatal("an empty folder has no host")
	}
	if hasClaudeCodeHost(filepath.Join(dir, "missing")) {
		t.Fatal("a missing folder has no host")
	}
	if err := os.WriteFile(filepath.Join(dir, "com.anthropic.claude_browser_extension.json"), []byte("{}"), 0o644); err != nil {
		t.Fatal(err)
	}
	if hasClaudeCodeHost(dir) {
		t.Fatal("the desktop app's host does not serve claude --chrome")
	}
	if err := os.WriteFile(filepath.Join(dir, "com.anthropic.claude_code_browser_extension.json"), []byte("{}"), 0o644); err != nil {
		t.Fatal(err)
	}
	if !hasClaudeCodeHost(dir) {
		t.Fatal("Claude Code's host is there")
	}
}
