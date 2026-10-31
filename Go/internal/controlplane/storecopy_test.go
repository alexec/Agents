package controlplane

import (
	"context"
	"errors"
	"testing"

	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
)

// A copy carries every record but leases and copies, and refuses a store already in use.
func TestCopyStoreCarriesRecordsAndRefusesAStoreInUse(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	from, to := store.NewFolder(t.TempDir()), store.NewFolder(t.TempDir())
	for _, key := range []string{records.SettingsKey, "v1/machines/a.json", "v1/leases/a.json", "v1/copies/b.json", "v1/keys/control.sealed"} {
		if _, err := from.Put(ctx, key, []byte(key), store.Absent); err != nil {
			t.Fatal(err)
		}
	}
	// The receiving copy's own sealed key is there already (#1458), and stays.
	to.Put(ctx, "v1/keys/control.sealed", []byte("its own"), store.Absent)
	copied, skipped, err := CopyStore(ctx, from, to)
	if err != nil || copied != 2 || skipped != 3 {
		t.Fatal(copied, skipped, err)
	}
	if o, _ := to.Get(ctx, "v1/machines/a.json"); o == nil || string(o.Data) != "v1/machines/a.json" {
		t.Fatal("the host record did not land")
	}
	if o, _ := to.Get(ctx, "v1/leases/a.json"); o != nil {
		t.Fatal("a lease was copied")
	}
	if o, _ := to.Get(ctx, "v1/keys/control.sealed"); o == nil || string(o.Data) != "its own" {
		t.Fatal("the receiving copy's sealed key changed")
	}
	if _, _, err := CopyStore(ctx, from, to); !errors.Is(err, ErrDestinationInUse) {
		t.Fatal(err)
	}
}
