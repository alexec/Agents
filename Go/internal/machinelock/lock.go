// Package machinelock is a person's machine lock (#3399, specs/3399-machine-lock): a chain
// of signed entries that says which clients may sign and which machines are the person's.
// The control plane keeps the chain; each client and each machine checks it and pins the
// head it last saw, so a control plane cannot add a key, change or remove an entry, put
// one in another order, or fork the chain without the check finding it.
//
// An entry is a LockBody's JSON, kept as its signer wrote it, and an ECDSA P-256 signature
// (r then s) over the domain then those bytes. Its hash is the SHA-256 of the body. Every
// client of the person signs (root and addClient), and so does the recovery key; a machine
// never signs (D1). An invite's key signs one addMachine, before it expires (D3).
package machinelock

import (
	"bytes"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"slices"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// Version is LockBody.v.
const Version = 1

// domain is what a signature covers before the body, so a lock signature is never one of
// another kind made with the same key (the channel handshake, #3400 step 4).
const domain = "agents-lock/1\n"

// MostEntries bounds a lock. A person adds and removes few clients and machines; past it
// the chain is refused, not kept growing.
const MostEntries = 4096

// MostBody bounds one entry's body.
const MostBody = 4096

// The ways a lock fails its check. A CheckError wraps one.
var (
	// ErrForged: a signature does not check, or the signer may not sign that entry.
	ErrForged = errors.New("an entry is not signed by a key of the lock")
	// ErrOutOfOrder: an entry does not follow the one before it (a reorder, a drop, or a
	// root that is not first).
	ErrOutOfOrder = errors.New("an entry does not follow the entry before it")
	// ErrInvalid: an entry says something the lock cannot take.
	ErrInvalid = errors.New("an entry is not one the lock takes")
	// ErrForked: the lock does not grow from the head that was pinned.
	ErrForked = errors.New("the lock changed in a way your devices did not sign")
	// ErrBehind: the lock is shorter than the head that was pinned, so it was kept back.
	ErrBehind = errors.New("the lock is older than the one last seen")
)

// CheckError is a failed check: what, and at which entry (-1 for the lock as a whole).
type CheckError struct {
	Index int
	Err   error
	Why   string
}

func (e *CheckError) Error() string {
	if e.Index < 0 {
		return fmt.Sprintf("%v: %s", e.Err, e.Why)
	}
	return fmt.Sprintf("entry %d: %v: %s", e.Index, e.Err, e.Why)
}

func (e *CheckError) Unwrap() error { return e.Err }

// Hash is an entry's hash: the SHA-256 of its body.
type Hash [sha256.Size]byte

func (h Hash) String() string { return hex.EncodeToString(h[:]) }

// Short is the first 8 bytes, as a log line names a head.
func (h Hash) Short() string { return hex.EncodeToString(h[:8]) }

// HashOf is an entry's hash.
func HashOf(e wire.LockEntry) Hash { return sha256.Sum256(e.Body) }

func signed(body []byte) []byte {
	sum := sha256.Sum256(append([]byte(domain), body...))
	return sum[:]
}

// PublicKey is a signing key's public half, X9.63, as an entry names it.
func PublicKey(key *ecdsa.PrivateKey) []byte {
	b, _ := key.PublicKey.Bytes()
	return b
}

// NewKey makes a signing key: for the tests, and later for a client that has no Secure
// Enclave or WebCrypto of its own.
func NewKey() (*ecdsa.PrivateKey, error) { return ecdsa.GenerateKey(elliptic.P256(), rand.Reader) }

// Sign makes an entry of body, signed with key: it sets v and signer.
func Sign(key *ecdsa.PrivateKey, body wire.LockBody) (wire.LockEntry, error) {
	body.V = Version
	body.Signer = PublicKey(key)
	b, err := json.Marshal(body)
	if err != nil {
		return wire.LockEntry{}, err
	}
	r, s, err := ecdsa.Sign(rand.Reader, key, signed(b))
	if err != nil {
		return wire.LockEntry{}, err
	}
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	return wire.LockEntry{Body: b, Sig: sig}, nil
}

// Open reads an entry's body and checks its signature by the signer it names. It does not
// say whether that signer may sign: State.Add does.
func Open(e wire.LockEntry) (wire.LockBody, error) {
	var body wire.LockBody
	if len(e.Body) > MostBody {
		return body, fmt.Errorf("%w: its body is over %d bytes", ErrInvalid, MostBody)
	}
	if err := json.Unmarshal(e.Body, &body); err != nil {
		return body, fmt.Errorf("%w: its body does not read: %v", ErrInvalid, err)
	}
	if body.V != Version {
		return body, fmt.Errorf("%w: version %d, not %d", ErrInvalid, body.V, Version)
	}
	key, err := ecdsa.ParseUncompressedPublicKey(elliptic.P256(), body.Signer)
	if err != nil {
		return body, fmt.Errorf("%w: its signer is not a P-256 key", ErrForged)
	}
	if len(e.Sig) != 64 || !ecdsa.Verify(key, signed(e.Body), new(big.Int).SetBytes(e.Sig[:32]), new(big.Int).SetBytes(e.Sig[32:])) {
		return body, fmt.Errorf("%w: its signature does not check", ErrForged)
	}
	return body, nil
}

// Member is a key the lock names: a client (root or addClient), a machine (addMachine) or
// an invite.
type Member struct {
	Kind       wire.LockEntryKind
	Key        []byte
	SealingKey []byte
	ID         string
	Name       string
	ClientKind string
	Expires    time.Time
	// Entry is the index of the entry that added it.
	Entry int
}

// Client says the member is a client, so a signer.
func (m Member) Client() bool {
	return m.Kind == wire.LockEntryKindRoot || m.Kind == wire.LockEntryKindAddClient
}

// State is a lock as its entries leave it.
type State struct {
	Person string
	// Root is the root entry's hash: the lock's fingerprint.
	Root Hash
	// hashes is each entry's hash, in order; the last is the head.
	hashes   []Hash
	members  map[string]Member
	recovery []byte
	// recoverySealed is the recovery key's private half, sealed under the secret (#3493).
	recoverySealed []byte
}

func keyID(key []byte) string { return string(key) }

// Count is how many entries the lock has.
func (s *State) Count() int { return len(s.hashes) }

// Head is the newest entry's hash; zero for a lock with no entries.
func (s *State) Head() Hash {
	if len(s.hashes) == 0 {
		return Hash{}
	}
	return s.hashes[len(s.hashes)-1]
}

// HashAt is the hash of entry i.
func (s *State) HashAt(i int) Hash { return s.hashes[i] }

// Recovery is the recovery key's public half, or nil.
func (s *State) Recovery() []byte { return s.recovery }

// Member is the member of that key, if the lock names it now.
func (s *State) Member(key []byte) (Member, bool) {
	m, ok := s.members[keyID(key)]
	return m, ok
}

// Signer says the key may sign an entry: a client of the person, or the recovery key.
func (s *State) Signer(key []byte) bool {
	if m, ok := s.members[keyID(key)]; ok {
		return m.Client()
	}
	return s.recovery != nil && bytes.Equal(key, s.recovery)
}

// Members are the lock's members of a kind, in the order they were added.
func (s *State) Members(kind wire.LockEntryKind) []Member {
	var out []Member
	for _, m := range s.members {
		if m.Kind == kind || kind == wire.LockEntryKindAddClient && m.Kind == wire.LockEntryKindRoot {
			out = append(out, m)
		}
	}
	slices.SortFunc(out, func(a, b Member) int { return a.Entry - b.Entry })
	return out
}

// Pin is what a client or a machine keeps of the lock it last checked.
type Pin struct {
	Person string `json:"person"`
	Count  int    `json:"count"`
	Head   []byte `json:"head"`
}

// Pin is the state's pin.
func (s *State) Pin() Pin {
	h := s.Head()
	return Pin{Person: s.Person, Count: s.Count(), Head: h[:]}
}

func validKey(key []byte) bool {
	_, err := ecdh.P256().NewPublicKey(key)
	return err == nil
}

// Add checks one entry onto the state and, when it passes, takes it. A state with no
// entries takes only a root.
func (s *State) Add(e wire.LockEntry) error {
	i := len(s.hashes)
	bad := func(err error, format string, args ...any) error {
		return &CheckError{Index: i, Err: err, Why: fmt.Sprintf(format, args...)}
	}
	if i >= MostEntries {
		return bad(ErrInvalid, "the lock has %d entries, the most it takes", MostEntries)
	}
	body, err := Open(e)
	if err != nil {
		var why error = ErrInvalid
		if errors.Is(err, ErrForged) {
			why = ErrForged
		}
		return &CheckError{Index: i, Err: why, Why: err.Error()}
	}
	if !validKey(body.Key) {
		return bad(ErrInvalid, "its key is not a P-256 key")
	}
	if i == 0 {
		if body.Kind != wire.LockEntryKindRoot {
			return bad(ErrOutOfOrder, "the first entry is %s, not root", body.Kind)
		}
		if len(body.Previous) != 0 {
			return bad(ErrOutOfOrder, "the root names an entry before it")
		}
		if body.Person == "" {
			return bad(ErrInvalid, "the root names no person")
		}
		if !bytes.Equal(body.Signer, body.Key) {
			return bad(ErrForged, "the root is not signed by the key it names")
		}
		s.Person = body.Person
		s.members = map[string]Member{}
		s.add(body, i)
		s.Root = HashOf(e)
		s.hashes = append(s.hashes, s.Root)
		return nil
	}
	if body.Person != s.Person {
		return bad(ErrForged, "it names the person %q, not %q", body.Person, s.Person)
	}
	if head := s.Head(); !bytes.Equal(body.Previous, head[:]) {
		return bad(ErrOutOfOrder, "it follows %x, not the head %s", body.Previous, head.Short())
	}
	signer := s.Signer(body.Signer)
	// An invite signs one addMachine, and is spent once that entry is taken.
	spent := ""
	switch body.Kind {
	case wire.LockEntryKindRoot:
		return bad(ErrOutOfOrder, "a second root")
	case wire.LockEntryKindAddMachine:
		if len(body.SealingKey) == 0 || !validKey(body.SealingKey) {
			return bad(ErrInvalid, "the machine's sealing key is not a P-256 key")
		}
		if invite, ok := s.members[keyID(body.Signer)]; ok && invite.Kind == wire.LockEntryKindInvite {
			if !body.At.Time().Before(invite.Expires) {
				return bad(ErrForged, "its invite expired at %s", invite.Expires.UTC().Format(time.RFC3339))
			}
			spent = keyID(body.Signer)
			signer = true
		}
	case wire.LockEntryKindInvite:
		if body.Expires == nil || !body.Expires.Time().After(body.At.Time()) {
			return bad(ErrInvalid, "the invite has no expiry after it was made")
		}
	case wire.LockEntryKindAddClient, wire.LockEntryKindRemove, wire.LockEntryKindRecovery:
	default:
		return bad(ErrInvalid, "the kind %q is not one this build knows", body.Kind)
	}
	if !signer {
		return bad(ErrForged, "its signer is not a client or the recovery key of the lock")
	}
	switch body.Kind {
	case wire.LockEntryKindRemove:
		if _, ok := s.members[keyID(body.Key)]; !ok {
			return bad(ErrInvalid, "it removes a key the lock does not name")
		}
		delete(s.members, keyID(body.Key))
	case wire.LockEntryKindRecovery:
		if _, ok := s.members[keyID(body.Key)]; ok {
			return bad(ErrInvalid, "the recovery key is a member of the lock")
		}
		s.recovery = slices.Clone(body.Key)
		s.recoverySealed = slices.Clone(body.Sealed)
	default:
		if _, ok := s.members[keyID(body.Key)]; ok || bytes.Equal(body.Key, s.recovery) {
			return bad(ErrInvalid, "its key is in the lock already")
		}
		s.add(body, i)
	}
	if spent != "" {
		delete(s.members, spent)
	}
	s.hashes = append(s.hashes, HashOf(e))
	return nil
}

func (s *State) add(body wire.LockBody, i int) {
	m := Member{Kind: body.Kind, Key: slices.Clone(body.Key), SealingKey: slices.Clone(body.SealingKey), Entry: i}
	if body.ID != nil {
		m.ID = *body.ID
	}
	if body.Name != nil {
		m.Name = *body.Name
	}
	if body.ClientKind != nil {
		m.ClientKind = *body.ClientKind
	}
	if body.Expires != nil {
		m.Expires = body.Expires.Time()
	}
	s.members[keyID(body.Key)] = m
}

// Check reads a whole chain, the root first, and says where it leaves the lock.
func Check(entries []wire.LockEntry) (*State, error) {
	s := &State{}
	for _, e := range entries {
		if err := s.Add(e); err != nil {
			return nil, err
		}
	}
	return s, nil
}

// Follow checks a lock against the pin last kept: it must pass Check, be the same
// person's, and grow from the pinned head. A zero pin (none kept yet) takes any lock
// that checks: trust on first use (D9).
func Follow(pin Pin, lock wire.Lock) (*State, error) {
	s, err := Check(lock.Entries)
	if err != nil {
		return nil, err
	}
	if pin.Count == 0 {
		return s, nil
	}
	whole := func(err error, format string, args ...any) error {
		return &CheckError{Index: -1, Err: err, Why: fmt.Sprintf(format, args...)}
	}
	if s.Person != pin.Person {
		return nil, whole(ErrForked, "it is %q's lock, not %q's", s.Person, pin.Person)
	}
	if s.Count() < pin.Count {
		return nil, whole(ErrBehind, "%d entries, and %d were seen", s.Count(), pin.Count)
	}
	if at := s.HashAt(pin.Count - 1); !bytes.Equal(at[:], pin.Head) {
		return nil, whole(ErrForked, "entry %d is %s, and %x was pinned", pin.Count-1, at.Short(), pin.Head)
	}
	return s, nil
}

// InviteKey reads an invite's private key, as a join code carries it (32 bytes, D3).
func InviteKey(raw []byte) (*ecdsa.PrivateKey, error) {
	return ecdsa.ParseRawPrivateKey(elliptic.P256(), raw)
}

// AddMachine is a machine's own addMachine, signed with the invite key from its join code
// (#3491, D3), following the state's head. The machine's key is also its sealing key: the
// key org routes and secrets are sealed to (D8).
func AddMachine(invite *ecdsa.PrivateKey, s *State, machineKey []byte, id, name string, at time.Time) (wire.LockEntry, error) {
	head := s.Head()
	body := wire.LockBody{Kind: wire.LockEntryKindAddMachine, Person: s.Person, Previous: head[:], At: wire.DateOf(at),
		Key: machineKey, SealingKey: machineKey}
	if id != "" {
		body.ID = &id
	}
	if name != "" {
		body.Name = &name
	}
	return Sign(invite, body)
}

// Invite is the open invite of that key, if the lock names one that has not expired.
func (s *State) Invite(key []byte, now time.Time) (Member, bool) {
	m, ok := s.members[keyID(key)]
	return m, ok && m.Kind == wire.LockEntryKindInvite && now.Before(m.Expires)
}
