package controlplane

import (
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"

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
		return store.NewFolder(u.Path), nil
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
		return s3store.New(location, credentials, nil), nil
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
