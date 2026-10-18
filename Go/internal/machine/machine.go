// Package machine says which computer this is, as MachineID.current did: the id a
// workflow's hosts name and a host gives the control plane (#1404).
package machine

import (
	"os"
	"strings"
)

// ID is AGENTS_MACHINE_ID, else the Mac's hardware UUID, else Linux's machine-id, else
// the host name.
func ID() string {
	if id := strings.TrimSpace(os.Getenv("AGENTS_MACHINE_ID")); id != "" {
		return id
	}
	if id := hardwareUUID(); id != "" {
		return id
	}
	for _, f := range []string{"/etc/machine-id", "/var/lib/dbus/machine-id"} {
		if b, err := os.ReadFile(f); err == nil && strings.TrimSpace(string(b)) != "" {
			return strings.TrimSpace(string(b))
		}
	}
	h, _ := os.Hostname()
	return h
}
