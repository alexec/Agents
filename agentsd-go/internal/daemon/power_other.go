//go:build !darwin

package daemon

import "os/exec"

// awake: a server has no idle sleep to hold off.
func (d *Daemon) awake(on bool) { _ = exec.Command }
