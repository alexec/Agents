// Package kms keeps the control plane's private key in the store, sealed in an envelope
// (#1126 stage 4). A fresh data key encrypts the control key with AES-256-GCM. A keeper
// from gocloud.dev/secrets wraps the data key. A copy with the store and the right to
// use the keeper gets the control key. A copy with the store alone does not.
//
// The local keeper is the default and needs no account. The cloud keepers are options.
// Nothing calls them unless their URL is given.
//
//	base64key://<32 bytes, base64url>   the local keeper
//	hashivault://K                      Vault's transit key K, with VAULT_SERVER_URL
//	                                    and VAULT_SERVER_TOKEN (stage 9)
//	gcpkms://projects/P/locations/L/keyRings/R/cryptoKeys/K
//	                                    Google Cloud KMS (#61)
package kms

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"gocloud.dev/secrets"
	_ "gocloud.dev/secrets/gcpkms"
	_ "gocloud.dev/secrets/hashivault"
	_ "gocloud.dev/secrets/localsecrets"

	"github.com/alexec/agents/Go/internal/controlplane/store"
)

// Timeout bounds the keeper calls at start. A test can make it shorter.
var Timeout = 30 * time.Second

// Key is where the sealed control key is in the store.
const Key = "v1/keys/control.sealed"

// Sealed is the envelope as stored. Nothing in it opens without the keeper.
type Sealed struct {
	// Keeper tells which keeper wrapped the data key. It never holds a secret.
	Keeper string `json:"keeper"`
	// WrappedKey is the data key, wrapped by the keeper.
	WrappedKey []byte `json:"wrappedKey"`
	Nonce      []byte `json:"nonce"`
	// Ciphertext is the control key, encrypted with the data key.
	Ciphertext []byte    `json:"ciphertext"`
	Sealed     time.Time `json:"sealed"`
}

// Keeper opens the keeper that a URL names. Its error never holds the URL: a local
// keeper's URL is its key, and no log line may hold a key (071 FR-033).
func Keeper(ctx context.Context, url string) (*secrets.Keeper, error) {
	k, err := secrets.OpenKeeper(ctx, url)
	if err != nil {
		words := strings.ReplaceAll(err.Error(), url, Describe(url))
		if i := strings.Index(url, "://"); i >= 0 && strings.HasPrefix(url, "base64key://") {
			words = strings.ReplaceAll(words, url[i+3:], "(local)")
		}
		if strings.HasPrefix(url, "base64key://") {
			words += " (a local key is 32 bytes in base64url, with its padding)"
		}
		return nil, errors.New(words)
	}
	return k, nil
}

// Describe gives the keeper URL to write down. It removes the bytes of a local key.
func Describe(url string) string {
	if strings.HasPrefix(url, "base64key://") {
		return "base64key://(local)"
	}
	return url
}

// Seal makes an envelope for plaintext.
func Seal(ctx context.Context, k *secrets.Keeper, keeperURL string, plaintext []byte) (*Sealed, error) {
	dataKey := make([]byte, 32)
	rand.Read(dataKey)
	wrapped, err := bounded(ctx, func() ([]byte, error) { return k.Encrypt(ctx, dataKey) })
	if err != nil {
		return nil, fmt.Errorf("the KMS would not wrap a data key: %w", err)
	}
	gcm, err := gcmOf(dataKey)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, gcm.NonceSize())
	rand.Read(nonce)
	return &Sealed{
		Keeper:     Describe(keeperURL),
		WrappedKey: wrapped,
		Nonce:      nonce,
		Ciphertext: gcm.Seal(nil, nonce, plaintext, []byte(Key)),
		Sealed:     time.Now().UTC(),
	}, nil
}

// Open unwraps the data key with the keeper and decrypts the envelope.
func Open(ctx context.Context, k *secrets.Keeper, s *Sealed) ([]byte, error) {
	dataKey, err := bounded(ctx, func() ([]byte, error) { return k.Decrypt(ctx, s.WrappedKey) })
	if err != nil {
		return nil, fmt.Errorf("the KMS would not unwrap the data key (sealed by %s): %w", s.Keeper, err)
	}
	gcm, err := gcmOf(dataKey)
	if err != nil {
		return nil, fmt.Errorf("the KMS gave a data key that is not usable: %w", err)
	}
	plain, err := gcm.Open(nil, s.Nonce, s.Ciphertext, []byte(Key))
	if err != nil {
		return nil, errors.New("the sealed control key does not open with its data key")
	}
	return plain, nil
}

// bounded stops waiting for a keeper call when ctx ends, also when the keeper ignores
// ctx. gocloud's hashivault ignores it, so a Vault that did not answer hung the start
// (stage 9). The call that is left ends with the process.
func bounded(ctx context.Context, call func() ([]byte, error)) ([]byte, error) {
	type result struct {
		b   []byte
		err error
	}
	done := make(chan result, 1)
	go func() {
		b, err := call()
		done <- result{b, err}
	}()
	select {
	case r := <-done:
		return r.b, r.err
	case <-ctx.Done():
		return nil, fmt.Errorf("the KMS did not answer: %w", ctx.Err())
	}
}

func gcmOf(key []byte) (cipher.AEAD, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

// ControlKey gets the control key from the store and opens it with the keeper. When the
// store has no sealed key, it calls make, seals that key and writes it. make gives the
// key of an existing key file, or a new key. When copies start together on an empty
// store, one write wins and the other copies open the winner's key.
func ControlKey(ctx context.Context, s store.Store, keeperURL string, make func() []byte) ([]byte, error) {
	// A keeper that does not answer stops the start with words. It does not hang it.
	ctx, cancel := context.WithTimeout(ctx, Timeout)
	defer cancel()
	k, err := Keeper(ctx, keeperURL)
	if err != nil {
		return nil, fmt.Errorf("the control key's keeper %s: %w", Describe(keeperURL), err)
	}
	// Close aside: Close waits for a call that bounded can leave behind.
	defer func() { go k.Close() }()
	for range 3 {
		o, err := s.Get(ctx, Key)
		if err != nil {
			return nil, err
		}
		if o != nil {
			var sealed Sealed
			if err := json.Unmarshal(o.Data, &sealed); err != nil {
				return nil, fmt.Errorf("%s cannot be read: %w", Key, err)
			}
			return Open(ctx, k, &sealed)
		}
		key := make()
		sealed, err := Seal(ctx, k, keeperURL, key)
		if err != nil {
			return nil, err
		}
		b, err := json.MarshalIndent(sealed, "", "  ")
		if err != nil {
			return nil, err
		}
		if _, err := s.Put(ctx, Key, b, store.Absent); err == nil {
			return key, nil
		} else if !store.IsConflict(err) {
			return nil, err
		}
	}
	return nil, errors.New("could not agree on one control key with the other copies")
}
