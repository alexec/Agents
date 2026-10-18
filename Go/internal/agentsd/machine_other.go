//go:build !darwin

package agentsd

// StartMachineWatch hears nothing off a Mac: there is no lid to close or screen to lock
// that this host could see (#372).
func (d *Daemon) StartMachineWatch() {}
