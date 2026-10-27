package controlplane

import (
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/store"
)

// #1807: a copy we run for an account has no ssh: no tunnels, and no machine installed,
// found or listed over the servers' own ssh.
func TestAHostedCopyHasNoSSH(t *testing.T) {
	t.Parallel()
	p := startPlaneWith(t, store.NewMemory(), controllink.NewPrivateKey(), func(c *Config) { c.Hosted = true })
	if p.s.tunnels != nil {
		t.Fatal("a hosted copy has ssh tunnels")
	}
	_, window := p.client("Window")
	for _, method := range []string{"hosts/install", "hosts/detect", "hosts/sshHosts"} {
		if e := callError(t, window, "", method, map[string]any{}); !strings.Contains(e, "no ssh of yours") {
			t.Fatalf("%s: %s", method, e)
		}
	}
	// Codes still work: machines join with one.
	call(t, window, "", "hosts/startEnroll", map[string]any{})
}
