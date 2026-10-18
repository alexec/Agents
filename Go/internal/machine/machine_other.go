//go:build !darwin

package machine

// hardwareUUID is a Mac's alone: Linux reads its machine-id.
func hardwareUUID() string { return "" }
