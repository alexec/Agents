package policylayers

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"

	"github.com/alexec/agents/Go/wire"
)

// Resolve finds the effective policy for a folder (or, with no folder layer, for "no
// folder") from its layers, top down (data-model.md "Resolve"; FR-005). For each rule: the
// effective value is the tightest of every layer that sets it; decides is the highest layer
// with that value; every other layer that sets a looser value is kept, not used (FR-006). A
// rule no layer sets has no decides: today's default applies.
func Resolve(layers []Layer) wire.EffectivePolicy {
	return wire.EffectivePolicy{
		Rules: []wire.EffectiveRule{
			scalar(wire.PolicyRuleNamePermissionMode, layers,
				func(r wire.PolicyRules) (wire.PermissionLevel, bool) {
					if r.PermissionMode == nil {
						return "", false
					}
					return *r.PermissionMode, true
				},
				func(v wire.PermissionLevel) float64 { return float64(PermissionModeOrder(v)) },
				permissionModeWords),
			scalar(wire.PolicyRuleNamePermissionRequests, layers,
				func(r wire.PolicyRules) (wire.ClientPermissionMode, bool) {
					if r.PermissionRequests == nil {
						return "", false
					}
					return *r.PermissionRequests, true
				},
				func(v wire.ClientPermissionMode) float64 { return float64(PermissionRequestsOrder(v)) },
				permissionRequestsWords),
			scalar(wire.PolicyRuleNameSandbox, layers,
				func(r wire.PolicyRules) (wire.SandboxChoice, bool) {
					if r.Sandbox == nil {
						return "", false
					}
					return *r.Sandbox, true
				},
				func(v wire.SandboxChoice) float64 { return float64(SandboxOrder(v)) },
				sandboxWords),
			scalar(wire.PolicyRuleNameBudgetsPerAgent, layers,
				func(r wire.PolicyRules) (float64, bool) {
					if r.Budgets == nil || r.Budgets.PerAgent == nil {
						return 0, false
					}
					return r.Budgets.PerAgent.Amount, true
				},
				NumberTighterIsLess, moneyWords("per agent")),
			scalar(wire.PolicyRuleNameBudgetsDaily, layers,
				func(r wire.PolicyRules) (float64, bool) {
					if r.Budgets == nil || r.Budgets.Daily == nil {
						return 0, false
					}
					return r.Budgets.Daily.Amount, true
				},
				NumberTighterIsLess, moneyWords("a day")),
			scalar(wire.PolicyRuleNameBudgetsPerAgentTokens, layers,
				func(r wire.PolicyRules) (float64, bool) {
					if r.Budgets == nil || r.Budgets.PerAgentTokens == nil {
						return 0, false
					}
					return float64(*r.Budgets.PerAgentTokens), true
				},
				NumberTighterIsLess, tokensWords("per agent")),
			scalar(wire.PolicyRuleNameBudgetsDailyTokens, layers,
				func(r wire.PolicyRules) (float64, bool) {
					if r.Budgets == nil || r.Budgets.DailyTokens == nil {
						return 0, false
					}
					return float64(*r.Budgets.DailyTokens), true
				},
				NumberTighterIsLess, tokensWords("a day")),
			scalar(wire.PolicyRuleNameHelpersMostRunning, layers,
				func(r wire.PolicyRules) (float64, bool) {
					if r.Helpers == nil || r.Helpers.MostRunning == nil {
						return 0, false
					}
					return float64(*r.Helpers.MostRunning), true
				},
				NumberTighterIsLess, countWords("running at once")),
			scalar(wire.PolicyRuleNameHelpersMostNotArchived, layers,
				func(r wire.PolicyRules) (float64, bool) {
					if r.Helpers == nil || r.Helpers.MostNotArchived == nil {
						return 0, false
					}
					return float64(*r.Helpers.MostNotArchived), true
				},
				NumberTighterIsLess, countWords("not archived")),
			scalar(wire.PolicyRuleNameWorkflowsMostOn, layers,
				func(r wire.PolicyRules) (float64, bool) {
					if r.Workflows == nil || r.Workflows.MostOn == nil {
						return 0, false
					}
					return float64(*r.Workflows.MostOn), true
				},
				NumberTighterIsLess, countWords("turned on")),
			scalar(wire.PolicyRuleNameNoticeLimitsBurst, layers,
				func(r wire.PolicyRules) (float64, bool) {
					if r.NoticeLimits == nil || r.NoticeLimits.Burst == nil {
						return 0, false
					}
					return float64(*r.NoticeLimits.Burst), true
				},
				NumberTighterIsLess, countWords("in a burst")),
			scalar(wire.PolicyRuleNameNoticeLimitsWaitMinutes, layers,
				func(r wire.PolicyRules) (float64, bool) {
					if r.NoticeLimits == nil || r.NoticeLimits.WaitMinutes == nil {
						return 0, false
					}
					return float64(*r.NoticeLimits.WaitMinutes), true
				},
				NumberTighterIsMore, minutesWords),
			scalar(wire.PolicyRuleNameArchiveMyChats, layers,
				func(r wire.PolicyRules) (bool, bool) {
					if r.ArchiveMyChats == nil {
						return false, false
					}
					return *r.ArchiveMyChats, true
				},
				func(v bool) float64 { return float64(ArchiveMyChatsOrder(v)) },
				boolWords),
			resolveRuntimes(layers),
			listPatterns(wire.PolicyRuleNameMarketplacesAllowed, layers,
				func(r wire.PolicyRules) ([]string, bool) {
					if r.Marketplaces == nil {
						return nil, false
					}
					return r.Marketplaces.Allowed, true
				}),
			scalar(wire.PolicyRuleNameMarketplacesCustomServers, layers,
				func(r wire.PolicyRules) (string, bool) {
					if r.Marketplaces == nil || r.Marketplaces.CustomServers == "" {
						return "", false
					}
					return r.Marketplaces.CustomServers, true
				},
				func(v string) float64 { return float64(CustomServersOrder(v)) },
				customServersWords),
			listPatterns(wire.PolicyRuleNameEnvironment, layers,
				func(r wire.PolicyRules) ([]string, bool) {
					if r.Environment == nil {
						return nil, false
					}
					return r.Environment.PassThrough, true
				}),
		},
		FoldersWithRules: []wire.PolicyFolderWithRules{},
		Behind:           []wire.PolicyBehindMachine{},
	}
}

// scalar resolves one rule whose value in a layer is a single comparable scalar: an enum, a
// number, or a boolean (FR-005). get reads the layer's value, when the layer sets it; order
// ranks it, tighter higher (FR-004); words is the value in the clients' words.
func scalar[T any](rule wire.PolicyRuleName, layers []Layer, get func(wire.PolicyRules) (T, bool), order func(T) float64, words func(T) string) wire.EffectiveRule {
	out := wire.EffectiveRule{Rule: rule, Layers: make([]wire.EffectiveLayerValue, 0, len(layers))}
	have := false
	var bestOrder float64
	var bestVal T
	var bestLayer wire.PolicyLayerRef
	for _, l := range layers {
		v, ok := get(l.Rules)
		if !ok {
			out.Layers = append(out.Layers, wire.EffectiveLayerValue{Layer: l.Ref, Words: "Not set"})
			continue
		}
		out.Layers = append(out.Layers, wire.EffectiveLayerValue{Layer: l.Ref, Value: mustJSON(v), Words: words(v)})
		if o := order(v); !have || o > bestOrder {
			bestOrder, bestVal, bestLayer, have = o, v, l.Ref, true
		}
	}
	if !have {
		return out
	}
	out.Value = mustJSON(bestVal)
	out.Words = words(bestVal)
	decides := bestLayer
	out.Decides = &decides
	for i, l := range layers {
		if v, ok := get(l.Rules); ok && order(v) < bestOrder {
			out.Layers[i].Kept = true
		}
	}
	return out
}

// listPatterns resolves a list rule (marketplaces allowed, environment variables): FR-004's
// "fewer: a name that a layer leaves out is not allowed". The effective list is the
// intersection of every layer that sets it (research R6). decides is the topmost layer
// whose own list already equals the effective intersection; when none matches exactly (an
// overlap no single layer's list states outright), the topmost layer that sets the rule
// decides, because it is the first to narrow from "every name allowed".
func listPatterns(rule wire.PolicyRuleName, layers []Layer, get func(wire.PolicyRules) ([]string, bool)) wire.EffectiveRule {
	out := wire.EffectiveRule{Rule: rule, Layers: make([]wire.EffectiveLayerValue, 0, len(layers))}
	var setRefs []wire.PolicyLayerRef
	var effective []string
	have := false
	for _, l := range layers {
		v, ok := get(l.Rules)
		if !ok {
			out.Layers = append(out.Layers, wire.EffectiveLayerValue{Layer: l.Ref, Words: "Not set"})
			continue
		}
		out.Layers = append(out.Layers, wire.EffectiveLayerValue{Layer: l.Ref, Value: mustJSON(v), Words: listWords(v)})
		setRefs = append(setRefs, l.Ref)
		if !have {
			effective, have = v, true
			continue
		}
		effective = intersectPatterns(effective, v)
	}
	if !have {
		return out
	}
	out.Value = mustJSON(effective)
	out.Words = listWords(effective)
	decides := setRefs[0]
	for _, l := range layers {
		if v, ok := get(l.Rules); ok && sameSet(v, effective) {
			decides = l.Ref
			break
		}
	}
	out.Decides = &decides
	for i, l := range layers {
		if v, ok := get(l.Rules); ok && !sameSet(v, effective) {
			out.Layers[i].Kept = true
		}
	}
	return out
}

// resolveRuntimes resolves the runtimes rule (research R6): a runtime id not named by a
// layer that sets this rule is not allowed, and for a runtime both layers name, the allowed
// models are the intersection of what each names (absent models for that runtime means
// every model).
func resolveRuntimes(layers []Layer) wire.EffectiveRule {
	out := wire.EffectiveRule{Rule: wire.PolicyRuleNameRuntimes, Layers: make([]wire.EffectiveLayerValue, 0, len(layers))}
	type setLayer struct {
		ref wire.PolicyLayerRef
		m   map[string]wire.PolicyRuntimeRule
	}
	var sets []setLayer
	for _, l := range layers {
		if l.Rules.Runtimes == nil {
			out.Layers = append(out.Layers, wire.EffectiveLayerValue{Layer: l.Ref, Words: "Not set"})
			continue
		}
		out.Layers = append(out.Layers, wire.EffectiveLayerValue{Layer: l.Ref, Value: mustJSON(l.Rules.Runtimes), Words: runtimesWords(l.Rules.Runtimes)})
		sets = append(sets, setLayer{l.Ref, l.Rules.Runtimes})
	}
	if len(sets) == 0 {
		return out
	}
	effective := map[string]wire.PolicyRuntimeRule{}
	for id, rule := range sets[0].m {
		effective[id] = rule
	}
	for _, s := range sets[1:] {
		for id := range effective {
			other, ok := s.m[id]
			if !ok {
				delete(effective, id)
				continue
			}
			merged := effective[id]
			merged.Models = intersectModels(merged.Models, other.Models)
			effective[id] = merged
		}
	}
	out.Value = mustJSON(effective)
	out.Words = runtimesWords(effective)
	decides := sets[0].ref
	for _, l := range layers {
		if l.Rules.Runtimes != nil && sameRuntimes(l.Rules.Runtimes, effective) {
			decides = l.Ref
			break
		}
	}
	out.Decides = &decides
	for i, l := range layers {
		if l.Rules.Runtimes != nil && !sameRuntimes(l.Rules.Runtimes, effective) {
			out.Layers[i].Kept = true
		}
	}
	return out
}

func intersectModels(a, b []string) []string {
	if a == nil {
		return b
	}
	if b == nil {
		return a
	}
	return intersectPatterns(a, b)
}

func sameRuntimes(m map[string]wire.PolicyRuntimeRule, effective map[string]wire.PolicyRuntimeRule) bool {
	if len(m) != len(effective) {
		return false
	}
	for id, rule := range m {
		other, ok := effective[id]
		if !ok || !sameSet(rule.Models, other.Models) {
			return false
		}
	}
	return true
}

func mustJSON(v any) wire.JSONValue {
	b, err := json.Marshal(v)
	if err != nil {
		return nil
	}
	return wire.JSONValue(b)
}

func permissionModeWords(v wire.PermissionLevel) string {
	switch v {
	case wire.PermissionLevelPlan:
		return "Plan"
	case wire.PermissionLevelAsk:
		return "Ask"
	case wire.PermissionLevelApproveForMe:
		return "Approve for me"
	case wire.PermissionLevelBypassPermissions:
		return "Bypass Permissions"
	}
	return string(v)
}

func permissionRequestsWords(v wire.ClientPermissionMode) string {
	switch v {
	case wire.ClientPermissionModeDefault:
		return "Ask me"
	case wire.ClientPermissionModeAlwaysApprove:
		return "Approve for me"
	}
	return string(v)
}

func sandboxWords(v wire.SandboxChoice) string {
	switch v {
	case wire.SandboxChoiceOff:
		return "Off allowed"
	case wire.SandboxChoiceRuntime:
		return "The runtime's"
	case wire.SandboxChoiceOn:
		return "On"
	}
	return string(v)
}

func customServersWords(v string) string {
	switch v {
	case "allow":
		return "Allow"
	case "refuse":
		return "Refuse"
	}
	return v
}

func boolWords(v bool) string {
	if v {
		return "On"
	}
	return "Off"
}

func moneyWords(suffix string) func(float64) string {
	return func(v float64) string { return fmt.Sprintf("$%.2f %s", v, suffix) }
}

func tokensWords(suffix string) func(float64) string {
	return func(v float64) string { return fmt.Sprintf("%.0f tokens %s", v, suffix) }
}

func countWords(suffix string) func(float64) string {
	return func(v float64) string { return fmt.Sprintf("%.0f %s", v, suffix) }
}

func minutesWords(v float64) string { return fmt.Sprintf("%.0f minutes", v) }

func listWords(v []string) string {
	if len(v) == 0 {
		return "None"
	}
	sorted := append([]string{}, v...)
	sort.Strings(sorted)
	return strings.Join(sorted, ", ")
}

func runtimesWords(m map[string]wire.PolicyRuntimeRule) string {
	if len(m) == 0 {
		return "None"
	}
	ids := make([]string, 0, len(m))
	for id := range m {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	return strings.Join(ids, ", ")
}
