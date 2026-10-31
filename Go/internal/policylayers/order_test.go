package policylayers

import (
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// FR-004's table, as a direct check of each Order function: tighter ranks higher.

func TestPermissionModeOrderIsTighterHigher(t *testing.T) {
	order := []wire.PermissionLevel{
		wire.PermissionLevelBypassPermissions, wire.PermissionLevelApproveForMe,
		wire.PermissionLevelAsk, wire.PermissionLevelPlan,
	}
	for i := 1; i < len(order); i++ {
		if PermissionModeOrder(order[i]) <= PermissionModeOrder(order[i-1]) {
			t.Fatalf("%s must rank tighter than %s", order[i], order[i-1])
		}
	}
}

func TestPermissionRequestsOrderTighterIsAskMe(t *testing.T) {
	if PermissionRequestsOrder(wire.ClientPermissionModeDefault) <= PermissionRequestsOrder(wire.ClientPermissionModeAlwaysApprove) {
		t.Fatal("Ask me (default) must rank tighter than Approve for me (alwaysApprove)")
	}
}

func TestSandboxOrderTighterOrder(t *testing.T) {
	order := []wire.SandboxChoice{wire.SandboxChoiceOff, wire.SandboxChoiceRuntime, wire.SandboxChoiceOn}
	for i := 1; i < len(order); i++ {
		if SandboxOrder(order[i]) <= SandboxOrder(order[i-1]) {
			t.Fatalf("%s must rank tighter than %s", order[i], order[i-1])
		}
	}
}

func TestCustomServersOrderTighterIsRefuse(t *testing.T) {
	if CustomServersOrder("refuse") <= CustomServersOrder("allow") {
		t.Fatal("refuse must rank tighter than allow")
	}
}

func TestNumberTighterIsLess(t *testing.T) {
	// Money, tokens, helpers, workflows and a notice burst: fewer is tighter (FR-004).
	if NumberTighterIsLess(5) <= NumberTighterIsLess(10) {
		t.Fatal("5 must rank tighter than 10")
	}
}

func TestNumberTighterIsMore(t *testing.T) {
	// The wait after a notice burst: longer is tighter (FR-004).
	if NumberTighterIsMore(30) <= NumberTighterIsMore(10) {
		t.Fatal("30 minutes must rank tighter than 10 minutes")
	}
}

func TestArchiveMyChatsOrderTighterIsOff(t *testing.T) {
	if ArchiveMyChatsOrder(false) <= ArchiveMyChatsOrder(true) {
		t.Fatal("off must rank tighter than on")
	}
}

func TestUnknownValueFallsBack(t *testing.T) {
	if PermissionModeOrder("made-up") != PermissionModeOrder(wire.PermissionLevelBypassPermissions) {
		t.Fatal("an unknown permission mode must fall back to the loosest, as automap.go's levelRank does")
	}
	if SandboxOrder("made-up") != SandboxOrder(wire.SandboxChoiceRuntime) {
		t.Fatal("an unknown sandbox choice must fall back to the middle (The runtime's)")
	}
}
