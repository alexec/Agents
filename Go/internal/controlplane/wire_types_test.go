package controlplane

import (
	"testing"

	"github.com/alexec/agents/Go/internal/wiretest"
	"github.com/alexec/agents/Go/wire"
)

// Every type the control plane writes or reads on the wire reads the bytes in
// testdata/wire-types.golden and writes them again unchanged (#1313).
func TestWireTypesKeepTheirBytes(t *testing.T) {
	wiretest.Check(t, "testdata/wire-types.golden", wiretest.Types{
		"ClientRecord":         func() any { return new(wire.ClientRecord) },
		"HostJoinStatus":       func() any { return new(wire.HostJoinStatus) },
		"ControlStatus":        func() any { return new(wire.ControlStatus) },
		"GitAsk":               func() any { return new(wire.GitAsk) },
		"ControlHost":          func() any { return new(wire.ControlHost) },
		"ClientConnection":     func() any { return new(wire.ClientConnection) },
		"HostHello":            func() any { return new(wire.HostHello) },
		"ControlCodeShown":     func() any { return new(wire.ControlCodeShown) },
		"Admitted":             func() any { return new(wire.Admitted) },
		"ClientAnnounce":       func() any { return new(wire.ClientAnnounce) },
		"HostAnnounce":         func() any { return new(wire.HostAnnounce) },
		"HostRequest":          func() any { return new(wire.HostRequest) },
		"LendSignIn":           func() any { return new(wire.LendSignIn) },
		"LendGit":              func() any { return new(wire.LendGit) },
		"HostRelayRequest":     func() any { return new(wire.HostRelayRequest) },
		"TunnelOpen":           func() any { return new(wire.TunnelOpen) },
		"ProjectDetection":     func() any { return new(wire.ProjectDetection) },
		"ChannelOpen":          func() any { return new(wire.ChannelOpen) },
		"PresenceReport":       func() any { return new(wire.PresenceReport) },
		"HandoverStatus":       func() any { return new(wire.HandoverStatus) },
		"HandoverMember":       func() any { return new(wire.HandoverMember) },
		"GitCredentialRequest": func() any { return new(wire.GitCredentialRequest) },
	}, *update)
}
