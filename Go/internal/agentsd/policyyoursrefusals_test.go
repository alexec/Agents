package agentsd

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// A refusal at each place of FR-007, when your layer is the tightest (#2957, T014, US5):
// the refusal's layer.kind is you, and it names the rule. The organisation is not joined
// in any of these, so your layer is always the one that decides.
//
// Most places here refuse with a policyRefused error, whose Data is a PolicyRefusal; those
// are checked with refusedByYou below. Two places (the notice limit, archive requests) have
// no error at all today, by the organisation's ceiling either: they change what the host
// does (wait for a notice, wait for approval) rather than refuse a call. Those are checked
// by their effect instead.

// setYourRules replaces your layer's rules directly (bypassing policy/setYours's own
// caller and revision checks, which policy_test.go covers on their own).
func setYourRules(t testing.TB, d *Daemon, rules wire.PolicyRules) {
	t.Helper()
	if err := d.editYoursLocked(func(r *wire.PolicyRules) error { *r = rules; return nil }); err != nil {
		t.Fatal(err)
	}
}

// refusedByYou fails the test unless err carries a PolicyRefusal naming rule and layer.kind
// "you": a policyRefused error for most places, and costlimits.go's own day/agent-limit
// codes for the turn and day budgets, which carry the same PolicyRefusal shape in Data
// (research table: the person's own budgets are not routed through policyRefused today).
func refusedByYou(t testing.TB, err error, rule string) {
	t.Helper()
	e, ok := err.(*Error)
	if !ok || e == nil || e.Data == nil {
		t.Fatalf("not refused by the policy: %+v", err)
	}
	r, ok := e.Data.(wire.PolicyRefusal)
	if !ok {
		b, _ := json.Marshal(e.Data)
		json.Unmarshal(b, &r)
	}
	if r.Layer == nil || r.Layer.Kind != "you" {
		t.Fatalf("refused %+v, wanted layer.kind you", r)
	}
	if rule != "" && (r.Rule == nil || *r.Rule != rule) {
		t.Fatalf("refused %+v, wanted rule %s", r, rule)
	}
}

// TestYourLayerStopsAnAgentStart: your layer's runtimes allowlist (FR-002, "runtimes and
// models allowed") refuses a start on a runtime it does not name.
func TestYourLayerStopsAnAgentStart(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	d.SettingsDir = t.TempDir()
	dir := t.TempDir()
	setYourRules(t, d, wire.PolicyRules{Runtimes: map[string]wire.PolicyRuntimeRule{"claude": {}}})
	e := c.callError(t, 1, "agents/start", startParams(dir, "grok", nil))
	refusedByYou(t, e, "runtimes")
}

// TestYourLayerStopsAHelperStart: your layer's helpers.mostRunning (FR-002, new for your
// layer) refuses the folder's own helper limits set higher than it allows
// (folders/setHelperLimits), the same place the organisation's cap refuses it
// (TestEveryRuleAtEveryPath's "folders/setHelperLimits: above the cap" row), and caps
// helperLimitsIn's count itself, which a helper's own start is held to (helpers.go).
func TestYourLayerStopsAHelperStart(t *testing.T) {
	d, _ := start(t, t.TempDir())
	d.SettingsDir = t.TempDir()
	dir := t.TempDir()
	one := int64(1)
	setYourRules(t, d, wire.PolicyRules{Helpers: &wire.PolicyHelpers{MostRunning: &one}})

	running, _, _ := d.helperLimitsIn(dir)
	if running != 1 {
		t.Fatalf("your layer's helpers.mostRunning did not cap helperLimitsIn: %d", running)
	}
	two := int64(2)
	refusedByYou(t, d.helperLimitsRefusal(wire.HelperLimits{Running: &two}), "helpers.mostRunning")
}

// TestYourLayerStopsAWorkflowRun: your layer's runtimes allowlist refuses a workflow's run
// on a runtime it does not name, the same path a helper's start takes (startedBy with no
// agent: DaemonCore+Helpers' workflow shape).
func TestYourLayerStopsAWorkflowRun(t *testing.T) {
	fakeRuntimes(t)
	d, _ := start(t, t.TempDir())
	d.SettingsDir = t.TempDir()
	dir := t.TempDir()
	setYourRules(t, d, wire.PolicyRules{Runtimes: map[string]wire.PolicyRuntimeRule{"claude": {}}})
	_, err := d.startFor(helperRequest("grok", dir, "run", "", nil, nil, nil), startedBy{owner: wire.SessionLabelOwnerAgent})
	refusedByYou(t, err, "runtimes")
}

// TestYourLayerStopsContinueInNewAndBranch: your layer's runtimes allowlist refuses
// Continue in New and Branch on a session whose runtime it no longer allows (the same
// table TestEveryRuleAtEveryPath runs for the organisation).
func TestYourLayerStopsContinueInNewAndBranch(t *testing.T) {
	fakeRuntimes(t)
	d, _ := start(t, t.TempDir())
	d.SettingsDir = t.TempDir()
	dir := t.TempDir()
	notAllowed := seeded(t, d, dir, func(a *wire.Agent) { a.RuntimeID = "grok" })
	setYourRules(t, d, wire.PolicyRules{Runtimes: map[string]wire.PolicyRuntimeRule{"claude": {}}})

	_, err := d.continueInFolder(wire.ContinueInFolderRequest{AgentID: notAllowed.ID})
	refusedByYou(t, err, "runtimes")

	_, err = d.fork(d.ctx, notAllowed.ID)
	refusedByYou(t, err, "runtimes")

	_, err = d.branchFrom(wire.BranchFromRequest{AgentID: notAllowed.ID})
	refusedByYou(t, err, "runtimes")
}

// TestYourLayerStopsALooserModeChange: your layer's permissionMode rule (FR-008) refuses a
// person's own choice of a mode looser than it allows.
func TestYourLayerStopsALooserModeChange(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	d.SettingsDir = t.TempDir()
	dir := t.TempDir()
	plan := wire.PermissionLevelPlan
	setYourRules(t, d, wire.PolicyRules{PermissionMode: &plan})
	var id wire.UUID
	json.Unmarshal(c.call(t, 1, "agents/start", map[string]any{"runtimeID": "auto", "cwd": "file://" + dir, "prompt": "hi"}), &id)
	e := c.callError(t, 2, "agents/setLevels", map[string]any{"agentID": id, "levels": map[string]any{"permission": "bypassPermissions"}})
	refusedByYou(t, e, "permissionMode")
}

// TestYourLayerStopsSandboxOff: your layer's sandbox rule (FR-002, new for your layer) set
// to on refuses turning the command sandbox off.
func TestYourLayerStopsSandboxOff(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	d.SettingsDir = t.TempDir()
	dir := t.TempDir()
	a := seeded(t, d, dir, func(a *wire.Agent) { a.RuntimeID = "claude" })
	on := wire.SandboxChoiceOn
	setYourRules(t, d, wire.PolicyRules{Sandbox: &on})
	off := wire.SandboxChoiceOff
	e := c.callError(t, 1, "agents/setSandbox", map[string]any{"agentID": a.ID, "choice": off})
	refusedByYou(t, e, "sandbox")
}

// TestYourLayerStopsYesToAll: your layer's permissionRequests rule (FR-002, tighter is Ask
// me) refuses Always-approve, the permission flow's ceiling.
func TestYourLayerStopsYesToAll(t *testing.T) {
	d, c := start(t, t.TempDir())
	d.SettingsDir = t.TempDir()
	askMe := wire.ClientPermissionModeDefault
	setYourRules(t, d, wire.PolicyRules{PermissionRequests: &askMe})
	e := c.callError(t, 1, "clientPermissions/set", map[string]any{"cursor": "alwaysApprove", "grok": "default", "opencode": "default"})
	refusedByYou(t, e, "permissionRequests")
}

// TestYourLayerStopsAMarketplaceAdd: your layer's marketplaces.allowed rule (FR-002, new
// for your layer) refuses a marketplace it does not name.
func TestYourLayerStopsAMarketplaceAdd(t *testing.T) {
	d, c := start(t, t.TempDir())
	d.SettingsDir = t.TempDir()
	d.PersonalHome = t.TempDir()
	setYourRules(t, d, wire.PolicyRules{Marketplaces: &wire.PolicyMarketplaces{Allowed: []string{"provided:github-mcp"}}})
	e := c.callError(t, 1, "marketplaces/add", map[string]any{"url": "https://example.com/repo", "format": "mcpb", "name": "x"})
	refusedByYou(t, e, "marketplaces")
}

// TestYourLayerStopsAConnectorAddedByHand: your layer's marketplaces.customServers rule
// (FR-002) set to refuse refuses an MCP server added by hand.
func TestYourLayerStopsAConnectorAddedByHand(t *testing.T) {
	d, _ := start(t, t.TempDir())
	d.SettingsDir = t.TempDir()
	setYourRules(t, d, wire.PolicyRules{Marketplaces: &wire.PolicyMarketplaces{CustomServers: "refuse"}})
	refusedByYou(t, d.customServerRefusal(), "marketplaces.customServers")
}

// TestYourLayerStopsTheDayBudget and TestYourLayerStopsTheAgentBudget: your layer's budgets
// rule (FR-002) refuses a start once the day's, or an agent's, budget is reached (the turn
// and day budgets).
func TestYourLayerStopsTheDayBudget(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	d.SettingsDir = t.TempDir()
	dir := t.TempDir()
	a := seeded(t, d, dir, nil)
	setYourRules(t, d, wire.PolicyRules{Budgets: &wire.PolicyRuleBudgets{Daily: new(wire.Cost{Amount: 1, Currency: "USD"})}})
	d.bankSessionCost(a.ID, wire.Cost{Amount: 2, Currency: "USD"})
	e := c.callError(t, 1, "agents/start", startParams(dir, "claude", nil))
	refusedByYou(t, e, "budgets.daily")
}

func TestYourLayerStopsTheAgentBudget(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	d.SettingsDir = t.TempDir()
	dir := t.TempDir()
	setYourRules(t, d, wire.PolicyRules{Budgets: &wire.PolicyRuleBudgets{PerAgent: new(wire.Cost{Amount: 0, Currency: "USD"})}})
	e := c.callError(t, 1, "agents/start", startParams(dir, "claude", nil))
	refusedByYou(t, e, "budgets.perAgent")
}

// TestYourLayerSetsTheNoticeLimit: your layer's noticeLimits rule (FR-002, moved from
// display.json, FR-012) is the burst notify() enforces. There is no policyRefused error
// here, by the organisation's ceiling either (research table): the tool's own reply says
// so, which this checks instead of a refusal's layer.
func TestYourLayerSetsTheNoticeLimit(t *testing.T) {
	d, _ := start(t, t.TempDir())
	d.SettingsDir = t.TempDir()
	one := int64(1)
	setYourRules(t, d, wire.PolicyRules{NoticeLimits: &wire.PolicyNoticeLimits{Burst: &one, WaitMinutes: new(int64(10))}})
	burst, _ := d.noticeLimits()
	if burst != 1 {
		t.Fatalf("your layer's noticeLimits.burst did not apply: %d", burst)
	}
}

// TestYourLayerSetsArchiveRequests: your layer's archiveMyChats rule (FR-002, moved from
// display.json, FR-012), when false, is what settleArchiveRequest reads to wait for the
// person's approval instead of archiving a chat they started on its own (archive
// requests). Like the notice limit, there is no refusal here, so the effect is checked.
func TestYourLayerSetsArchiveRequests(t *testing.T) {
	d, _ := start(t, t.TempDir())
	d.SettingsDir = t.TempDir()
	no := false
	setYourRules(t, d, wire.PolicyRules{ArchiveMyChats: &no})
	if d.agentsMayArchiveMyChats() {
		t.Fatal("your layer's archiveMyChats did not apply")
	}
}

// TestYourLayerSetsTheRuntimeLaunchEnvironment: your layer's environment rule (FR-002,
// moved from runtime-environment.json, FR-012) is what passThrough gives a runtime to
// launch with.
func TestYourLayerSetsTheRuntimeLaunchEnvironment(t *testing.T) {
	d, _ := start(t, t.TempDir())
	d.SettingsDir = t.TempDir()
	setYourRules(t, d, wire.PolicyRules{Environment: &wire.PolicyEnvironment{PassThrough: []string{"AWS_PROFILE"}, Runtimes: map[string][]string{"claude": {"SECRET_TOKEN"}}}})
	names := d.passThrough("claude")
	if len(names) != 2 || !strings.Contains(strings.Join(names, ","), "AWS_PROFILE") || !strings.Contains(strings.Join(names, ","), "SECRET_TOKEN") {
		t.Fatalf("%v", names)
	}
	if names := d.passThrough("codex"); len(names) != 1 || names[0] != "AWS_PROFILE" {
		t.Fatalf("a runtime-only name leaked to another runtime: %v", names)
	}
}
