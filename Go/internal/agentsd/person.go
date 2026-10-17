package agentsd

import (
	"context"
	"os"
	"path/filepath"

	"github.com/alexec/agents/Go/internal/agentsd/diskjson"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// person/state and person/set (#121): what agents call the person, in person.json in the
// person's settings (PersonSettingsStore), said to every window as person/changed.
func (d *Daemon) registerPerson() {
	On(d, wire.CallPersonState, func(ctx context.Context, c *Client, _ wire.Empty) (wire.PersonSettings, error) {
		return d.personSettings(), nil
	})
	On(d, wire.CallPersonSet, func(ctx context.Context, c *Client, p wire.PersonSettings) (wire.PersonSettings, error) {
		b, err := diskjson.Marshal(p)
		if err != nil {
			return wire.PersonSettings{}, err
		}
		file := filepath.Join(d.SettingsDir, "person.json")
		if err := os.MkdirAll(filepath.Dir(file), 0o700); err != nil {
			return wire.PersonSettings{}, err
		}
		if err := store.WriteAtomically(file, b, 0o600); err != nil {
			return wire.PersonSettings{}, err
		}
		Broadcast(d, wire.NotifyPersonChanged, p)
		return p, nil
	})
}

// personSettings is person.json, or none given when it is missing or does not decode.
func (d *Daemon) personSettings() wire.PersonSettings {
	var p wire.PersonSettings
	if b, err := os.ReadFile(filepath.Join(d.SettingsDir, "person.json")); err == nil {
		if diskjson.Unmarshal(b, &p) != nil {
			p = wire.PersonSettings{}
		}
	}
	return p
}
