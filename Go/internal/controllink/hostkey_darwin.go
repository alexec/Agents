package controllink

import (
	"bytes"
	"errors"
	"fmt"
	"os"

	"github.com/alexec/agents/Go/internal/mac"
)

// hostKeyAccount is the Keychain item's account under the root's service.
const hostKeyAccount = "machine"

// HostKeyFor is the root's store: on a Mac the Keychain (mac.KeychainAdd), which takes in
// a control-host-key file the root kept before and then removes it.
func HostKeyFor(root string) HostKeyStore {
	return HostKeyKeychain{Service: HostKeyService(root), File: HostKeyFile{Root: root}}
}

// HostKeyKeychain is the key in a Keychain item that only the program that made it reads.
type HostKeyKeychain struct {
	Service string
	// File is the root's old file: moved into the item, then removed.
	File HostKeyFile
}

func (k HostKeyKeychain) Load() ([]byte, bool, error) {
	key, ok, err := mac.KeychainGet(k.Service, hostKeyAccount)
	if err != nil {
		// Never a new key: that would leave the control plane this machine joined.
		return nil, false, fmt.Errorf("this machine's key: %w", err)
	}
	if ok && len(key) != 32 {
		return nil, false, errors.New("this machine's key in the Keychain is not a key")
	}
	if !ok {
		old, had, err := k.File.Load()
		if err != nil || !had {
			return nil, false, err
		}
		if err := k.Save(old); err != nil {
			return nil, false, err
		}
		key, ok = old, true
	}
	// The file is removed once the item holds the key, also when an earlier start kept it
	// and did not get to the removal.
	if err := os.Remove(k.File.path()); err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, false, fmt.Errorf("this machine's old key file: %w", err)
	}
	return key, ok, nil
}

func (k HostKeyKeychain) Save(key []byte) error {
	if err := mac.KeychainAdd(k.Service, hostKeyAccount, "Agents machine key", key); err != nil {
		return fmt.Errorf("this machine's key: %w", err)
	}
	// Read back: a key not kept is a key lost at the next start.
	got, ok, err := mac.KeychainGet(k.Service, hostKeyAccount)
	if err != nil || !ok || !bytes.Equal(got, key) {
		return errors.New("this machine's key: the Keychain did not keep it")
	}
	return nil
}
