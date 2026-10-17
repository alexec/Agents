//go:build !darwin

package agentsd

import "os"

// registerDevices serves nothing off a Mac: a server's devices pair with the control plane.
func (d *Daemon) registerDevices() {}

func macName() string {
	if n, err := os.Hostname(); err == nil {
		return n
	}
	return "This Mac"
}
