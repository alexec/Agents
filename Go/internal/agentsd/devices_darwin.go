package agentsd

import (
	"os/exec"
	"strings"
)

// registerDevices serves pairing on a Mac (devices.go).
func (d *Daemon) registerDevices() { d.serveDevices() }

// macName is what the bridge advertises, so the phone looks for this Mac by name: the
// Mac's own name, as Host.current().localizedName.
func macName() string {
	if out, err := exec.Command("/usr/sbin/scutil", "--get", "ComputerName").Output(); err == nil {
		if n := strings.TrimSpace(string(out)); n != "" {
			return n
		}
	}
	return "This Mac"
}
