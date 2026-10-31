package hostinstall

import (
	"flag"
	"testing"

	"github.com/alexec/agents/Go/internal/wiretest"
)

var update = flag.Bool("update", false, "write testdata/wire-types.golden from today's types")

// What Add a Machine sends and is answered reads the bytes in testdata/wire-types.golden and
// writes them again unchanged (#1313).
func TestWireTypesKeepTheirBytes(t *testing.T) {
	wiretest.Check(t, "testdata/wire-types.golden", wiretest.Types{
		"MachineInstall": func() any { return new(Request) },
		"DetectedServer": func() any { return new(DetectedServer) },
		"SSHHost":        func() any { return new(SSHHost) },
	}, *update)
}
