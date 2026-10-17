package agentsd

import (
	"os/exec"

	"github.com/alexec/agents/Go/wire"
)

// macOpen runs /usr/bin/open, as DaemonCore.macOpen does: started, not waited on.
func macOpen(args ...string) error {
	cmd := exec.Command("/usr/bin/open", args...)
	if err := cmd.Start(); err != nil {
		return &Error{Code: wire.FailureNotSupported, Message: "This Mac could not open that: " + err.Error()}
	}
	go cmd.Wait()
	return nil
}
