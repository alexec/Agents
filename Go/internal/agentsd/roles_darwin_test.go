package agentsd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/agentsd/store"
)

// The live root on a Mac, ~/Library/Application Support/Agents, takes roles by signature;
// a root in /tmp is open. It compared with ~/.agents, so the live socket was open (#1400).
func TestTheStandardRootChecksRolesAndATemporaryOneIsOpen(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("AGENTS_ENFORCE_ROLES", "")
	helper := filepath.Join(home, "agents-peer")
	os.WriteFile(helper, []byte("#!/bin/sh\necho 'team T'\nwhile read t; do echo control; done\n"), 0o755)
	t.Setenv("AGENTS_PEER_HELPER", helper)
	policy := func(root string) SocketPolicy {
		return platformSocketPolicy(&Daemon{Store: &store.Store{Loc: store.Locations{Root: root}}})
	}

	live := policy(filepath.Join(home, "Library", "Application Support", "Agents") + "/")
	if s, ok := live.(signatures); !ok || s.team != "T" {
		t.Fatalf("standard root: %T %q", live, live.Summary())
	}
	live.(signatures).peers.Close()
	for _, root := range []string{filepath.Join(os.TempDir(), "run-1400"), "/tmp/run-1400", filepath.Join(home, ".agents")} {
		if p := policy(root); !strings.HasPrefix(p.Summary(), "a scratch root, so ") {
			t.Errorf("%s: %q", root, p.Summary())
		}
	}
}

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
