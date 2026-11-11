//go:build !darwin

package agentsd

// pressureLevel is none off a Mac: Linux's swap, in /proc/meminfo, is the warm pool's
// signal there (#4514). Capacity reads PSI (kernelPressure) as well.
func pressureLevel() string { return "" }
