package policylayers

import "github.com/alexec/agents/Go/wire"

// This file is FR-004's table, as code: one order per rule, tighter ranked higher, so
// Resolve can pick the tightest of every layer that sets a rule with a plain comparison.
// An unknown value falls back to the loosest for permission mode, permission requests and
// connectors by hand, and to the middle (The runtime's) for sandbox, as automap.go's
// levelRank does for the runtime tables.

var permissionModeOrder = map[wire.PermissionLevel]int{
	wire.PermissionLevelBypassPermissions: 0,
	wire.PermissionLevelApproveForMe:      1,
	wire.PermissionLevelAsk:               2,
	wire.PermissionLevelPlan:              3,
}

// PermissionModeOrder ranks a permission mode, tightest highest: Bypass Permissions, Approve
// for me, Ask, Plan (FR-004).
func PermissionModeOrder(v wire.PermissionLevel) int {
	if r, ok := permissionModeOrder[v]; ok {
		return r
	}
	return 0
}

var permissionRequestsOrder = map[wire.ClientPermissionMode]int{
	wire.ClientPermissionModeAlwaysApprove: 0,
	wire.ClientPermissionModeDefault:       1,
}

// PermissionRequestsOrder ranks a permission-requests choice, tighter is Ask me (FR-004).
func PermissionRequestsOrder(v wire.ClientPermissionMode) int {
	if r, ok := permissionRequestsOrder[v]; ok {
		return r
	}
	return 0
}

var sandboxOrder = map[wire.SandboxChoice]int{
	wire.SandboxChoiceOff:     0,
	wire.SandboxChoiceRuntime: 1,
	wire.SandboxChoiceOn:      2,
}

// SandboxOrder ranks a sandbox choice, tighter order Off allowed, The runtime's, On
// (FR-004). The organisation's old sandbox: required reads as On (research R6) before it
// reaches this function.
func SandboxOrder(v wire.SandboxChoice) int {
	if r, ok := sandboxOrder[v]; ok {
		return r
	}
	return 1
}

var customServersOrder = map[string]int{
	"allow":  0,
	"refuse": 1,
}

// CustomServersOrder ranks whether a connector added by hand is allowed, tighter is refuse
// (FR-004).
func CustomServersOrder(v string) int {
	if r, ok := customServersOrder[v]; ok {
		return r
	}
	return 0
}

// NumberTighterIsLess ranks a numeric rule where a smaller number is tighter: money, tokens,
// helpers running, helpers not archived, workflows turned on, and notices in a burst
// (FR-004).
func NumberTighterIsLess(v float64) float64 { return -v }

// NumberTighterIsMore ranks a numeric rule where a larger number is tighter: the wait after
// a notice burst (FR-004).
func NumberTighterIsMore(v float64) float64 { return v }

// ArchiveMyChatsOrder ranks the archive switch, tighter is off (FR-004).
func ArchiveMyChatsOrder(v bool) int {
	if v {
		return 0
	}
	return 1
}
