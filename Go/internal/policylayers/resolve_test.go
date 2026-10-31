package policylayers

import (
	"encoding/json"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

func i64(v int64) *int64                                                          { return &v }
func str(v string) *string                                                        { return &v }
func boolp(v bool) *bool                                                          { return &v }
func cost(v float64) *wire.Cost                                                   { return &wire.Cost{Amount: v, Currency: "USD"} }
func permissionLevel(v wire.PermissionLevel) *wire.PermissionLevel                { return &v }
func clientPermissionMode(v wire.ClientPermissionMode) *wire.ClientPermissionMode { return &v }
func sandboxChoice(v wire.SandboxChoice) *wire.SandboxChoice                      { return &v }

var (
	orgRef    = wire.PolicyLayerRef{Kind: "organisation", Name: "Acme"}
	youRef    = wire.PolicyLayerRef{Kind: "you", Name: "You"}
	folderRef = wire.PolicyLayerRef{Kind: "folder", Name: "payments-api", Folder: str("/p")}
)

// layersWith builds the three layers, top down, with one of them holding tight and the
// other two holding loose.
func layersWith(tightKind string, tight, loose wire.PolicyRules) []Layer {
	pick := func(kind string) wire.PolicyRules {
		if kind == tightKind {
			return tight
		}
		return loose
	}
	return []Layer{
		{Ref: orgRef, Rules: pick("organisation")},
		{Ref: youRef, Rules: pick("you")},
		{Ref: folderRef, Rules: pick("folder")},
	}
}

func ruleOf(ep wire.EffectivePolicy, rule wire.PolicyRuleName) wire.EffectiveRule {
	for _, r := range ep.Rules {
		if r.Rule == rule {
			return r
		}
	}
	panic("rule not found: " + rule)
}

// SC-003: for every rule and every pair of layers, with the tightest value set in each
// layer in turn, the resolved effective value is never looser than the tightest layer that
// sets it (0 escapes).
func TestResolveNeverLooserThanTheTightestLayer(t *testing.T) {
	type tc struct {
		name  string
		rule  wire.PolicyRuleName
		tight wire.PolicyRules
		loose wire.PolicyRules
	}
	cases := []tc{
		{"permissionMode", wire.PolicyRuleNamePermissionMode,
			wire.PolicyRules{PermissionMode: permissionLevel(wire.PermissionLevelPlan)},
			wire.PolicyRules{PermissionMode: permissionLevel(wire.PermissionLevelBypassPermissions)}},
		{"permissionRequests", wire.PolicyRuleNamePermissionRequests,
			wire.PolicyRules{PermissionRequests: clientPermissionMode(wire.ClientPermissionModeDefault)},
			wire.PolicyRules{PermissionRequests: clientPermissionMode(wire.ClientPermissionModeAlwaysApprove)}},
		{"sandbox", wire.PolicyRuleNameSandbox,
			wire.PolicyRules{Sandbox: sandboxChoice(wire.SandboxChoiceOn)},
			wire.PolicyRules{Sandbox: sandboxChoice(wire.SandboxChoiceOff)}},
		{"budgets.perAgent", wire.PolicyRuleNameBudgetsPerAgent,
			wire.PolicyRules{Budgets: &wire.PolicyRuleBudgets{PerAgent: cost(10)}},
			wire.PolicyRules{Budgets: &wire.PolicyRuleBudgets{PerAgent: cost(100)}}},
		{"budgets.daily", wire.PolicyRuleNameBudgetsDaily,
			wire.PolicyRules{Budgets: &wire.PolicyRuleBudgets{Daily: cost(10)}},
			wire.PolicyRules{Budgets: &wire.PolicyRuleBudgets{Daily: cost(100)}}},
		{"budgets.perAgentTokens", wire.PolicyRuleNameBudgetsPerAgentTokens,
			wire.PolicyRules{Budgets: &wire.PolicyRuleBudgets{PerAgentTokens: i64(1000)}},
			wire.PolicyRules{Budgets: &wire.PolicyRuleBudgets{PerAgentTokens: i64(100000)}}},
		{"budgets.dailyTokens", wire.PolicyRuleNameBudgetsDailyTokens,
			wire.PolicyRules{Budgets: &wire.PolicyRuleBudgets{DailyTokens: i64(1000)}},
			wire.PolicyRules{Budgets: &wire.PolicyRuleBudgets{DailyTokens: i64(100000)}}},
		{"helpers.mostRunning", wire.PolicyRuleNameHelpersMostRunning,
			wire.PolicyRules{Helpers: &wire.PolicyHelpers{MostRunning: i64(1)}},
			wire.PolicyRules{Helpers: &wire.PolicyHelpers{MostRunning: i64(10)}}},
		{"helpers.mostNotArchived", wire.PolicyRuleNameHelpersMostNotArchived,
			wire.PolicyRules{Helpers: &wire.PolicyHelpers{MostNotArchived: i64(1)}},
			wire.PolicyRules{Helpers: &wire.PolicyHelpers{MostNotArchived: i64(20)}}},
		{"workflows.mostOn", wire.PolicyRuleNameWorkflowsMostOn,
			wire.PolicyRules{Workflows: &wire.PolicyWorkflows{MostOn: i64(1)}},
			wire.PolicyRules{Workflows: &wire.PolicyWorkflows{MostOn: i64(100)}}},
		{"noticeLimits.burst", wire.PolicyRuleNameNoticeLimitsBurst,
			wire.PolicyRules{NoticeLimits: &wire.PolicyNoticeLimits{Burst: i64(1)}},
			wire.PolicyRules{NoticeLimits: &wire.PolicyNoticeLimits{Burst: i64(20)}}},
		{"noticeLimits.waitMinutes", wire.PolicyRuleNameNoticeLimitsWaitMinutes,
			wire.PolicyRules{NoticeLimits: &wire.PolicyNoticeLimits{WaitMinutes: i64(1440)}},
			wire.PolicyRules{NoticeLimits: &wire.PolicyNoticeLimits{WaitMinutes: i64(1)}}},
		{"archiveMyChats", wire.PolicyRuleNameArchiveMyChats,
			wire.PolicyRules{ArchiveMyChats: boolp(false)},
			wire.PolicyRules{ArchiveMyChats: boolp(true)}},
		{"runtimes", wire.PolicyRuleNameRuntimes,
			wire.PolicyRules{Runtimes: map[string]wire.PolicyRuntimeRule{"claude": {}}},
			wire.PolicyRules{Runtimes: map[string]wire.PolicyRuntimeRule{"claude": {}, "codex": {}, "grok": {}}}},
		{"marketplaces.allowed", wire.PolicyRuleNameMarketplacesAllowed,
			wire.PolicyRules{Marketplaces: &wire.PolicyMarketplaces{Allowed: []string{"github"}, CustomServers: "allow"}},
			wire.PolicyRules{Marketplaces: &wire.PolicyMarketplaces{Allowed: []string{"github", "gitlab", "npm"}, CustomServers: "allow"}}},
		{"marketplaces.customServers", wire.PolicyRuleNameMarketplacesCustomServers,
			wire.PolicyRules{Marketplaces: &wire.PolicyMarketplaces{Allowed: []string{}, CustomServers: "refuse"}},
			wire.PolicyRules{Marketplaces: &wire.PolicyMarketplaces{Allowed: []string{}, CustomServers: "allow"}}},
		{"environment", wire.PolicyRuleNameEnvironment,
			wire.PolicyRules{Environment: &wire.PolicyEnvironment{PassThrough: []string{"API_KEY"}}},
			wire.PolicyRules{Environment: &wire.PolicyEnvironment{PassThrough: []string{"API_KEY", "HOME", "PATH"}}}},
	}
	kinds := []string{"organisation", "you", "folder"}
	for _, c := range cases {
		for _, kind := range kinds {
			t.Run(c.name+"/"+kind, func(t *testing.T) {
				ep := Resolve(layersWith(kind, c.tight, c.loose))
				r := ruleOf(ep, c.rule)
				if r.Decides == nil {
					t.Fatalf("no layer decides %s", c.name)
				}
				if r.Decides.Kind != kind {
					t.Fatalf("%s: decides is %q, want %q (0 escapes)", c.name, r.Decides.Kind, kind)
				}
				wantTight := ruleOf(Resolve([]Layer{{Ref: wire.PolicyLayerRef{Kind: kind, Name: "x"}, Rules: c.tight}}), c.rule).Value
				if string(r.Value) != string(wantTight) {
					t.Fatalf("%s: effective value %s is looser than the tightest layer's %s", c.name, r.Value, wantTight)
				}
			})
		}
	}
}

func TestResolveRuleNoLayerSetsHasNoDecides(t *testing.T) {
	ep := Resolve([]Layer{{Ref: orgRef, Rules: wire.PolicyRules{}}, {Ref: youRef, Rules: wire.PolicyRules{}}, {Ref: folderRef, Rules: wire.PolicyRules{}}})
	for _, r := range ep.Rules {
		if r.Decides != nil {
			t.Fatalf("rule %s: no layer sets it, so decides must be absent (today's default applies)", r.Rule)
		}
		for _, lv := range r.Layers {
			if lv.Words != "Not set" || lv.Kept {
				t.Fatalf("rule %s: an unset layer must show \"Not set\" and not be kept", r.Rule)
			}
		}
	}
	if len(ep.Rules) != 17 {
		t.Fatalf("got %d rules, want 17 (FR-002)", len(ep.Rules))
	}
}

func TestResolveLooserLayerIsKeptNotUsed(t *testing.T) {
	tight := wire.PolicyRules{Budgets: &wire.PolicyRuleBudgets{Daily: cost(10)}}
	loose := wire.PolicyRules{Budgets: &wire.PolicyRuleBudgets{Daily: cost(100)}}
	ep := Resolve(layersWith("you", tight, loose))
	r := ruleOf(ep, wire.PolicyRuleNameBudgetsDaily)
	for _, lv := range r.Layers {
		switch lv.Layer.Kind {
		case "you":
			if lv.Kept {
				t.Fatal("the deciding layer must not be marked kept")
			}
		case "organisation", "folder":
			if !lv.Kept {
				t.Fatalf("%s set a looser value than you, so it must be kept, not used (FR-006)", lv.Layer.Kind)
			}
		}
	}
}

func TestResolveFoldersWithRulesAndBehindAreNeverNil(t *testing.T) {
	ep := Resolve(nil)
	if ep.FoldersWithRules == nil || ep.Behind == nil {
		t.Fatal("foldersWithRules and behind must be present, even when empty")
	}
	var roundtrip wire.EffectivePolicy
	b, err := json.Marshal(ep)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(b, &roundtrip); err != nil {
		t.Fatal(err)
	}
}
