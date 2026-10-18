package kms

import (
	"bytes"
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/controlplane/store"
)

// The file kind makes a key in a 0600 file the first time and gives the same key after.
func TestFileSourceMakesAndKeepsAKey(t *testing.T) {
	path := filepath.Join(t.TempDir(), "control", "control-key")
	var source Source = File{Path: path}
	first, err := source.ControlKey(ctx)
	if err != nil || len(first) != 32 {
		t.Fatal(err, len(first))
	}
	info, err := os.Stat(path)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatal(err, info.Mode())
	}
	again, err := source.ControlKey(ctx)
	if err != nil || !bytes.Equal(again, first) {
		t.Fatal(err)
	}
	if !strings.Contains(source.String(), path) {
		t.Fatal(source.String())
	}
}

// The kept kind seals a new key in the store and puts nothing on the disk: localsecrets
// stands in for Google Cloud KMS, as both are gocloud.dev keepers.
func TestKeptSourceSealsANewKey(t *testing.T) {
	dir := t.TempDir()
	st := store.NewFolder(dir)
	var source Source = Kept{Store: st, Keeper: localURL(1)}
	first, err := source.ControlKey(ctx)
	if err != nil || len(first) != 32 {
		t.Fatal(err, len(first))
	}
	// No file on the disk holds the key in clear, also not in base64.
	files := 0
	filepath.WalkDir(dir, func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		files++
		data, _ := os.ReadFile(path)
		if bytes.Contains(data, first) || strings.Contains(string(data), base64.StdEncoding.EncodeToString(first)) {
			t.Errorf("%s holds the key in clear", path)
		}
		return nil
	})
	if files == 0 {
		t.Fatal("the sealed key is not in the store's folder")
	}
	again, err := Kept{Store: st, Keeper: localURL(1)}.ControlKey(ctx)
	if err != nil || !bytes.Equal(again, first) {
		t.Fatal(err)
	}
	if source.String() != "sealed in the store by base64key://(local)" {
		t.Fatal(source.String())
	}
}

// A key handed in (a Mac's, for a move) is sealed the first time, and the same key after
// is accepted. Another key is refused: one store has one control key.
func TestKeptSourceSealsTheKeyGiven(t *testing.T) {
	st := store.NewMemory()
	mac := bytes.Repeat([]byte{7}, 32)
	key, err := Kept{Store: st, Keeper: localURL(1), Given: mac}.ControlKey(ctx)
	if err != nil || !bytes.Equal(key, mac) {
		t.Fatal(err)
	}
	if key, err := (Kept{Store: st, Keeper: localURL(1), Given: mac}).ControlKey(ctx); err != nil || !bytes.Equal(key, mac) {
		t.Fatal(err)
	}
	other := bytes.Repeat([]byte{8}, 32)
	if _, err := (Kept{Store: st, Keeper: localURL(1), Given: other}).ControlKey(ctx); err == nil ||
		!strings.Contains(err.Error(), "not the one sealed in the store") {
		t.Fatal(err)
	}
}

// An empty credentials file means the machine's own service account.
func TestNoCredentialsFile(t *testing.T) {
	empty := filepath.Join(t.TempDir(), "gcp-service-account")
	if err := os.WriteFile(empty, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("GOOGLE_APPLICATION_CREDENTIALS", empty)
	NoCredentialsFile()
	if _, set := os.LookupEnv("GOOGLE_APPLICATION_CREDENTIALS"); set {
		t.Fatal("an empty file is still the credentials")
	}
	full := filepath.Join(t.TempDir(), "sa.json")
	if err := os.WriteFile(full, []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("GOOGLE_APPLICATION_CREDENTIALS", full)
	NoCredentialsFile()
	if os.Getenv("GOOGLE_APPLICATION_CREDENTIALS") != full {
		t.Fatal("a service account file was let go")
	}
}

// Existing gives the key sealed in the store, and makes none on an empty store (#1477).
func TestExistingOpensTheSealedKeyAndMakesNone(t *testing.T) {
	st := store.NewFolder(t.TempDir())
	if _, err := Existing(ctx, st, localURL(1)); err != ErrNoKey {
		t.Fatalf("an empty store gave %v", err)
	}
	if o, _ := st.Get(ctx, Key); o != nil {
		t.Fatal("Existing sealed a key")
	}
	sealed, err := Kept{Store: st, Keeper: localURL(1)}.ControlKey(ctx)
	if err != nil {
		t.Fatal(err)
	}
	got, err := Existing(ctx, st, localURL(1))
	if err != nil || !bytes.Equal(got, sealed) {
		t.Fatal(err)
	}
	if _, err := Existing(ctx, st, localURL(2)); err == nil {
		t.Fatal("another keeper opened the key")
	}
}
