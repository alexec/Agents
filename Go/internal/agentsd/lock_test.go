package agentsd

import (
	"crypto/ecdsa"
	"encoding/json"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/machinelock"
	"github.com/alexec/agents/Go/wire"
)

func lockEntry(t *testing.T, signer *ecdsa.PrivateKey, kind wire.LockEntryKind, added *ecdsa.PrivateKey, previous *wire.LockEntry) wire.LockEntry {
	t.Helper()
	body := wire.LockBody{Kind: kind, Person: "sam", At: wire.DateOf(time.Now()), Key: machinelock.PublicKey(added)}
	if previous != nil {
		h := machinelock.HashOf(*previous)
		body.Previous = h[:]
	}
	e, err := machinelock.Sign(signer, body)
	if err != nil {
		t.Fatal(err)
	}
	return e
}

func newLockKey(t *testing.T) *ecdsa.PrivateKey {
	t.Helper()
	k, err := machinelock.NewKey()
	if err != nil {
		t.Fatal(err)
	}
	return k
}

func TestTheHostPinsTheHeadAndRefusesNothingYet(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	mac, phone, ipad := newLockKey(t), newLockKey(t), newLockKey(t)
	root := lockEntry(t, mac, wire.LockEntryKindRoot, mac, nil)
	add := lockEntry(t, mac, wire.LockEntryKindAddClient, phone, &root)

	// The first lock is taken on trust (D9).
	params, _ := json.Marshal(wire.Lock{Person: "sam", Entries: []wire.LockEntry{root}})
	d.Told(wire.NotifyHostLock.Name, params)
	if pin := d.LockPin(); pin.Count != 1 || pin.Person != "sam" {
		t.Fatalf("pin after the first lock: %+v", pin)
	}
	// A lock that grows from the pin moves it.
	if !d.TakeLock(wire.Lock{Person: "sam", Entries: []wire.LockEntry{root, add}}) {
		t.Fatal("a lock that grows was not taken")
	}
	grown := d.LockPin()
	if h := machinelock.HashOf(add); grown.Count != 2 || string(grown.Head) != string(h[:]) {
		t.Fatalf("pin after it grew: %+v", grown)
	}
	// A fork, a lock kept back and a forged entry are not taken, and leave the pin.
	fork := lockEntry(t, mac, wire.LockEntryKindAddClient, ipad, &root)
	forged := lockEntry(t, ipad, wire.LockEntryKindAddClient, ipad, &add)
	for name, lock := range map[string][]wire.LockEntry{
		"fork":   {root, fork},
		"behind": {root},
		"forged": {root, add, forged},
	} {
		if d.TakeLock(wire.Lock{Person: "sam", Entries: lock}) {
			t.Fatalf("%s was taken", name)
		}
		if pin := d.LockPin(); pin.Count != grown.Count || string(pin.Head) != string(grown.Head) {
			t.Fatalf("%s moved the pin: %+v", name, pin)
		}
	}
}
