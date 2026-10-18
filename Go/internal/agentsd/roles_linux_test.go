package agentsd

import (
	"os"
	"testing"
)

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

// fakeStatus is a /proc where the caller, whatever its pid, is peer, and peer's parent
// is parent.
func fakeStatus(peer, parent procStatus) func(int) (procStatus, bool) {
	return func(pid int) (procStatus, bool) {
		if pid == peer.parent {
			return parent, true
		}
		return peer, true
	}
}

// rootSSHD is the privileged sshd every login's session is a child of.
var rootSSHD = procStatus{name: "sshd", uid: 0, parent: 1}

// The Mac's forward, an ssh login's session, may call everything; the same name under
// the account's own shell may not.
func TestALinuxHostLetsAnSSHSessionIn(t *testing.T) {
	login := procStatus{name: "sshd-session", uid: os.Geteuid(), parent: 1 << 30}
	_, path := serveWith(t, sshSessions{uid: os.Geteuid(), status: fakeStatus(login, rootSSHD)})
	if m := socketCall(t, path, "agents/list"); m == nil || m.Error != nil {
		t.Fatalf("an ssh login's agents/list: %+v", m)
	}
	shell := procStatus{name: "bash", uid: os.Geteuid(), parent: 1}
	_, path = serveWith(t, sshSessions{uid: os.Geteuid(), status: fakeStatus(login, shell)})
	if m := socketCall(t, path, "agents/list"); m == nil || m.Error == nil || m.Error.Code != CodeNotPermitted {
		t.Fatalf("sshd under a shell: %+v", m)
	}
}

// Another account is closed before a line is read, ssh login or not.
func TestALinuxHostClosesAnotherAccount(t *testing.T) {
	login := procStatus{name: "sshd-session", uid: os.Geteuid(), parent: 1 << 30}
	_, path := serveWith(t, sshSessions{uid: os.Geteuid() + 1, status: fakeStatus(login, rootSSHD)})
	if m := socketCall(t, path, "daemon/ping"); m != nil {
		t.Fatalf("answered another account: %+v", m)
	}
}
