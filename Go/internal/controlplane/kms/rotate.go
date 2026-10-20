package kms

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/store"
)

// A rotation of the control key (#997) keeps the new key where the old one was, and the
// old one beside it while members still on it are accepted.

// PreviousKey is where the sealed key before a rotation is in the store.
const PreviousKey = "v1/keys/control-previous.sealed"

func (f File) previousPath() string { return f.Path + ".previous" }

// Rotate writes the previous key beside the key file, then the new key in its place.
func (f File) Rotate(_ context.Context, previous, next []byte) error {
	if err := writeKeyFile(f.previousPath(), previous); err != nil {
		return err
	}
	return writeKeyFile(f.Path, next)
}

// Previous is the key before the last rotation, or nil.
func (f File) Previous(context.Context) ([]byte, error) {
	b, err := os.ReadFile(f.previousPath())
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if !controllink.ValidPrivateKey(b) {
		return nil, fmt.Errorf("%s is not a key", f.previousPath())
	}
	return b, nil
}

// DropPrevious deletes the previous key's file.
func (f File) DropPrevious(context.Context) error {
	if err := os.Remove(f.previousPath()); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

// writeKeyFile writes a key whole, 0600, synced, then renames it into place.
func writeKeyFile(path string, key []byte) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	b := make([]byte, 8)
	rand.Read(b)
	tmp := filepath.Join(dir, fmt.Sprintf(".%s.%x.tmp", filepath.Base(path), b))
	w, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	defer os.Remove(tmp)
	_, err = w.Write(key)
	if err == nil {
		err = w.Sync()
	}
	if cerr := w.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// Rotate seals the previous key at PreviousKey, then the new one at Key.
func (k Kept) Rotate(ctx context.Context, previous, next []byte) error {
	if err := k.seal(ctx, PreviousKey, previous); err != nil {
		return err
	}
	return k.seal(ctx, Key, next)
}

// Previous opens the key before the last rotation, or gives nil when there is none.
func (k Kept) Previous(ctx context.Context) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, Timeout)
	defer cancel()
	o, err := k.Store.Get(ctx, PreviousKey)
	if err != nil || o == nil {
		return nil, err
	}
	var sealed Sealed
	if err := json.Unmarshal(o.Data, &sealed); err != nil {
		return nil, fmt.Errorf("%s cannot be read: %w", PreviousKey, err)
	}
	keeper, err := Keeper(ctx, k.Keeper)
	if err != nil {
		return nil, err
	}
	defer func() { go keeper.Close() }()
	return Open(ctx, keeper, &sealed)
}

// DropPrevious deletes the sealed previous key.
func (k Kept) DropPrevious(ctx context.Context) error {
	return k.Store.Delete(ctx, PreviousKey)
}

func (k Kept) seal(ctx context.Context, at string, key []byte) error {
	ctx, cancel := context.WithTimeout(ctx, Timeout)
	defer cancel()
	keeper, err := Keeper(ctx, k.Keeper)
	if err != nil {
		return err
	}
	defer func() { go keeper.Close() }()
	sealed, err := Seal(ctx, keeper, k.Keeper, key)
	if err != nil {
		return err
	}
	b, err := json.MarshalIndent(sealed, "", "  ")
	if err != nil {
		return err
	}
	_, err = k.Store.Put(ctx, at, b, store.Always)
	return err
}
