//go:build !darwin && !linux

package agentsd

// registerInstall serves nothing off a Mac or Linux.
func (d *Daemon) registerInstall() {}

// installDefaultToolsets has nothing to install off Linux.
func (d *Daemon) installDefaultToolsets() {}
