package kms

import (
	"bytes"
	"context"
	"path/filepath"
	"testing"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/store"
)

// #997: each source keeps a rotated key in its own place, and the one before it beside
// it until it is dropped.
func TestBothSourcesKeepARotation(t *testing.T) {
	dir := t.TempDir()
	for name, source := range map[string]interface {
		Source
		Rotate(ctx context.Context, previous, next []byte) error
		Previous(ctx context.Context) ([]byte, error)
		DropPrevious(ctx context.Context) error
	}{
		"file": File{Path: filepath.Join(dir, "control-key")},
		"kept": Kept{Store: store.NewFolder(filepath.Join(dir, "store")), Keeper: localURL(2)},
	} {
		old, err := source.ControlKey(ctx)
		if err != nil {
			t.Fatal(name, err)
		}
		if p, err := source.Previous(ctx); p != nil || err != nil {
			t.Fatal(name, "a previous key before any rotation", err)
		}
		next := controllink.NewPrivateKey()
		if err := source.Rotate(ctx, old, next); err != nil {
			t.Fatal(name, err)
		}
		if now, err := source.ControlKey(ctx); err != nil || !bytes.Equal(now, next) {
			t.Fatal(name, "the new key is not the key", err)
		}
		if p, err := source.Previous(ctx); err != nil || !bytes.Equal(p, old) {
			t.Fatal(name, "the old key is not the previous one", err)
		}
		if err := source.DropPrevious(ctx); err != nil {
			t.Fatal(name, err)
		}
		if p, err := source.Previous(ctx); p != nil || err != nil {
			t.Fatal(name, "the previous key was kept", err)
		}
	}
}
