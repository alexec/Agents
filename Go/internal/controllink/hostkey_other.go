//go:build !darwin

package controllink

// HostKeyFor is the root's store: off a Mac, control-host-key in the root.
func HostKeyFor(root string) HostKeyStore { return HostKeyFile{Root: root} }
