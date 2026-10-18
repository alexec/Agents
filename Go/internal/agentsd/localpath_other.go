//go:build !darwin

package agentsd

// There is no window beside a host that is not a Mac: its clients go through the control
// plane.
func localPathHere() bool { return false }

func makeLocalGroup() {}
