package controllink

import (
	"bytes"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"testing"

	"github.com/alexec/agents/Go/internal/mac"
)

// scratchHostKeys is a scratch root's Keychain store, its item deleted after the test: a
// temporary root has its own service, so the real root's item is never read or written.
func scratchHostKeys(t *testing.T) (string, HostKeyKeychain) {
	t.Helper()
	root := t.TempDir()
	s := HostKeyFor(root).(HostKeyKeychain)
	t.Cleanup(func() { mac.KeychainDelete(s.Service, hostKeyAccount) })
	return root, s
}

// skipWithoutKeychain skips where the login Keychain would ask (a locked one on CI).
func skipWithoutKeychain(t *testing.T, err error) {
	t.Helper()
	if errors.Is(err, mac.ErrKeychainDenied) {
		t.Skip("the login Keychain is locked here")
	}
}

// On a Mac the machine key is not in a file of the root: any process of the person, an
// agent included, reads those.
func TestTheMachineKeyIsNotAFileOnAMac(t *testing.T) {
	root, s := scratchHostKeys(t)
	if s.Service != HostKeyService(root) || s.Service == HostKeyService(t.TempDir()) {
		t.Fatalf("not the root's own service: %s", s.Service)
	}
	key, err := HostPrivateKey(s)
	skipWithoutKeychain(t, err)
	if err != nil || len(key) != 32 {
		t.Fatalf("%v %d", err, len(key))
	}
	again, err := HostPrivateKey(HostKeyFor(root))
	if err != nil || !bytes.Equal(again, key) {
		t.Fatalf("not the same key after a restart: %v", err)
	}
	noFileHolds(t, root, key)
}

// A root that kept control-host-key before moves it into the Keychain on its first start,
// keeps the same key (its membership still holds) and removes the file.
func TestAnOldKeyFileMovesIntoTheKeychain(t *testing.T) {
	root, s := scratchHostKeys(t)
	old := NewPrivateKey()
	if err := os.WriteFile(filepath.Join(root, HostKeyFileName), old, 0o600); err != nil {
		t.Fatal(err)
	}
	key, err := HostPrivateKey(s)
	skipWithoutKeychain(t, err)
	if err != nil || !bytes.Equal(key, old) {
		t.Fatalf("not the old key: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, HostKeyFileName)); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("the old file is still there: %v", err)
	}
	got, ok, err := mac.KeychainGet(s.Service, hostKeyAccount)
	if err != nil || !ok || !bytes.Equal(got, old) {
		t.Fatalf("not in the Keychain: %v %v", ok, err)
	}
	noFileHolds(t, root, key)

	// A file left by a start that stopped before the removal goes too; the item wins.
	os.WriteFile(filepath.Join(root, HostKeyFileName), NewPrivateKey(), 0o600)
	again, err := HostPrivateKey(s)
	if err != nil || !bytes.Equal(again, old) {
		t.Fatalf("not the Keychain's key: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, HostKeyFileName)); !errors.Is(err, fs.ErrNotExist) {
		t.Fatal("the left file is still there")
	}
}

// An item already there is never written over: it may be another program's.
func TestTheKeychainItemIsNotWrittenOver(t *testing.T) {
	_, s := scratchHostKeys(t)
	key, err := HostPrivateKey(s)
	skipWithoutKeychain(t, err)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Save(NewPrivateKey()); err == nil {
		t.Fatal("written over")
	}
	if got, _, _ := s.Load(); !bytes.Equal(got, key) {
		t.Fatal("the key changed")
	}
}

// noFileHolds says no file under root holds key, raw or in hex or base64.
func noFileHolds(t *testing.T, root string, key []byte) {
	t.Helper()
	forms := [][]byte{key, []byte(B64URL(key)), []byte(hex.EncodeToString(key)), []byte(base64.StdEncoding.EncodeToString(key))}
	filepath.WalkDir(root, func(path string, e fs.DirEntry, err error) error {
		if err != nil || e.IsDir() {
			return nil
		}
		b, _ := os.ReadFile(path)
		for _, f := range forms {
			if bytes.Contains(b, f) {
				t.Errorf("%s holds the machine key", path)
			}
		}
		return nil
	})
}
