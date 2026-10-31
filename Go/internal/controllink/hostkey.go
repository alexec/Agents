package controllink

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
)

// This machine's private key (P-256, 32 raw bytes, made once): what it proves itself with to
// the control plane, and what org routes are sealed to. On a Mac it is kept in a Keychain
// item that only agentsd's code signature reads (hostkey_darwin.go), so another program of
// the person, an agent's shell included, cannot read it from the root. On Linux there is
// no such store for one user: it is control-host-key in the root, 0600, and any process of
// the same user can read it (spec 999, "Limits").

// HostKeyFileName is the key's file in the root, where it is kept on Linux and was kept on
// a Mac before the Keychain.
const HostKeyFileName = "control-host-key"

// HostKeyStore keeps this machine's private key.
type HostKeyStore interface {
	// Load is the key, or false when none was made yet.
	Load() ([]byte, bool, error)
	Save(key []byte) error
}

// HostPrivateKey is the store's key, made and kept the first time.
func HostPrivateKey(s HostKeyStore) ([]byte, error) {
	if k, ok, err := s.Load(); err != nil || ok {
		return k, err
	}
	k := NewPrivateKey()
	return k, s.Save(k)
}

// HostKeyFile is the key in <root>/control-host-key, 0600: Linux's store, and the tests'.
type HostKeyFile struct{ Root string }

func (f HostKeyFile) path() string { return filepath.Join(f.Root, HostKeyFileName) }

func (f HostKeyFile) Load() ([]byte, bool, error) {
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

func (f HostKeyFile) Save(key []byte) error { return os.WriteFile(f.path(), key, 0o600) }

// HostKeyService is the root's own Keychain service for its key: the first four bytes of
// the root path's SHA-256, as connections.KeychainService, so a scratch root never reads or
// writes the real one's item.
func HostKeyService(root string) string {
	sum := sha256.Sum256([]byte(filepath.Clean(root)))
	return "agents.machine-key." + hex.EncodeToString(sum[:4])
}
