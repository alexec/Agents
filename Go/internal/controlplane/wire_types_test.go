package controlplane

import (
	"testing"

	"github.com/alexec/agents/Go/internal/wiretest"
	"github.com/alexec/agents/Go/wire"
)

// Every type the control plane writes or reads on the wire reads the bytes in
// testdata/wire-types.golden and writes them again unchanged (#1313).
func TestWireTypesKeepTheirBytes(t *testing.T) {
	t.Parallel()
	wiretest.Check(t, "testdata/wire-types.golden", wiretest.Types{
		"ClientRecord":         func() any { return new(wire.ClientRecord) },
		"MachineJoinStatus":    func() any { return new(wire.MachineJoinStatus) },
		"ControlStatus":        func() any { return new(wire.ControlStatus) },
		"GitAsk":               func() any { return new(wire.GitAsk) },
		"ControlMachine":       func() any { return new(wire.ControlMachine) },
		"ClientConnection":     func() any { return new(wire.ClientConnection) },
		"MachineHello":         func() any { return new(wire.MachineHello) },
		"ControlCodeShown":     func() any { return new(wire.ControlCodeShown) },
		"Admitted":             func() any { return new(wire.Admitted) },
		"ClientAnnounce":       func() any { return new(wire.ClientAnnounce) },
		"MachineAnnounce":      func() any { return new(wire.MachineAnnounce) },
		"MachineRequest":       func() any { return new(wire.MachineRequest) },
		"LendSignIn":           func() any { return new(wire.LendSignIn) },
		"LendGit":              func() any { return new(wire.LendGit) },
		"MachineRelayRequest":  func() any { return new(wire.MachineRelayRequest) },
		"TunnelOpen":           func() any { return new(wire.TunnelOpen) },
		"FolderDetection":      func() any { return new(wire.FolderDetection) },
		"ChannelOpen":          func() any { return new(wire.ChannelOpen) },
		"PresenceReport":       func() any { return new(wire.PresenceReport) },
		"HandoverStatus":       func() any { return new(wire.HandoverStatus) },
		"HandoverMember":       func() any { return new(wire.HandoverMember) },
		"GitCredentialRequest": func() any { return new(wire.GitCredentialRequest) },
	}, *update)
}
