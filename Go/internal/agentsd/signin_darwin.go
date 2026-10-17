package agentsd

import (
	"context"
	"os"

	"github.com/alexec/agents/Go/internal/buildinfo"
	"github.com/alexec/agents/Go/internal/mac/signin"
	"github.com/alexec/agents/Go/wire"
)

// macState is what a Mac's host keeps that a server's does not.
type macState struct {
	signInRelays *signin.Relays
}


// registerMacSignIn is relay/grant (058, T091), on a Mac's host: relay a runtime's
// sign-in to a server through the control plane. The token stays here; what goes back is
// the stand-in and the relay's CA. A tunnel the control plane opens for the lend reaches
// the relay through LendingPort.
func (d *Daemon) registerMacSignIn() {
	home, _ := os.UserHomeDir()
	relays := &signin.Relays{Root: d.Store.Loc.Root, Logs: d.Store.Loc.Logs, Home: home}
	// A walk's stand-in for Claude's Keychain item, so a lend is walked without the
	// person's sign-in: an unreleased build only.
	if buildinfo.Version == "dev" {
		relays.TestKeychain = os.Getenv("AGENTS_TEST_CLAUDE_KEYCHAIN_SERVICE")
	}
	d.signInRelays = relays
	On(d, wire.CallRelayGrant, func(ctx context.Context, c *Client, r wire.RelayGrantRequest) (wire.RelayGrantReply, error) {
		g, err := relays.Grant(r.Runtime)
		if err != nil {
			// DaemonAPI.Failure.notPermitted, as the Swift host answers.
			return wire.RelayGrantReply{}, &Error{Code: -32045, Message: err.Error()}
		}
		return wire.RelayGrantReply{Runtime: g.Runtime, CaCertificate: g.CACertificate, StandIn: g.StandIn}, nil
	})
}

// LendingPort is where the relay for runtime listens on this Mac once granted, for a
// tunnel the control plane opens to it; 0 when this host does not relay it.
func (d *Daemon) LendingPort(runtime string) int {
	if d.signInRelays == nil {
		return 0
	}
	return d.signInRelays.Port(runtime)
}

func (d *Daemon) stopSignInRelays() {
	if d.signInRelays != nil {
		d.signInRelays.Stop()
	}
}
