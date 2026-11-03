package controlplane

import (
	"context"
	"os"
	"path/filepath"

	"github.com/alexec/agents/Go/internal/codespacessh"
)

// prepareSSH is the installer's and the tunnels' Prepare (#3347): a codespace a
// codespaces-api provider lists is reached through gh, with the provider's token. Its host
// is put in the ssh config, and gh is given the token in ssh's environment. A control plane
// is never signed in to gh, so nothing else gives it one. Any other destination: nothing.
func (s *Service) prepareSSH(ctx context.Context, destination string) ([]string, error) {
	if s.providers == nil {
		return nil, nil
	}
	name, token := s.providers.Codespace(destination)
	if token == "" {
		return nil, nil
	}
	if err := codespacessh.Prepare(ctx, sshConfigPath(), name, destination, token, os.Environ()); err != nil {
		return nil, err
	}
	return []string{codespacessh.Token(token)}, nil
}

// sshConfigPath is the ssh config ssh reads here: AGENTS_SSH_CONFIG, as the installer's
// and the tunnels' -F, else ~/.ssh/config.
func sshConfigPath() string {
	if file := os.Getenv("AGENTS_SSH_CONFIG"); file != "" {
		return file
	}
	home, err := os.UserHomeDir()
	if err != nil {
		home = "/"
	}
	return filepath.Join(home, ".ssh", "config")
}
