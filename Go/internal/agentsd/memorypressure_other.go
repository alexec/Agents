//go:build !darwin

package agentsd

// pressureLevel is none off a Mac: Linux's swap, in /proc/meminfo, is the signal there.
func pressureLevel() string { return "" }
