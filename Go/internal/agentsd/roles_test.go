package agentsd

import (
	"bufio"
	"context"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// fixedPolicy gives every caller one role, or closes it.
type fixedPolicy struct {
	role Role
	ok   bool
}

func (p fixedPolicy) Role(net.Conn) (Role, bool) { return p.role, p.ok }
func (fixedPolicy) Summary() string              { return "a test's" }

func TestRoleAllows(t *testing.T) {
	for _, c := range []struct {
		role   Role
		method string
		want   bool
	}{
		{RoleControl, "agents/delete", true},
		{RoleDevice, "agents/delete", true},
		{RoleAgent, "resources/lease", true},
		{RoleAgent, "agents/finishTurn", false},
		{RoleAgent, "sessions/list", false},
		{RoleAgent, "daemon/ping", true},
		{RoleAgent, "agents/delete", false},
		{RoleAgent, "folders/setHelperLimits", false},
		{RolePairing, "devices/announce", true},
		{RolePairing, "agents/list", false},
		{RoleHostApp, "folders/list", true},
		{RoleHostApp, "agents/list", true},
		{RoleHostApp, "agents/prompt", false},
		{RoleStranger, "daemon/status", true},
		{RoleStranger, "git/credential", true},
		{RoleStranger, "agents/list", false},
		{RoleStranger, "approvals/answer", false},
	} {
		if got := c.role.Allows(c.method); got != c.want {
			t.Errorf("%s %s: %v", c.role, c.method, got)
		}
	}
	if RoleAgent.HearsNotifications() || RoleStranger.HearsNotifications() || !RoleControl.HearsNotifications() {
		t.Error("only a person's connection hears notifications")
	}
}

// socketCall sends one call on daemon.sock and reads the answer.
func socketCall(t *testing.T, path, method string) *message {
	t.Helper()
	c, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	b, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": 1, "method": method})
	c.Write(append(b, '\n'))
	c.SetReadDeadline(time.Now().Add(5 * time.Second))
	line, err := bufio.NewReader(c).ReadString('\n')
	if err != nil {
		return nil
	}
	var m message
	json.Unmarshal([]byte(line), &m)
	return &m
}

func serveWith(t *testing.T, p SocketPolicy) (*Daemon, string) {
	t.Helper()
	if p != nil {
		old := socketPolicyFor
		socketPolicyFor = func(*Daemon) SocketPolicy { return p }
		t.Cleanup(func() { socketPolicyFor = old })
	}
	root := t.TempDir()
	d, _ := start(t, root)
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	// A short path: a Unix socket's is at most 104 bytes on a Mac.
	dir, err := os.MkdirTemp("", "sock")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	path := filepath.Join(dir, "d.sock")
	go d.ServeSocket(ctx, path)
	for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); time.Sleep(10 * time.Millisecond) {
		if _, err := os.Stat(path); err == nil {
			break
		}
	}
	return d, path
}

func TestSocketRefusesWhatTheRoleMayNotCall(t *testing.T) {
	_, path := serveWith(t, fixedPolicy{role: RoleStranger, ok: true})
	if m := socketCall(t, path, "daemon/ping"); m == nil || m.Error != nil {
		t.Fatalf("a stranger's ping: %+v", m)
	}
	m := socketCall(t, path, "agents/list")
	if m == nil || m.Error == nil || m.Error.Code != CodeNotPermitted {
		t.Fatalf("a stranger's agents/list: %+v", m)
	}
}

func TestSocketControlMayCallEverything(t *testing.T) {
	_, path := serveWith(t, fixedPolicy{role: RoleControl, ok: true})
	if m := socketCall(t, path, "agents/list"); m == nil || m.Error != nil {
		t.Fatalf("a window's agents/list: %+v", m)
	}
}

func TestSocketClosesACallerThePolicyTurnsAway(t *testing.T) {
	_, path := serveWith(t, fixedPolicy{ok: false})
	if m := socketCall(t, path, "daemon/ping"); m != nil {
		t.Fatalf("answered: %+v", m)
	}
}

func TestOnlyAPersonIsCountedAsAClient(t *testing.T) {
	d, window := start(t, t.TempDir()) // one window, in memory
	window.call(t, 1, "daemon/ping", nil)
	stranger := &roledConn{conn: newConn(), role: RoleStranger}
	go d.Accept(stranger)
	defer close(stranger.in)
	if m := stranger.ask(t, "daemon/ping"); m.Error != nil {
		t.Fatal(m.Error)
	}
	d.mu.Lock()
	n := len(d.clients)
	d.mu.Unlock()
	if n != 1 {
		t.Fatalf("%d clients, want the window alone", n)
	}
}

type roledConn struct {
	*conn
	role Role
}

func (r *roledConn) Role() Role { return r.role }

func (r *roledConn) ask(t *testing.T, method string) message {
	t.Helper()
	b, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": 1, "method": method})
	r.in <- string(b)
	select {
	case line := <-r.out:
		var m message
		json.Unmarshal([]byte(line), &m)
		return m
	case <-time.After(5 * time.Second):
		t.Fatalf("%s: no answer", method)
	}
	return message{}
}

// MARK: Linux servers (#726)

// The lines that matter, as Debian's kernel writes them for an ssh login's session.
func TestProcStatusIsRead(t *testing.T) {
	status := "Name:\tsshd\nUmask:\t0022\nState:\tS (sleeping)\nTgid:\t3389\nPid:\t3389\nPPid:\t3383\n" +
		"Uid:\t1000\t1000\t1000\t1000\nGid:\t1000\t1000\t1000\t1000\n"
	if s, ok := parseProcStatus(status); !ok || s != (procStatus{name: "sshd", uid: 1000, parent: 3383}) {
		t.Fatalf("%+v %v", s, ok)
	}
	if s, ok := parseProcStatus("Name:\tbash\nPPid:\t1\n"); ok {
		t.Fatalf("no Uid line: %+v", s)
	}
}

// The Mac's forward is carried by the login's own sshd, whose parent is the root one.
func TestAnSSHLoginsSessionIsControl(t *testing.T) {
	for _, name := range []string{"sshd", "sshd-session"} {
		if !isSSHSession(procStatus{name: name, uid: 1000, parent: 3383}, &procStatus{name: name, uid: 0, parent: 1}) {
			t.Errorf("%s", name)
		}
	}
}

// Everything an agent can start: under the daemon, orphaned to a container's sshd at pid
// 1, named sshd under its own shell, or run by cron as root's child.
func TestNothingAnAgentStartsIsAnSSHSession(t *testing.T) {
	for _, c := range []struct {
		peer   procStatus
		parent *procStatus
	}{
		{procStatus{"socat", 1000, 400}, &procStatus{"bash", 1000, 300}},
		{procStatus{"sshd", 1000, 1}, &procStatus{"sshd", 0, 0}},
		{procStatus{"sshd", 1000, 400}, &procStatus{"bash", 1000, 300}},
		{procStatus{"socat", 1000, 3383}, &procStatus{"sshd", 0, 1}},
		{procStatus{"sshd", 1000, 500}, &procStatus{"cron", 0, 1}},
		{procStatus{"sshd", 1000, 3383}, nil},
	} {
		if isSSHSession(c.peer, c.parent) {
			t.Errorf("%+v under %+v", c.peer, c.parent)
		}
	}
}
