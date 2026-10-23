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
	if l, _ := withSandbox(acp.Launch{Args: []string{"acp"}}, nil, "grok", wire.SandboxChoiceOn); !slices.Equal(l.Args, []string{"acp"}) {
		t.Fatal(l.Args)
	}
	if l, _ := withSandbox(acp.Launch{Env: []string{"GEMINI_SANDBOX=true", "A=b"}}, nil, "gemini", wire.SandboxChoiceOff); !slices.Equal(l.Env, []string{"A=b", "GEMINI_SANDBOX=false"}) {
		t.Fatal(l.Env)
	}
	if l, m := withSandbox(acp.Launch{Args: []string{"acp"}}, nil, "grok", wire.SandboxChoiceRuntime); len(l.Args) != 1 || m != nil {
		t.Fatal(l.Args, m)
	}
	if c := sandboxChoices("gemini"); len(c) != 2 || sandboxChoices("cursor") != nil || sandboxChoices("grok") != nil || len(sandboxChoices("claude")) != 3 {
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
}

func TestASandboxThatCouldNotStart(t *testing.T) {
	if got := sandboxMatch("claude", "\x1b[31mError: run failed. sandbox_apply: Operation not permitted\x1b[0m\nok"); got != "sandbox_apply: Operation not permitted" {
		t.Fatalf("%q", got)
	}
	if got := sandboxMatch("claude", `It said "sandbox_apply: Operation not permitted" before.`); got != "" {
		t.Fatalf("a quote: %q", got)
	}
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	var id wire.UUID
	json.Unmarshal(c.call(t, 1, "agents/start", map[string]any{"runtimeID": "claude", "cwd": "file://" + t.TempDir(), "prompt": "the sandbox fails"}), &id)
	c.until(t, "stopped with the card", ended(id, wire.AgentStateStopped))
	a := d.Store.Agent(id)
	if a.EndedReason == nil || *a.EndedReason != wire.EndedReasonSandboxFailed || a.PendingSandboxFailure == nil ||
		a.PendingSandboxFailure.Detail != "sandbox_apply: Operation not permitted" || !a.PendingSandboxFailure.RecoveryOffered ||
		a.PendingSandboxFailure.CompletedToolCalls != 0 {
		t.Fatalf("%+v %+v", a.EndedReason, a.PendingSandboxFailure)
	}
	if k := kinds(d, id); !slices.Contains(k, "sandboxFailure") {
		t.Fatal(k)
	}
	waitFor(t, "its turn over", func() bool {
		l := d.live(id)
		l.mu.Lock()
		defer l.mu.Unlock()
		return !l.inTurn && !l.running
	})
	// Carried on: off for this agent, and the person's prompt sent again.
	var answered wire.Agent
	json.Unmarshal(c.call(t, 2, "agents/answerSandbox", map[string]any{"agentID": id, "carryOn": true}), &answered)
	if answered.SandboxOverride == nil || *answered.SandboxOverride != wire.SandboxChoiceOff || answered.PendingSandboxFailure != nil {
		t.Fatalf("%+v", answered)
	}
	waitFor(t, "it went", func() bool { return d.Store.Agent(id).State == wire.AgentStateFinished })
	if u := userMessages(d, id); len(u) != 2 || u[1] != "the sandbox fails" {
		t.Fatalf("%q", u)
	}
	if e := c.callError(t, 3, "agents/answerSandbox", map[string]any{"agentID": id, "carryOn": false}); e.Code != wire.FailureNotAllowed {
		t.Fatalf("%+v", e)
	}
}
