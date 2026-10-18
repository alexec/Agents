//go:build !darwin && !linux

package agentsd

// platformSocketPolicy: no peer check here, so the socket's mode 0600 is the only door.
func platformSocketPolicy(*Daemon) SocketPolicy {
	return openPolicy{why: "no peer check on this platform, so "}
}
