package providers

import (
	"testing"

	"github.com/alexec/agents/Go/internal/wiretest"
)

// Every type providers write or read on the wire reads the bytes in
// testdata/wire-types.golden and writes them again unchanged (#1313).
func TestWireTypesKeepTheirBytes(t *testing.T) {
	wiretest.Check(t, "testdata/wire-types.golden", wiretest.Types{
		"WorkspaceInfo":         func() any { return new(WorkspaceInfo) },
		"ProviderSummary":       func() any { return new(ProviderSummary) },
		"HostWorkspace":         func() any { return new(HostWorkspace) },
		"ProviderAdd":           func() any { return new(ProviderAdd) },
		"ProviderRequest":       func() any { return new(providerRequest) },
		"HostRequest":           func() any { return new(hostRequest) },
		"HostLink":              func() any { return new(HostLink) },
		"HostWorkspaceOptions":  func() any { return new(HostWorkspaceOptions) },
		"ProviderOptions":       func() any { return new(ProviderOptions) },
		"ProviderCreate":        func() any { return new(ProviderCreate) },
		"ProviderCreated":       func() any { return new(ProviderCreated) },
		"HostStop":              func() any { return new(HostStop) },
		"HostWorkspaceCall":     func() any { return new(HostWorkspaceCall) },
		"AgentWorkspaces":       func() any { return new(AgentWorkspaces) },
		"HostStatus":            func() any { return new(HostStatus) },
		"HostSchedule":          func() any { return new(HostSchedule) },
		"KeptRequest":           func() any { return new(KeptRequest) },
		"KeepRequest":           func() any { return new(KeepRequest) },
		"KeptRequestID":         func() any { return new(KeptRequestID) },
		"KeptList":              func() any { return new(KeptList) },
		"KeptDelivered":         func() any { return new(KeptDelivered) },
		"ProviderDraftStart":    func() any { return new(ProviderDraftStart) },
		"ProviderDraftStarted":  func() any { return new(ProviderDraftStarted) },
		"ProviderDraftRequest":  func() any { return new(ProviderDraftRequest) },
		"ProviderDraftAnswer":   func() any { return new(ProviderDraftAnswer) },
		"ProviderRuntimes":      func() any { return new(ProviderRuntimes) },
		"DraftUpdate":           func() any { return new(DraftUpdate) },
		"HostProviderDraftCall": func() any { return new(HostProviderDraftCall) },
	}, *update)
}
