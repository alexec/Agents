package controlplane

import (
	"testing"

	"github.com/alexec/agents/Go/internal/wiretest"
)

// Every type the control plane writes or reads on the wire reads the bytes in
// testdata/wire-types.golden and writes them again unchanged (#1313).
func TestWireTypesKeepTheirBytes(t *testing.T) {
	wiretest.Check(t, "testdata/wire-types.golden", wiretest.Types{
		"ClientRecord":         func() any { return new(clientWire) },
		"HostJoinStatus":       func() any { return new(HostJoinStatus) },
		"ControlStatus":        func() any { return new(controlStatus) },
		"GitAsk":               func() any { return new(gitAsk) },
		"ControlHost":          func() any { return new(controlHost) },
		"ClientConnection":     func() any { return new(clientConnection) },
		"HostHello":            func() any { return new(hostHello) },
		"ControlCodeShown":     func() any { return new(codeShown) },
		"Admitted":             func() any { return new(admitted) },
		"ClientAnnounce":       func() any { return new(clientAnnounce) },
		"HostAnnounce":         func() any { return new(hostAnnounce) },
		"HostRequest":          func() any { return new(hostRequest) },
		"LendSignIn":           func() any { return new(lendSignIn) },
		"LendGit":              func() any { return new(lendGit) },
		"HostRelayRequest":     func() any { return new(hostRelayRequest) },
		"TunnelOpen":           func() any { return new(tunnelOpen) },
		"ProjectDetection":     func() any { return new(projectDetection) },
		"ChannelOpen":          func() any { return new(channelOpen) },
		"PresenceReport":       func() any { return new(presenceReport) },
		"HandoverStatus":       func() any { return new(handoverStatus) },
		"HandoverMember":       func() any { return new(handoverMember) },
		"GitCredentialRequest": func() any { return new(gitCredentialRequest) },
	}, *update)
}
