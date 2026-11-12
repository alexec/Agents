package agentsd

import (
	"context"
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"unicode"

	"github.com/alexec/agents/Go/internal/agentsd/diskjson"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// A secret's hint (#4158): its last 4 characters, so a person can tell it is the one they
// expect. Only for a value of 16 characters or more, because 4 characters of a short PIN or
// password are most of it; a card's is the last 4 of its number. This machine works it out
// when it opens its copy, keeps it beside the copy in ~/.agents-secrets/hints.json (0600),
// and sends it with its state (machine/secretOps, held). The control plane passes it to the
// person's own clients and never writes it to its store.

// secretHintMin is the shortest value that has a hint.
const secretHintMin = 16

// secretHint is a value's hint, or "" when it has none.
func secretHint(value string, kind *wire.UserSecretKind) string {
	if kind != nil && *kind == wire.UserSecretKindCard {
		var card struct {
			Number string `json:"number"`
		}
		if json.Unmarshal([]byte(value), &card) != nil {
			return ""
		}
		var digits []rune
		for _, r := range card.Number {
			if unicode.IsDigit(r) {
				digits = append(digits, r)
			}
		}
		if len(digits) < 8 {
			return ""
		}
		return string(digits[len(digits)-4:])
	}
	runes := []rune(value)
	if len(runes) < secretHintMin {
		return ""
	}
	return string(runes[len(runes)-4:])
}

// secretHintRecord is one secret's hint, for the version it was worked out from.
type secretHintRecord struct {
	Version int64  `json:"version,omitempty"`
	Hint    string `json:"hint"`
}

func secretHintsPath(home string) string {
	return filepath.Join(home, ".agents-secrets", "hints.json")
}

func readSecretHints(home string) map[string]secretHintRecord {
	out := map[string]secretHintRecord{}
	if home == "" {
		return out
	}
	if raw, err := os.ReadFile(secretHintsPath(home)); err == nil && diskjson.Unmarshal(raw, &out) != nil {
		log.Printf("hints.json: unreadable, starting afresh")
		return map[string]secretHintRecord{}
	}
	return out
}

// writeSecretHints keeps the hints of names only: a secret removed takes its hint with it.
func writeSecretHints(home string, hints map[string]secretHintRecord, names []string) {
	if home == "" {
		return
	}
	kept := map[string]secretHintRecord{}
	for _, n := range names {
		if h, ok := hints[n]; ok && h.Hint != "" {
			kept[n] = h
		}
	}
	p := secretHintsPath(home)
	if len(kept) == 0 {
		if err := os.Remove(p); err != nil && !os.IsNotExist(err) {
			log.Printf("hints.json: could not remove: %v", err)
		}
		return
	}
	raw, err := json.Marshal(kept)
	if err == nil {
		err = os.MkdirAll(filepath.Dir(p), 0o700)
	}
	if err == nil {
		err = store.WriteAtomically(p, raw, 0o600)
	}
	if err != nil {
		log.Printf("hints.json: could not save: %v", err)
	}
}

// secretsHeld is every one of the person's secrets this machine holds a copy of: its version,
// its hint for that version, and its last operation here.
func (d *Daemon) secretsHeld() []wire.MachineSecretHeld {
	d.userScopeMu.Lock()
	mark := d.userMarkLocked()
	d.userScopeMu.Unlock()
	hints := readSecretHints(d.personalHome())
	held := []wire.MachineSecretHeld{}
	for _, n := range mark.Secrets {
		h := wire.MachineSecretHeld{Name: wire.UserSecretName(n)}
		version, hasVersion := mark.Versions[n]
		if hasVersion {
			h.Version = new(version)
		}
		if hint, ok := hints[n]; ok && hint.Hint != "" && (!hasVersion || hint.Version == version) {
			h.Hint = new(hint.Hint)
		}
		if op, ok := d.secretLastOp(n); ok {
			h.LastOp = &wire.SecretLastOp{What: op.What, At: op.At, Agent: op.Agent}
		}
		held = append(held, h)
	}
	return held
}

// tellSecretsHeld sends this machine's state of the person's secrets to the control plane.
func (d *Daemon) tellSecretsHeld() {
	ask := d.askControl.Load()
	if ask == nil {
		return
	}
	ctx, cancel := context.WithTimeout(d.ctx, secretOpsAsk)
	defer cancel()
	if _, err := (*ask)(ctx, wire.CallMachineSecretOps.Name, wire.MachineSecretOpsCall{Ops: []wire.SecretOperation{}, Held: d.secretsHeld()}); err != nil {
		log.Printf("secret ops: the control plane was not told what is held here: %v", err)
	}
}
