package kms

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"os"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/store"
)

// Source is where the control plane keeps its key (#1458). There are two kinds:
//
//   - File: the key, raw, in a 0600 file, made if missing. The default, and what a
//     control plane on a Mac uses.
//   - Kept: the key sealed in the store by a keeper, such as Google Cloud KMS
//     (gcpkms://…). What a control plane on a cloud machine uses: the key is never on its
//     disk in clear.
type Source interface {
	// ControlKey gives the key, made the first time.
	ControlKey(ctx context.Context) ([]byte, error)
	// String says where the key is, for a log line. It never holds a key.
	String() string
}

// File is the key in a file of its own, mode 0600.
type File struct{ Path string }

func (f File) ControlKey(context.Context) ([]byte, error) {
	if f.Path == "" {
		return nil, errors.New("no key file is given")
	}
	return controllink.LoadOrMakeKey(f.Path)
}

func (f File) String() string { return "the key file " + f.Path }

// Kept is the key sealed in Store by the keeper that Keeper names. Given is a key handed
// in (by a descriptor, the environment or an old key file), sealed the first time; nil
// makes a new key. When the store already has a sealed key, a key given must be that
// key: two control keys for one store is an error, not a choice.
type Kept struct {
	Store  store.Store
	Keeper string
	Given  []byte
}

func (k Kept) ControlKey(ctx context.Context) ([]byte, error) {
	key, err := ControlKey(ctx, k.Store, k.Keeper, func() []byte {
		if k.Given != nil {
			return k.Given
		}
		return controllink.NewPrivateKey()
	})
	if err != nil {
		return nil, err
	}
	if k.Given != nil && !bytes.Equal(key, k.Given) {
		return nil, errors.New("the key given is not the one sealed in the store: give no key, or the store's own")
	}
	return key, nil
}

func (k Kept) String() string { return "sealed in the store by " + Describe(k.Keeper) }

// NoCredentialsFile lets Google's default credentials find the machine's own service
// account (the metadata server) when GOOGLE_APPLICATION_CREDENTIALS names an empty file.
// deploy/make-secrets.sh --public writes an empty one when it is given no service account
// file, as a compose secret must be a file. Then no key of any kind is on the disk.
func NoCredentialsFile() {
	file := os.Getenv("GOOGLE_APPLICATION_CREDENTIALS")
	if file == "" {
		return
	}
	if info, err := os.Stat(file); err == nil && info.Size() == 0 {
		os.Unsetenv("GOOGLE_APPLICATION_CREDENTIALS")
	}
}

// LocalKeeper is the keeper of people's secrets on a control plane with no cloud keeper
// (#1760, FR-025): a local key in a 0600 file of its own, outside the store, made if
// missing. It gives the keeper's URL, which holds the key: never write it down whole
// (Describe).
func LocalKeeper(path string) (string, error) {
	key, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		key = make([]byte, 32)
		rand.Read(key)
		if err = writeKeyFile(path, key); err != nil {
			return "", err
		}
	} else if err != nil {
		return "", err
	}
	if len(key) != 32 {
		return "", errors.New(path + " is not a key for secrets: it must be 32 bytes")
	}
	return "base64key://" + base64.URLEncoding.EncodeToString(key), nil
}
