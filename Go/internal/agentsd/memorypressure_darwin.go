package agentsd

import "golang.org/x/sys/unix"

// pressureLevel is macOS's memory pressure, as the kernel says it to memory_pressure(1)
// and the dispatch source: 1 normal, 2 warning, 4 critical.
func pressureLevel() string {
	switch v, err := unix.SysctlUint32("kern.memorystatus_vm_pressure_level"); {
	case err != nil:
		return ""
	case v == 4:
		return "memory pressure critical"
	case v == 2:
		return "memory pressure warning"
	}
	return ""
}
