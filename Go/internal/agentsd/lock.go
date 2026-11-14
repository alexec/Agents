package agentsd

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/rand"
	"encoding/json"
	"errors"
	"log"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/agentloops-dev/agents/Go/internal/agentsd/store"
	"github.com/agentloops-dev/agents/Go/internal/controllink"
	"github.com/agentloops-dev/agents/Go/internal/machinelock"
	"github.com/agentloops-dev/agents/Go/wire"
)

// The machine lock (#3399, specs/3399-machine-lock): machine/lock is the person's whole lock.
// This host checks it, and pins the head it took in <root>/lock-pin.json; it takes only a
// lock that grows from that pin. The first lock it is sent is taken on trust (D9), unless
// the code it joined with carried the lock's head (D3): then it pins that one. A lock that
// fails the check is logged, and the pin stays where it was. The lock it took is kept in
// <root>/lock.json, so after a restart it checks requests before the control plane sends
// the lock again (lockcheck.go, #3492).
//
// A machine joins the lock (#3491, D3): with the invite from its join code it signs its
// own addMachine (machine/lockAdd). With none (it asked to join, a provider started it with no
// client there, or it joined before the lock) it asks as a client does (machine/lockJoin): a
// signer sends a nonce, this machine reveals its own, and it shows the six digits in its
// log and in <root>/lock-join-shown for the person to compare.

const (
	lockPinFile   = "lock-pin.json"
	lockFile      = "lock.json"
	lockShownFile = "lock-join-shown"
	// lockAskAgain is how long one request to join waits before the machine asks again, as
	// the control plane's requests last.
	lockAskAgain = 10 * time.Minute
)

type lockState struct {
	lockMu sync.Mutex
	// lockAsk is this machine's request to join the lock, while it waits.
	lockAsk *lockAsk
	// lockHeld is the lock this machine took last, checked; nil before it read one.
	lockHeld *machinelock.State
	lockRead bool
	// lockSeen is each signed request taken, by machinelock.SignedID, and when it was
	// signed, so each is taken once (lockcheck.go).
	lockSeen map[string]int64
	// lockSigner is this machine's key as a signer, read once.
	lockSigner *ecdsa.PrivateKey
}

type lockAsk struct {
	nonce    []byte
	asked    time.Time
	request  string
	revealed bool
}

func (d *Daemon) lockPinPath() string { return filepath.Join(d.Store.Loc.Root, lockPinFile) }

func (d *Daemon) lockFilePath() string { return filepath.Join(d.Store.Loc.Root, lockFile) }

func fileExists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

// heldLock is the lock this machine checks requests against, and whether it holds one at
// all. pinned with a nil state is a lock pinned and not read yet: nothing is taken on it.
func (d *Daemon) heldLock() (state *machinelock.State, pinned bool) {
	d.lockMu.Lock()
	defer d.lockMu.Unlock()
	return d.heldLockLocked()
}

func (d *Daemon) heldLockLocked() (*machinelock.State, bool) {
	if d.lockRead {
		return d.lockHeld, d.lockHeld != nil
	}
	pin := d.LockPin()
	if pin.Count == 0 {
		return nil, false
	}
	var lock wire.Lock
	b, err := os.ReadFile(d.lockFilePath())
	if err == nil {
		err = json.Unmarshal(b, &lock)
	}
	if err == nil {
		state, ferr := machinelock.Follow(pin, lock)
		if ferr == nil {
			d.lockHeld, d.lockRead = state, true
			return state, true
		}
		err = ferr
	}
	if !errors.Is(err, os.ErrNotExist) {
		log.Printf("lock: the kept lock does not check (%v); waiting for the control plane's", err)
	}
	return nil, true
}

// LockPin is the head this host last took; zero when it has taken none.
func (d *Daemon) LockPin() machinelock.Pin {
	var pin machinelock.Pin
	if b, err := os.ReadFile(d.lockPinPath()); err == nil {
		json.Unmarshal(b, &pin)
	}
	return pin
}

// toldLock is machine/lock.
func (d *Daemon) toldLock(params json.RawMessage) {
	var lock wire.Lock
	if err := json.Unmarshal(params, &lock); err != nil {
		log.Printf("lock: %v", err)
		return
	}
	d.TakeLock(lock)
}

// TakeLock checks a lock against the pin and, when it passes, pins its head and joins it
// when this machine is not in it yet. It says whether it took it. A lock that fails is only
// logged, as what this host would refuse.
func (d *Daemon) TakeLock(lock wire.Lock) bool {
	d.lockMu.Lock()
	defer d.lockMu.Unlock()
	kept := d.LockPin()
	pin := kept
	invite := controllink.LoadLockInvite(d.Store.Loc.Root)
	if pin.Count == 0 && invite != nil {
		// The head from the code, not the control plane's (D3).
		pin = machinelock.Pin{Person: invite.Person, Count: invite.Count, Head: invite.Head}
	}
	state, err := machinelock.Follow(pin, lock)
	if err != nil {
		log.Printf("lock: would refuse %s's lock of %d entries: %v", lock.Person, len(lock.Entries), err)
		return false
	}
	d.lockHeld, d.lockRead = state, true
	if b, err := json.Marshal(lock); err == nil && (state.Count() != kept.Count || !fileExists(d.lockFilePath())) {
		if err := store.WriteAtomically(d.lockFilePath(), b, 0o644); err != nil {
			log.Printf("lock: the lock could not be kept: %v", err)
		}
	}
	if state.Count() != kept.Count {
		b, _ := json.Marshal(state.Pin())
		if err := store.WriteAtomically(d.lockPinPath(), b, 0o644); err != nil {
			log.Printf("lock: the head could not be pinned: %v", err)
			return false
		}
		if pin.Count == 0 {
			log.Printf("lock: pinned %s's lock on first use, %d entries, root %s, head %s",
				state.Person, state.Count(), state.Root.Short(), state.Head().Short())
		} else {
			log.Printf("lock: %s's lock grew from %d to %d entries, head %s",
				state.Person, pin.Count, state.Count(), state.Head().Short())
		}
	}
	d.joinLockLocked(state, invite, time.Now())
	if state.Count() != kept.Count {
		// A machine new to the lock waits for the bot's key (#3950).
		d.goShareBotKey(false)
	}
	return true
}

// lockIdentity is this machine's id, name and public key; ok false before it joined a
// control plane.
func (d *Daemon) lockIdentity() (host, name string, key []byte, ok bool) {
	member, err := controllink.LoadMembership(d.Store.Loc.Root)
	if err != nil || member.Host == "" || d.HostKey == nil {
		return "", "", nil, false
	}
	private, found, err := d.HostKey.Load()
	if err != nil || !found {
		return "", "", nil, false
	}
	key, err = controllink.PublicKey(private)
	if err != nil {
		return "", "", nil, false
	}
	name, _ = os.Hostname()
	return member.Host, name, key, true
}

// joinLockLocked puts this machine on the lock when it is not on it: its own addMachine
// with the invite, else a request to join.
func (d *Daemon) joinLockLocked(state *machinelock.State, invite *controllink.LockInvite, now time.Time) {
	root := d.Store.Loc.Root
	host, name, key, ok := d.lockIdentity()
	if !ok {
		return
	}
	if m, in := state.Member(key); in && m.Kind == wire.LockEntryKindAddMachine {
		if invite != nil || d.lockAsk != nil {
			log.Printf("lock: this machine is in %s's lock", state.Person)
		}
		controllink.DropLockInvite(root)
		os.Remove(filepath.Join(root, lockShownFile))
		d.lockAsk = nil
		return
	}
	tell := d.tellControl.Load()
	if tell == nil {
		return
	}
	if invite != nil {
		signer, err := machinelock.InviteKey(invite.Key)
		if err == nil && invite.Person == state.Person {
			if _, open := state.Invite(machinelock.PublicKey(signer), now); open {
				entry, err := machinelock.AddMachine(signer, state, key, host, name, now)
				if err == nil {
					(*tell)(wire.CallMachineLockAdd.Name, wire.LockAdd{Entries: []wire.LockEntry{entry}})
					log.Printf("lock: added this machine to %s's lock with the invite from its join code", state.Person)
					return
				}
			}
		}
		log.Printf("lock: the invite from the join code is spent, expired or not this lock's; asking to join")
		controllink.DropLockInvite(root)
	}
	if d.lockAsk != nil && now.Sub(d.lockAsk.asked) < lockAskAgain {
		return
	}
	nonce := make([]byte, machinelock.NonceSize)
	rand.Read(nonce)
	d.lockAsk = &lockAsk{nonce: nonce, asked: now}
	os.Remove(filepath.Join(root, lockShownFile))
	(*tell)(wire.CallMachineLockJoin.Name, wire.LockJoin{Key: key, Commitment: machinelock.Commitment(key, nonce)})
	log.Printf("lock: this machine is not in %s's lock: asking to join; approve it on one of your devices", state.Person)
}

// toldLockJoin is machine/lockJoinChanged: this machine's request, as it goes on.
func (d *Daemon) toldLockJoin(params json.RawMessage) {
	var r wire.LockJoinRequest
	if err := json.Unmarshal(params, &r); err != nil {
		log.Printf("lock: %v", err)
		return
	}
	d.lockMu.Lock()
	defer d.lockMu.Unlock()
	ask := d.lockAsk
	if ask == nil || !bytes.Equal(r.Commitment, machinelock.Commitment(r.Key, ask.nonce)) {
		return
	}
	ask.request = r.Request
	if len(r.Nonce) != machinelock.NonceSize || ask.revealed {
		return
	}
	tell := d.tellControl.Load()
	if tell == nil {
		return
	}
	ask.revealed = true
	(*tell)(wire.CallMachineLockJoinReveal.Name, wire.LockJoinNonce{Request: r.Request, Nonce: ask.nonce})
	// The digits made here, from this machine's own key and nonce: a control plane that
	// passed on another key could only pass on that key's digits.
	digits := machinelock.Digits(r.Key, ask.nonce, r.Nonce)
	shown := digits[:3] + " " + digits[3:]
	os.WriteFile(filepath.Join(d.Store.Loc.Root, lockShownFile), []byte(shown+"\n"), 0o600)
	log.Printf("lock: to add this machine to the lock, check that your device shows the digits %s, then approve it", shown)
}

// registerLockReset serves daemon/lockReset, which `agentsd lock reset` calls (#3493, D4):
// only on daemon.sock, which this machine's own account alone reaches, never on a channel
// the control plane opened nor on the window's local socket, whose requests are checked.
func (d *Daemon) registerLockReset() {
	On(d, wire.CallDaemonLockReset, func(_ context.Context, c *Client, _ wire.Empty) (wire.Empty, error) {
		if c.checked {
			return wire.Empty{}, &Error{Code: CodeNotPermitted, Message: "Only agentsd lock reset, in this machine's shell, resets its lock."}
		}
		d.ResetLock()
		return wire.Empty{}, nil
	})
}

// ResetLock forgets the lock this machine pinned (#3493, D4): the person started a new
// lock, because every signer and the recovery key were lost. It drops the pin, the lock it
// kept, the invite and the request to join, and asks the control plane for the person's
// lock again, which it then pins on first use. Until then it checks nothing, as before the
// lock.
func (d *Daemon) ResetLock() {
	d.lockMu.Lock()
	defer d.lockMu.Unlock()
	ResetLockFiles(d.Store.Loc.Root)
	d.lockHeld, d.lockRead, d.lockAsk = nil, false, nil
	log.Printf("lock: reset by agentsd lock reset; the next lock the control plane sends is pinned on first use")
	if tell := d.tellControl.Load(); tell != nil {
		(*tell)(wire.CallMachineLockAgain.Name, wire.Empty{})
	}
}

// ResetLockFiles removes the lock's files from a root: what `agentsd lock reset` does
// itself when no agentsd runs on that root.
func ResetLockFiles(root string) {
	for _, name := range []string{lockPinFile, lockFile, lockShownFile} {
		os.Remove(filepath.Join(root, name))
	}
	controllink.DropLockInvite(root)
}
