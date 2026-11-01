package policylayers

import "github.com/alexec/agents/Go/wire"

// WithCaps fills each rule's cap and capLine for the layer a client edits, the lowest of
// the layers eff was resolved from (data-model.md "EffectiveRule"): the tightest value of
// the layers above it, and the line that names the layer deciding it, such as "Acme: at
// most Approve for me". A client dims what is looser than the cap (FR-019); the machine
// still decides (research R12). above is the layers over the edited one, top down.
func WithCaps(eff wire.EffectivePolicy, above []Layer) wire.EffectivePolicy {
	if len(above) == 0 {
		return eff
	}
	capped := Resolve(above)
	for i := range eff.Rules {
		for _, c := range capped.Rules {
			if c.Rule != eff.Rules[i].Rule || c.Decides == nil {
				continue
			}
			line := CapLine(c.Rule, *c.Decides, c.Words)
			eff.Rules[i].Cap = c.Value
			eff.Rules[i].CapLine = &line
		}
	}
	return eff
}

// CapLine is a capped row's line in the clients' words (contracts/policy-layers-api.md,
// "Client words"): the layer's name, then the value it allows.
func CapLine(rule wire.PolicyRuleName, layer wire.PolicyLayerRef, words string) string {
	return LayerName(layer) + ": " + capPhrase(rule, words)
}

// LayerName is how a line names a layer: the organisation's or the folder's own name, and
// "Your policy" for the person's (#3150's words).
func LayerName(layer wire.PolicyLayerRef) string {
	if layer.Kind == "you" {
		return "Your policy"
	}
	return layer.Name
}

func capPhrase(rule wire.PolicyRuleName, words string) string {
	switch rule {
	case wire.PolicyRuleNameRuntimes, wire.PolicyRuleNameMarketplacesAllowed, wire.PolicyRuleNameEnvironment:
		return "only " + words
	case wire.PolicyRuleNameArchiveMyChats, wire.PolicyRuleNameMarketplacesCustomServers:
		return words
	}
	return "at most " + words
}
