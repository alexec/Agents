//go:build !darwin

package agentsd

// registerSelfUpdate serves nothing off a Mac: a server's agentsd is updated by the control
// plane over ssh (hosts/update, #1766).
func (d *Daemon) registerSelfUpdate() {}
