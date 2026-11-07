package controlplane

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"encoding/json"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/internal/machinelock"
	"github.com/alexec/agents/Go/wire"
)

func lockKey(t *testing.T) *ecdsa.PrivateKey {
	t.Helper()
	k, err := machinelock.NewKey()
	if err != nil {
		t.Fatal(err)
	}
	return k
}

// signOnto signs body as the next entry of the lock s reads, and puts it there.
func signOnto(t *testing.T, s *controllink.Session, signer *ecdsa.PrivateKey, body wire.LockBody) wire.LockHead {
	t.Helper()
	var lock wire.Lock
	json.Unmarshal(call(t, s, "", "lock/get", nil), &lock)
	body.Person, body.At = lock.Person, wire.DateOf(time.Now())
	if len(lock.Entries) > 0 {
		h := machinelock.HashOf(lock.Entries[len(lock.Entries)-1])
		body.Previous = h[:]
	}
	e, err := machinelock.Sign(signer, body)
	if err != nil {
		t.Fatal(err)
	}
	var head wire.LockHead
	json.Unmarshal(call(t, s, "", "lock/add", wire.LockAdd{Entries: []wire.LockEntry{e}}), &head)
	return head
}

func joinNote(t *testing.T, s *controllink.Session, request string, ok func(wire.LockJoinRequest) bool) wire.LockJoinRequest {
	t.Helper()
	for {
		var r wire.LockJoinRequest
		json.Unmarshal(waitNote(t, s, "control/lockJoinRequested").Params, &r)
		if r.Request == request && ok(r) {
			return r
		}
	}
}

// #3490 (D2): a new client joins the lock by approval on a device that is in it. The six
// digits come from a commitment, so the control plane passes the nonces on but cannot
// choose them, and only a signer's addClient approves.
func TestANewClientJoinsTheLockByApproval(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	_, mac := p.client("Mac")
	browserMember, browser := p.client("Browser")
	macKey, browserKey := lockKey(t), lockKey(t)

	// With no lock, there is nothing to join: the first client makes the root.
	commitmentOf := func(nonce []byte) []byte { return machinelock.Commitment(machinelock.PublicKey(browserKey), nonce) }
	clientNonce := bytes.Repeat([]byte{7}, machinelock.NonceSize)
	ask := wire.LockJoin{Key: machinelock.PublicKey(browserKey), Commitment: commitmentOf(clientNonce)}
	if e := callError(t, browser, "", "lock/join", ask); !strings.Contains(e, "no lock yet") {
		t.Fatal(e)
	}
	signOnto(t, mac, macKey, wire.LockBody{Kind: wire.LockEntryKindRoot, Key: machinelock.PublicKey(macKey), Name: new("Mac"), ClientKind: new("mac")})

	var started wire.LockJoinStarted
	json.Unmarshal(call(t, browser, "", "lock/join", ask), &started)
	asked := joinNote(t, mac, started.Request, func(wire.LockJoinRequest) bool { return true })
	if asked.Client != browserMember.Client || asked.Name != "Browser" || !bytes.Equal(asked.Commitment, ask.Commitment) || asked.Nonce != nil {
		t.Fatalf("%+v", asked)
	}
	var listed []wire.LockJoinRequest
	json.Unmarshal(call(t, mac, "", "lock/joinRequests", nil), &listed)
	if len(listed) != 1 || listed[0].Request != started.Request {
		t.Fatalf("%+v", listed)
	}

	// The browser cannot show its nonce before a signer sent one, nor approve itself.
	if e := callError(t, browser, "", "lock/joinReveal", wire.LockJoinNonce{Request: started.Request, Nonce: clientNonce}); !strings.Contains(e, "not waiting") {
		t.Fatal(e)
	}
	signerNonce := bytes.Repeat([]byte{9}, machinelock.NonceSize)
	if e := callError(t, browser, "", "lock/joinAnswer", wire.LockJoinNonce{Request: started.Request, Nonce: signerNonce}); !strings.Contains(e, "approve itself") {
		t.Fatal(e)
	}
	call(t, mac, "", "lock/joinAnswer", wire.LockJoinNonce{Request: started.Request, Nonce: signerNonce})
	answered := joinNote(t, browser, started.Request, func(r wire.LockJoinRequest) bool { return r.Nonce != nil })
	if !bytes.Equal(answered.Nonce, signerNonce) || deref(answered.AnsweredBy) == "" {
		t.Fatalf("%+v", answered)
	}
	// One signer's nonce only: a second cannot be sent, so nobody tries the digits twice.
	if e := callError(t, mac, "", "lock/joinAnswer", wire.LockJoinNonce{Request: started.Request, Nonce: clientNonce}); !strings.Contains(e, "already") {
		t.Fatal(e)
	}
	// A nonce that is not the committed one is refused.
	if e := callError(t, browser, "", "lock/joinReveal", wire.LockJoinNonce{Request: started.Request, Nonce: signerNonce}); !strings.Contains(e, "not the one") {
		t.Fatal(e)
	}
	call(t, browser, "", "lock/joinReveal", wire.LockJoinNonce{Request: started.Request, Nonce: clientNonce})
	revealed := joinNote(t, mac, started.Request, func(r wire.LockJoinRequest) bool { return r.Reveal != nil })
	key := machinelock.PublicKey(browserKey)
	if machinelock.Digits(key, revealed.Reveal, signerNonce) != machinelock.Digits(key, clientNonce, answered.Nonce) {
		t.Fatal("the two screens show different digits")
	}

	// Approve: the signer puts the browser's addClient on the lock.
	signOnto(t, mac, macKey, wire.LockBody{Kind: wire.LockEntryKindAddClient, Key: key, Name: new("Browser"), ClientKind: new("web")})
	var decided wire.LockJoinDecided
	json.Unmarshal(waitNote(t, browser, "control/lockJoinDecided").Params, &decided)
	if decided.Request != started.Request || decided.Result != "approved" {
		t.Fatalf("%+v", decided)
	}
	json.Unmarshal(call(t, mac, "", "lock/joinRequests", nil), &listed)
	if len(listed) != 0 {
		t.Fatalf("%+v", listed)
	}
	var lock wire.Lock
	json.Unmarshal(call(t, browser, "", "lock/get", nil), &lock)
	state, err := machinelock.Check(lock.Entries)
	if err != nil || !state.Signer(key) {
		t.Fatal(err)
	}
	// In the lock now, it does not ask again.
	if e := callError(t, browser, "", "lock/join", ask); !strings.Contains(e, "already") {
		t.Fatal(e)
	}
}

// A signer that says no ends the request; the client asking again ends its old one.
func TestALockJoinIsDeniedOrAskedAgain(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	_, mac := p.client("Mac")
	_, phone := p.client("Phone")
	macKey, phoneKey := lockKey(t), lockKey(t)
	signOnto(t, mac, macKey, wire.LockBody{Kind: wire.LockEntryKindRoot, Key: machinelock.PublicKey(macKey)})
	ask := wire.LockJoin{Key: machinelock.PublicKey(phoneKey), Commitment: machinelock.Commitment(machinelock.PublicKey(phoneKey), make([]byte, 16))}
	var first, second wire.LockJoinStarted
	json.Unmarshal(call(t, phone, "", "lock/join", ask), &first)
	json.Unmarshal(call(t, phone, "", "lock/join", ask), &second)
	var listed []wire.LockJoinRequest
	json.Unmarshal(call(t, mac, "", "lock/joinRequests", nil), &listed)
	if len(listed) != 1 || listed[0].Request != second.Request {
		t.Fatalf("%+v", listed)
	}
	call(t, mac, "", "lock/joinDeny", wire.LockJoinEnd{Request: second.Request})
	for {
		var decided wire.LockJoinDecided
		json.Unmarshal(waitNote(t, phone, "control/lockJoinDecided").Params, &decided)
		if decided.Request == second.Request {
			if decided.Result != "denied" {
				t.Fatalf("%+v", decided)
			}
			break
		}
	}
	if e := callError(t, mac, "", "lock/joinAnswer", wire.LockJoinNonce{Request: second.Request, Nonce: make([]byte, 16)}); !strings.Contains(e, "ended") {
		t.Fatal(e)
	}
}

// machineNotes is what the fake machines are told of their requests to join the lock.
type machineNotes struct {
	mu  sync.Mutex
	got []wire.LockJoinRequest
}

func (n *machineNotes) heard(host, method string, params json.RawMessage) {
	if method != wire.NotifyMachineLockJoinChanged.Name {
		return
	}
	var r wire.LockJoinRequest
	json.Unmarshal(params, &r)
	n.mu.Lock()
	n.got = append(n.got, r)
	n.mu.Unlock()
}

func (n *machineNotes) answered() *wire.LockJoinRequest {
	n.mu.Lock()
	defer n.mu.Unlock()
	for _, r := range n.got {
		if r.Nonce != nil {
			return &r
		}
	}
	return nil
}

// #3491 (D3): a machine with no invite asks to join its person's lock as a client does; a
// signer compares the digits and approves it with an addMachine. A machine with an invite
// adds itself, and only itself.
func TestAMachineJoinsTheLock(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	notes := &machineNotes{}
	p.told = notes.heard
	_, mac := p.client("Mac")
	macKey := lockKey(t)
	signOnto(t, mac, macKey, wire.LockBody{Kind: wire.LockEntryKindRoot, Key: machinelock.PublicKey(macKey)})
	box := p.host("box")
	boxKey, _ := controllink.PublicKey(box.private)
	ctx := context.Background()

	// A machine asks with its own key only.
	nonce := bytes.Repeat([]byte{3}, machinelock.NonceSize)
	other, _ := controllink.PublicKey(controllink.NewPrivateKey())
	if _, err := box.uplink.Ask(ctx, "machine/lockJoin", wire.LockJoin{Key: other, Commitment: machinelock.Commitment(other, nonce)}); err == nil ||
		!strings.Contains(err.Error(), "this machine's key") {
		t.Fatal(err)
	}
	var started wire.LockJoinStarted
	b, err := box.uplink.Ask(ctx, "machine/lockJoin", wire.LockJoin{Key: boxKey, Commitment: machinelock.Commitment(boxKey, nonce)})
	if err != nil {
		t.Fatal(err)
	}
	json.Unmarshal(b, &started)
	asked := joinNote(t, mac, started.Request, func(wire.LockJoinRequest) bool { return true })
	if asked.Machine == nil || string(*asked.Machine) != box.member.Host || asked.Name != "box box" {
		t.Fatalf("%+v", asked)
	}
	signerNonce := bytes.Repeat([]byte{4}, machinelock.NonceSize)
	call(t, mac, "", "lock/joinAnswer", wire.LockJoinNonce{Request: started.Request, Nonce: signerNonce})
	p.waitFor(func() bool { return notes.answered() != nil }, "the machine told the signer's nonce")
	if !bytes.Equal(notes.answered().Nonce, signerNonce) {
		t.Fatalf("%+v", notes.answered())
	}
	if _, err := box.uplink.Ask(ctx, "machine/lockJoinReveal", wire.LockJoinNonce{Request: started.Request, Nonce: nonce}); err != nil {
		t.Fatal(err)
	}
	revealed := joinNote(t, mac, started.Request, func(r wire.LockJoinRequest) bool { return r.Reveal != nil })
	if machinelock.Digits(boxKey, revealed.Reveal, signerNonce) != machinelock.Digits(boxKey, nonce, signerNonce) {
		t.Fatal("the two screens show different digits")
	}
	signOnto(t, mac, macKey, wire.LockBody{Kind: wire.LockEntryKindAddMachine, Key: boxKey, SealingKey: boxKey, ID: new(box.member.Host)})
	var decided wire.LockJoinDecided
	json.Unmarshal(waitNote(t, mac, "control/lockJoinDecided").Params, &decided)
	if decided.Request != started.Request || decided.Result != "approved" {
		t.Fatalf("%+v", decided)
	}

	// An invite: the machine adds itself with it, and cannot add another key.
	inviteKey := lockKey(t)
	signOnto(t, mac, macKey, wire.LockBody{Kind: wire.LockEntryKindInvite, Key: machinelock.PublicKey(inviteKey),
		Expires: new(wire.DateOf(time.Now().Add(5 * time.Minute)))})
	dev := p.host("dev")
	devKey, _ := controllink.PublicKey(dev.private)
	var lock wire.Lock
	json.Unmarshal(call(t, mac, "", "lock/get", nil), &lock)
	state, err := machinelock.Check(lock.Entries)
	if err != nil {
		t.Fatal(err)
	}
	stolen, _ := machinelock.AddMachine(inviteKey, state, other, "", "", time.Now())
	if _, err := dev.uplink.Ask(ctx, "machine/lockAdd", wire.LockAdd{Entries: []wire.LockEntry{stolen}}); err == nil ||
		!strings.Contains(err.Error(), "only its own") {
		t.Fatal(err)
	}
	own, _ := machinelock.AddMachine(inviteKey, state, devKey, dev.member.Host, "dev", time.Now())
	if _, err := dev.uplink.Ask(ctx, "machine/lockAdd", wire.LockAdd{Entries: []wire.LockEntry{own}}); err != nil {
		t.Fatal(err)
	}
	json.Unmarshal(call(t, mac, "", "lock/get", nil), &lock)
	state, err = machinelock.Check(lock.Entries)
	if err != nil {
		t.Fatal(err)
	}
	for _, key := range [][]byte{boxKey, devKey} {
		if m, ok := state.Member(key); !ok || m.Kind != wire.LockEntryKindAddMachine {
			t.Fatalf("%x is not a machine of the lock", key)
		}
	}
	// The invite was spent.
	if _, open := state.Invite(machinelock.PublicKey(inviteKey), time.Now()); open {
		t.Fatal("the invite is still open")
	}
}

// #3493 (D4): a client with no signer types the recovery key, and signs its own addClient
// with it; with no recovery key either, it starts a new lock with lock/reset.
func TestTheRecoveryKeyAndANewLock(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	_, mac := p.client("Mac")
	_, phone := p.client("Phone")
	macKey, recoveryKey, phoneKey := lockKey(t), lockKey(t), lockKey(t)
	secret := bytes.Repeat([]byte{3}, machinelock.RecoverySecretSize)
	sealed, err := machinelock.SealRecovery(secret, recoveryKey)
	if err != nil {
		t.Fatal(err)
	}
	signOnto(t, mac, macKey, wire.LockBody{Kind: wire.LockEntryKindRoot, Key: machinelock.PublicKey(macKey)})
	signOnto(t, mac, macKey, wire.LockBody{Kind: wire.LockEntryKindRecovery, Key: machinelock.PublicKey(recoveryKey), Sealed: sealed})

	// The Mac is lost. The phone reads the sealed key from the lock and opens it.
	var lock wire.Lock
	json.Unmarshal(call(t, phone, "", "lock/get", nil), &lock)
	state, err := machinelock.Check(lock.Entries)
	if err != nil {
		t.Fatal(err)
	}
	opened, err := machinelock.OpenRecovery(secret, state.Recovery(), state.RecoverySealed())
	if err != nil {
		t.Fatal(err)
	}
	signOnto(t, phone, opened, wire.LockBody{Kind: wire.LockEntryKindAddClient, Key: machinelock.PublicKey(phoneKey), ClientKind: new("remote")})
	json.Unmarshal(call(t, phone, "", "lock/get", nil), &lock)
	if state, _ = machinelock.Check(lock.Entries); !state.Signer(machinelock.PublicKey(phoneKey)) {
		t.Fatal("the recovered phone is not a signer")
	}

	// Every signer and the recovery key lost: a new lock, which a new root starts.
	call(t, phone, "", "lock/reset", nil)
	json.Unmarshal(call(t, phone, "", "lock/get", nil), &lock)
	if len(lock.Entries) != 0 {
		t.Fatalf("the lock after a reset: %d entries", len(lock.Entries))
	}
	signOnto(t, phone, phoneKey, wire.LockBody{Kind: wire.LockEntryKindRoot, Key: machinelock.PublicKey(phoneKey)})
}
