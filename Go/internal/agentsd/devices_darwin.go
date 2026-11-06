package agentsd

import (
	"os/exec"
	"strings"
)

// registerDevices serves the paired devices on a Mac (devices.go).
func (d *Daemon) registerDevices() { d.serveDevices() }

// macName is the Mac's own name, as Host.current().localizedName: what a backup says it
// was made on.
func macName() string {
	if out, err := exec.Command("/usr/sbin/scutil", "--get", "ComputerName").Output(); err == nil {
		if n := strings.TrimSpace(string(out)); n != "" {
			return n
		}
	}
	return "This Mac"
}
