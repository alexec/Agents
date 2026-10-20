package agentsd

import (
	"os"
	"slices"
	"strings"

	"github.com/alexec/agents/Go/wire"
)

// Capabilities is this host's list (#1748): each capability whose methods it registers,
// and the ones a host declares. AGENTS_TEST_DROP_CAPABILITIES (comma-separated) takes some
// out, so a walk can be an older host.
func (d *Daemon) Capabilities() []string {
	list := wire.Served(wire.HostCapabilities, wire.HostNotifications, func(m string) bool {
		_, ok := d.handlers[m]
		return ok
	}, wire.DeclaredCapabilities["host"]...)
	if drop := os.Getenv("AGENTS_TEST_DROP_CAPABILITIES"); drop != "" {
		gone := strings.Split(drop, ",")
		list = slices.DeleteFunc(list, func(c string) bool { return slices.Contains(gone, c) })
	}
	return list
}
