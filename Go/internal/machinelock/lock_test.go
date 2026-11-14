package machinelock

import (
	"crypto/ecdsa"
	"errors"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/agentloops-dev/agents/Go/wire"
)

// chain makes a person's lock entry by entry, as their clients would.
type chain struct {
	t       *testing.T
	person  string
	entries []wire.LockEntry
	now     time.Time
}

func key(t *testing.T) *ecdsa.PrivateKey {
	t.Helper()
	k, err := NewKey()
	if err != nil {
		t.Fatal(err)
	}
	return k
}

func ptr[T any](v T) *T { return &v }

func newChain(t *testing.T, root *ecdsa.PrivateKey) *chain {
	c := &chain{t: t, person: "alex", now: time.Now()}
	c.add(root, wire.LockBody{Kind: wire.LockEntryKindRoot, Key: PublicKey(root), Name: ptr("Mac"), ClientKind: ptr("mac")})
	return c
}

func (c *chain) add(signer *ecdsa.PrivateKey, b wire.LockBody) wire.LockEntry {
	c.t.Helper()
	if b.Person == "" {
		b.Person = c.person
	}
	if b.At == 0 {
		b.At = wire.DateOf(c.now)
	}
	if b.Kind != wire.LockEntryKindRoot && b.Previous == nil {
		h := HashOf(c.entries[len(c.entries)-1])
		b.Previous = h[:]
	}
	e, err := Sign(signer, b)
	if err != nil {
		c.t.Fatal(err)
	}
	c.entries = append(c.entries, e)
	return e
}

func wantErr(t *testing.T, err, want error, index int) {
	t.Helper()
	if !errors.Is(err, want) {
		t.Fatalf("got %v, want %v", err, want)
	}
	var ce *CheckError
	if !errors.As(err, &ce) || ce.Index != index {
		t.Fatalf("got %v, want it at entry %d", err, index)
	}
}

func TestAValidChainIsTaken(t *testing.T) {
	mac, phone, recovery, invite, machine, sealing, second := key(t), key(t), key(t), key(t), key(t), key(t), key(t)
	c := newChain(t, mac)
	c.add(mac, wire.LockBody{Kind: wire.LockEntryKindAddClient, Key: PublicKey(phone), Name: ptr("iPhone"), ClientKind: ptr("remote")})
	c.add(phone, wire.LockBody{Kind: wire.LockEntryKindRecovery, Key: PublicKey(recovery)})
	c.add(mac, wire.LockBody{Kind: wire.LockEntryKindInvite, Key: PublicKey(invite), Expires: ptr(wire.DateOf(c.now.Add(5 * time.Minute)))})
	// The machine adds itself with the invite's key (D3).
	c.add(invite, wire.LockBody{Kind: wire.LockEntryKindAddMachine, Key: PublicKey(machine), SealingKey: PublicKey(sealing), ID: ptr("dev-1"), Name: ptr("dev-1")})
	// A signer adds a machine too.
	c.add(phone, wire.LockBody{Kind: wire.LockEntryKindAddMachine, Key: PublicKey(second), SealingKey: PublicKey(second), ID: ptr("dev-2")})
	// The recovery key signs: it adds a new client.
	laptop := key(t)
	c.add(recovery, wire.LockBody{Kind: wire.LockEntryKindAddClient, Key: PublicKey(laptop), ClientKind: ptr("web")})
	c.add(laptop, wire.LockBody{Kind: wire.LockEntryKindRemove, Key: PublicKey(mac)})

	s, err := Check(c.entries)
	if err != nil {
		t.Fatal(err)
	}
	if s.Person != "alex" || s.Count() != len(c.entries) || s.Head() != HashOf(c.entries[len(c.entries)-1]) || s.Root != HashOf(c.entries[0]) {
		t.Fatalf("state %+v", s.Pin())
	}
	if s.Signer(PublicKey(mac)) {
		t.Fatal("a removed client still signs")
	}
	for _, k := range []*ecdsa.PrivateKey{phone, laptop, recovery} {
		if !s.Signer(PublicKey(k)) {
			t.Fatal("a client or the recovery key does not sign")
		}
	}
	if s.Signer(PublicKey(machine)) {
		t.Fatal("a machine signs")
	}
	if _, ok := s.Member(PublicKey(invite)); ok {
		t.Fatal("the invite was not spent")
	}
	m, ok := s.Member(PublicKey(machine))
	if !ok || m.ID != "dev-1" || !slices.Equal(m.SealingKey, PublicKey(sealing)) {
		t.Fatalf("machine %+v", m)
	}
	if got := len(s.Members(wire.LockEntryKindAddMachine)); got != 2 {
		t.Fatalf("%d machines", got)
	}
	if got := s.Members(wire.LockEntryKindAddClient); len(got) != 2 || got[0].ClientKind != "remote" {
		t.Fatalf("clients %+v", got)
	}
	// A machine that pinned the head part way takes the lock that grew from it.
	part, _ := Check(c.entries[:3])
	if _, err := Follow(part.Pin(), wire.Lock{Person: "alex", Entries: c.entries}); err != nil {
		t.Fatal(err)
	}
	if _, err := Follow(Pin{}, wire.Lock{Person: "alex", Entries: c.entries}); err != nil {
		t.Fatal(err)
	}
}

func TestAForgedEntryIsFound(t *testing.T) {
	mac, stranger := key(t), key(t)
	t.Run("a signature that does not check", func(t *testing.T) {
		c := newChain(t, mac)
		e := c.add(mac, wire.LockBody{Kind: wire.LockEntryKindAddClient, Key: PublicKey(key(t))})
		e.Sig[5] ^= 1
		c.entries[1] = e
		_, err := Check(c.entries)
		wantErr(t, err, ErrForged, 1)
	})
	t.Run("a body changed after it was signed", func(t *testing.T) {
		c := newChain(t, mac)
		e := c.add(mac, wire.LockBody{Kind: wire.LockEntryKindAddClient, Key: PublicKey(key(t)), Name: ptr("iPad")})
		c.entries[1].Body = []byte(strings.Replace(string(e.Body), "iPad", "iPaD", 1))
		_, err := Check(c.entries)
		wantErr(t, err, ErrForged, 1)
	})
	t.Run("a key the lock does not name", func(t *testing.T) {
		c := newChain(t, mac)
		c.add(stranger, wire.LockBody{Kind: wire.LockEntryKindAddClient, Key: PublicKey(stranger)})
		_, err := Check(c.entries)
		wantErr(t, err, ErrForged, 1)
	})
	t.Run("a machine signs", func(t *testing.T) {
		c := newChain(t, mac)
		machine := key(t)
		c.add(mac, wire.LockBody{Kind: wire.LockEntryKindAddMachine, Key: PublicKey(machine), SealingKey: PublicKey(machine)})
		c.add(machine, wire.LockBody{Kind: wire.LockEntryKindAddClient, Key: PublicKey(stranger)})
		_, err := Check(c.entries)
		wantErr(t, err, ErrForged, 2)
	})
	t.Run("an invite used twice", func(t *testing.T) {
		c := newChain(t, mac)
		invite := key(t)
		c.add(mac, wire.LockBody{Kind: wire.LockEntryKindInvite, Key: PublicKey(invite), Expires: ptr(wire.DateOf(c.now.Add(5 * time.Minute)))})
		one, two := key(t), key(t)
		c.add(invite, wire.LockBody{Kind: wire.LockEntryKindAddMachine, Key: PublicKey(one), SealingKey: PublicKey(one)})
		c.add(invite, wire.LockBody{Kind: wire.LockEntryKindAddMachine, Key: PublicKey(two), SealingKey: PublicKey(two)})
		_, err := Check(c.entries)
		wantErr(t, err, ErrForged, 3)
	})
	t.Run("an invite that expired", func(t *testing.T) {
		c := newChain(t, mac)
		invite, one := key(t), key(t)
		c.add(mac, wire.LockBody{Kind: wire.LockEntryKindInvite, Key: PublicKey(invite), Expires: ptr(wire.DateOf(c.now.Add(5 * time.Minute)))})
		c.add(invite, wire.LockBody{Kind: wire.LockEntryKindAddMachine, Key: PublicKey(one), SealingKey: PublicKey(one), At: wire.DateOf(c.now.Add(6 * time.Minute))})
		_, err := Check(c.entries)
		wantErr(t, err, ErrForged, 2)
	})
	t.Run("an invite signs no client", func(t *testing.T) {
		c := newChain(t, mac)
		invite := key(t)
		c.add(mac, wire.LockBody{Kind: wire.LockEntryKindInvite, Key: PublicKey(invite), Expires: ptr(wire.DateOf(c.now.Add(5 * time.Minute)))})
		c.add(invite, wire.LockBody{Kind: wire.LockEntryKindAddClient, Key: PublicKey(stranger)})
		_, err := Check(c.entries)
		wantErr(t, err, ErrForged, 2)
	})
	t.Run("a root signed by another key", func(t *testing.T) {
		c := &chain{t: t, person: "alex", now: time.Now()}
		c.add(stranger, wire.LockBody{Kind: wire.LockEntryKindRoot, Key: PublicKey(mac)})
		_, err := Check(c.entries)
		wantErr(t, err, ErrForged, 0)
	})
	t.Run("an entry of another person's lock", func(t *testing.T) {
		c := newChain(t, mac)
		c.add(mac, wire.LockBody{Kind: wire.LockEntryKindAddClient, Person: "sam", Key: PublicKey(stranger)})
		_, err := Check(c.entries)
		wantErr(t, err, ErrForged, 1)
	})
}

func TestAReorderedEntryIsFound(t *testing.T) {
	mac, phone, pad := key(t), key(t), key(t)
	c := newChain(t, mac)
	c.add(mac, wire.LockBody{Kind: wire.LockEntryKindAddClient, Key: PublicKey(phone)})
	c.add(phone, wire.LockBody{Kind: wire.LockEntryKindAddClient, Key: PublicKey(pad)})
	c.add(pad, wire.LockBody{Kind: wire.LockEntryKindRemove, Key: PublicKey(phone)})

	swapped := slices.Clone(c.entries)
	swapped[2], swapped[3] = swapped[3], swapped[2]
	_, err := Check(swapped)
	wantErr(t, err, ErrOutOfOrder, 2)

	dropped := slices.Delete(slices.Clone(c.entries), 1, 2)
	_, err = Check(dropped)
	wantErr(t, err, ErrOutOfOrder, 1)

	_, err = Check(c.entries[1:])
	wantErr(t, err, ErrOutOfOrder, 0)

	// A second root, after the first.
	other := key(t)
	c2 := newChain(t, mac)
	head := HashOf(c2.entries[0])
	c2.add(other, wire.LockBody{Kind: wire.LockEntryKindRoot, Key: PublicKey(other), Previous: head[:]})
	_, err = Check(c2.entries)
	wantErr(t, err, ErrOutOfOrder, 1)
}

func TestAForkedLockIsFound(t *testing.T) {
	mac, phone, theirs := key(t), key(t), key(t)
	c := newChain(t, mac)
	c.add(mac, wire.LockBody{Kind: wire.LockEntryKindAddClient, Key: PublicKey(phone)})
	pinned, err := Check(c.entries)
	if err != nil {
		t.Fatal(err)
	}
	pin := pinned.Pin()

	// A control plane that has a key of the person's (one that signed, then was removed)
	// makes another chain from the root: every entry checks, but it is not the chain the
	// machine pinned.
	fork := &chain{t: t, person: "alex", now: c.now, entries: slices.Clone(c.entries[:1])}
	fork.add(mac, wire.LockBody{Kind: wire.LockEntryKindAddClient, Key: PublicKey(theirs)})
	fork.add(theirs, wire.LockBody{Kind: wire.LockEntryKindAddClient, Key: PublicKey(key(t))})
	if _, err := Check(fork.entries); err != nil {
		t.Fatal(err)
	}
	_, err = Follow(pin, wire.Lock{Person: "alex", Entries: fork.entries})
	wantErr(t, err, ErrForked, -1)

	// A lock kept back is not taken either.
	_, err = Follow(pin, wire.Lock{Person: "alex", Entries: c.entries[:1]})
	wantErr(t, err, ErrBehind, -1)

	// Nor another person's lock.
	sam := &chain{t: t, person: "sam", now: c.now}
	sam.add(theirs, wire.LockBody{Kind: wire.LockEntryKindRoot, Key: PublicKey(theirs)})
	sam.add(theirs, wire.LockBody{Kind: wire.LockEntryKindAddClient, Key: PublicKey(key(t))})
	_, err = Follow(pin, wire.Lock{Person: "sam", Entries: sam.entries})
	wantErr(t, err, ErrForked, -1)

	// The same lock, grown, is taken.
	c.add(phone, wire.LockBody{Kind: wire.LockEntryKindAddClient, Key: PublicKey(key(t))})
	if _, err := Follow(pin, wire.Lock{Person: "alex", Entries: c.entries}); err != nil {
		t.Fatal(err)
	}
}

func TestAnEntryTheLockCannotTake(t *testing.T) {
	mac := key(t)
	c := newChain(t, mac)
	c.add(mac, wire.LockBody{Kind: wire.LockEntryKindAddClient, Key: PublicKey(mac)})
	_, err := Check(c.entries)
	wantErr(t, err, ErrInvalid, 1)

	c = newChain(t, mac)
	c.add(mac, wire.LockBody{Kind: wire.LockEntryKindRemove, Key: PublicKey(key(t))})
	_, err = Check(c.entries)
	wantErr(t, err, ErrInvalid, 1)

	c = newChain(t, mac)
	c.add(mac, wire.LockBody{Kind: wire.LockEntryKindAddClient, Key: []byte{4, 1, 2}})
	_, err = Check(c.entries)
	wantErr(t, err, ErrInvalid, 1)

	c = newChain(t, mac)
	c.add(mac, wire.LockBody{Kind: "addWatch", Key: PublicKey(key(t))})
	_, err = Check(c.entries)
	wantErr(t, err, ErrInvalid, 1)

	// A failed entry leaves the state as it was.
	c = newChain(t, mac)
	invite := key(t)
	c.add(mac, wire.LockBody{Kind: wire.LockEntryKindInvite, Key: PublicKey(invite), Expires: ptr(wire.DateOf(c.now.Add(time.Minute)))})
	s, err := Check(c.entries)
	if err != nil {
		t.Fatal(err)
	}
	m := key(t)
	bad := c.add(invite, wire.LockBody{Kind: wire.LockEntryKindAddMachine, Key: PublicKey(m), SealingKey: []byte{1}})
	if err := s.Add(bad); !errors.Is(err, ErrInvalid) {
		t.Fatal(err)
	}
	if _, ok := s.Member(PublicKey(invite)); !ok || s.Count() != 2 {
		t.Fatal("a failed entry changed the state")
	}
}
