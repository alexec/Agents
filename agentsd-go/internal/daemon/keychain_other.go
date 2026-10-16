//go:build !darwin

package daemon

func keychainSignIn() bool { return false }
