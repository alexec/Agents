package policylayers

import "github.com/alexec/agents/Go/wire"

// Looser reports whether next sets any rule looser than approved, by that rule's order
// (research R10): a folder's layer uses this to decide whether an outside change to
// .agents/policy.json applies at once (never looser) or waits for the person's OK. A rule
// next does not set is never looser than one approved does not set either; a rule approved
// sets that next removes is looser, because the restriction is lifted.
func Looser(approved, next wire.PolicyRules) bool {
	return len(LooserRules(approved, next)) > 0
}

// LooserRules is every rule next sets looser than approved, in the Policy pane's order:
// what a waiting folder change says it does (#2957, frame D, GuardedChange.policy).
func LooserRules(approved, next wire.PolicyRules) []wire.PolicyRuleName {
	checks := []struct {
		rule   wire.PolicyRuleName
		looser bool
	}{
		{wire.PolicyRuleNamePermissionMode, looserScalar(approved.PermissionMode, next.PermissionMode, func(v wire.PermissionLevel) float64 { return float64(PermissionModeOrder(v)) })},
		{wire.PolicyRuleNamePermissionRequests, looserScalar(approved.PermissionRequests, next.PermissionRequests, func(v wire.ClientPermissionMode) float64 { return float64(PermissionRequestsOrder(v)) })},
		{wire.PolicyRuleNameSandbox, looserScalar(approved.Sandbox, next.Sandbox, func(v wire.SandboxChoice) float64 { return float64(SandboxOrder(v)) })},
		{wire.PolicyRuleNameBudgetsPerAgent, looserScalar(budgetPerAgent(approved), budgetPerAgent(next), NumberTighterIsLess)},
		{wire.PolicyRuleNameBudgetsPerAgentTokens, looserScalar(budgetPerAgentTokens(approved), budgetPerAgentTokens(next), NumberTighterIsLess)},
		{wire.PolicyRuleNameBudgetsDaily, looserScalar(budgetDaily(approved), budgetDaily(next), NumberTighterIsLess)},
		{wire.PolicyRuleNameBudgetsDailyTokens, looserScalar(budgetDailyTokens(approved), budgetDailyTokens(next), NumberTighterIsLess)},
		{wire.PolicyRuleNameHelpersMostRunning, looserScalar(helpersMostRunning(approved), helpersMostRunning(next), NumberTighterIsLess)},
		{wire.PolicyRuleNameHelpersMostNotArchived, looserScalar(helpersMostNotArchived(approved), helpersMostNotArchived(next), NumberTighterIsLess)},
		{wire.PolicyRuleNameWorkflowsMostOn, looserScalar(workflowsMostOn(approved), workflowsMostOn(next), NumberTighterIsLess)},
		{wire.PolicyRuleNameNoticeLimitsBurst, looserScalar(noticeBurst(approved), noticeBurst(next), NumberTighterIsLess)},
		{wire.PolicyRuleNameNoticeLimitsWaitMinutes, looserScalar(noticeWaitMinutes(approved), noticeWaitMinutes(next), NumberTighterIsMore)},
		{wire.PolicyRuleNameArchiveMyChats, looserScalar(archiveMyChats(approved), archiveMyChats(next), func(v bool) float64 { return float64(ArchiveMyChatsOrder(v)) })},
		{wire.PolicyRuleNameRuntimes, looserRuntimes(approved.Runtimes, next.Runtimes)},
		{wire.PolicyRuleNameMarketplacesAllowed, looserList(marketplacesAllowed(approved), marketplacesAllowed(next))},
		{wire.PolicyRuleNameMarketplacesCustomServers, looserScalar(customServers(approved), customServers(next), func(v string) float64 { return float64(CustomServersOrder(v)) })},
		{wire.PolicyRuleNameEnvironment, looserList(environmentPassThrough(approved), environmentPassThrough(next))},
	}
	var out []wire.PolicyRuleName
	for _, c := range checks {
		if c.looser {
			out = append(out, c.rule)
		}
	}
	return out
}

// RuleTitle is a rule's name as the Policy pane says it (PolicyLayersWords.rows,
// Web/src/model/policyLayers.ts).
func RuleTitle(rule wire.PolicyRuleName) string {
	if t, ok := ruleTitles[rule]; ok {
		return t
	}
	return string(rule)
}

var ruleTitles = map[wire.PolicyRuleName]string{
	wire.PolicyRuleNamePermissionMode:            "Permission mode",
	wire.PolicyRuleNamePermissionRequests:        "Permission requests",
	wire.PolicyRuleNameSandbox:                   "Sandbox",
	wire.PolicyRuleNameBudgetsPerAgent:           "Per agent",
	wire.PolicyRuleNameBudgetsPerAgentTokens:     "Tokens per agent",
	wire.PolicyRuleNameBudgetsDaily:              "Per day",
	wire.PolicyRuleNameBudgetsDailyTokens:        "Tokens per day",
	wire.PolicyRuleNameHelpersMostRunning:        "Helpers running in each folder",
	wire.PolicyRuleNameHelpersMostNotArchived:    "Helpers not archived in each folder",
	wire.PolicyRuleNameWorkflowsMostOn:           "Workflows turned on in each folder",
	wire.PolicyRuleNameNoticeLimitsBurst:         "Notices in a burst",
	wire.PolicyRuleNameNoticeLimitsWaitMinutes:   "Wait after a burst",
	wire.PolicyRuleNameArchiveMyChats:            "Agents may archive the chats I start",
	wire.PolicyRuleNameRuntimes:                  "Runtimes and models",
	wire.PolicyRuleNameMarketplacesAllowed:       "Marketplaces",
	wire.PolicyRuleNameMarketplacesCustomServers: "Connectors added by hand",
	wire.PolicyRuleNameEnvironment:               "Variables agents get",
}

// looserScalar reports whether next is looser than approved for one scalar rule: approved
// sets it and next does not (the restriction lifts), or both set it and next's order is
// lower (looser).
func looserScalar[T any](approved, next *T, order func(T) float64) bool {
	if approved == nil {
		return false
	}
	if next == nil {
		return true
	}
	return order(*next) < order(*approved)
}

// looserList reports whether next's allowlist allows a name approved's does not, or next
// removes an allowlist approved set.
func looserList(approved *[]string, next *[]string) bool {
	if approved == nil {
		return false
	}
	if next == nil {
		return true
	}
	for _, p := range *next {
		name := p
		if !allowedBy(*approved, name) {
			return true
		}
	}
	return false
}

func looserRuntimes(approved, next map[string]wire.PolicyRuntimeRule) bool {
	if approved == nil {
		return false
	}
	if next == nil {
		return true
	}
	for id, rule := range next {
		old, ok := approved[id]
		if !ok {
			return true // a runtime now allowed that was not named before
		}
		if old.Models != nil {
			if rule.Models == nil {
				return true // every model now allowed for this runtime
			}
			for _, m := range rule.Models {
				if !allowedBy(old.Models, m) {
					return true
				}
			}
		}
	}
	return false
}

func budgetPerAgent(r wire.PolicyRules) *float64 {
	if r.Budgets == nil || r.Budgets.PerAgent == nil {
		return nil
	}
	v := r.Budgets.PerAgent.Amount
	return &v
}

func budgetDaily(r wire.PolicyRules) *float64 {
	if r.Budgets == nil || r.Budgets.Daily == nil {
		return nil
	}
	v := r.Budgets.Daily.Amount
	return &v
}

func budgetPerAgentTokens(r wire.PolicyRules) *float64 {
	if r.Budgets == nil || r.Budgets.PerAgentTokens == nil {
		return nil
	}
	v := float64(*r.Budgets.PerAgentTokens)
	return &v
}

func budgetDailyTokens(r wire.PolicyRules) *float64 {
	if r.Budgets == nil || r.Budgets.DailyTokens == nil {
		return nil
	}
	v := float64(*r.Budgets.DailyTokens)
	return &v
}

func helpersMostRunning(r wire.PolicyRules) *float64 {
	if r.Helpers == nil || r.Helpers.MostRunning == nil {
		return nil
	}
	v := float64(*r.Helpers.MostRunning)
	return &v
}

func helpersMostNotArchived(r wire.PolicyRules) *float64 {
	if r.Helpers == nil || r.Helpers.MostNotArchived == nil {
		return nil
	}
	v := float64(*r.Helpers.MostNotArchived)
	return &v
}

func workflowsMostOn(r wire.PolicyRules) *float64 {
	if r.Workflows == nil || r.Workflows.MostOn == nil {
		return nil
	}
	v := float64(*r.Workflows.MostOn)
	return &v
}

func noticeBurst(r wire.PolicyRules) *float64 {
	if r.NoticeLimits == nil || r.NoticeLimits.Burst == nil {
		return nil
	}
	v := float64(*r.NoticeLimits.Burst)
	return &v
}

func noticeWaitMinutes(r wire.PolicyRules) *float64 {
	if r.NoticeLimits == nil || r.NoticeLimits.WaitMinutes == nil {
		return nil
	}
	v := float64(*r.NoticeLimits.WaitMinutes)
	return &v
}

func archiveMyChats(r wire.PolicyRules) *bool { return r.ArchiveMyChats }

func marketplacesAllowed(r wire.PolicyRules) *[]string {
	if r.Marketplaces == nil {
		return nil
	}
	v := r.Marketplaces.Allowed
	return &v
}

func customServers(r wire.PolicyRules) *string {
	if r.Marketplaces == nil || r.Marketplaces.CustomServers == "" {
		return nil
	}
	v := r.Marketplaces.CustomServers
	return &v
}

func environmentPassThrough(r wire.PolicyRules) *[]string {
	if r.Environment == nil {
		return nil
	}
	v := r.Environment.PassThrough
	return &v
}
