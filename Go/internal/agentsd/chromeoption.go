package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	goruntime "runtime"
	"strings"

	"github.com/alexec/agents/Go/wire"
)

// Use Chrome (#1837): a Claude session started with `--chrome`, so it can drive the
// person's own Chrome through the Claude in Chrome extension, signed in as them. Off unless
// asked for: a chat turns it on among Claude's options, and a workflow with `options:
// chrome: true`. The app adds the option to what Claude offers, so every client draws it
// as it draws Claude's own; the adapter hands `extraArgs` on to the CLI.

const chromeOptionID = "chrome"

func chromeOption(on bool) wire.ConfigOption {
	v, _ := json.Marshal(on)
	description := "Claude drives your own Chrome, signed in as you, through the Claude in Chrome extension. " +
		"Takes effect from the chat's next turn."
	return wire.ConfigOption{ID: chromeOptionID, Name: "Use Chrome", Description: &description, Type: "boolean", CurrentValue: v}
}

// chromeOn is whether the values ask for Chrome: true, or a workflow's "true".
func chromeOn(values map[string]wire.JSONValue) bool {
	raw, ok := values[chromeOptionID]
	if !ok {
		return false
	}
	var v any
	if json.Unmarshal(raw, &v) != nil {
		return false
	}
	switch v := v.(type) {
	case bool:
		return v
	case string:
		switch strings.ToLower(strings.TrimSpace(v)) {
		case "true", "on", "yes":
			return true
		}
	}
	return false
}

// withAppOptions is what a runtime offers and the app's own options for it beside them.
func withAppOptions(runtimeID string, values map[string]wire.JSONValue, opts []wire.ConfigOption) []wire.ConfigOption {
	if runtimeID != "claude" {
		return opts
	}
	out := make([]wire.ConfigOption, 0, len(opts)+1)
	for _, o := range opts {
		if o.ID != chromeOptionID {
			out = append(out, o)
		}
	}
	return append(out, chromeOption(chromeOn(values)))
}

// agentSessionMeta is sessionMeta for this agent: with `--chrome` when it asked for it.
func agentSessionMeta(a *wire.Agent) map[string]any {
	meta := sessionMeta(a.RuntimeID)
	if a.RuntimeID != "claude" || !chromeOn(a.StartOptions.Values) {
		return meta
	}
	code, _ := meta["claudeCode"].(map[string]any)
	options, _ := code["options"].(map[string]any)
	extra := map[string]any{}
	if e, ok := options["extraArgs"].(map[string]any); ok {
		for k, v := range e {
			extra[k] = v
		}
	}
	extra["chrome"] = nil // a flag with no value: `--chrome`
	merged := map[string]any{}
	for k, v := range options {
		merged[k] = v
	}
	merged["extraArgs"] = extra
	out := map[string]any{}
	for k, v := range meta {
		out[k] = v
	}
	out["claudeCode"] = map[string]any{"options": merged}
	return out
}

// setChrome is agents/setOption for Use Chrome: kept on the agent, never sent to Claude,
// which takes it only as it starts. A runtime between turns is let go, so the next turn
// starts it again with the choice in force, carrying on its conversation (as a sandbox
// change does).
func (d *Daemon) setChrome(a *wire.Agent, l *live, value wire.JSONValue) []wire.ConfigOption {
	var options []wire.ConfigOption
	d.change(a.ID, func(a *wire.Agent) {
		values := map[string]wire.JSONValue{}
		for k, v := range a.StartOptions.Values {
			values[k] = v
		}
		values[chromeOptionID] = value
		a.StartOptions.Values = values
		a.AdvertisedOptions = d.markOptions(a.RuntimeID, withAppOptions(a.RuntimeID, values, a.AdvertisedOptions))
		options = a.AdvertisedOptions
	})
	l.mu.Lock()
	s := l.session
	if l.inTurn {
		s = nil
	}
	l.mu.Unlock()
	if s != nil {
		s.Stop()
	}
	d.record(a.ID, wire.TranscriptEntryKind{OptionChanged: &wire.TranscriptEntryKindOptionChanged{ID: chromeOptionID, Value: value}})
	return options
}

// chromeHostNote is the Runtimes page's note on Claude when Use Chrome cannot work here
// (#1946): Chrome has no native messaging host for Claude Code, which `/chrome` in `claude`
// installs. Nil when the host is there, or Chrome keeps its hosts where we do not look.
func chromeHostNote() *string {
	dir := chromeNativeHostsDir()
	if dir == "" {
		return nil
	}
	if hasClaudeCodeHost(dir) {
		return nil
	}
	s := "Use Chrome needs Claude Code’s native host in Chrome. Run `claude`, then `/chrome`."
	return &s
}

// chromeNativeHostsDir is where Chrome reads its native messaging hosts for this user.
func chromeNativeHostsDir() string {
	home, _ := os.UserHomeDir()
	if home == "" {
		return ""
	}
	switch goruntime.GOOS {
	case "darwin":
		return filepath.Join(home, "Library", "Application Support", "Google", "Chrome", "NativeMessagingHosts")
	case "linux":
		return filepath.Join(home, ".config", "google-chrome", "NativeMessagingHosts")
	}
	return ""
}

// hasClaudeCodeHost is whether dir has Claude Code's host manifest
// (com.anthropic.claude_code_browser_extension.json). The Claude desktop app's own host
// (com.anthropic.claude_browser_extension) does not serve `claude --chrome`.
func hasClaudeCodeHost(dir string) bool {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return false
	}
	for _, e := range entries {
		if n := e.Name(); strings.HasPrefix(n, "com.anthropic.claude_code") && strings.HasSuffix(n, ".json") {
			return true
		}
	}
	return false
}
