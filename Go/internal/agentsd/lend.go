package agentsd

import (
	"context"
	"strings"
	"sync"

	"github.com/alexec/agents/Go/wire"
)

// A credential the window lends (043). The secret stays in memory for this host and is
// never logged. credentials/offer says which runtimes the window can still lend; one it
// no longer names is dropped.

const geminiAPIKey wire.CredentialKind = "geminiAPIKey"

// lentBook is the secrets currently lent, and the runtimes the last offer named.
type lentBook struct {
	mu      sync.Mutex
	secrets map[string]string
	offered map[string]bool
}

func (d *Daemon) registerLend() {
	On(d, wire.CallCredentialsOffer, func(_ context.Context, _ *Client, o wire.CredentialsOffer) (wire.Empty, error) {
		d.noteCredentialOffer(o)
		return wire.Empty{}, nil
	})
	On(d, wire.CallCredentialsLend, func(_ context.Context, _ *Client, r wire.CredentialsLend) (wire.Empty, error) {
		return wire.Empty{}, d.lendCredential(r)
	})
}

func (d *Daemon) noteCredentialOffer(o wire.CredentialsOffer) {
	d.lent.mu.Lock()
	defer d.lent.mu.Unlock()
	d.lent.offered = map[string]bool{}
	for _, runtime := range o.Runtimes {
		d.lent.offered[runtime] = true
	}
	for runtime := range d.lent.secrets {
		if !d.lent.offered[runtime] {
			delete(d.lent.secrets, runtime)
		}
	}
}

// lendCredential keeps a Gemini key. Anything else is refused, and the refusal does not
// repeat the secret.
func (d *Daemon) lendCredential(r wire.CredentialsLend) error {
	runtime := strings.TrimSpace(r.Runtime)
	if r.Kind != geminiAPIKey || runtime == "" || strings.ContainsAny(runtime, "\r\n=") ||
		strings.TrimSpace(r.Secret) == "" || strings.ContainsAny(r.Secret, "\r\n\x00") {
		return Invalid("That credential cannot be lent.")
	}
	d.lent.mu.Lock()
	defer d.lent.mu.Unlock()
	if d.lent.secrets == nil {
		d.lent.secrets = map[string]string{}
	}
	d.lent.secrets[runtime] = r.Secret
	return nil
}

func (d *Daemon) lentSecret(runtime string) string {
	d.lent.mu.Lock()
	defer d.lent.mu.Unlock()
	return d.lent.secrets[runtime]
}
