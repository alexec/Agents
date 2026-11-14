package locks

import (
	"context"
	"crypto/ecdsa"
	"encoding/json"
	"errors"
	"testing"
	"time"

	"github.com/agentloops-dev/agents/Go/internal/controlplane/store"
	"github.com/agentloops-dev/agents/Go/internal/machinelock"
	"github.com/agentloops-dev/agents/Go/wire"
)

func key(t *testing.T) *ecdsa.PrivateKey {
	t.Helper()
	k, err := machinelock.NewKey()
	if err != nil {
		t.Fatal(err)
	}
	return k
}

func entry(t *testing.T, signer *ecdsa.PrivateKey, kind wire.LockEntryKind, added *ecdsa.PrivateKey, previous []byte) wire.LockEntry {
	t.Helper()
	e, err := machinelock.Sign(signer, wire.LockBody{Kind: kind, Person: "alex", Previous: previous, At: wire.DateOf(time.Now()), Key: machinelock.PublicKey(added)})
	if err != nil {
		t.Fatal(err)
	}
	return e
}

func hash(e wire.LockEntry) []byte {
	h := machinelock.HashOf(e)
	return h[:]
}

func TestALockIsKeptEntryByEntry(t *testing.T) {
	ctx := context.Background()
	b := New(store.NewMemory())
	empty, err := b.Get(ctx, "alex")
	if err != nil || len(empty.Entries) != 0 || empty.Person != "alex" {
		t.Fatalf("no lock yet: %+v, %v", empty, err)
	}
	mac, phone := key(t), key(t)
	root := entry(t, mac, wire.LockEntryKindRoot, mac, nil)
	add := entry(t, mac, wire.LockEntryKindAddClient, phone, hash(root))
	head, err := b.Add(ctx, "alex", []wire.LockEntry{root, add})
	if err != nil {
		t.Fatal(err)
	}
	if head.Count != 2 || string(head.Head) != string(hash(add)) {
		t.Fatalf("head %+v", head)
	}
	lock, err := b.Get(ctx, "alex")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := machinelock.Check(lock.Entries); err != nil || len(lock.Entries) != 2 {
		t.Fatalf("read back %d entries: %v", len(lock.Entries), err)
	}
}

func TestTwoEntriesCannotBothFollowOneHead(t *testing.T) {
	ctx := context.Background()
	b := New(store.NewMemory())
	mac, phone, ipad := key(t), key(t), key(t)
	root := entry(t, mac, wire.LockEntryKindRoot, mac, nil)
	if _, err := b.Add(ctx, "alex", []wire.LockEntry{root}); err != nil {
		t.Fatal(err)
	}
	first := entry(t, mac, wire.LockEntryKindAddClient, phone, hash(root))
	second := entry(t, mac, wire.LockEntryKindAddClient, ipad, hash(root))
	if _, err := b.Add(ctx, "alex", []wire.LockEntry{first}); err != nil {
		t.Fatal(err)
	}
	if _, err := b.Add(ctx, "alex", []wire.LockEntry{second}); !errors.Is(err, ErrChanged) {
		t.Fatalf("a second entry on the same head: %v", err)
	}
	// A second root, once there is one, is the same race.
	if _, err := b.Add(ctx, "alex", []wire.LockEntry{entry(t, ipad, wire.LockEntryKindRoot, ipad, nil)}); !errors.Is(err, ErrChanged) {
		t.Fatalf("a second root: %v", err)
	}
}

// racing is a store where another copy writes each place just before this copy does.
type racing struct {
	store.Store
	other []byte
}

func (r racing) Put(ctx context.Context, key string, data []byte, when store.Condition) (string, error) {
	r.Store.Put(ctx, key, r.other, store.Absent)
	return r.Store.Put(ctx, key, data, when)
}

func TestAConditionalWriteLosesTheRace(t *testing.T) {
	ctx := context.Background()
	mac, phone := key(t), key(t)
	other, _ := json.Marshal(entry(t, phone, wire.LockEntryKindRoot, phone, nil))
	s := store.NewMemory()
	b := New(racing{Store: s, other: other})
	root := entry(t, mac, wire.LockEntryKindRoot, mac, nil)
	if _, err := b.Add(ctx, "alex", []wire.LockEntry{root}); !errors.Is(err, ErrChanged) {
		t.Fatalf("got %v", err)
	}
	lock, err := New(s).Get(ctx, "alex")
	if err != nil || len(lock.Entries) != 1 || string(lock.Entries[0].Body) == string(root.Body) {
		t.Fatalf("the other copy's root is not the one kept: %v", err)
	}
}

func TestTheControlPlaneRefusesWhatAClientWould(t *testing.T) {
	ctx := context.Background()
	b := New(store.NewMemory())
	mac, stranger, phone := key(t), key(t), key(t)
	root := entry(t, mac, wire.LockEntryKindRoot, mac, nil)
	if _, err := b.Add(ctx, "alex", []wire.LockEntry{root}); err != nil {
		t.Fatal(err)
	}
	forged := entry(t, stranger, wire.LockEntryKindAddClient, phone, hash(root))
	if _, err := b.Add(ctx, "alex", []wire.LockEntry{forged}); !errors.Is(err, ErrInvalid) {
		t.Fatalf("a forged entry: %v", err)
	}
	// Another person's root is not the caller's.
	if _, err := b.Add(ctx, "sam", []wire.LockEntry{root}); !errors.Is(err, ErrInvalid) {
		t.Fatalf("alex's root as sam's: %v", err)
	}
	if _, err := b.Add(ctx, "../alex", []wire.LockEntry{root}); !errors.Is(err, ErrInvalid) {
		t.Fatalf("a path as a person: %v", err)
	}
	if _, err := b.Add(ctx, "alex", nil); !errors.Is(err, ErrInvalid) {
		t.Fatalf("no entries: %v", err)
	}
	lock, _ := b.Get(ctx, "alex")
	if len(lock.Entries) != 1 {
		t.Fatalf("%d entries kept", len(lock.Entries))
	}
}
