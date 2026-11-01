//go:build !darwin

package controllink

// PersonKeyFor is the root's store: off a Mac, person-key in the root.
func PersonKeyFor(root string) PersonKeyStore { return PersonKeyFile{Root: root} }
