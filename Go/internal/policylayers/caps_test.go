package policylayers

import (
	"encoding/json"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// A row on your layer is capped by the organisation's value: the cap is the organisation's
// value and the line names it (FR-019; contracts "Client words").
func TestWithCapsNamesTheLayerAbove(t *testing.T) {
	org := Layer{Ref: orgRef, Rules: wire.PolicyRules{PermissionMode: permissionLevel(wire.PermissionLevelApproveForMe)}}
	you := Layer{Ref: youRef, Rules: wire.PolicyRules{PermissionMode: permissionLevel(wire.PermissionLevelBypassPermissions)}}
	eff := WithCaps(Resolve([]Layer{org, you}), []Layer{org})
	r := ruleOf(eff, wire.PolicyRuleNamePermissionMode)
	if r.CapLine == nil || *r.CapLine != "Acme: at most Approve for me" {
		t.Fatalf("capLine = %v", r.CapLine)
	}
	var cap wire.PermissionLevel
	if err := json.Unmarshal(r.Cap, &cap); err != nil || cap != wire.PermissionLevelApproveForMe {
		t.Fatalf("cap = %s", r.Cap)
	}
	if !r.Layers[1].Kept {
		t.Fatal("your looser value is kept, not used")
	}
}

// A folder's row is capped by the tighter of the organisation and you; your layer is named
// "Your policy".
func TestWithCapsForAFolderNamesYourPolicy(t *testing.T) {
	org := Layer{Ref: orgRef, Rules: wire.PolicyRules{}}
	you := Layer{Ref: youRef, Rules: wire.PolicyRules{Budgets: &wire.PolicyRuleBudgets{Daily: cost(40)}}}
	folder := Layer{Ref: folderRef, Rules: wire.PolicyRules{}}
	eff := WithCaps(Resolve([]Layer{org, you, folder}), []Layer{org, you})
	r := ruleOf(eff, wire.PolicyRuleNameBudgetsDaily)
	if r.CapLine == nil || *r.CapLine != "Your policy: at most $40.00 a day" {
		t.Fatalf("capLine = %v", r.CapLine)
	}
}

// A rule no layer above sets has no cap.
func TestWithCapsLeavesAnUncappedRuleAlone(t *testing.T) {
	org := Layer{Ref: orgRef}
	you := Layer{Ref: youRef, Rules: wire.PolicyRules{ArchiveMyChats: boolp(false)}}
	eff := WithCaps(Resolve([]Layer{org, you}), []Layer{org})
	for _, r := range eff.Rules {
		if r.Cap != nil || r.CapLine != nil {
			t.Fatalf("%s capped with nothing above", r.Rule)
		}
	}
}

// A list rule's line says "only".
func TestCapLineForAList(t *testing.T) {
	if got := CapLine(wire.PolicyRuleNameEnvironment, orgRef, "FOO, BAR"); got != "Acme: only FOO, BAR" {
		t.Fatal(got)
	}
}
