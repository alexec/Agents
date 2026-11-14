//go:build !darwin

package agentsd

import "github.com/agentloops-dev/agent-loops/Go/wire"

func macOpen(...string) error {
	return &Error{Code: wire.FailureNotSupported, Message: "Only a Mac can open Finder or another app."}
}
