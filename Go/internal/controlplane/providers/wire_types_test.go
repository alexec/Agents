package providers

import (
	"testing"

	"github.com/alexec/agents/Go/internal/wiretest"
)

// Every type providers write or read on the wire reads the bytes in
// testdata/wire-types.golden and writes them again unchanged (#1313).
func TestWireTypesKeepTheirBytes(t *testing.T) {
	wiretest.Check(t, "testdata/wire-types.golden", wiretest.Types{
		"MachineInfo":              func() any { return new(MachineInfo) },
		"ProviderSummary":          func() any { return new(ProviderSummary) },
		"MachineWorkspace":         func() any { return new(MachineWorkspace) },
		"ProviderAdd":              func() any { return new(ProviderAdd) },
		"ProviderRequest":          func() any { return new(providerRequest) },
		"MachineRequest":           func() any { return new(hostRequest) },
		"MachineLink":              func() any { return new(MachineLink) },
		"MachineOptions":           func() any { return new(MachineOptions) },
		"ProviderOptions":          func() any { return new(ProviderOptions) },
		"ProviderCreate":           func() any { return new(ProviderCreate) },
		"ProviderCreated":          func() any { return new(ProviderCreated) },
		"MachineStop":              func() any { return new(MachineStop) },
		"MachineWorkspaceCall":     func() any { return new(MachineWorkspaceCall) },
		"AgentMachines":            func() any { return new(AgentMachines) },
		"MachineStatus":            func() any { return new(MachineStatus) },
		"MachineSchedule":          func() any { return new(MachineSchedule) },
		"KeptRequest":              func() any { return new(KeptRequest) },
		"KeepRequest":              func() any { return new(KeepRequest) },
		"KeptRequestID":            func() any { return new(KeptRequestID) },
		"KeptList":                 func() any { return new(KeptList) },
		"KeptDelivered":            func() any { return new(KeptDelivered) },
		"ProviderDraftStart":       func() any { return new(ProviderDraftStart) },
		"ProviderDraftStarted":     func() any { return new(ProviderDraftStarted) },
		"ProviderDraftRequest":     func() any { return new(ProviderDraftRequest) },
		"ProviderDraftAnswer":      func() any { return new(ProviderDraftAnswer) },
		"ProviderRuntimes":         func() any { return new(ProviderRuntimes) },
		"DraftUpdate":              func() any { return new(DraftUpdate) },
		"MachineProviderDraftCall": func() any { return new(MachineProviderDraftCall) },
	}, *update)
}
