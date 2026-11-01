package controllink

import (
	"bytes"
	"errors"
	"fmt"
	"os"

	"github.com/alexec/agents/Go/internal/mac"
)

// personKeyAccount is the Keychain item's account under the root's service: distinct from
// hostKeyAccount ("machine"), so the person key and the machine key never share an item.
const personKeyAccount = "person"

// PersonKeyFor is the root's store: on a Mac the Keychain (mac.KeychainAdd).
func PersonKeyFor(root string) PersonKeyStore {
	return PersonKeyKeychain{Service: PersonKeyService(root), File: PersonKeyFile{Root: root}}
}

// PersonKeyKeychain is the person key in a Keychain item that only the program that made it
// reads (the pattern of HostKeyKeychain).
type PersonKeyKeychain struct {
	Service string
	// File is the root's file, from before the Keychain held it, or a start that stopped
	// before it could remove it: taken in, then removed.
	File PersonKeyFile
}

func (k PersonKeyKeychain) Load() ([]byte, bool, error) {
	key, ok, err := mac.KeychainGet(k.Service, personKeyAccount)
	if err != nil {
		return nil, false, fmt.Errorf("the person key: %w", err)
	}
	if ok && len(key) != 32 {
		return nil, false, errors.New("the person key in the Keychain is not a key")
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
	if err := os.Remove(k.File.path()); err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, false, fmt.Errorf("the person key's old file: %w", err)
	}
	return key, ok, nil
}

func (k PersonKeyKeychain) Save(key []byte) error {
	if err := mac.KeychainAdd(k.Service, personKeyAccount, "Agents person key", key); err != nil {
		return fmt.Errorf("the person key: %w", err)
	}
	got, ok, err := mac.KeychainGet(k.Service, personKeyAccount)
	if err != nil || !ok || !bytes.Equal(got, key) {
		return errors.New("the person key: the Keychain did not keep it")
	}
	return nil
}
