//go:build !linux

package agentsd

import "net"

// openPolicy is everything to every caller. A Linux server uses ssh sessions
// (roles_linux.go) instead, so this type is not in that build.
type openPolicy struct{ why string }

func (openPolicy) Role(net.Conn) (Role, bool) { return RoleControl, true }
func (p openPolicy) Summary() string {
	return p.why + "every process of this account may call everything"
}
