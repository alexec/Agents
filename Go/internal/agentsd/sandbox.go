package agentsd

import (
	"context"
	"encoding/json"
	"slices"

	"github.com/alexec/agents/Go/internal/agentsd/acp"
	"github.com/alexec/agents/Go/wire"
)

// A runtime's command sandbox (064, SandboxCatalog): on, off or the runtime's own say, for
// each runtime by the person's default in sandbox.json and for each agent by its own
// choice, applied as that runtime takes it: arguments, the environment, Claude's _meta or
// Codex's mode.
//
// A sandbox that fails to start is in sandboxfailure.go.

type sandboxRoute struct {
	onArgs, offArgs []string
	onEnv, offEnv   map[string]string
	envOnOffered    bool
	claudeMeta      bool
	codexMode       bool
	fixed           wire.SandboxState
	why             string
}

var sandboxCatalog = map[string]sandboxRoute{
	"claude": {claudeMeta: true},
	"codex":  {codexMode: true},
	"grok":        {fixed: wire.SandboxStateRuntimeControlled, why: "Grok 1.0.67 does not accept --sandbox with agent stdio. The app cannot change Grok’s sandbox."},
	"cursor":      {fixed: wire.SandboxStateRuntimeControlled, why: "Cursor’s own sandbox setting decides. The app cannot change it."},
	"copilot":     {fixed: wire.SandboxStateRuntimeControlled, why: "Copilot’s own sandbox setting decides. The app cannot change it yet."},
	"antigravity": {fixed: wire.SandboxStateNone, why: "Antigravity sandboxes commands only when a business account’s admin turns Sandbox mode on."},
	"opencode":    {fixed: wire.SandboxStateNone, why: "OpenCode has no command sandbox. It asks before running commands unless set to Always-approve."},
}

const (
	codexFullAccess     = "agent-full-access"
	codexAskForApproval = "read-only"
)

// sandboxChoices is SandboxCatalog.choices: what the app can set for a runtime.
func sandboxChoices(runtimeID string) []wire.SandboxChoice {
	r, ok := sandboxCatalog[runtimeID]
	switch {
	case !ok || r.fixed != "":
		return nil
	case r.offEnv != nil && !r.envOnOffered:
		return []wire.SandboxChoice{wire.SandboxChoiceRuntime, wire.SandboxChoiceOff}
	}
	return []wire.SandboxChoice{wire.SandboxChoiceRuntime, wire.SandboxChoiceOn, wire.SandboxChoiceOff}
}

func (d *Daemon) defaultSandbox(runtimeID string) wire.SandboxChoice {
	if c, ok := d.sandboxSettings().Defaults[runtimeID]; ok {
		return c
	}
	return wire.SandboxChoiceRuntime
}

// resolveSandbox is the choice in force for an agent, and why when it is not the one
// asked for: off is not given to a helper of an agent whose sandbox is on.
func (d *Daemon) resolveSandbox(runtimeID string, override *wire.SandboxChoice, starter *wire.UUID) (wire.SandboxChoice, *string) {
	choice := d.defaultSandbox(runtimeID)
	if override != nil {
		choice = *override
	}
	if !slices.Contains(sandboxChoices(runtimeID), choice) {
		choice = wire.SandboxChoiceRuntime
	}
	if choice == wire.SandboxChoiceOff && starter != nil {
		if s := d.Store.Agent(*starter); s != nil && s.EffectiveSandbox != nil && s.EffectiveSandbox.State == wire.SandboxStateOn {
			why := "Limited by the agent that started it"
			return wire.SandboxChoiceRuntime, &why
		}
	}
	// The effective sandbox rule caps the person's choice (#998, #2957): on where the app
	// can set it. The person's own default is kept as they wrote it.
	if on, layer := d.effectiveSandboxOn(""); on && choice != wire.SandboxChoiceOn {
		if onChoice, ok := requiredSandbox(runtimeID); ok {
			why := sandboxRequiredWordsFor(layer)
			if layer != nil && layer.Kind == "organisation" {
				why = orgSetBy + " " + why
			}
			return onChoice, &why
		}
	}
	return choice, nil
}

// withSandbox is LaunchSandbox: the launch and the session's _meta with the choice in.
func withSandbox(l acp.Launch, meta map[string]any, runtimeID string, choice wire.SandboxChoice) (acp.Launch, map[string]any) {
	r, ok := sandboxCatalog[runtimeID]
	if !ok || choice == wire.SandboxChoiceRuntime {
		return l, meta
	}
	on := choice == wire.SandboxChoiceOn
	args, env := r.offArgs, r.offEnv
	if on {
		args, env = r.onArgs, r.onEnv
	}
	l.Args = append(slices.Clone(l.Args), args...)
	for k, v := range env {
		l.Env = append(without(l.Env, k), k+"="+v)
	}
	if r.claudeMeta {
		meta = mergeMeta(meta, map[string]any{"claudeCode": map[string]any{"options": map[string]any{"sandbox": map[string]any{"enabled": on}}}})
	}
	return l, meta
}

// mergeMeta puts b's keys into a copy of a, object into object.
func mergeMeta(a, b map[string]any) map[string]any {
	out := map[string]any{}
	for k, v := range a {
		out[k] = v
	}
	for k, v := range b {
		x, xok := out[k].(map[string]any)
		y, yok := v.(map[string]any)
		if xok && yok {
			out[k] = mergeMeta(x, y)
		} else {
			out[k] = v
		}
	}
	return out
}

// codexStartMode is the mode a Codex agent starts in for a choice, when it changes it.
func codexStartMode(runtimeID string, choice wire.SandboxChoice, mode string) (string, bool) {
	if runtimeID != "codex" {
		return "", false
	}
	switch {
	case choice == wire.SandboxChoiceOff:
		return codexFullAccess, mode != codexFullAccess
	case choice == wire.SandboxChoiceOn && mode == codexFullAccess:
		return codexAskForApproval, true
	}
	return "", false
}

func stringValue(v wire.JSONValue) string {
	var s string
	json.Unmarshal(v, &s)
	return s
}

// sandboxState is SandboxCatalog.state.
func sandboxState(runtimeID string, choice wire.SandboxChoice, codexMode string) wire.SandboxState {
	r, ok := sandboxCatalog[runtimeID]
	switch {
	case !ok:
		return wire.SandboxStateRuntimeControlled
	case r.fixed != "":
		return r.fixed
	case r.codexMode:
		if codexMode == codexFullAccess {
			return wire.SandboxStateOff
		}
		return wire.SandboxStateOn
	case choice == wire.SandboxChoiceOn:
		return wire.SandboxStateOn
	case choice == wire.SandboxChoiceOff:
		return wire.SandboxStateOff
	}
	return wire.SandboxStateRuntimeControlled
}

// noteEffectiveSandbox says on the agent what its sandbox is, once its runtime has started.
func (d *Daemon) noteEffectiveSandbox(id wire.UUID, choice wire.SandboxChoice, reason *string) {
	d.change(id, func(a *wire.Agent) {
		requested := d.defaultSandbox(a.RuntimeID)
		if a.SandboxOverride != nil {
			requested = *a.SandboxOverride
		}
		e := wire.EffectiveSandbox{State: sandboxState(a.RuntimeID, choice, stringValue(a.StartOptions.Values["mode"])),
			Requested: requested, Reason: reason}
		a.EffectiveSandbox = &e
	})
}

// setSandbox is agents/setSandbox: the agent's own choice, nil for the person's default.
// It is applied the next time its runtime starts; Codex's mode changes at once.
func (d *Daemon) setSandbox(ctx context.Context, r wire.SetSandboxRequest) (wire.Agent, error) {
	a := d.Store.Agent(r.AgentID)
	if a == nil {
		return wire.Agent{}, &Error{Code: CodeNoSuchAgent, Message: "That agent is not here."}
	}
	if r.Choice != nil && *r.Choice == wire.SandboxChoiceOff {
		if on, layer := d.effectiveSandboxOn(""); on {
			return wire.Agent{}, policyRefusal("policy", "sandbox", sandboxRequiredWordsFor(layer), nil, *layer)
		}
	}
	if r.Choice != nil && !slices.Contains(sandboxChoices(a.RuntimeID), *r.Choice) {
		why := sandboxCatalog[a.RuntimeID].why
		if why == "" {
			why = "The app cannot change this runtime’s sandbox."
		}
		return wire.Agent{}, Invalid("%s", why)
	}
	d.change(a.ID, func(a *wire.Agent) {
		if r.Choice == nil {
			a.SandboxOverride = nil
		} else {
			c := *r.Choice
			a.SandboxOverride = &c
		}
	})
	// Applied from its next turn: a runtime between turns is let go, and the next turn
	// starts it again with the choice in force, carrying on its conversation.
	if a.RuntimeID != "codex" {
		l := d.live(a.ID)
		l.mu.Lock()
		s := l.session
		if l.inTurn {
			s = nil
		}
		l.mu.Unlock()
		if s != nil {
			s.Stop()
		}
	}
	if a.RuntimeID == "codex" {
		choice, _ := d.resolveSandbox(a.RuntimeID, r.Choice, a.StartedByAgent)
		if mode, ok := codexStartMode(a.RuntimeID, choice, stringValue(a.StartOptions.Values["mode"])); ok {
			v, _ := json.Marshal(mode)
			if _, err := d.setOption(ctx, wire.SetOptionRequest{AgentID: a.ID, OptionID: "mode", Value: v}); err != nil {
				return wire.Agent{}, err
			}
		}
	}
	return *d.Store.Agent(a.ID), nil
}

// setSandboxDefaults is sandbox/set (064). A choice the catalog does not offer is dropped.
// "runtime" is said by leaving the runtime out. An agent's own choice is not touched.
func (d *Daemon) setSandboxDefaults(in wire.SandboxSettings) (wire.SandboxSettings, error) {
	kept := map[string]wire.SandboxChoice{}
	for runtime, choice := range in.Defaults {
		if choice == wire.SandboxChoiceRuntime || !slices.Contains(sandboxChoices(runtime), choice) {
			continue
		}
		kept[runtime] = choice
	}
	if err := d.writeSetting("sandbox.json", wire.SandboxSettings{Defaults: kept}); err != nil {
		return wire.SandboxSettings{}, &Error{Code: wire.FailureCouldNotSave, Message: "sandbox.json: " + err.Error()}
	}
	st := d.sandboxState()
	Broadcast(d, wire.NotifySandboxChanged, st)
	return st, nil
}

func (d *Daemon) registerSandbox() {
	On(d, wire.CallSandboxSet, func(ctx context.Context, c *Client, s wire.SandboxSettings) (wire.SandboxSettings, error) {
		return d.setSandboxDefaults(s)
	})
	On(d, wire.CallAgentsSetSandbox, func(ctx context.Context, c *Client, r wire.SetSandboxRequest) (wire.Agent, error) {
		return d.setSandbox(ctx, r)
	})
	On(d, wire.CallAgentsAnswerSandbox, func(ctx context.Context, c *Client, r wire.AnswerSandboxRequest) (wire.Agent, error) {
		return d.answerSandbox(ctx, r)
	})
}
