package agentsd

import (
	"log"
	"net"
	"os"
	"syscall"

	"golang.org/x/sys/unix"
)

// platformSocketPolicy is RolePolicy.sshSessions (#726): a server's daemon.sock is
// reached through an ssh forward, so only an ssh login's session is control.
func platformSocketPolicy(*Daemon) SocketPolicy {
	return sshSessions{uid: os.Geteuid(), status: readProcStatus}
}

// sshSessions is a Linux server's door: control for an ssh login's own session process,
// which is what carries the Mac's forward to the socket, and stranger for anything else.
// That is every process an agent starts, orphaned or not: none is sshd's child. The
// control plane's channels never reach the socket, and helpers reach the daemon over its
// MCP endpoint (#185), so neither is lost. An agent that can ssh into its own account with
// a key it holds is that account's login, and is let in as one. Another account is turned
// away before it can send a line.
type sshSessions struct {
	uid    int
	status func(pid int) (procStatus, bool)
}

func (sshSessions) Summary() string {
	return "control for this account's ssh sessions alone, anything else a stranger"
}

func (p sshSessions) Role(c net.Conn) (Role, bool) {
	cred, err := peerCred(c)
	if err != nil {
		log.Printf("socket: %v", err)
		return "", false
	}
	if int(cred.Uid) != p.uid {
		return "", false
	}
	peer, ok := p.status(int(cred.Pid))
	if !ok {
		return RoleStranger, true
	}
	var parent *procStatus
	if s, ok := p.status(peer.parent); ok {
		parent = &s
	}
	if isSSHSession(peer, parent) {
		return RoleControl, true
	}
	return RoleStranger, true
}

// peerCred is the caller's SO_PEERCRED: its pid and uid when it connected.
func peerCred(c net.Conn) (*unix.Ucred, error) {
	sc, ok := c.(syscall.Conn)
	if !ok {
		return nil, unix.EINVAL
	}
	raw, err := sc.SyscallConn()
	if err != nil {
		return nil, err
	}
	var cred *unix.Ucred
	var credErr error
	if err := raw.Control(func(fd uintptr) {
		cred, credErr = unix.GetsockoptUcred(int(fd), unix.SOL_SOCKET, unix.SO_PEERCRED)
	}); err != nil {
		return nil, err
	}
	return cred, credErr
}
