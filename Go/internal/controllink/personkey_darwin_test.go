package controllink

import (
	"bytes"
	"testing"

	"github.com/alexec/agents/Go/internal/mac"
)

// scratchPersonKeys is a scratch root's Keychain store for the person key, its item deleted
// after the test (the pattern of scratchHostKeys in hostkey_darwin_test.go).
func scratchPersonKeys(t *testing.T) (string, PersonKeyKeychain) {
	t.Helper()
	root := t.TempDir()
	s := PersonKeyFor(root).(PersonKeyKeychain)
	t.Cleanup(func() { mac.KeychainDelete(s.Service, personKeyAccount) })
	return root, s
}

// On a Mac the person key is kept in the Keychain, scoped to its own root, and never shares
// an item with the machine key even though both live under the same root.
func TestThePersonKeyIsNotAFileOnAMac(t *testing.T) {
	root, s := scratchPersonKeys(t)
	if s.Service != PersonKeyService(root) || s.Service == PersonKeyService(t.TempDir()) {
		t.Fatalf("not the root's own service: %s", s.Service)
	}
	key, err := PersonPrivateKey(s)
	skipWithoutKeychain(t, err)
	if err != nil || len(key) != 32 {
		t.Fatalf("%v %d", err, len(key))
	}
	again, err := PersonPrivateKey(PersonKeyFor(root))
	if err != nil || !bytes.Equal(again, key) {
		t.Fatalf("not the same key after a restart: %v", err)
	}
	noFileHolds(t, root, key)
}

// An old person-key file (left by a start that stopped before the Keychain took it in)
// moves into the Keychain on its first read, and is removed.
func TestAnOldPersonKeyFileMovesIntoTheKeychain(t *testing.T) {
	root, s := scratchPersonKeys(t)
	old := NewPrivateKey()
	if err := s.File.Save(old); err != nil {
		t.Fatal(err)
	}
	key, err := PersonPrivateKey(s)
	skipWithoutKeychain(t, err)
	if err != nil || !bytes.Equal(key, old) {
		t.Fatalf("not the old key: %v", err)
	}
	if _, had, _ := s.File.Load(); had {
		t.Fatal("the old file is still there")
	}
	noFileHolds(t, root, old)
}
