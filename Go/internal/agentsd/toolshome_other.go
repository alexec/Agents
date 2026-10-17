//go:build !darwin

package agentsd

// setToolsHome leaves a server's toolsets in ~/.agents-server/tools.
func (d *Daemon) setToolsHome() {}
