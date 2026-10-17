//go:build !darwin

package agentsd

// macState is empty off a Mac.
type macState struct{}

// registerMacSignIn is a Mac's: only a Mac relays a sign-in.
func (d *Daemon) registerMacSignIn() {}

// LendingPort is a Mac's: only a Mac relays a sign-in.
func (d *Daemon) LendingPort(string) int { return 0 }

func (d *Daemon) stopSignInRelays() {}
