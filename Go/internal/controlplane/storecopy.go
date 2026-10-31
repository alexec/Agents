package controlplane

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
)

// ErrDestinationInUse is StoreCopy.Failure.destinationInUse: the destination is already
// some control plane's store.
var ErrDestinationInUse = errors.New("The new store already holds a control plane's records, so nothing was copied into it.")

// copySkipped is never carried across: leases and copies are rebuilt when a copy starts,
// and each copy keeps the control key its own way (a Mac in a file or the keychain, a cloud
// machine sealed in its store by its own keeper, #1458), so a sealed key stays where it is.
var copySkipped = []string{"v1/leases/", "v1/copies/", "v1/keys/"}

// backupSkipped is what a backup leaves out (#2137): only what a copy rebuilds when it
// starts. A sealed key stays in, as a restore at the same keeper needs it.
var backupSkipped = []string{"v1/leases/", "v1/copies/"}

// leftOut says a key is under one of the prefixes skipped.
func leftOut(key string, skipped []string) bool {
	for _, prefix := range skipped {
		if strings.HasPrefix(key, prefix) {
			return true
		}
	}
	return false
}

// CopyStore is StoreCopy (contracts/store.md "Copying a store"): every record under v1/
// from one store into an empty one, create only, then checked by count and content. Switch
// Store… runs it with no copy serving; a handover runs it between a frozen copy and a
// receiving one, each end a PeerStore (#1490).
func CopyStore(ctx context.Context, from, to store.Store) (copied, skipped int, err error) {
	return copyStoreLeaving(ctx, from, to, copySkipped)
}

// BackupStore is CopyStore for a backup (#2137): the sealed keys go too.
func BackupStore(ctx context.Context, from, to store.Store) (copied, skipped int, err error) {
	return copyStoreLeaving(ctx, from, to, backupSkipped)
}

func copyStoreLeaving(ctx context.Context, from, to store.Store, leaving []string) (copied, skipped int, err error) {
	if held, err := to.Get(ctx, records.SettingsKey); err != nil {
		return 0, 0, err
	} else if held != nil {
		return 0, 0, ErrDestinationInUse
	}
	keys, err := from.List(ctx, "v1/")
	if err != nil {
		return 0, 0, err
	}
	// A store of a build before #2316 keeps machines under v1/hosts (#2662): they land
	// under v1/machines, unless the store has both.
	oldMachines := true
	for _, k := range keys {
		if strings.HasPrefix(k.Key, records.MachinesPrefix) {
			oldMachines = false
		}
	}
	written := map[string][]byte{}
	for _, k := range keys {
		if leftOut(k.Key, leaving) {
			skipped++
			continue
		}
		object, err := from.Get(ctx, k.Key)
		if err != nil {
			return 0, 0, err
		}
		if object == nil {
			continue
		}
		key := k.Key
		if oldMachines && strings.HasPrefix(key, records.OldMachinesPrefix) {
			key = records.MachinesPrefix + strings.TrimPrefix(key, records.OldMachinesPrefix)
		}
		// Create only: a destination written to meanwhile is a conflict, not overwritten.
		if _, err := to.Put(ctx, key, object.Data, store.Absent); err != nil {
			return 0, 0, err
		}
		written[key] = object.Data
	}
	landed, err := to.List(ctx, "v1/")
	if err != nil {
		return 0, 0, err
	}
	count := 0
	for _, k := range landed {
		if !leftOut(k.Key, leaving) {
			count++
		}
	}
	mismatch := func(what string) error {
		return fmt.Errorf("The copy did not come out the same (%s). The old store is untouched; the new one should be emptied before trying again.", what)
	}
	if count != len(written) {
		return 0, 0, mismatch(fmt.Sprintf("%d records copied, %d found", len(written), count))
	}
	for key, data := range written {
		back, err := to.Get(ctx, key)
		if err != nil {
			return 0, 0, err
		}
		if back == nil || !bytes.Equal(back.Data, data) {
			return 0, 0, mismatch(key)
		}
	}
	return len(written), skipped, nil
}
