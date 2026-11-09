//go:build !linux

package agentsd

// keepMemoryPrivate is Linux's: on a Mac the hardened runtime keeps agentsd's memory its own.
func keepMemoryPrivate() error { return nil }
