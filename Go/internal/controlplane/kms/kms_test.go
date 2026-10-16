package kms

import (
	"bytes"
	"context"
	"encoding/base64"
	"net/url"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"gocloud.dev/gcerrors"
	"gocloud.dev/secrets"
	"gocloud.dev/secrets/driver"

	"github.com/alexec/agents/Go/internal/controlplane/store"
)

var ctx = context.Background()

func localURL(fill byte) string {
	return "base64key://" + base64.URLEncoding.EncodeToString(bytes.Repeat([]byte{fill}, 32))
}

func TestSealAndOpen(t *testing.T) {
	k, err := Keeper(ctx, localURL(1))
	if err != nil {
		t.Fatal(err)
	}
	defer k.Close()
	control := []byte("thirty-two bytes of control key!")
	s, err := Seal(ctx, k, localURL(1), control)
	if err != nil {
		t.Fatal(err)
	}
	if s.Keeper != "base64key://(local)" || bytes.Contains(s.Ciphertext, []byte("control")) {
		t.Fatalf("%+v", s)
	}
	plain, err := Open(ctx, k, s)
	if err != nil || !bytes.Equal(plain, control) {
		t.Fatal(err, string(plain))
	}
}

// The store keeps the key sealed, and a second start opens it without make.
func TestControlKeyOpensWhatItSealed(t *testing.T) {
	st := store.NewMemory()
	made := bytes.Repeat([]byte{7}, 32)
	first, err := ControlKey(ctx, st, localURL(1), func() []byte { return made })
	if err != nil || !bytes.Equal(first, made) {
		t.Fatal(err)
	}
	o, _ := st.Get(ctx, Key)
	if o == nil || bytes.Contains(o.Data, made) || strings.Contains(string(o.Data), base64.StdEncoding.EncodeToString(made)) {
		t.Fatal("the key is in the store in the clear")
	}
	if strings.Contains(string(o.Data), localURL(1)[len("base64key://"):]) {
		t.Fatal("the local keeper's key is in the store")
	}
	again, err := ControlKey(ctx, st, localURL(1), func() []byte { t.Fatal("made a second key"); return nil })
	if err != nil || !bytes.Equal(again, made) {
		t.Fatal(err)
	}
}

// Another keeper key refuses to open the envelope, and says why.
func TestWrongKeeperRefuses(t *testing.T) {
	st := store.NewMemory()
	if _, err := ControlKey(ctx, st, localURL(1), func() []byte { return bytes.Repeat([]byte{7}, 32) }); err != nil {
		t.Fatal(err)
	}
	_, err := ControlKey(ctx, st, localURL(9), func() []byte { t.Fatal("made a key"); return nil })
	if err == nil || !strings.Contains(err.Error(), "the KMS would not unwrap the data key (sealed by base64key://(local))") {
		t.Fatal(err)
	}
	t.Logf("another keeper key: %v", err)
}

// Ten copies that start at once on an empty store settle on one control key.
func TestCopiesSettleOnOneKey(t *testing.T) {
	st := store.NewMemory()
	var mu sync.Mutex
	keys := map[string]bool{}
	var wg sync.WaitGroup
	for i := range 10 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			key, err := ControlKey(ctx, st, localURL(1), func() []byte { return bytes.Repeat([]byte{byte(i)}, 32) })
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
}

// hang is a keeper that never answers, ignores its context and hangs on Close too.
type hang struct{ never chan struct{} }

func (h hang) Encrypt(context.Context, []byte) ([]byte, error) { <-h.never; return nil, nil }
func (h hang) Decrypt(context.Context, []byte) ([]byte, error) { <-h.never; return nil, nil }
func (h hang) Close() error                                    { <-h.never; return nil }
func (hang) ErrorAs(error, any) bool                           { return false }
func (hang) ErrorCode(error) gcerrors.ErrorCode                { return gcerrors.Unknown }

var _ driver.Keeper = hang{}

type hangOpener struct{ never chan struct{} }

func (o hangOpener) OpenKeeperURL(context.Context, *url.URL) (*secrets.Keeper, error) {
	return secrets.NewKeeper(hang(o)), nil
}

var never = make(chan struct{})

func init() { secrets.DefaultURLMux().RegisterKeeper("hang", hangOpener{never}) }

// A keeper that hangs stops the start with words, inside the timeout.
func TestHungKeeperGivesUp(t *testing.T) {
	was := Timeout
	Timeout = 100 * time.Millisecond
	defer func() { Timeout = was }()
	start := time.Now()
	_, err := ControlKey(ctx, store.NewMemory(), "hang://k", func() []byte { return bytes.Repeat([]byte{7}, 32) })
	if err == nil || !strings.Contains(err.Error(), "the KMS did not answer") {
		t.Fatal(err)
	}
	if took := time.Since(start); took > 2*time.Second {
		t.Fatalf("took %v", took)
	}
	t.Logf("a keeper that hangs: %v", err)
}

// Vault's transit through the same envelope. Only when VAULT_SERVER_URL is set (and
// VAULT_SERVER_TOKEN); AGENTS_TEST_VAULT_KEY names the transit key, cpgo if not set.
func TestVaultKeeper(t *testing.T) {
	if os.Getenv("VAULT_SERVER_URL") == "" {
		t.Skip("VAULT_SERVER_URL is not set")
	}
	name := os.Getenv("AGENTS_TEST_VAULT_KEY")
	if name == "" {
		name = "cpgo"
	}
	keeper := "hashivault://" + name
	st := store.NewMemory()
	made := bytes.Repeat([]byte{7}, 32)
	first, err := ControlKey(ctx, st, keeper, func() []byte { return made })
	if err != nil || !bytes.Equal(first, made) {
		t.Fatal(err)
	}
	o, _ := st.Get(ctx, Key)
	if !strings.Contains(string(o.Data), `"keeper": "`+keeper+`"`) || bytes.Contains(o.Data, made) {
		t.Fatalf("%s", o.Data)
	}
	again, err := ControlKey(ctx, st, keeper, func() []byte { t.Fatal("made a second key"); return nil })
	if err != nil || !bytes.Equal(again, made) {
		t.Fatal(err)
	}
}

// A bad local key is said without its bytes: no log line may hold a key (071 FR-033).
func TestABadLocalKeyIsNotSaid(t *testing.T) {
	url := "base64key://c2VjcmV0LXNlY3JldC1zZWNyZXQtc2VjcmV0LXNlY3JldA"
	_, err := Keeper(context.Background(), url)
	if err == nil || strings.Contains(err.Error(), "c2VjcmV0") {
		t.Fatal(err)
	}
}
