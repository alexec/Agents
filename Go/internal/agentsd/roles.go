package agentsd

import (
	"net"
)

// Role is what a connection is, and so what it may ask for (ConnectionRole.swift). The
// host decides it from who is on the other end, never from anything the caller says.
type Role string

const (
	// RoleControl is a window, the bridge, or a channel the control plane opened:
	// everything.
	RoleControl Role = "control"
	// RoleAgent is a runtime's helper relaying an agent's call to the app's own tools.
	RoleAgent Role = "agent"
	// RoleDevice is a phone, an iPad or a browser the bridge carries: everything a window may.
	RoleDevice Role = "device"
	// RolePairing is a phone with a pairing code and no key yet: it may say who it is.
	RolePairing Role = "pairing"
	// RoleHostApp is Agents Host's window: whether the host is there and what it holds.
	RoleHostApp Role = "hostApp"
	// RoleWindow is the App Store window, signed by this team. On daemon.sock, which its
	// sandbox cannot reach anyway, it is a stranger; on the local socket it may prove its
	// key (localpath.go, #1118).
	RoleWindow Role = "window"
	// RoleStranger is anything else of this account: whether the host is there.
	RoleStranger Role = "stranger"
)

// CodeNotPermitted is DaemonAPI.Failure.notPermitted: a method this connection's role
// may not call.
const CodeNotPermitted = -32045

// strangerMethods: enough to find out a host is answering, which a client does first.
var strangerMethods = []string{"daemon/ping", "daemon/status"}

// agentMethods: what an agent's connection may call on the socket, and nothing a window
// does. The app tools are served over MCP (apptools.go), so only those this host serves on
// the socket too are here (#2172): the rest were names with no handler, and one of the new
// names, sessions/list, is the window's.
var agentMethods = methodSet(append([]string{
	"resources/lease", "resources/release", "resources/list", "views/toolCall",
}, strangerMethods...))

var pairingMethods = methodSet(append([]string{"devices/announce"}, strangerMethods...))

// hostAppMethods: what Agents Host's window counts, folders and agents working (#168).
var hostAppMethods = methodSet(append([]string{"folders/list", "agents/list"}, strangerMethods...))

// A Linux host's git, through `agentsd git-credential` (#1122), is any process of the
// account, as git runs it for every one of them.
var strangerOnly = methodSet(append([]string{"git/credential"}, strangerMethods...))

func methodSet(names []string) map[string]bool {
	s := make(map[string]bool, len(names))
	for _, n := range names {
		s[n] = true
	}
	return s
}

// Allows says whether a connection of this role may call method.
func (r Role) Allows(method string) bool {
	switch r {
	case RoleControl, RoleDevice:
		return true
	case RoleAgent:
		return agentMethods[method]
	case RolePairing:
		return pairingMethods[method]
	case RoleHostApp:
		return hostAppMethods[method]
	default:
		return strangerOnly[method]
	}
}

// HearsNotifications: a window and a device hear what the host says; a helper only waits
// on its own replies, and a stranger must not read every transcript going by.
func (r Role) HearsNotifications() bool { return r == RoleControl || r == RoleDevice }

// roled is a connection whose role was decided when it was accepted.
type roled interface{ Role() Role }

func roleOf(conn any) Role {
	if r, ok := conn.(roled); ok {
		return r.Role()
	}
	return RoleControl // a channel the control plane opened (#111)
}

// SocketPolicy decides the role of each caller on daemon.sock.
type SocketPolicy interface {
	// Role is the caller's role, or false to close the connection before a line is read.
	Role(c net.Conn) (Role, bool)
	// Summary is said once in the log, so which door is in place is never a guess.
	Summary() string
}

// socketPolicy is socketPolicyFor(d), decided once: daemon.sock and the local socket
// ask the same agents-peer.
func (d *Daemon) socketPolicy() SocketPolicy {
	d.policyOnce.Do(func() { d.policy = socketPolicyFor(d) })
	return d.policy
}

// socketPolicyFor is the policy for d's daemon.sock: by code signature on a Mac
// (roles_darwin.go), by ssh session on Linux (roles_linux.go). Tests replace it.
var socketPolicyFor = platformSocketPolicy
