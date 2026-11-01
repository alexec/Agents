package controllink

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"

	"github.com/alexec/agents/Go/wire"
)

// The person key (#2957, research R1): a new ECDSA P-256 key, distinct from the machine key
// (hostkey.go) and the control key. The Mac's host makes it the first time the person's own
// layer is saved, and keeps it in the Keychain (hostkey_darwin.go's pattern, account
// "person", a service distinct from the machine key's) or in a 0600 file
// <root>/person-key on a scratch root or Linux. The host that holds the private key is the
// keeper (research R4): only it may sign the person's layer. SignPolicy and VerifyPolicy
// (policysig.go) are reused as they are; this file only makes and keeps the key.

// PersonKeyFileName is the key's file in the root, kept off a Mac, or on a scratch root
// before the Keychain holds it.
const PersonKeyFileName = "person-key"

// PersonKeyStore keeps the person key's private half.
type PersonKeyStore interface {
	// Load is the key, or false when none was made yet.
	Load() ([]byte, bool, error)
	Save(key []byte) error
}

// PersonPrivateKey is the store's key, made and kept the first time (R1): the first save of
// the person's layer makes it, and every later save on this machine reuses it.
func PersonPrivateKey(s PersonKeyStore) ([]byte, error) {
	if k, ok, err := s.Load(); err != nil || ok {
		return k, err
	}
	k := NewPrivateKey()
	return k, s.Save(k)
}

// PersonKeyFile is the key in <root>/person-key, 0600: Linux's store, and a scratch root's.
type PersonKeyFile struct{ Root string }

func (f PersonKeyFile) path() string { return filepath.Join(f.Root, PersonKeyFileName) }

func (f PersonKeyFile) Load() ([]byte, bool, error) {
	b, err := os.ReadFile(f.path())
	if errors.Is(err, os.ErrNotExist) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	if len(b) != 32 {
		return nil, false, nil
	}
	return b, true, nil
}

func (f PersonKeyFile) Save(key []byte) error { return os.WriteFile(f.path(), key, 0o600) }

// PersonKeyService is the root's own Keychain service for the person key: distinct from
// HostKeyService's prefix (the machine key), so the two never collide in the same Keychain,
// scoped to the root's hash so a scratch root never touches the real Keychain item.
func PersonKeyService(root string) string {
	sum := sha256.Sum256([]byte(filepath.Clean(root)))
	return "agents.person-key." + hex.EncodeToString(sum[:4])
}

// PersonKeyRotationFor is a PersonKeyRotation record moving from oldPrivate to a newly made
// key (data-model.md "PersonKeyRotation"): the new public key, signed by the old one, so a
// machine that already pinned the old key can verify the move before it takes the new one.
func PersonKeyRotationFor(oldPrivate []byte) (newPrivate []byte, rotation wire.PersonKeyRotation, err error) {
	newPrivate = NewPrivateKey()
	newPublic, err := PublicKey(newPrivate)
	if err != nil {
		return nil, wire.PersonKeyRotation{}, err
	}
	newKeyID := KeyID(newPublic)
	raw, err := personKeyRotationPayload{NewKey: newPublic, NewKeyID: newKeyID}.canonical()
	if err != nil {
		return nil, wire.PersonKeyRotation{}, err
	}
	sig, err := SignPolicy(oldPrivate, raw)
	if err != nil {
		return nil, wire.PersonKeyRotation{}, err
	}
	oldPublic, err := PublicKey(oldPrivate)
	if err != nil {
		return nil, wire.PersonKeyRotation{}, err
	}
	return newPrivate, wire.PersonKeyRotation{
		NewKey:   newPublic,
		NewKeyID: newKeyID,
		Signature: wire.PolicySignature{
			Version: 1,
			KeyID:   KeyID(oldPublic),
			Alg:     PolicyAlg,
			Sig:     sig,
		},
	}, nil
}

// PersonKeyRotationValid says whether rotation moves the pin on, checked against the
// currently pinned public key (data-model.md "State transitions"): a rotation is accepted
// only if it verifies against the previously pinned key.
func PersonKeyRotationValid(pinnedPublic []byte, rotation wire.PersonKeyRotation) bool {
	raw, err := personKeyRotationPayload{NewKey: rotation.NewKey, NewKeyID: rotation.NewKeyID}.canonical()
	if err != nil {
		return false
	}
	return VerifyPolicy(pinnedPublic, raw, rotation.Signature.Sig)
}

// personKeyRotationPayload is what a rotation record signs: the new key and its id, so the
// signature cannot be replayed for a different key.
type personKeyRotationPayload struct {
	NewKey   []byte `json:"newKey"`
	NewKeyID string `json:"newKeyID"`
}

func (p personKeyRotationPayload) canonical() ([]byte, error) {
	raw, err := json.Marshal(p)
	if err != nil {
		return nil, err
	}
	return CanonicalJSON(raw)
}
