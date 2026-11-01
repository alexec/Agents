package controllink

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// A machine that is not the keeper of a person's layer pins the keeper's public key once
// (#2957, research R3, data-model.md "PinnedPersonKey"), at <root>/person-key.pub.json,
// 0600: from a join code (path 1, PersonKeyFromCode), the Mac window's direct link (path 2,
// policy/applyYours), or, for a machine joined before this version, the first signed copy
// the control plane sends (path 3, trust on first use). After the pin, only a rotation
// record that checks against the pinned key moves it.

// PinnedPersonKeyFileName is the file this machine's pin is kept in.
const PinnedPersonKeyFileName = "person-key.pub.json"

// PinnedPersonKey is the person's public key this machine trusts (data-model.md
// "PinnedPersonKey").
type PinnedPersonKey struct {
	Key   []byte    `json:"key"`
	KeyID string    `json:"keyID"`
	From  string    `json:"from"` // joinCode | window | controlPlane
	At    time.Time `json:"at"`
}

// The three places a pin may come from (research R3).
const (
	PinFromJoinCode     = "joinCode"
	PinFromWindow       = "window"
	PinFromControlPlane = "controlPlane"
)

func pinnedPersonKeyPath(root string) string { return filepath.Join(root, PinnedPersonKeyFileName) }

// LoadPinnedPersonKey is this machine's pin, or nil when it has none yet.
func LoadPinnedPersonKey(root string) (*PinnedPersonKey, error) {
	b, err := os.ReadFile(pinnedPersonKeyPath(root))
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var p PinnedPersonKey
	if err := json.Unmarshal(b, &p); err != nil || len(p.Key) == 0 {
		return nil, nil
	}
	return &p, nil
}

func (p *PinnedPersonKey) save(root string) error {
	b, err := json.Marshal(p)
	if err != nil {
		return err
	}
	path := pinnedPersonKeyPath(root)
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// PinPersonKey pins key as this machine's trusted person key, from source, when none is
// pinned yet. When one is already pinned, it is returned unchanged: only a rotation record
// (AcceptPersonKeyRotation) moves a pin once it exists.
func PinPersonKey(root string, key []byte, from string, at time.Time) (*PinnedPersonKey, error) {
	if existing, err := LoadPinnedPersonKey(root); err != nil {
		return nil, err
	} else if existing != nil {
		return existing, nil
	}
	p := &PinnedPersonKey{Key: key, KeyID: KeyID(key), From: from, At: at}
	if err := p.save(root); err != nil {
		return nil, err
	}
	return p, nil
}

// AcceptPersonKeyRotation moves this machine's pin to rotation's new key, only when rotation
// checks against the key already pinned (data-model.md "State transitions"). Refuses when
// nothing is pinned yet: a rotation is never the first pin.
func AcceptPersonKeyRotation(root string, rotation wire.PersonKeyRotation, at time.Time) (*PinnedPersonKey, error) {
	pinned, err := LoadPinnedPersonKey(root)
	if err != nil {
		return nil, err
	}
	if pinned == nil {
		return nil, errors.New("no person key is pinned yet; a rotation cannot be the first pin")
	}
	if !PersonKeyRotationValid(pinned.Key, rotation) {
		return nil, errors.New("the rotation does not check against the pinned key")
	}
	p := &PinnedPersonKey{Key: rotation.NewKey, KeyID: rotation.NewKeyID, From: pinned.From, At: at}
	if err := p.save(root); err != nil {
		return nil, err
	}
	return p, nil
}
