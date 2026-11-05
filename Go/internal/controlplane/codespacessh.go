package controlplane

import (
	"context"
	"errors"
	"strings"
)

// prepareSSH is the installer's and the tunnels' Prepare (#3347): a codespace is reached
// through gh with its provider's token, which stays on the machine that carries the
// provider (#3398). That machine starts the codespace's agentsd over ssh, and reads its
// host key (providers/ssh); the control plane has no token to install one, or to hold a
// tunnel to it, so it says so. Any other destination: nothing.
func (s *Service) prepareSSH(_ context.Context, destination string) ([]string, error) {
	if !strings.HasPrefix(destination, "cs.") {
		return nil, nil
	}
	return nil, errors.New("A codespace is reached over SSH from the machine that carries its provider, with the token kept there: the control plane holds none, so it can't install Agents in it or keep a tunnel to it. Install Agents in the codespace with its join command")
}
