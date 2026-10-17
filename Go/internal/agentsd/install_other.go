//go:build !darwin

package agentsd

// registerInstall serves nothing off a Mac: a server keeps 043's toolset install.
func (d *Daemon) registerInstall() {}
