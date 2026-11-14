package machinelock

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/agentloops-dev/agents/Go/wire"
)

// The recovery vectors (#3493): a secret and its text, the ways a person may type it, and a
// lock whose recovery entry carries the sealed key and whose last entry the recovery key
// signed. AgentsKit's MachineLockTests and Web/test/machineLock.test.mjs read the same file.
// go test ./internal/machinelock -run TestTheRecoveryVectors -args -write-recovery-vectors
const recoveryVectors = "../../../Packages/AgentsKit/Tests/AgentsKitTests/Fixtures/lock/recovery.json"

var writeRecoveryVectors = flag.Bool("write-recovery-vectors", false, "seal the recovery vectors afresh")

type recoveryVectorFile struct {
	Secret []byte `json:"secret"`
	Text   string `json:"text"`
	// Typed are other ways to type Text that read as the same secret.
	Typed []string `json:"typed"`
	// Typos are texts that are not a recovery key.
	Typos []string `json:"typos"`
	// Other is a recovery key that is not this lock's.
	Other string `json:"other"`
	// Lock: root, recovery (with sealed), and an addClient the recovery key signed.
	Lock    wire.Lock `json:"lock"`
	Public  []byte    `json:"public"`
	Private []byte    `json:"private"`
}

func makeRecoveryVectors(t *testing.T) recoveryVectorFile {
	var v recoveryVectorFile
	v.Secret = []byte{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}
	v.Text = RecoveryText(v.Secret)
	plain := strings.ReplaceAll(v.Text, "-", "")
	v.Typed = []string{strings.ToLower(v.Text), plain, " " + strings.Join(strings.Split(v.Text, "-"), " ") + " ",
		strings.ReplaceAll(v.Text, "0", "o"), strings.ReplaceAll(v.Text, "1", "l")}
	swapped := []byte(plain)
	swapped[0], swapped[1] = swapped[1], swapped[0]
	if swapped[0] == swapped[1] {
		swapped[0] = 'Z'
	}
	v.Typos = []string{"", plain[:31], plain + "0", string(swapped), strings.Replace(plain, plain[:1], "U", 1)}
	v.Other = RecoveryText(bytes.Repeat([]byte{7}, RecoverySecretSize))

	mac, recovery, laptop := key(t), key(t), key(t)
	sealed, err := SealRecovery(v.Secret, recovery)
	if err != nil {
		t.Fatal(err)
	}
	c := newChain(t, mac)
	c.now = time.Date(2026, 11, 5, 12, 0, 0, 0, time.UTC)
	c.add(mac, wire.LockBody{Kind: wire.LockEntryKindRecovery, Key: PublicKey(recovery), Sealed: sealed})
	c.add(recovery, wire.LockBody{Kind: wire.LockEntryKindAddClient, Key: PublicKey(laptop), Name: ptr("Laptop"), ClientKind: ptr("web")})
	v.Lock = wire.Lock{Person: c.person, Entries: c.entries}
	v.Public = PublicKey(recovery)
	v.Private, _ = recovery.Bytes()
	return v
}

func TestTheRecoveryVectors(t *testing.T) {
	if *writeRecoveryVectors {
		b, _ := json.MarshalIndent(makeRecoveryVectors(t), "", "  ")
		if err := os.WriteFile(recoveryVectors, append(b, '\n'), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	b, err := os.ReadFile(recoveryVectors)
	if err != nil {
		t.Fatal(err)
	}
	var v recoveryVectorFile
	if err := json.Unmarshal(b, &v); err != nil {
		t.Fatal(err)
	}
	if got := RecoveryText(v.Secret); got != v.Text {
		t.Fatalf("text %s, want %s", got, v.Text)
	}
	for _, typed := range append([]string{v.Text}, v.Typed...) {
		secret, err := ParseRecovery(typed)
		if err != nil || !bytes.Equal(secret, v.Secret) {
			t.Fatalf("%q read as %x, %v", typed, secret, err)
		}
	}
	for _, typo := range v.Typos {
		if _, err := ParseRecovery(typo); !errors.Is(err, ErrRecoveryTypo) {
			t.Fatalf("%q: %v, want a typo", typo, err)
		}
	}
	s, err := Check(v.Lock.Entries)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(s.Recovery(), v.Public) || !s.Signer(v.Public) {
		t.Fatal("the recovery entry's key is not a signer")
	}
	opened, err := OpenRecovery(v.Secret, s.Recovery(), s.RecoverySealed())
	if err != nil {
		t.Fatal(err)
	}
	if private, _ := opened.Bytes(); !bytes.Equal(private, v.Private) {
		t.Fatal("the sealed key opened to another key")
	}
	other, err := ParseRecovery(v.Other)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := OpenRecovery(other, s.Recovery(), s.RecoverySealed()); !errors.Is(err, ErrRecoveryNotThisLock) {
		t.Fatalf("another lock's key: %v", err)
	}
}

// A person who lost every device types the recovery key on a new one: it signs that
// client's addClient, which the lock takes as a signer's.
func TestTheRecoveryKeyAddsANewClient(t *testing.T) {
	mac, recovery, phone, newer := key(t), key(t), key(t), key(t)
	secret := bytes.Repeat([]byte{9}, RecoverySecretSize)
	sealed, err := SealRecovery(secret, recovery)
	if err != nil {
		t.Fatal(err)
	}
	c := newChain(t, mac)
	c.add(mac, wire.LockBody{Kind: wire.LockEntryKindRecovery, Key: PublicKey(recovery), Sealed: sealed})
	s, _ := Check(c.entries)

	typed, err := ParseRecovery(strings.ToLower(RecoveryText(secret)))
	if err != nil {
		t.Fatal(err)
	}
	opened, err := OpenRecovery(typed, s.Recovery(), s.RecoverySealed())
	if err != nil {
		t.Fatal(err)
	}
	c.add(opened, wire.LockBody{Kind: wire.LockEntryKindAddClient, Key: PublicKey(phone), ClientKind: ptr("remote")})
	if s, err = Check(c.entries); err != nil {
		t.Fatal(err)
	}
	if m, ok := s.Member(PublicKey(phone)); !ok || !m.Client() {
		t.Fatal("the recovered client is not in the lock")
	}

	// A new recovery key takes the old one's place: the old one signs no more.
	sealed2, _ := SealRecovery(secret, newer)
	c.add(phone, wire.LockBody{Kind: wire.LockEntryKindRecovery, Key: PublicKey(newer), Sealed: sealed2})
	s, _ = Check(c.entries)
	if s.Signer(PublicKey(recovery)) || !s.Signer(PublicKey(newer)) {
		t.Fatal("the old recovery key still signs")
	}
	if _, err := OpenRecovery(secret, PublicKey(recovery), s.RecoverySealed()); err == nil {
		t.Fatal("the new sealed key opened as the old one")
	}
}
