// Package kms keeps the control plane's private key in the store, sealed in an envelope:
// a fresh data key encrypts it (AES-256-GCM), and a key management service, through
// gocloud.dev/secrets, wraps the data key. Every copy with the bucket and the right to
// use the KMS key gets the control key; nobody with the bucket alone does, and no copy
// needs a key file (#1126 stage 4; Google Cloud KMS is #61).
//
//	AGENTS_CONTROL_KMS=base64key://<32 bytes, base64url>     the local keeper: tests and walks
//	AGENTS_CONTROL_KMS=gcpkms://projects/P/locations/L/keyRings/R/cryptoKeys/K
//	                                                         written, not run: it waits for #61
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
	_ "gocloud.dev/secrets/localsecrets"

	"github.com/alexec/agents/controlplane-go/internal/store"
)

// Key is where the sealed control key lives in the store.
const Key = "v1/keys/control.sealed"

// Sealed is the envelope as stored: nothing in it opens without the KMS.
type Sealed struct {
	// Which keeper wrapped the data key: its URL's scheme and path, never a secret.
	Keeper string `json:"keeper"`
	// The data key, wrapped by the KMS.
	WrappedKey []byte `json:"wrappedKey"`
	Nonce      []byte `json:"nonce"`
	// The control key, encrypted under the data key.
	Ciphertext []byte    `json:"ciphertext"`
	Sealed     time.Time `json:"sealed"`
}

// Keeper opens the keeper a URL names.
func Keeper(ctx context.Context, url string) (*secrets.Keeper, error) {
	return secrets.OpenKeeper(ctx, url)
}

// Describe is what is written down about a keeper: the URL without a local key's bytes.
func Describe(url string) string {
	if strings.HasPrefix(url, "base64key://") {
		return "base64key://(local)"
	}
	return url
}

// Seal makes an envelope for plaintext.
func Seal(ctx context.Context, k *secrets.Keeper, keeper string, plaintext []byte) (*Sealed, error) {
	dataKey := make([]byte, 32)
	rand.Read(dataKey)
	wrapped, err := k.Encrypt(ctx, dataKey)
	if err != nil {
		return nil, fmt.Errorf("the KMS would not wrap a data key: %w", err)
	}
	gcm, err := gcmOf(dataKey)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, gcm.NonceSize())
	rand.Read(nonce)
	return &Sealed{Keeper: Describe(keeper), WrappedKey: wrapped, Nonce: nonce,
		Ciphertext: gcm.Seal(nil, nonce, plaintext, []byte(Key)), Sealed: time.Now().UTC()}, nil
}

// Open unwraps the data key with the KMS and decrypts the envelope.
func Open(ctx context.Context, k *secrets.Keeper, s *Sealed) ([]byte, error) {
	dataKey, err := k.Decrypt(ctx, s.WrappedKey)
	if err != nil {
		return nil, fmt.Errorf("the KMS would not unwrap the data key (%s): %w", s.Keeper, err)
	}
	gcm, err := gcmOf(dataKey)
	if err != nil {
		return nil, err
	}
	plain, err := gcm.Open(nil, s.Nonce, s.Ciphertext, []byte(Key))
	if err != nil {
		return nil, errors.New("the sealed control key does not open with its data key")
	}
	return plain, nil
}

func gcmOf(key []byte) (cipher.AEAD, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

// ControlKey is the control key from the store, opened with the KMS; or, the first time,
// the key make gives, sealed and written. Two copies starting together both try, and the
// one that loses opens the winner's.
func ControlKey(ctx context.Context, st store.Store, keeperURL string, make func() []byte) ([]byte, error) {
	k, err := Keeper(ctx, keeperURL)
	if err != nil {
		return nil, fmt.Errorf("AGENTS_CONTROL_KMS: %w", err)
	}
	defer k.Close()
	for attempt := 0; attempt < 3; attempt++ {
		o, err := st.Get(ctx, Key)
		if err != nil {
			return nil, err
		}
		if o != nil {
			var s Sealed
			if err := json.Unmarshal(o.Data, &s); err != nil {
				return nil, fmt.Errorf("%s can't be read: %w", Key, err)
			}
			return Open(ctx, k, &s)
		}
		key := make()
		s, err := Seal(ctx, k, keeperURL, key)
		if err != nil {
			return nil, err
		}
		b, _ := json.MarshalIndent(s, "", "  ")
		if _, err := st.Put(ctx, Key, b, store.Absent); err == nil {
			return key, nil
		} else if !store.IsConflict(err) {
			return nil, err
		}
	}
	return nil, errors.New("could not settle the control key with the other copies")
}
