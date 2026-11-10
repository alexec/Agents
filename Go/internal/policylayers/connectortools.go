package policylayers

import (
	"fmt"
	"sort"
	"strings"

	"github.com/alexec/agents/Go/wire"
)

// The connectorTools rule (#4099): Allow, Ask or Off for each tool of a connector, by the
// connector's name. A layer sets a level for a tool by its name, or one level for every tool
// that writes; a tool's own level comes before the switch. Across layers the tightest wins,
// as for every other rule, so a layer below can only move a tool towards Off. A tool no
// layer names has the default: Ask when it writes, Allow when it only reads.

var connectorToolLevelOrder = map[wire.ConnectorToolLevel]int{
	wire.ConnectorToolLevelAllow: 0,
	wire.ConnectorToolLevelAsk:   1,
	wire.ConnectorToolLevelOff:   2,
}

// ConnectorToolLevelOrder ranks a tool's level, tighter higher: Allow, Ask, Off. An unknown
// level is Ask.
func ConnectorToolLevelOrder(v wire.ConnectorToolLevel) int {
	if r, ok := connectorToolLevelOrder[v]; ok {
		return r
	}
	return 1
}

// DefaultToolLevel is a tool's level when no layer names it.
func DefaultToolLevel(writes bool) wire.ConnectorToolLevel {
	if writes {
		return wire.ConnectorToolLevelAsk
	}
	return wire.ConnectorToolLevelAllow
}

// OwnToolLevel is what one layer's rules set for a tool: its own level, or, for a tool that
// writes, the layer's writes switch. ok is false when the layer sets neither.
func OwnToolLevel(r wire.PolicyRules, server, tool string, writes bool) (wire.ConnectorToolLevel, bool) {
	rule, ok := r.ConnectorTools[server]
	if !ok {
		return "", false
	}
	if v, ok := rule.Tools[tool]; ok {
		return v, true
	}
	if writes && rule.Writes != nil {
		return *rule.Writes, true
	}
	return "", false
}

// ToolLevel is a tool's level in force from layers, top down, and the layer that decides it
// (the topmost with the tightest level); decides is nil when no layer sets it, and the
// default applies.
func ToolLevel(layers []Layer, server, tool string, writes bool) (wire.ConnectorToolLevel, *wire.PolicyLayerRef) {
	level, decides := wire.ConnectorToolLevel(""), (*wire.PolicyLayerRef)(nil)
	for _, l := range layers {
		v, ok := OwnToolLevel(l.Rules, server, tool, writes)
		if !ok {
			continue
		}
		if decides == nil || ConnectorToolLevelOrder(v) > ConnectorToolLevelOrder(level) {
			ref := l.Ref
			level, decides = v, &ref
		}
	}
	if decides == nil {
		return DefaultToolLevel(writes), nil
	}
	return level, decides
}

// WritesLevel is the tightest writes switch of layers, and the layer that sets it; nil when
// none does.
func WritesLevel(layers []Layer, server string) (wire.ConnectorToolLevel, *wire.PolicyLayerRef) {
	level, decides := wire.ConnectorToolLevel(""), (*wire.PolicyLayerRef)(nil)
	for _, l := range layers {
		rule, ok := l.Rules.ConnectorTools[server]
		if !ok || rule.Writes == nil {
			continue
		}
		if decides == nil || ConnectorToolLevelOrder(*rule.Writes) > ConnectorToolLevelOrder(level) {
			ref := l.Ref
			level, decides = *rule.Writes, &ref
		}
	}
	return level, decides
}

// ToolLevelWords is a level as the clients say it.
func ToolLevelWords(v wire.ConnectorToolLevel) string {
	switch v {
	case wire.ConnectorToolLevelAllow:
		return "Allow"
	case wire.ConnectorToolLevelAsk:
		return "Ask"
	case wire.ConnectorToolLevelOff:
		return "Off"
	}
	return string(v)
}

// resolveConnectorTools is the rule's row in the effective policy: for each connector a
// layer names, the tightest writes switch and the tightest level of each tool named.
func resolveConnectorTools(layers []Layer) wire.EffectiveRule {
	out := wire.EffectiveRule{Rule: wire.PolicyRuleNameConnectorTools, Layers: make([]wire.EffectiveLayerValue, 0, len(layers))}
	var setRefs []wire.PolicyLayerRef
	effective := map[string]wire.PolicyConnectorRule{}
	for _, l := range layers {
		if len(l.Rules.ConnectorTools) == 0 {
			out.Layers = append(out.Layers, wire.EffectiveLayerValue{Layer: l.Ref, Words: "Not set"})
			continue
		}
		out.Layers = append(out.Layers, wire.EffectiveLayerValue{Layer: l.Ref, Value: mustJSON(l.Rules.ConnectorTools), Words: connectorToolsWords(l.Rules.ConnectorTools)})
		setRefs = append(setRefs, l.Ref)
		for server, rule := range l.Rules.ConnectorTools {
			merged := effective[server]
			if rule.Writes != nil && (merged.Writes == nil || ConnectorToolLevelOrder(*rule.Writes) > ConnectorToolLevelOrder(*merged.Writes)) {
				w := *rule.Writes
				merged.Writes = &w
			}
			for tool, v := range rule.Tools {
				if merged.Tools == nil {
					merged.Tools = map[string]wire.ConnectorToolLevel{}
				}
				if old, ok := merged.Tools[tool]; !ok || ConnectorToolLevelOrder(v) > ConnectorToolLevelOrder(old) {
					merged.Tools[tool] = v
				}
			}
			effective[server] = merged
		}
	}
	if len(setRefs) == 0 {
		return out
	}
	out.Value = mustJSON(effective)
	out.Words = connectorToolsWords(effective)
	decides := setRefs[0]
	out.Decides = &decides
	return out
}

// connectorToolsWords names what a layer sets, such as "github: 2 off, 1 ask; linear: writes
// ask".
func connectorToolsWords(m map[string]wire.PolicyConnectorRule) string {
	if len(m) == 0 {
		return "None"
	}
	servers := make([]string, 0, len(m))
	for s := range m {
		servers = append(servers, s)
	}
	sort.Strings(servers)
	parts := make([]string, 0, len(servers))
	for _, s := range servers {
		rule := m[s]
		var bits []string
		if rule.Writes != nil {
			bits = append(bits, "writes "+strings.ToLower(ToolLevelWords(*rule.Writes)))
		}
		counts := map[wire.ConnectorToolLevel]int{}
		for _, v := range rule.Tools {
			counts[v]++
		}
		for _, v := range []wire.ConnectorToolLevel{wire.ConnectorToolLevelOff, wire.ConnectorToolLevelAsk, wire.ConnectorToolLevelAllow} {
			if counts[v] > 0 {
				bits = append(bits, fmt.Sprintf("%d %s", counts[v], strings.ToLower(ToolLevelWords(v))))
			}
		}
		if len(bits) == 0 {
			bits = append(bits, "nothing set")
		}
		parts = append(parts, s+": "+strings.Join(bits, ", "))
	}
	return strings.Join(parts, "; ")
}

// looserConnectorTools is whether next lifts a level approved sets: a switch or a tool's
// level removed, or made looser.
func looserConnectorTools(approved, next map[string]wire.PolicyConnectorRule) bool {
	for server, old := range approved {
		rule := next[server]
		if old.Writes != nil && (rule.Writes == nil || ConnectorToolLevelOrder(*rule.Writes) < ConnectorToolLevelOrder(*old.Writes)) {
			return true
		}
		for tool, v := range old.Tools {
			nv, ok := rule.Tools[tool]
			if !ok || ConnectorToolLevelOrder(nv) < ConnectorToolLevelOrder(v) {
				return true
			}
		}
	}
	// A tool's own level that is looser than the switch it now overrides lifts it too.
	for server, rule := range next {
		old, ok := approved[server]
		if !ok || old.Writes == nil {
			continue
		}
		for tool, v := range rule.Tools {
			if _, had := old.Tools[tool]; !had && ConnectorToolLevelOrder(v) < ConnectorToolLevelOrder(*old.Writes) {
				return true
			}
		}
	}
	return false
}

// validateConnectorTools checks each name and level of the rule.
func validateConnectorTools(m map[string]wire.PolicyConnectorRule) error {
	known := func(v wire.ConnectorToolLevel) bool { _, ok := connectorToolLevelOrder[v]; return ok }
	for server, rule := range m {
		if server == "" {
			return fmt.Errorf("policylayers: connectorTools has an empty name")
		}
		if rule.Writes != nil && !known(*rule.Writes) {
			return fmt.Errorf("policylayers: unknown connectorTools.%s.writes %q", server, *rule.Writes)
		}
		for tool, v := range rule.Tools {
			if tool == "" {
				return fmt.Errorf("policylayers: connectorTools.%s.tools has an empty name", server)
			}
			if !known(v) {
				return fmt.Errorf("policylayers: unknown connectorTools.%s.tools.%s %q", server, tool, v)
			}
		}
	}
	return nil
}
