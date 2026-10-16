package kms

import (
	"bytes"
	"context"
	"encoding/base64"
	"strings"
	"sync"
	"testing"

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
