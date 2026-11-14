package machinelock

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"os"
	"testing"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// The lock vectors (#3490): a chain Go signed, one with a forged entry, and a join's
// commitment and digits. AgentsKit's MachineLockTests and Web/test/machineLock.test.mjs read
// the same file, so the three check a chain and make the digits the same way.
// go test ./internal/machinelock -run TestTheLockVectors -args -write-lock-vectors
const lockVectors = "../../../Packages/AgentsKit/Tests/AgentsKitTests/Fixtures/lock/vectors.json"

var writeLockVectors = flag.Bool("write-lock-vectors", false, "sign the lock vectors afresh")

type vectorMember struct {
	Key        []byte `json:"key"`
	Kind       string `json:"kind"`
	Name       string `json:"name,omitempty"`
	ClientKind string `json:"clientKind,omitempty"`
}

type vectors struct {
	Lock    wire.Lock      `json:"lock"`
	Root    string         `json:"root"`
	Head    string         `json:"head"`
	Members []vectorMember `json:"members"`
	// Forged is the lock with its last entry signed by a key that is not in it.
	Forged wire.Lock `json:"forged"`
	Join   struct {
		Key         []byte `json:"key"`
		ClientNonce []byte `json:"clientNonce"`
		SignerNonce []byte `json:"signerNonce"`
		Commitment  []byte `json:"commitment"`
		Digits      string `json:"digits"`
	} `json:"join"`
}

func makeVectors(t *testing.T) vectors {
	mac, phone, stranger := key(t), key(t), key(t)
	c := newChain(t, mac)
	c.now = time.Date(2026, 11, 4, 12, 0, 0, 0, time.UTC)
	c.add(mac, wire.LockBody{Kind: wire.LockEntryKindAddClient, Key: PublicKey(phone), Name: ptr("Sam’s iPhone"), ClientKind: ptr("remote")})
	var v vectors
	v.Lock = wire.Lock{Person: c.person, Entries: c.entries}
	forged := &chain{t: t, person: c.person, entries: append([]wire.LockEntry{}, c.entries[:1]...), now: c.now}
	forged.add(stranger, wire.LockBody{Kind: wire.LockEntryKindAddClient, Key: PublicKey(phone), Name: ptr("Not mine"), ClientKind: ptr("web")})
	v.Forged = wire.Lock{Person: c.person, Entries: forged.entries}
	v.Members = []vectorMember{{Key: PublicKey(mac), Kind: "root", Name: "Mac", ClientKind: "mac"},
		{Key: PublicKey(phone), Kind: "addClient", Name: "Sam’s iPhone", ClientKind: "remote"}}
	v.Join.Key = PublicKey(phone)
	v.Join.ClientNonce = bytes.Repeat([]byte{1}, NonceSize)
	v.Join.SignerNonce = bytes.Repeat([]byte{2}, NonceSize)
	return v
}

func TestTheLockVectors(t *testing.T) {
	var v vectors
	if *writeLockVectors {
		v = makeVectors(t)
	} else {
		data, err := os.ReadFile(lockVectors)
		if err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(data, &v); err != nil {
			t.Fatal(err)
		}
	}
	s, err := Check(v.Lock.Entries)
	if err != nil {
		t.Fatal(err)
	}
	commitment := Commitment(v.Join.Key, v.Join.ClientNonce)
	digits := Digits(v.Join.Key, v.Join.ClientNonce, v.Join.SignerNonce)
	if *writeLockVectors {
		v.Root, v.Head = s.Root.String(), s.Head().String()
		v.Join.Commitment, v.Join.Digits = commitment, digits
		data, _ := json.MarshalIndent(v, "", "  ")
		if err := os.MkdirAll("../../../Packages/AgentsKit/Tests/AgentsKitTests/Fixtures/lock", 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(lockVectors, append(data, '\n'), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if s.Root.String() != v.Root || s.Head().String() != v.Head || s.Person != v.Lock.Person {
		t.Fatalf("root %s head %s person %s", s.Root, s.Head(), s.Person)
	}
	for _, want := range v.Members {
		m, ok := s.Member(want.Key)
		if !ok || string(m.Kind) != want.Kind || m.Name != want.Name || m.ClientKind != want.ClientKind || !s.Signer(want.Key) {
			t.Fatalf("%+v, want %+v", m, want)
		}
	}
	if _, err := Check(v.Forged.Entries); !errors.Is(err, ErrForged) {
		t.Fatal(err)
	}
	if !bytes.Equal(commitment, v.Join.Commitment) || digits != v.Join.Digits || len(digits) != 6 {
		t.Fatalf("%x %s", commitment, digits)
	}
}

func TestDigitsTurnOnEveryInput(t *testing.T) {
	k := PublicKey(key(t))
	a, b := bytes.Repeat([]byte{1}, NonceSize), bytes.Repeat([]byte{2}, NonceSize)
	base := Digits(k, a, b)
	if Digits(k, b, a) == base || Digits(PublicKey(key(t)), a, b) == base {
		t.Fatal("the digits do not turn on each input")
	}
	if hex.EncodeToString(Commitment(k, a)) == hex.EncodeToString(Commitment(k, b)) {
		t.Fatal("the commitment does not turn on the nonce")
	}
}
