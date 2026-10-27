package controllink

import (
	"flag"
	"testing"

	"github.com/alexec/agents/Go/internal/wiretest"
	"github.com/alexec/agents/Go/wire"
)

var update = flag.Bool("update", false, "write testdata/wire-types.golden from today's types")

// The exchange's lines and what a host says read the bytes in testdata/wire-types.golden
// and write them again unchanged (#1313).
func TestWireTypesKeepTheirBytes(t *testing.T) {
	wiretest.Check(t, "testdata/wire-types.golden", wiretest.Types{
		"ControlHello":    func() any { return new(Hello) },
		"ControlAuth":     func() any { return new(Auth) },
		"ControlOK":       func() any { return new(OK) },
		"MachineHello":    func() any { return new(MachineHello) },
		"MachineAnnounce": func() any { return new(wire.MachineAnnounce) },
	}, *update)
}
