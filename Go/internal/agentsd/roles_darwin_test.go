package agentsd

import (
	"os"
	"testing"
)

// The real door: agents-peer (AGENTS_PEER_HELPER, a signed build of Host/PeerCheck) on a
// scratch root that enforces roles. This test binary is not signed by the team, so it is a
// stranger: it may ping and nothing more.
func TestSignaturesMakeAnUnsignedCallerAStranger(t *testing.T) {
	if os.Getenv("AGENTS_PEER_HELPER") == "" {
		t.Skip("set AGENTS_PEER_HELPER to a signed agents-peer")
	}
	t.Setenv("AGENTS_ENFORCE_ROLES", "1")
	_, path := serveWith(t, nil)
	if m := socketCall(t, path, "daemon/ping"); m == nil || m.Error != nil {
		t.Fatalf("ping: %+v", m)
	}
	if m := socketCall(t, path, "agents/list"); m == nil || m.Error == nil || m.Error.Code != CodeNotPermitted {
		t.Fatalf("agents/list: %+v", m)
	}
}
