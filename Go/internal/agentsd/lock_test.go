package agentsd

import (
	"crypto/ecdsa"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"testing"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/controllink"
	"github.com/agentloops-dev/agent-loops/Go/internal/machinelock"
	"github.com/agentloops-dev/agent-loops/Go/wire"
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
	d.Told(wire.NotifyMachineLock.Name, params)
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

// joinedMachine is a host that joined a control plane as h-1, and what it tells it.
func joinedMachine(t *testing.T) (*Daemon, []byte, func() []told) {
	t.Helper()
	root := t.TempDir()
	d, _ := start(t, root)
	private, err := controllink.HostPrivateKey(d.HostKey)
	if err != nil {
		t.Fatal(err)
	}
	key, _ := controllink.PublicKey(private)
	m := &controllink.Membership{Host: "h-1", Addresses: []string{}}
	if err := m.Save(root); err != nil {
		t.Fatal(err)
	}
	var mu sync.Mutex
	var said []told
	d.SetControl(func(method string, params any) {
		b, _ := json.Marshal(params)
		mu.Lock()
		said = append(said, told{method, b})
		mu.Unlock()
	})
	return d, key, func() []told { mu.Lock(); defer mu.Unlock(); return slices.Clone(said) }
}

type told struct {
	method string
	params json.RawMessage
}

func lastOf(t *testing.T, said []told, method string) json.RawMessage {
	t.Helper()
	for i := len(said) - 1; i >= 0; i-- {
		if said[i].method == method {
			return said[i].params
		}
	}
	t.Fatalf("no %s in %+v", method, said)
	return nil
}

// #3491 (D3): a machine whose code carried an invite pins the lock from the code, signs its
// own addMachine with the invite, and once it is in the lock drops the invite.
func TestAMachineAddsItselfWithTheInviteFromItsCode(t *testing.T) {
	d, key, said := joinedMachine(t)
	mac, invite := newLockKey(t), newLockKey(t)
	root := lockEntry(t, mac, wire.LockEntryKindRoot, mac, nil)
	h := machinelock.HashOf(root)
	inv, err := machinelock.Sign(mac, wire.LockBody{Kind: wire.LockEntryKindInvite, Person: "sam", Previous: h[:],
		At: wire.DateOf(time.Now()), Expires: new(wire.DateOf(time.Now().Add(5 * time.Minute))), Key: machinelock.PublicKey(invite)})
	if err != nil {
		t.Fatal(err)
	}
	ih := machinelock.HashOf(inv)
	raw, _ := invite.Bytes()
	controllink.SaveLockInvite(d.Store.Loc.Root, controllink.LockInvite{Key: raw, Person: "sam", Count: 2, Head: ih[:]})

	// A lock the control plane made up, with no invite, does not follow the code's head.
	stranger := newLockKey(t)
	other := lockEntry(t, stranger, wire.LockEntryKindRoot, stranger, nil)
	if d.TakeLock(wire.Lock{Person: "sam", Entries: []wire.LockEntry{other}}) {
		t.Fatal("a lock that is not the code's was taken")
	}
	if !d.TakeLock(wire.Lock{Person: "sam", Entries: []wire.LockEntry{root, inv}}) {
		t.Fatal("the code's lock was not taken")
	}
	var add wire.LockAdd
	json.Unmarshal(lastOf(t, said(), wire.CallMachineLockAdd.Name), &add)
	state, err := machinelock.Check([]wire.LockEntry{root, inv, add.Entries[0]})
	if err != nil {
		t.Fatal(err)
	}
	if m, ok := state.Member(key); !ok || m.Kind != wire.LockEntryKindAddMachine || m.ID != "h-1" || string(m.SealingKey) != string(key) {
		t.Fatalf("%+v", m)
	}
	d.TakeLock(wire.Lock{Person: "sam", Entries: []wire.LockEntry{root, inv, add.Entries[0]}})
	if controllink.LoadLockInvite(d.Store.Loc.Root) != nil {
		t.Fatal("the invite was kept after the machine was in the lock")
	}
}

// #3491 (D3): a machine with no invite asks with a commitment, reveals its nonce once a
// signer sent one, and shows the digits the signer makes.
func TestAMachineWithNoInviteAsksAndShowsTheDigits(t *testing.T) {
	d, key, said := joinedMachine(t)
	mac := newLockKey(t)
	root := lockEntry(t, mac, wire.LockEntryKindRoot, mac, nil)
	d.TakeLock(wire.Lock{Person: "sam", Entries: []wire.LockEntry{root}})
	var ask wire.LockJoin
	json.Unmarshal(lastOf(t, said(), wire.CallMachineLockJoin.Name), &ask)
	if string(ask.Key) != string(key) || len(ask.Commitment) != 32 {
		t.Fatalf("%+v", ask)
	}
	// Asked again on the next lock: not while this one waits.
	d.TakeLock(wire.Lock{Person: "sam", Entries: []wire.LockEntry{root}})
	asks := 0
	for _, s := range said() {
		if s.method == wire.CallMachineLockJoin.Name {
			asks++
		}
	}
	if asks != 1 {
		t.Fatalf("asked %d times", asks)
	}
	signerNonce := make([]byte, machinelock.NonceSize)
	signerNonce[0] = 7
	row, _ := json.Marshal(wire.LockJoinRequest{Request: "r1", Client: "h-1", Key: ask.Key, Commitment: ask.Commitment, Nonce: signerNonce})
	d.Told(wire.NotifyMachineLockJoinChanged.Name, row)
	var reveal wire.LockJoinNonce
	json.Unmarshal(lastOf(t, said(), wire.CallMachineLockJoinReveal.Name), &reveal)
	if reveal.Request != "r1" || string(machinelock.Commitment(key, reveal.Nonce)) != string(ask.Commitment) {
		t.Fatalf("%+v", reveal)
	}
	digits := machinelock.Digits(key, reveal.Nonce, signerNonce)
	shown, _ := os.ReadFile(filepath.Join(d.Store.Loc.Root, lockShownFile))
	if string(shown) != digits[:3]+" "+digits[3:]+"\n" {
		t.Fatalf("shown %q, digits %s", shown, digits)
	}
}
