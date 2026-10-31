package policylayers

import (
	"encoding/json"
	"fmt"
	"log"
	"sync"

	"github.com/alexec/agents/Go/wire"
)

const maxLayerBytes = 16 * 1024

var knownPolicyRuleFields = map[string]bool{
	"permissionMode":     true,
	"permissionRequests": true,
	"sandbox":            true,
	"budgets":            true,
	"helpers":            true,
	"workflows":          true,
	"noticeLimits":       true,
	"archiveMyChats":     true,
	"runtimes":           true,
	"marketplaces":       true,
	"environment":        true,
}

var loggedUnknown sync.Map

// logUnknownFieldOnce logs an unknown field once per field name for the life of the
// process, so a newer file's field does not spam the log of an older machine (FR-011,
// research R10: "an unknown rule name is ignored and logged once").
func logUnknownFieldOnce(field string) {
	if _, already := loggedUnknown.LoadOrStore(field, true); !already {
		log.Printf("policylayers: ignoring unknown field %q", field)
	}
}

// Validate checks a layer's raw JSON (data-model.md "Validation"): under 16 KiB, each
// number in its range, each enum value known, and no list entry with an empty name. An
// unknown field is ignored and logged once, so a newer file still works on an older
// machine. The caller keeps the last good copy when this returns an error (FR-011, R10).
func Validate(raw []byte) (wire.PolicyRules, error) {
	var rules wire.PolicyRules
	if len(raw) > maxLayerBytes {
		return rules, fmt.Errorf("policylayers: %d bytes, over the %d byte limit", len(raw), maxLayerBytes)
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(raw, &fields); err != nil {
		return rules, fmt.Errorf("policylayers: not JSON: %w", err)
	}
	for field := range fields {
		if !knownPolicyRuleFields[field] {
			logUnknownFieldOnce(field)
		}
	}
	// permissionMode and permissionRequests have an x-fallback (#2658): their generated
	// UnmarshalJSON silently replaces an unrecognised string with the fallback, so an
	// unknown value must be caught here, against the raw JSON, before that happens.
	if raw, ok := fields["permissionMode"]; ok {
		var s string
		if err := json.Unmarshal(raw, &s); err == nil && !isKnownPermissionMode(wire.PermissionLevel(s)) {
			return rules, fmt.Errorf("policylayers: unknown permissionMode %q", s)
		}
	}
	if raw, ok := fields["permissionRequests"]; ok {
		var s string
		if err := json.Unmarshal(raw, &s); err == nil && !isKnownPermissionRequests(wire.ClientPermissionMode(s)) {
			return rules, fmt.Errorf("policylayers: unknown permissionRequests %q", s)
		}
	}
	if err := json.Unmarshal(raw, &rules); err != nil {
		return rules, fmt.Errorf("policylayers: %w", err)
	}
	if err := validateRules(rules); err != nil {
		return rules, err
	}
	return rules, nil
}

func validateRules(r wire.PolicyRules) error {
	if r.Sandbox != nil && !isKnownSandbox(*r.Sandbox) {
		return fmt.Errorf("policylayers: unknown sandbox %q", *r.Sandbox)
	}
	if r.Marketplaces != nil && r.Marketplaces.CustomServers != "" {
		if _, ok := customServersOrder[r.Marketplaces.CustomServers]; !ok {
			return fmt.Errorf("policylayers: unknown marketplaces.customServers %q", r.Marketplaces.CustomServers)
		}
	}
	if r.Budgets != nil {
		if err := atLeastOne("budgets.perAgentTokens", r.Budgets.PerAgentTokens); err != nil {
			return err
		}
		if err := atLeastOne("budgets.dailyTokens", r.Budgets.DailyTokens); err != nil {
			return err
		}
	}
	if r.Helpers != nil {
		if err := inRange("helpers.mostRunning", r.Helpers.MostRunning, 1, 10); err != nil {
			return err
		}
		if err := inRange("helpers.mostNotArchived", r.Helpers.MostNotArchived, 1, 20); err != nil {
			return err
		}
	}
	if r.Workflows != nil {
		if err := inRange("workflows.mostOn", r.Workflows.MostOn, 1, 100); err != nil {
			return err
		}
	}
	if r.NoticeLimits != nil {
		if err := inRange("noticeLimits.burst", r.NoticeLimits.Burst, 1, 20); err != nil {
			return err
		}
		if err := inRange("noticeLimits.waitMinutes", r.NoticeLimits.WaitMinutes, 1, 1440); err != nil {
			return err
		}
	}
	if r.Marketplaces != nil {
		if err := noEmptyName("marketplaces.allowed", r.Marketplaces.Allowed); err != nil {
			return err
		}
	}
	if r.Environment != nil {
		if err := noEmptyName("environment.passThrough", r.Environment.PassThrough); err != nil {
			return err
		}
	}
	if r.Runtimes != nil {
		for id, rule := range r.Runtimes {
			if id == "" {
				return fmt.Errorf("policylayers: runtimes has an empty name")
			}
			if err := noEmptyName("runtimes."+id+".models", rule.Models); err != nil {
				return err
			}
		}
	}
	return nil
}

func isKnownPermissionMode(v wire.PermissionLevel) bool {
	switch v {
	case wire.PermissionLevelPlan, wire.PermissionLevelAsk, wire.PermissionLevelApproveForMe, wire.PermissionLevelBypassPermissions:
		return true
	}
	return false
}

func isKnownPermissionRequests(v wire.ClientPermissionMode) bool {
	switch v {
	case wire.ClientPermissionModeDefault, wire.ClientPermissionModeAlwaysApprove:
		return true
	}
	return false
}

func isKnownSandbox(v wire.SandboxChoice) bool {
	switch v {
	case wire.SandboxChoiceOff, wire.SandboxChoiceRuntime, wire.SandboxChoiceOn:
		return true
	}
	return false
}

func atLeastOne(name string, v *int64) error {
	if v != nil && *v < 1 {
		return fmt.Errorf("policylayers: %s is %d, must be at least 1", name, *v)
	}
	return nil
}

func inRange(name string, v *int64, min, max int64) error {
	if v != nil && (*v < min || *v > max) {
		return fmt.Errorf("policylayers: %s is %d, must be %d-%d", name, *v, min, max)
	}
	return nil
}

func noEmptyName(name string, list []string) error {
	for _, s := range list {
		if s == "" {
			return fmt.Errorf("policylayers: %s has an empty name", name)
		}
	}
	return nil
}
