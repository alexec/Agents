package hosttunnels

import (
	"context"
	"net"
	"sort"
	"strings"
	"time"
)

// networkEvery is how often the network is looked at. Swift's NWPathMonitor is told
// of a change; Go has no such thing, so it asks.
var networkEvery = 2 * time.Second

// watchNetwork is HostTunnels.watchNetwork: a new network (another Wi-Fi, a VPN, the
// cable) leaves every session on the old one. So each session starts again when the
// interfaces change, or when the network comes back.
func (t *Tunnels) watchNetwork(ctx context.Context) {
	last := networkShape()
	for {
		select {
		case <-ctx.Done():
			return
		case <-time.After(networkEvery):
		}
		shape := networkShape()
		if shape != last && shape != "none" {
			t.Restart("the network changed")
		}
		last = shape
	}
}

// networkShape is the shape networkIs compares: the names of the interfaces that are
// up with an address that routes, or "none".
func networkShape() string {
	interfaces, err := net.Interfaces()
	if err != nil {
		return "none"
	}
	var names []string
	for _, i := range interfaces {
		if i.Flags&net.FlagUp == 0 || i.Flags&net.FlagLoopback != 0 {
			continue
		}
		addresses, err := i.Addrs()
		if err != nil {
			continue
		}
		for _, a := range addresses {
			if ip, ok := a.(*net.IPNet); ok && ip.IP.IsGlobalUnicast() {
				names = append(names, i.Name)
				break
			}
		}
	}
	if len(names) == 0 {
		return "none"
	}
	sort.Strings(names)
	return strings.Join(names, ",")
}
