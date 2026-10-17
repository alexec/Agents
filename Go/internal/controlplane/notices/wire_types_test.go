package notices

import (
	"flag"
	"testing"

	"github.com/alexec/agents/Go/internal/wiretest"
)

var update = flag.Bool("update", false, "write testdata/wire-types.golden from today's types")

// A relay delivery reads the bytes in testdata/wire-types.golden and writes them again
// unchanged (#1313).
func TestWireTypesKeepTheirBytes(t *testing.T) {
	wiretest.Check(t, "testdata/wire-types.golden", wiretest.Types{
		"RelayDelivery": func() any { return new(RelayDelivery) },
	}, *update)
}
