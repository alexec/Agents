package policylayers

import (
	"testing"

	"github.com/agentloops-dev/agents/Go/wire"
)

func toolLevel(v wire.ConnectorToolLevel) *wire.ConnectorToolLevel { return &v }

func TestAToolNoLayerNamesHasTheDefault(t *testing.T) {
	layers := []Layer{{Ref: youRef}, {Ref: folderRef}}
	if v, by := ToolLevel(layers, "github", "create_issue", true); v != wire.ConnectorToolLevelAsk || by != nil {
		t.Fatalf("a tool that writes: got %s by %v, want ask by no layer", v, by)
	}
	if v, by := ToolLevel(layers, "github", "get_issue", false); v != wire.ConnectorToolLevelAllow || by != nil {
		t.Fatalf("a tool that reads: got %s by %v, want allow by no layer", v, by)
	}
}

func TestTheTightestLayerDecidesATool(t *testing.T) {
	you := wire.PolicyRules{ConnectorTools: map[string]wire.PolicyConnectorRule{
		"github": {Tools: map[string]wire.ConnectorToolLevel{"delete_repo": wire.ConnectorToolLevelOff, "get_issue": wire.ConnectorToolLevelAsk}},
	}}
	folder := wire.PolicyRules{ConnectorTools: map[string]wire.PolicyConnectorRule{
		"github": {Tools: map[string]wire.ConnectorToolLevel{"delete_repo": wire.ConnectorToolLevelAllow, "get_issue": wire.ConnectorToolLevelOff}},
	}}
	layers := []Layer{{Ref: youRef, Rules: you}, {Ref: folderRef, Rules: folder}}
	if v, by := ToolLevel(layers, "github", "delete_repo", true); v != wire.ConnectorToolLevelOff || by == nil || by.Kind != "you" {
		t.Fatalf("a folder cannot loosen your Off: got %s by %v", v, by)
	}
	if v, by := ToolLevel(layers, "github", "get_issue", false); v != wire.ConnectorToolLevelOff || by == nil || by.Kind != "folder" {
		t.Fatalf("a folder can tighten your Ask: got %s by %v", v, by)
	}
}

func TestAToolsOwnLevelComesBeforeItsLayersSwitch(t *testing.T) {
	you := wire.PolicyRules{ConnectorTools: map[string]wire.PolicyConnectorRule{
		"github": {Writes: toolLevel(wire.ConnectorToolLevelOff), Tools: map[string]wire.ConnectorToolLevel{"create_issue": wire.ConnectorToolLevelAsk}},
	}}
	layers := []Layer{{Ref: youRef, Rules: you}}
	if v, _ := ToolLevel(layers, "github", "create_issue", true); v != wire.ConnectorToolLevelAsk {
		t.Fatalf("the tool's own level: got %s, want ask", v)
	}
	if v, _ := ToolLevel(layers, "github", "merge_pull_request", true); v != wire.ConnectorToolLevelOff {
		t.Fatalf("the switch: got %s, want off", v)
	}
	if v, _ := ToolLevel(layers, "github", "get_issue", false); v != wire.ConnectorToolLevelAllow {
		t.Fatalf("a tool that reads is not under the switch: got %s, want allow", v)
	}
}

func TestConnectorToolsResolvesToTheTightestOfEach(t *testing.T) {
	you := wire.PolicyRules{ConnectorTools: map[string]wire.PolicyConnectorRule{
		"github": {Writes: toolLevel(wire.ConnectorToolLevelAsk), Tools: map[string]wire.ConnectorToolLevel{"a": wire.ConnectorToolLevelOff}},
	}}
	folder := wire.PolicyRules{ConnectorTools: map[string]wire.PolicyConnectorRule{
		"github": {Writes: toolLevel(wire.ConnectorToolLevelOff), Tools: map[string]wire.ConnectorToolLevel{"a": wire.ConnectorToolLevelAllow}},
		"linear": {Tools: map[string]wire.ConnectorToolLevel{"b": wire.ConnectorToolLevelAsk}},
	}}
	r := ruleOf(Resolve([]Layer{{Ref: youRef, Rules: you}, {Ref: folderRef, Rules: folder}}), wire.PolicyRuleNameConnectorTools)
	if r.Words != "github: writes off, 1 off; linear: 1 ask" {
		t.Fatalf("words: %q", r.Words)
	}
	if r.Decides == nil || r.Decides.Kind != "you" {
		t.Fatalf("decides: %v", r.Decides)
	}
}

func TestLiftingAToolLevelIsLooser(t *testing.T) {
	approved := wire.PolicyRules{ConnectorTools: map[string]wire.PolicyConnectorRule{
		"github": {Writes: toolLevel(wire.ConnectorToolLevelAsk), Tools: map[string]wire.ConnectorToolLevel{"a": wire.ConnectorToolLevelOff}},
	}}
	cases := map[string]struct {
		next   wire.PolicyRules
		looser bool
	}{
		"the same": {approved, false},
		"tighter": {wire.PolicyRules{ConnectorTools: map[string]wire.PolicyConnectorRule{
			"github": {Writes: toolLevel(wire.ConnectorToolLevelOff), Tools: map[string]wire.ConnectorToolLevel{"a": wire.ConnectorToolLevelOff}},
		}}, false},
		"a tool removed": {wire.PolicyRules{ConnectorTools: map[string]wire.PolicyConnectorRule{
			"github": {Writes: toolLevel(wire.ConnectorToolLevelAsk)},
		}}, true},
		"the switch loosened": {wire.PolicyRules{ConnectorTools: map[string]wire.PolicyConnectorRule{
			"github": {Writes: toolLevel(wire.ConnectorToolLevelAllow), Tools: map[string]wire.ConnectorToolLevel{"a": wire.ConnectorToolLevelOff}},
		}}, true},
		"a new tool under the switch allowed": {wire.PolicyRules{ConnectorTools: map[string]wire.PolicyConnectorRule{
			"github": {Writes: toolLevel(wire.ConnectorToolLevelAsk), Tools: map[string]wire.ConnectorToolLevel{"a": wire.ConnectorToolLevelOff, "b": wire.ConnectorToolLevelAllow}},
		}}, true},
		"the rule removed": {wire.PolicyRules{}, true},
	}
	for name, c := range cases {
		if got := Looser(approved, c.next); got != c.looser {
			t.Errorf("%s: looser %v, want %v", name, got, c.looser)
		}
	}
}

func TestConnectorToolsValidates(t *testing.T) {
	if _, err := Validate([]byte(`{"connectorTools":{"github":{"writes":"ask","tools":{"a":"off"}}}}`)); err != nil {
		t.Fatalf("a good rule: %v", err)
	}
	for _, bad := range []string{
		`{"connectorTools":{"github":{"tools":{"a":"never"}}}}`,
		`{"connectorTools":{"github":{"writes":"maybe"}}}`,
		`{"connectorTools":{"":{"writes":"ask"}}}`,
		`{"connectorTools":{"github":{"tools":{"":"ask"}}}}`,
	} {
		if _, err := Validate([]byte(bad)); err == nil {
			t.Errorf("%s: no error", bad)
		}
	}
}
