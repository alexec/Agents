package controlplane

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"

	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/s3store"
	"github.com/alexec/agents/Go/internal/controlplane/store"
)

// StoreCredentials are a bucket's keys handed over apart from the environment: Agents
// Host's --store-credentials-fd (T058a), as JSON {"accessKey":…,"secretKey":…}.
type StoreCredentials struct {
	AccessKey string `json:"accessKey"`
	SecretKey string `json:"secretKey"`
}

// OpenStore is StoreAddress.open: a store named by its URL (contracts/store.md
// "Configuration"). file:///path is a folder, the default, which needs no account;
// s3://bucket/prefix is a bucket, an option, with its keys given, or from the
// environment or ~/.aws/credentials.
func OpenStore(text string, env func(string) string, given *StoreCredentials) (store.Store, error) {
	u, err := url.Parse(text)
	if err != nil || u.Scheme == "" {
		return nil, fmt.Errorf("%s is not a store: say file:///path or s3://bucket/prefix", text)
	}
	switch u.Scheme {
	case "file":
		if err := moveOldMachines(u.Path); err != nil {
			return nil, err
		}
		folder := store.NewFolder(u.Path)
		if err := moveOldMachineKeys(context.Background(), folder); err != nil {
			return nil, err
		}
		return folder, nil
	case "s3":
		location, ok := s3store.ParseLocation(text, env)
		if !ok {
			break
		}
		credentials, ok := s3store.CredentialsFrom(env)
		if given != nil {
			credentials, ok = s3store.Credentials{AccessKey: given.AccessKey, SecretKey: given.SecretKey}, true
		}
		if !ok {
			return nil, fmt.Errorf("no keys for the bucket: AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY, ~/.aws/credentials, or --store-credentials-fd")
		}
		bucket := s3store.New(location, credentials, nil)
		if err := moveOldMachineKeys(context.Background(), bucket); err != nil {
			return nil, err
		}
		return bucket, nil
	}
	return nil, fmt.Errorf("%s is not a store: say file:///path or s3://bucket/prefix", text)
}

// moveOldMachines renames a folder store's v1/hosts to v1/machines (#2662), when only
// the old one is there: the store of a build before #2316. The records do not change.
func moveOldMachines(root string) error {
	old := filepath.Join(root, filepath.FromSlash(records.OldMachinesPrefix))
	now := filepath.Join(root, filepath.FromSlash(records.MachinesPrefix))
	if _, err := os.Stat(old); err != nil {
		return nil
	}
	if _, err := os.Stat(now); !errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err := os.Rename(old, now); err != nil {
		return fmt.Errorf("move %s to %s: %w", old, now, err)
	}
	fmt.Fprintf(os.Stderr, "agents-control: moved the machine records from %s to %s (#2316)\n", old, now)
	return nil
}

// moveOldMachineKeys moves each machine record under v1/hosts to v1/machines, on every
// open of every store (H20261027-1): a bucket of a build before #2316, and what an old
// copy writes to v1/hosts after the move, in a rolling handover (H20261027-3). Each
// write is create-only, so copies that open the store together move each record once,
// and a machine already under v1/machines keeps that record. The old key is then
// deleted: unconditionally, as a store has no conditional delete, so an old copy's write
// between the read and the delete is lost; that copy is being replaced.
func moveOldMachineKeys(ctx context.Context, s store.Store) error {
	old, err := s.List(ctx, records.OldMachinesPrefix)
	if err != nil {
		return fmt.Errorf("list %s: %w", records.OldMachinesPrefix, err)
	}
	moved := 0
	for _, k := range old {
		object, err := s.Get(ctx, k.Key)
		if err != nil {
			return err
		}
		if object == nil {
			continue // Another copy moved it.
		}
		key := records.MachinesPrefix + strings.TrimPrefix(k.Key, records.OldMachinesPrefix)
		if _, err := s.Put(ctx, key, object.Data, store.Absent); err == nil {
			moved++
		} else if !store.IsConflict(err) {
			return err
		}
		if err := s.Delete(ctx, k.Key); err != nil {
			return err
		}
	}
	if moved > 0 {
		fmt.Fprintf(os.Stderr, "agents-control: moved %d machine records from %s to %s (#2316)\n", moved, records.OldMachinesPrefix, records.MachinesPrefix)
	}
	return nil
}
