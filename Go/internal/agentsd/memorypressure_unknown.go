//go:build !darwin && !linux

package agentsd

import "github.com/agentloops-dev/agents/Go/wire"

// kernelPressure is unknown where the kernel has no word for it.
func kernelPressure() wire.MemoryPressure { return "" }
