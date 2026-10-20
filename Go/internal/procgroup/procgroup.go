// Package procgroup runs a command in a process group of its own, so what it leaves
// behind can be ended with it (#1643).
//
// ssh starts a ProxyCommand as its child. gh's (`gh cs ssh -c <name> --stdio`) does not
// end when ssh does: each ssh call to a codespace left one gh relay running, with its
// connection to GitHub. In its own group, the relay is ended when ssh has exited.
package procgroup

import (
	"os/exec"
	"syscall"
)

// Own puts cmd, before it starts, in a process group of its own. End the group when
// cmd has exited, also when a cancelled context killed it.
func Own(cmd *exec.Cmd) {
	if cmd.SysProcAttr == nil {
		cmd.SysProcAttr = &syscall.SysProcAttr{}
	}
	cmd.SysProcAttr.Setpgid = true
}

// End kills what is left in cmd's group. Call it when cmd has exited and before the
// group can be empty for long: while one of its processes runs, its id is not reused.
// A command that never started, or a group with nothing left, does nothing.
func End(cmd *exec.Cmd) {
	if cmd.Process == nil || cmd.Process.Pid <= 1 {
		return
	}
	syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
}
