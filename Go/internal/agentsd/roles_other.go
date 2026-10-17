//go:build !darwin

package agentsd

// platformSocketPolicy: a server's daemon.sock is reached through ssh, mode 0600, as it
// was before roles.
func platformSocketPolicy(*Daemon) SocketPolicy { return openPolicy{} }
