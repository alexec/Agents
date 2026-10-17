package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/alexec/agents/Go/internal/agentsd/acp"
	"github.com/alexec/agents/Go/wire"
)

// Ports SandboxCatalogTests and DaemonSandboxTests: each runtime's sandbox is set as it
// takes it, an agent's own choice wins over the person's default, and a helper of an agent
// whose sandbox is on is not given off.

func TestEachRuntimesSandboxAsItTakesIt(t *testing.T) {
	l, meta := withSandbox(acp.Launch{Args: []string{"acp"}, Env: []string{"GEMINI_SANDBOX=true"}}, sessionMeta("claude"), "claude", wire.SandboxChoiceOff)
	b, _ := json.Marshal(meta)
	if string(b) != `{"claudeCode":{"options":{"disallowedTools":["Workflow","CronCreate","CronList","CronDelete","ScheduleWakeup","Monitor","RemoteTrigger","PushNotification","EnterWorktree","ExitWorktree"],"sandbox":{"enabled":false}}}}` || len(l.Args) != 1 {
		t.Fatalf("%s %v", b, l.Args)
	}
	if l, _ := withSandbox(acp.Launch{Args: []string{"acp"}}, nil, "grok", wire.SandboxChoiceOn); !slices.Equal(l.Args, []string{"acp", "--sandbox", "workspace"}) {
		t.Fatal(l.Args)
	}
	if l, _ := withSandbox(acp.Launch{Env: []string{"GEMINI_SANDBOX=true", "A=b"}}, nil, "gemini", wire.SandboxChoiceOff); !slices.Equal(l.Env, []string{"A=b", "GEMINI_SANDBOX=false"}) {
		t.Fatal(l.Env)
	}
	if l, m := withSandbox(acp.Launch{Args: []string{"acp"}}, nil, "grok", wire.SandboxChoiceRuntime); len(l.Args) != 1 || m != nil {
		t.Fatal(l.Args, m)
	}
	if c := sandboxChoices("gemini"); len(c) != 2 || sandboxChoices("cursor") != nil || len(sandboxChoices("claude")) != 3 {
		t.Fatal(c)
	}
	if m, ok := codexStartMode("codex", wire.SandboxChoiceOff, "auto"); !ok || m != codexFullAccess {
		t.Fatal(m)
	}
	if _, ok := codexStartMode("codex", wire.SandboxChoiceOn, "auto"); ok {
		t.Fatal("changed a mode already sandboxed")
	}
}

func TestAnAgentsSandbox(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	d.SettingsDir = t.TempDir()
	os.WriteFile(filepath.Join(d.SettingsDir, "sandbox.json"), []byte(`{"defaults":{"claude":"on"}}`), 0o644)
	if choice, why := d.resolveSandbox("claude", nil, nil); choice != wire.SandboxChoiceOn || why != nil {
		t.Fatal(choice)
	}
	var id wire.UUID
	json.Unmarshal(c.call(t, 1, "agents/start", map[string]any{"runtimeID": "claude", "cwd": "file://" + t.TempDir(), "prompt": "hello"}), &id)
	c.until(t, "the turn", ended(id, wire.AgentStateFinished))
	if e := d.Store.Agent(id).EffectiveSandbox; e == nil || e.State != wire.SandboxStateOn || e.Requested != wire.SandboxChoiceOn {
		t.Fatalf("%+v", e)
	}
	// A helper of it is not given off.
	off := wire.SandboxChoiceOff
	if choice, why := d.resolveSandbox("claude", &off, &id); choice != wire.SandboxChoiceRuntime || why == nil {
		t.Fatal(choice)
	}
	var a wire.Agent
	json.Unmarshal(c.call(t, 2, "agents/setSandbox", map[string]any{"agentID": id, "choice": "off"}), &a)
	if a.SandboxOverride == nil || *a.SandboxOverride != wire.SandboxChoiceOff {
		t.Fatalf("%+v", a.SandboxOverride)
	}
	if choice, _ := d.resolveSandbox("claude", a.SandboxOverride, nil); choice != wire.SandboxChoiceOff {
		t.Fatal(choice)
	}
	a = wire.Agent{}
	json.Unmarshal(c.call(t, 3, "agents/setSandbox", map[string]any{"agentID": id}), &a)
	if a.SandboxOverride != nil {
		t.Fatal(*a.SandboxOverride)
	}
	if e := c.callError(t, 4, "agents/answerSandbox", map[string]any{"agentID": id, "carryOn": true}); e.Code != wire.FailureNotAllowed {
		t.Fatalf("%+v", e)
	}
}
