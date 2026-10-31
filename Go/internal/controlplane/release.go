package controlplane

import (
	"slices"
	"strings"

	"github.com/alexec/agents/Go/wire"
)

// sendRelease is host/release, at each join of a machine that says host.update/1 (#2178):
// the release this control plane names is its own version, so a Mac's Agents Host updates
// itself to what the organisation runs. A development build names nothing.
func (s *Service) sendRelease(host string) {
	version := s.cfg.Version
	if version == "" || strings.ContainsAny(version, "-+") {
		return
	}
	h := s.records.Host(host)
	if h == nil || !slices.Contains(hostCapabilities(*h), wire.CapHostUpdate1) {
		return
	}
	s.router.Tell(host, wire.NotifyHostRelease.Name, wire.MachineRelease{Version: version})
}
