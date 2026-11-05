package controlplane

import (
	"context"
	"errors"
	"strings"
)

// prepareSSH is the installer's and the tunnels' Prepare (#3347): a codespace is reached
// through gh with its provider's token, which stays on the machine that carries the
// provider (#3398). That machine starts the codespace's agentsd over ssh, reads its host
// key, and installs Agents in it for Add as Machine… (providers/ssh, #3497). The control
// plane has no token to do any of it itself, or to hold a tunnel to it, so it says so: a
// carried codespace dials the control plane's own address. Any other destination: nothing.
func (s *Service) prepareSSH(_ context.Context, destination string) ([]string, error) {
	if !strings.HasPrefix(destination, "cs.") {
		return nil, nil
	}
	return nil, errors.New("A codespace is reached over SSH from the machine that carries its provider, with the token kept there: the control plane holds none, so it can't reach it over SSH or keep a tunnel to it. Use Add as Machine… on the codespace in its provider's card, or install Agents in it with its join command")
}
