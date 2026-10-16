package kms

import (
	"bytes"
	"context"
	"encoding/base64"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/controlplane-go/internal/store"
)

func localURL(t *testing.T) string {
	b := make([]byte, 32)
	for i := range b {
		b[i] = byte(i + len(t.Name()))
	}
	return "base64key://" + base64.URLEncoding.EncodeToString(b)
}

var ctx = context.Background()

func TestSealAndOpen(t *testing.T) {
	k, err := Keeper(ctx, localURL(t))
	if err != nil {
		t.Fatal(err)
	}
	s, err := Seal(ctx, k, localURL(t), []byte("thirty-two bytes of control key!"))
	if err != nil {
		t.Fatal(err)
	}
	if s.Keeper != "base64key://(local)" || bytes.Contains(s.Ciphertext, []byte("control")) {
		t.Fatalf("%+v", s)
	}
	plain, err := Open(ctx, k, s)
	if err != nil || string(plain) != "thirty-two bytes of control key!" {
		t.Fatal(err, string(plain))
	}
	other, _ := Keeper(ctx, "base64key://"+base64.URLEncoding.EncodeToString(bytes.Repeat([]byte{9}, 32)))
	if _, err := Open(ctx, other, s); err == nil {
		t.Fatal("another keeper opened it")
	}
}

// Several copies starting on one store at once settle on one control key.
func TestCopiesSettleOnOneKey(t *testing.T) {
	st := store.NewMemory()
	var mu sync.Mutex
	keys := map[string]bool{}
	var wg sync.WaitGroup
	for i := range 10 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			key, err := ControlKey(ctx, st, localURL(t), func() []byte { return bytes.Repeat([]byte{byte(i)}, 32) })
			if err != nil {
				t.Error(err)
				return
			}
			mu.Lock()
			keys[string(key)] = true
			mu.Unlock()
		}()
	}
	wg.Wait()
	if len(keys) != 1 {
		t.Fatalf("%d keys", len(keys))
	}
	o, _ := st.Get(ctx, Key)
	if strings.Contains(string(o.Data), base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{0}, 32))) {
		t.Fatal("the key is in the store in the clear")
	}
}

// The Google Cloud KMS keeper is linked in, and its URL is understood; opening one needs
// credentials, which this spike has none of (#61).
func TestGCPKMSIsWrittenNotRun(t *testing.T) {
	_, err := Keeper(ctx, "gcpkms://projects/p/locations/global/keyRings/r/cryptoKeys/k")
	if err != nil && strings.Contains(err.Error(), "no driver registered") {
		t.Fatal("gcpkms is not linked in")
	}
	t.Logf("gcpkms without credentials: %v", err)
}

// A remote keeper, Vault's transit (./vault.sh up; eval "$(./vault.sh env)"), through the
// same envelope: a copy with nothing but the store and the token opens the sealed key, and
// another transit key refuses it. The token can encrypt and decrypt, not read the key.
func TestVaultKeeper(t *testing.T) {
	addr := os.Getenv("AGENTS_TEST_VAULT")
	if addr == "" {
		t.Skip("AGENTS_TEST_VAULT is not set (./vault.sh up)")
	}
	t.Setenv("VAULT_SERVER_URL", addr)
	st := store.NewMemory()
	made := bytes.Repeat([]byte{7}, 32)
	first, err := ControlKey(ctx, st, "hashivault://cpgo", func() []byte { return made })
	if err != nil || !bytes.Equal(first, made) {
		t.Fatal(err)
	}
	o, _ := st.Get(ctx, Key)
	if !strings.Contains(string(o.Data), `"keeper": "hashivault://cpgo"`) || bytes.Contains(o.Data, made) {
		t.Fatalf("%s", o.Data)
	}
	// Another copy: a new keeper, no key of its own to make.
	again, err := ControlKey(ctx, st, "hashivault://cpgo", func() []byte { t.Fatal("made a second key"); return nil })
	if err != nil || !bytes.Equal(again, made) {
		t.Fatal(err)
	}
	if _, err := ControlKey(ctx, st, "hashivault://cpgo-other", func() []byte { return nil }); err == nil {
		t.Fatal("another transit key opened it")
	} else {
		t.Logf("another transit key: %v", err)
	}
	// A bad token is tried live (REPORT.md stage 9): gocloud's default hashivault opener
	// reads VAULT_SERVER_URL and VAULT_SERVER_TOKEN once for each process, so a change here
	// would not be seen.
}

// A keeper that never answers, and does not heed its context, still ends the call.
func TestBoundedGivesUp(t *testing.T) {
	c, cancel := context.WithTimeout(ctx, 50*time.Millisecond)
	defer cancel()
	never := make(chan struct{})
	defer close(never)
	if _, err := bounded(c, func() ([]byte, error) { <-never; return nil, nil }); err == nil || !strings.Contains(err.Error(), "did not answer") {
		t.Fatal(err)
	}
}
