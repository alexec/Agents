package agentsd

import (
	"golang.org/x/sys/unix"

	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// kernelPressure is macOS's memory pressure, as the kernel says it to memory_pressure(1)
// and the dispatch source: 1 normal, 2 warning, 4 critical. "" when the read fails.
func kernelPressure() wire.MemoryPressure {
	switch v, err := unix.SysctlUint32("kern.memorystatus_vm_pressure_level"); {
	case err != nil:
		return ""
	case v == 4:
		return wire.MemoryPressureCritical
	case v == 2:
		return wire.MemoryPressureWarn
	}
	return wire.MemoryPressureNormal
}

// pressureLevel is the warm pool's reading of kernelPressure (#4514): why it keeps none,
// or "".
func pressureLevel() string {
	switch kernelPressure() {
	case wire.MemoryPressureCritical:
		return "memory pressure critical"
	case wire.MemoryPressureWarn:
		return "memory pressure warning"
	}
	return ""
}
