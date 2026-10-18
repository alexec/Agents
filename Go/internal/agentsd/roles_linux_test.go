package agentsd

import "testing"

// This test is no ssh login, so a Linux host makes it a stranger (#726): it may ping and
// nothing more. Open, an agent's own shell could answer its prompts and delete other agents.
func TestALinuxHostMakesAShellAStranger(t *testing.T) {
	_, path := serveWith(t, nil)
	if m := socketCall(t, path, "daemon/ping"); m == nil || m.Error != nil {
		t.Fatalf("ping: %+v", m)
	}
	for _, method := range []string{"agents/list", "agents/start", "permissions/answer"} {
		if m := socketCall(t, path, method); m == nil || m.Error == nil || m.Error.Code != CodeNotPermitted {
			t.Fatalf("%s: %+v", method, m)
		}
	}
}
