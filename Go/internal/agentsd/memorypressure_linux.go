package agentsd

import (
	"os"

	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// kernelPressure is Linux's PSI for memory (#4578), /proc/pressure/memory: "" when the
// kernel has no PSI (before 4.20, or turned off).
func kernelPressure() wire.MemoryPressure {
	b, err := os.ReadFile("/proc/pressure/memory")
	if err != nil {
		return ""
	}
	return psiPressure(string(b))
}
