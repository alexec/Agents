package agentsd

import (
	"context"
	"sort"

	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// secrets/localList (#5122): the secrets this machine keeps for itself, for Settings ▸ You ▸
// Secrets ▸ On This Machine. An agent saved them (ask_secret, capture_secret,
// generate_secret) or a connector's form set them, so they are in sealed.json only: not the
// person's (Settings ▸ You ▸ Secrets, which the control plane lists) and not a session's
// own (secrets/sessionList). Without this list a person could not see them, nor turn Ask
// before use off with secrets/setNeedsApproval. Names only, never a value.

// localSecretList is every secret in this machine's store that is not the person's, by name.
func (d *Daemon) localSecretList() wire.LocalSecrets {
	out := wire.LocalSecrets{Secrets: []wire.LocalSecret{}}
	home := d.personalHome()
	if home == "" {
		return out
	}
	d.userScopeMu.Lock()
	mark := d.userMarkLocked()
	d.userScopeMu.Unlock()
	user := map[string]bool{}
	for _, n := range mark.Secrets {
		user[n] = true
	}
	descriptions := readSecretDescriptions(home)
	for name, s := range readSealedSecrets(home).Secrets {
		if s.From == sealedFromUser || user[name] {
			continue
		}
		row := wire.LocalSecret{Name: name, SetAt: s.SetAt, BackedUp: new(false)}
		if !s.NoAsk {
			row.NeedsApproval = new(true)
		}
		if about := descriptions[name]; about != "" {
			row.Description = new(about)
		}
		if op, ok := d.secretLastOp(name); ok {
			row.LastOp = &wire.SecretLastOp{What: op.What, At: op.At, Agent: op.Agent}
		}
		out.Secrets = append(out.Secrets, row)
	}
	sort.Slice(out.Secrets, func(i, j int) bool { return out.Secrets[i].Name < out.Secrets[j].Name })
	return out
}

// Only the person's own clients reach it (Role.Allows): an agent's connection has none.
func (d *Daemon) registerLocalSecrets() {
	On(d, wire.CallSecretsLocalList, func(_ context.Context, _ *Client, _ wire.Empty) (wire.LocalSecrets, error) {
		return d.localSecretList(), nil
	})
}
