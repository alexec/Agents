//go:build !darwin

package agentsd

// registerWake serves nothing off a Mac: a server is not put to sleep by its idle time.
func (d *Daemon) registerWake() {}
