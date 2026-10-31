// Package policylayers resolves what agents may do from the policy's layers: Organisation,
// You and a Folder (#2957). Each layer can only make a rule tighter; Resolve finds the
// tightest value of every layer that sets a rule. The package knows nothing of files, the
// network or signatures: callers read a layer's rules, validate them, and pass Resolve the
// layers from the top down.
package policylayers

import "github.com/alexec/agents/Go/wire"

// Layer is one layer's rules, with the reference that names it in the effective policy.
// Callers pass Resolve layers from the top down: organisation, then you, then a folder
// (FR-001). The empty groups slot is left out until there is a Group layer to fill it.
type Layer struct {
	Ref   wire.PolicyLayerRef
	Rules wire.PolicyRules
}
