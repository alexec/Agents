package controllink

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"

	"github.com/alexec/agents/Go/wire"
)

// OrgRoutePurpose is HPKE's info an org route's secret is sealed under (#999, research R4).
// v2: the associated data holds the whole delivered route, not only its id.
const OrgRoutePurpose = "com.alexecollins.agents.orgroute.v2"

// OrgRouteAD is the associated data of a delivered route's secrets for one machine: the
// route, the machine and the version, and a digest of everything else delivered with them
// (kind, vendor, runtimes, settings, models, expiry). A file copied to another machine,
// another route's or an older version's does not open; nor does one whose address, header
// or kind differs from what was delivered.
// The control plane seals with it and the machine opens with it: both are Go, and
// encoding/json writes a struct's fields in order and a map's keys sorted.
func OrgRouteAD(r wire.DeliveredRoute, host string) ([]byte, error) {
	r.Sealed = nil
	b, err := json.Marshal(r)
	if err != nil {
		return nil, fmt.Errorf("route %s: %w", r.ID, err)
	}
	return fmt.Appendf(nil, "%s|%s|%d|%x", r.ID, host, r.Version, sha256.Sum256(b)), nil
}
