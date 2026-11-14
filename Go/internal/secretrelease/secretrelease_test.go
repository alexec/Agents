package secretrelease

import (
	"crypto/ecdsa"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/machinelock"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

func signingKey(t *testing.T) *ecdsa.PrivateKey {
	t.Helper()
	k, err := machinelock.NewKey()
	if err != nil {
		t.Fatal(err)
	}
	return k
}

// lockOf is alex's lock: the client mac (the root) and the machine dev-1.
func lockOf(t *testing.T, mac, machine *ecdsa.PrivateKey) wire.Lock {
	t.Helper()
	now := wire.DateOf(time.Now())
	root, err := machinelock.Sign(mac, wire.LockBody{Kind: wire.LockEntryKindRoot, Person: "alex", At: now, Key: machinelock.PublicKey(mac)})
	if err != nil {
		t.Fatal(err)
	}
	h := machinelock.HashOf(root)
	id := "dev-1"
	add, err := machinelock.Sign(mac, wire.LockBody{Kind: wire.LockEntryKindAddMachine, Person: "alex", At: now, Previous: h[:],
		Key: machinelock.PublicKey(machine), SealingKey: machinelock.PublicKey(machine), ID: &id, Name: &id})
	if err != nil {
		t.Fatal(err)
	}
	return wire.Lock{Person: "alex", Entries: []wire.LockEntry{root, add}}
}

func TestALayerOpensOnlyWithTheKeyTheControlPlaneReleases(t *testing.T) {
	private, err := NewKey()
	if err != nil {
		t.Fatal(err)
	}
	ad := []byte("sealedsecret.release.v1|local|GITLAB_PASSWORD")
	l, err := Seal(private.PublicKey().Bytes(), "GITLAB_PASSWORD", "hunter2", ad)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(l.Sealed), "hunter2") {
		t.Fatal("the layer holds the value as plain text")
	}
	key, err := Release(private, "GITLAB_PASSWORD", l.Encapsulated)
	if err != nil {
		t.Fatal(err)
	}
	if v, err := Open(key, l, ad); err != nil || v != "hunter2" {
		t.Fatalf("open: %q, %v", v, err)
	}
	// The key for another name, another release key, or another place does not open it.
	other, _ := Release(private, "OTHER", l.Encapsulated)
	if _, err := Open(other, l, ad); err == nil {
		t.Fatal("the key released for another name opened it")
	}
	stranger, _ := NewKey()
	if k, err := Release(stranger, "GITLAB_PASSWORD", l.Encapsulated); err == nil {
		if _, err := Open(k, l, ad); err == nil {
			t.Fatal("another release key opened it")
		}
	}
	if _, err := Open(key, l, []byte("sealedsecret.release.v1|session:x|GITLAB_PASSWORD")); err == nil {
		t.Fatal("it opened for another store")
	}
}

func TestAnApprovalIsCheckedAgainstTheLock(t *testing.T) {
	mac, machine, stranger := signingKey(t), signingKey(t), signingKey(t)
	state, err := machinelock.Check(lockOf(t, mac, machine).Entries)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	a := Approval{Request: "R1", Name: "GITLAB_PASSWORD", Use: "fill", Place: "gitlab.com", Action: "once"}
	signed, err := SignApproval(mac, "dev-1", a, now)
	if err != nil {
		t.Fatal(err)
	}
	if got, err := CheckApproval(state, "dev-1", signed, now); err != nil || got != a {
		t.Fatalf("a fresh approval: %+v, %v", got, err)
	}
	if _, err := CheckApproval(state, "dev-1", signed, now.Add(ApprovalLifetime+time.Minute)); !errors.Is(err, ErrStale) {
		t.Fatalf("an old approval: %v", err)
	}
	if _, err := CheckApproval(state, "dev-2", signed, now); !errors.Is(err, machinelock.ErrForged) {
		t.Fatalf("an approval for another machine: %v", err)
	}
	changed := signed
	changed.Params = strings.Replace(signed.Params, "gitlab.com", "evil.example", 1)
	if _, err := CheckApproval(state, "dev-1", changed, now); !errors.Is(err, machinelock.ErrForged) {
		t.Fatalf("an approval with another place: %v", err)
	}
	// The machine's own key, which an agent can read on Linux, is not a client's.
	byMachine, _ := SignApproval(machine, "dev-1", a, now)
	if _, err := CheckApproval(state, "dev-1", byMachine, now); !errors.Is(err, ErrNotClient) {
		t.Fatalf("an approval the machine signed: %v", err)
	}
	byStranger, _ := SignApproval(stranger, "dev-1", a, now)
	if _, err := CheckApproval(state, "dev-1", byStranger, now); !errors.Is(err, machinelock.ErrNotMember) {
		t.Fatalf("an approval by a key the lock does not name: %v", err)
	}
	other := signed
	other.Method = "agents/prompt"
	if _, err := CheckApproval(state, "dev-1", other, now); !errors.Is(err, ErrNotApproval) {
		t.Fatalf("another signed request: %v", err)
	}
}
