package agentsd

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/agentsd/yamlnode"
	"github.com/alexec/agents/Go/wire"
)

// Auto and the shared words (#2658): every cell of the shipped table is filled and gives no
// more access than its value says; Auto picks the first runtime that can take the session,
// leaves out the excluded and the out ones, tries a rate-limited one last, and says why
// when none can; the person's own cells win; workflows on Auto take only the shared words.

// SC-004, SC-005.
func TestTheShippedAutoMapIsWholeAndSafe(t *testing.T) {
	settings := wire.AutoSettings{}
	for _, rt := range catalog {
		for _, f := range autoFields {
			minRank := 99
			for _, l := range levelsOf(f) {
				if c := shippedCell(rt.ID, f, l); c.mark != wire.AutoMarkNotPossible && c.rank < minRank {
					minRank = c.rank
				}
			}
			for _, l := range levelsOf(f) {
				m := cellMapping(rt.ID, f, l, settings, nil)
				if m.Words == "" || m.Mark == "" {
					t.Errorf("%s %s %s: an empty cell", rt.ID, f, l)
				}
				if m.Mark != wire.AutoMarkNotPossible && m.Native == nil {
					t.Errorf("%s %s %s: no setting", rt.ID, f, l)
				}
				ranks, ranked := levelRank[f]
				if !ranked || m.Mark == wire.AutoMarkNotPossible {
					continue
				}
				c := shippedCell(rt.ID, f, l)
				switch {
				case c.rank <= ranks[l]:
				case c.mark == wire.AutoMarkNearestSafer && c.rank == minRank:
					// No setting of the runtime gives less: the nearest one, said in the cell.
				default:
					t.Errorf("%s %s %s: gives more access (%d) than its value (%d)", rt.ID, f, l, c.rank, ranks[l])
				}
			}
		}
	}
	if m := cellMapping("opencode", wire.AutoFieldSandbox, "on", settings, nil); m.Mark != wire.AutoMarkNotPossible {
		t.Fatalf("%+v", m)
	}
	if m := cellMapping("grok", wire.AutoFieldPermission, "plan", settings, nil); m.Mark != wire.AutoMarkNearestSafer || m.Note == nil || *m.Note != "nearest safer: no plan mode" {
		t.Fatalf("%+v", m)
	}
}

// A model the runtime no longer offers is dropped, and Auto passes that runtime by (FR-020).
func TestADroppedCell(t *testing.T) {
	cat := "model"
	offers := []wire.ConfigOption{{ID: "model", Name: "Model", Type: "select", Category: &cat,
		Options: json.RawMessage(`[{"value":"sonnet","name":"Sonnet 5"},{"value":"opus[1m]","name":"Opus 5.5"}]`)}}
	settings := wire.AutoSettings{}
	if m := cellMapping("claude", wire.AutoFieldModel, "fast", settings, offers); m.Mark != wire.AutoMarkDropped {
		t.Fatalf("%+v", m)
	}
	if m := cellMapping("claude", wire.AutoFieldModel, "balanced", settings, offers); m.Mark != wire.AutoMarkAutoMapped || m.Words != "Sonnet 5" {
		t.Fatalf("%+v", m)
	}
	// Opus with 1M context, else Opus: the first the plan has.
	offers[0].Options = json.RawMessage(`[{"value":"opus","name":"Opus 5.5"}]`)
	if m := cellMapping("claude", wire.AutoFieldModel, "smart", settings, offers); m.Native == nil || stringValue(m.Native.Options["model"]) != "opus" {
		t.Fatalf("%+v", m)
	}
}

func out(d *Daemon, runtime string, rateLimited bool) {
	s := availableState(ownKey(runtime))
	s.Status = wire.AllowanceStateStatus{Out: &wire.AllowanceStateStatusOut{Why: wire.AllowanceStateOutReasonAllowanceSpent}}
	if rateLimited {
		s.Status = wire.AllowanceStateStatus{RateLimited: &wire.AllowanceStateStatusRateLimited{Until: now()}}
	}
	d.allowMu.Lock()
	d.allowancesLocked()[s.CredentialKey] = s
	d.allowMu.Unlock()
}

func TestAutoPicksTheRuntime(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	d.SettingsDir = t.TempDir()
	dir := "file://" + t.TempDir()
	startAuto := func(id int, levels map[string]any) wire.Agent {
		var agent wire.UUID
		json.Unmarshal(c.call(t, id, "agents/start", map[string]any{"runtimeID": "auto", "cwd": dir, "prompt": "hello", "levels": levels}), &agent)
		return *d.Store.Agent(agent)
	}
	a := startAuto(1, map[string]any{"model": "balanced", "permission": "ask"})
	if a.RuntimeID != "claude" || a.Auto == nil || a.Auto.RuntimeID != "claude" {
		t.Fatalf("%s %+v", a.RuntimeID, a.Auto)
	}
	if stringValue(a.StartOptions.Values["model"]) != "sonnet" || stringValue(a.StartOptions.Values["mode"]) != "default" {
		t.Fatalf("%s", a.StartOptions.Values)
	}
	if a.Levels == nil || a.Levels.Model == nil || *a.Levels.Model != wire.ModelLevelBalanced || *a.Levels.Permission != wire.PermissionLevelAsk {
		t.Fatalf("%+v", a.Levels)
	}
	// Claude out: the next in the order.
	out(d, "claude", false)
	if a := startAuto(2, map[string]any{"permission": "plan"}); a.RuntimeID != "codex" || stringValue(a.StartOptions.Values["collaboration_mode"]) != "plan" ||
		len(a.Auto.Skipped) != 1 || a.Auto.Skipped[0].Reason != "out" {
		t.Fatalf("%s %+v", a.RuntimeID, a.Auto)
	}
	// The person's order and Include switches.
	c.call(t, 3, "auto/set", map[string]any{"order": []string{"gemini", "codex"}, "excluded": []string{"codex"}, "overrides": []any{}})
	if a := startAuto(4, nil); a.RuntimeID != "gemini" {
		t.Fatal(a.RuntimeID)
	}
	// Runtime sandbox: Gemini cannot, and nor can the rest once Claude is out and Codex
	// left out. The prompt stays, with why for each.
	err := c.callError(t, 5, "agents/start", map[string]any{"runtimeID": "auto", "cwd": dir, "prompt": "hello", "sandbox": "on"})
	if err == nil || !strings.Contains(err.Message, "Gemini: no Runtime sandbox") {
		t.Fatalf("%+v", err)
	}
}

func TestAutoWhenNoRuntimeCan(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	d.SettingsDir = t.TempDir()
	var all []string
	for _, r := range catalog {
		if r.ID != "claude" {
			all = append(all, r.ID)
		}
	}
	c.call(t, 1, "auto/set", map[string]any{"order": []string{}, "excluded": all, "overrides": []any{}})
	out(d, "claude", false)
	err := c.callError(t, 2, "agents/start", map[string]any{"runtimeID": "auto", "cwd": "file://" + t.TempDir(), "prompt": "hello"})
	if err == nil || err.Code != wire.FailureAutoNoRuntime || !strings.Contains(err.Message, "Claude: out") || !strings.Contains(err.Message, "Codex: left out") {
		t.Fatalf("%+v", err)
	}
	var p wire.AutoPreview
	json.Unmarshal(c.call(t, 3, "auto/preview", map[string]any{"cwd": "file://" + t.TempDir()}), &p)
	if p.RuntimeID != nil || len(p.Skipped) != len(catalog) {
		t.Fatalf("%+v", p)
	}
	// A rate-limited runtime is still taken when no other can.
	out(d, "claude", true)
	json.Unmarshal(c.call(t, 4, "auto/preview", map[string]any{"cwd": "file://" + t.TempDir()}), &p)
	if p.RuntimeID == nil || *p.RuntimeID != "claude" {
		t.Fatalf("%+v", p)
	}
}

// The person's own cell wins, on Auto and on a named runtime (FR-016, FR-018); a native value
// in the start wins over a level (the ⋯ own menu).
func TestTheMappingsAreThePersons(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	d.SettingsDir = t.TempDir()
	bypass := map[string]any{"options": map[string]any{"mode": "bypassPermissions"}}
	c.call(t, 1, "auto/set", map[string]any{"order": []string{}, "excluded": []string{},
		"overrides": []any{map[string]any{"runtimeID": "claude", "field": "permission", "level": "approveForMe", "native": bypass}}})
	var m wire.AutoMappings
	json.Unmarshal(c.call(t, 2, "auto/mappings", map[string]any{}), &m)
	found := false
	for _, cell := range m.Cells {
		if cell.RuntimeID == "claude" && cell.Field == wire.AutoFieldPermission && cell.Level == "approveForMe" {
			found = cell.Mark == wire.AutoMarkYours && stringValue(cell.Native.Options["mode"]) == "bypassPermissions"
		}
	}
	if !found || len(m.Cells) != len(catalog)*11 || len(m.Choices) == 0 {
		t.Fatalf("%v %d", found, len(m.Cells))
	}
	var id wire.UUID
	json.Unmarshal(c.call(t, 3, "agents/start", map[string]any{"runtimeID": "claude", "cwd": "file://" + t.TempDir(), "prompt": "hello",
		"levels": map[string]any{"permission": "approveForMe", "model": "smart"}, "startOptions": map[string]any{"values": map[string]any{"model": "haiku"}, "extraArguments": []string{}}}), &id)
	a := d.Store.Agent(id)
	if stringValue(a.StartOptions.Values["mode"]) != "bypassPermissions" || stringValue(a.StartOptions.Values["model"]) != "haiku" || a.Auto != nil {
		t.Fatalf("%s", a.StartOptions.Values)
	}
	if a.Levels == nil || a.Levels.Permission == nil || *a.Levels.Permission != wire.PermissionLevelApproveForMe || a.Levels.Model != nil {
		t.Fatalf("%+v", a.Levels)
	}
}

// A per-agent answer to permission requests, before the person's in Settings (FR-019).
func TestAnAgentsOwnPermissionRequests(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	d.SettingsDir = t.TempDir()
	var id wire.UUID
	json.Unmarshal(c.call(t, 1, "agents/start", map[string]any{"runtimeID": "cursor", "cwd": "file://" + t.TempDir(), "prompt": "hello",
		"levels": map[string]any{"permissionRequests": "alwaysApprove"}}), &id)
	if a := d.Store.Agent(id); !d.agentAlwaysApproves(a) || d.alwaysApproves("cursor") {
		t.Fatal("not the agent's own")
	}
	var a wire.Agent
	json.Unmarshal(c.call(t, 2, "agents/setClientPermission", map[string]any{"agentID": id}), &a)
	if a.ClientPermission != nil || d.agentAlwaysApproves(&a) {
		t.Fatalf("%+v", a.ClientPermission)
	}
}

// Story 5: workflows take the shared words; on Auto, only them.
func TestWorkflowWordsOnAuto(t *testing.T) {
	read := func(src string) error {
		m, err := yamlnode.MappingFrom(strings.Split(strings.TrimSpace(src), "\n"))
		if err != nil {
			t.Fatal(err)
		}
		_, err = workflowSettings(m)
		return err
	}
	if err := read("runtime: auto\nmodel: smart\npermission-mode: plan\nsandbox: runtime\n"); err != nil {
		t.Fatal(err)
	}
	if err := read("runtime: auto\nmodel: opus\n"); err == nil || !strings.Contains(err.Error(), "fast") {
		t.Fatal(err)
	}
	if err := read("runtime: claude\nmodel: opus\npermission-mode: acceptEdits\n"); err != nil {
		t.Fatal(err)
	}
	if err := read("permission-requests: always\n"); err == nil {
		t.Fatal("took a word it does not know")
	}
	levels, model, mode, box, err := fileLevels("auto", "fast", new("approve-for-me"), "", "none")
	if err != nil || model != "" || mode != nil || *levels.Model != wire.ModelLevelFast || *levels.Permission != wire.PermissionLevelApproveForMe || *box != wire.SandboxChoiceOff {
		t.Fatal(levels, model, mode, box, err)
	}
}
