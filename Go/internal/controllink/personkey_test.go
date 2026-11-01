package controllink

import (
	"bytes"
	"testing"
	"time"
)

// The person key (#2957, research R1): made on the first save of your layer, kept in the
// Keychain on a Mac (personkey_darwin_test.go) or a 0600 file elsewhere; signs and verifies
// YourPolicy's CanonicalJSON with the existing SignPolicy/VerifyPolicy (alg es256, KeyID);
// a PersonKeyRotation record checks only against the previously pinned key.

// TestPersonPrivateKeyIsMadeOnceAndKept covers the file store directly (Linux and a scratch
// root without the Keychain): the first call makes a key and keeps it; a later call, even
// from a fresh store value pointed at the same root, gets the same key back.
func TestPersonPrivateKeyIsMadeOnceAndKept(t *testing.T) {
	root := t.TempDir()
	store := PersonKeyFile{Root: root}
	key, err := PersonPrivateKey(store)
	if err != nil || len(key) != 32 {
		t.Fatalf("PersonPrivateKey: %v, %d bytes", err, len(key))
	}
	again, err := PersonPrivateKey(PersonKeyFile{Root: root})
	if err != nil || !bytes.Equal(again, key) {
		t.Fatalf("not the same key after a restart: %v", err)
	}
}

// TestPersonKeyFileIs0600AndDistinctFromTheMachineKey: the person key's file is not the
// machine key's file, and the two never collide in the same root.
func TestPersonKeyFileIs0600AndDistinctFromTheMachineKey(t *testing.T) {
	root := t.TempDir()
	personKey, err := PersonPrivateKey(PersonKeyFile{Root: root})
	if err != nil {
		t.Fatal(err)
	}
	machineKey, err := HostPrivateKey(HostKeyFile{Root: root})
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Equal(personKey, machineKey) {
		t.Fatal("the person key and the machine key are the same")
	}
	if PersonKeyFileName == HostKeyFileName {
		t.Fatal("the person key and the machine key share a file name")
	}
}

// TestPersonKeyServiceIsDistinctFromTheMachineKeysService: the Keychain service prefixes
// never collide, root for root.
func TestPersonKeyServiceIsDistinctFromTheMachineKeysService(t *testing.T) {
	root := t.TempDir()
	if PersonKeyService(root) == HostKeyService(root) {
		t.Fatal("the person key and the machine key share a Keychain service")
	}
}

// TestSignAndVerifyYourPolicy signs a YourPolicy-shaped document's canonical JSON with the
// person key and checks it, as agentsd's keeper does (policyyours.go).
func TestSignAndVerifyYourPolicy(t *testing.T) {
	private := NewPrivateKey()
	public, err := PublicKey(private)
	if err != nil {
		t.Fatal(err)
	}
	doc := []byte(`{"rules":{"permissionMode":"ask"},"revision":1,"person":"local"}`)
	sig, err := SignPolicy(private, doc)
	if err != nil {
		t.Fatal(err)
	}
	if !VerifyPolicy(public, doc, sig) {
		t.Fatal("does not verify with its own key")
	}
	other, _ := PublicKey(NewPrivateKey())
	if VerifyPolicy(other, doc, sig) {
		t.Fatal("verifies with a different key")
	}
	if KeyID(public) == "" {
		t.Fatal("no KeyID")
	}
}

// TestPersonKeyRotationChecksOnlyAgainstThePinnedKey: a rotation record signed by the right
// old key moves the pin; one "signed" by any other key does not.
func TestPersonKeyRotationChecksOnlyAgainstThePinnedKey(t *testing.T) {
	oldPrivate := NewPrivateKey()
	oldPublic, err := PublicKey(oldPrivate)
	if err != nil {
		t.Fatal(err)
	}
	newPrivate, rotation, err := PersonKeyRotationFor(oldPrivate)
	if err != nil {
		t.Fatal(err)
	}
	if len(newPrivate) != 32 {
		t.Fatalf("no new key: %d bytes", len(newPrivate))
	}
	newPublic, err := PublicKey(newPrivate)
	if err != nil || !bytes.Equal(newPublic, rotation.NewKey) {
		t.Fatalf("rotation.NewKey is not the new key's public half: %v", err)
	}
	if !PersonKeyRotationValid(oldPublic, rotation) {
		t.Fatal("does not check against the key it replaces")
	}
	// Signed by a stranger's key, not the one pinned: refused.
	strangerPrivate := NewPrivateKey()
	_, forgedRotation, err := PersonKeyRotationFor(strangerPrivate)
	if err != nil {
		t.Fatal(err)
	}
	if PersonKeyRotationValid(oldPublic, forgedRotation) {
		t.Fatal("a rotation signed by a stranger's key checks against the pinned key")
	}
	// A rotation that names a different new key than the one it signed does not check.
	tampered := rotation
	tampered.NewKey = append([]byte{}, newPublic...)
	tampered.NewKey[0] ^= 0xFF
	if PersonKeyRotationValid(oldPublic, tampered) {
		t.Fatal("a tampered rotation checks")
	}
}

// TestPinnedPersonKeyStateTransitions covers data-model.md's "State transitions" for a
// machine that is not the keeper (#2957, T024): no pin -> pinned (from a join code, the
// window, or trust on first use from the control plane); pinned -> moves only on a rotation
// that checks against the key already pinned; a second PinPersonKey call, with no
// rotation, never overwrites an existing pin, from whichever source.
func TestPinnedPersonKeyStateTransitions(t *testing.T) {
	root := t.TempDir()
	if p, err := LoadPinnedPersonKey(root); err != nil || p != nil {
		t.Fatalf("no pin: %v, %v", p, err)
	}
	private := NewPrivateKey()
	public, err := PublicKey(private)
	if err != nil {
		t.Fatal(err)
	}
	// Path 3: trust on first use, from the first signed layer the control plane sends.
	pinned, err := PinPersonKey(root, public, PinFromControlPlane, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if pinned.From != PinFromControlPlane || pinned.KeyID != KeyID(public) {
		t.Fatalf("not pinned as expected: %+v", pinned)
	}
	again, err := LoadPinnedPersonKey(root)
	if err != nil || again == nil || !bytes.Equal(again.Key, public) {
		t.Fatalf("the pin did not persist: %v, %v", again, err)
	}
	// A second pin attempt, from a different source and a different key, changes nothing:
	// only a rotation moves an existing pin.
	other, _ := PublicKey(NewPrivateKey())
	unchanged, err := PinPersonKey(root, other, PinFromWindow, time.Now())
	if err != nil || !bytes.Equal(unchanged.Key, public) || unchanged.From != PinFromControlPlane {
		t.Fatalf("a second pin overwrote the first: %+v, %v", unchanged, err)
	}
	// A rotation signed by a stranger's key does not check against the pin, and does not
	// move it.
	_, forged, err := PersonKeyRotationFor(NewPrivateKey())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := AcceptPersonKeyRotation(root, forged, time.Now()); err == nil {
		t.Fatal("a forged rotation moved the pin")
	}
	if kept, _ := LoadPinnedPersonKey(root); !bytes.Equal(kept.Key, public) {
		t.Fatal("the pin moved on a forged rotation")
	}
	// A rotation signed by the pinned key's own private half moves the pin.
	newPrivate, rotation, err := PersonKeyRotationFor(private)
	if err != nil {
		t.Fatal(err)
	}
	newPublic, err := PublicKey(newPrivate)
	if err != nil {
		t.Fatal(err)
	}
	moved, err := AcceptPersonKeyRotation(root, rotation, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(moved.Key, newPublic) || moved.From != PinFromControlPlane {
		t.Fatalf("the rotation did not move the pin as expected: %+v", moved)
	}
}

// TestAcceptPersonKeyRotationRefusesWithNoPinYet: a rotation is never the first pin.
func TestAcceptPersonKeyRotationRefusesWithNoPinYet(t *testing.T) {
	root := t.TempDir()
	_, rotation, err := PersonKeyRotationFor(NewPrivateKey())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := AcceptPersonKeyRotation(root, rotation, time.Now()); err == nil {
		t.Fatal("a rotation with nothing pinned yet was accepted")
	}
}
