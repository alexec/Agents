package hosttunnels

import (
	"flag"
	"testing"

	"github.com/alexec/agents/Go/internal/wiretest"
)

var update = flag.Bool("update", false, "write testdata/wire-types.golden from today's types")

// A tunnel's state reads the bytes in testdata/wire-types.golden and writes them again
// unchanged (#1313).
func TestWireTypesKeepTheirBytes(t *testing.T) {
	wiretest.Check(t, "testdata/wire-types.golden", wiretest.Types{
		"MachineTunnel":        func() any { return new(Tunnel) },
		"MachineTunnelChanged": func() any { return new(Changed) },
	}, *update)
}
