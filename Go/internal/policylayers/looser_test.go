package policylayers

import (
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// Looser is true only for a looser rule (research R10): used to decide whether an outside
// change to a folder's policy.json applies at once or waits for the person's OK.

func TestLooserFalseWhenNothingChanges(t *testing.T) {
	r := wire.PolicyRules{PermissionMode: permissionLevel(wire.PermissionLevelAsk)}
	if Looser(r, r) {
		t.Fatal("the same rules must not be looser")
	}
}

func TestLooserFalseWhenTighter(t *testing.T) {
	approved := wire.PolicyRules{PermissionMode: permissionLevel(wire.PermissionLevelAsk)}
	next := wire.PolicyRules{PermissionMode: permissionLevel(wire.PermissionLevelPlan)}
	if Looser(approved, next) {
		t.Fatal("a tighter mode must not be looser")
	}
}

func TestLooserTrueWhenARuleIsRelaxed(t *testing.T) {
	approved := wire.PolicyRules{PermissionMode: permissionLevel(wire.PermissionLevelPlan)}
	next := wire.PolicyRules{PermissionMode: permissionLevel(wire.PermissionLevelBypassPermissions)}
	if !Looser(approved, next) {
		t.Fatal("a looser mode must be looser")
	}
}

func TestLooserTrueWhenARestrictionIsRemoved(t *testing.T) {
	approved := wire.PolicyRules{Budgets: &wire.PolicyRuleBudgets{Daily: cost(10)}}
	next := wire.PolicyRules{}
	if !Looser(approved, next) {
		t.Fatal("removing a restriction entirely must be looser")
	}
}

func TestLooserFalseWhenAddingARestriction(t *testing.T) {
	approved := wire.PolicyRules{}
	next := wire.PolicyRules{Budgets: &wire.PolicyRuleBudgets{Daily: cost(10)}}
	if Looser(approved, next) {
		t.Fatal("adding a restriction must not be looser")
	}
}

func TestLooserListAllowingAnExtraNameIsLooser(t *testing.T) {
	approved := wire.PolicyRules{Environment: &wire.PolicyEnvironment{PassThrough: []string{"API_KEY"}}}
	next := wire.PolicyRules{Environment: &wire.PolicyEnvironment{PassThrough: []string{"API_KEY", "HOME"}}}
	if !Looser(approved, next) {
		t.Fatal("allowing an extra name must be looser")
	}
	narrower := wire.PolicyRules{Environment: &wire.PolicyEnvironment{PassThrough: []string{"API_KEY"}}}
	if Looser(approved, narrower) {
		t.Fatal("the same list must not be looser")
	}
}

func TestLooserRuntimesAddingARuntimeIsLooser(t *testing.T) {
	approved := wire.PolicyRules{Runtimes: map[string]wire.PolicyRuntimeRule{"claude": {}}}
	next := wire.PolicyRules{Runtimes: map[string]wire.PolicyRuntimeRule{"claude": {}, "codex": {}}}
	if !Looser(approved, next) {
		t.Fatal("allowing an extra runtime must be looser")
	}
}
