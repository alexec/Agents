// Package locks keeps each person's machine lock (#3399, specs/3399-machine-lock) at
// v1/locks/<person>/: one object for each entry, named by its place in the chain. An entry
// is written only where none is (a conditional write on the head), so two entries cannot
// both follow one head. The control plane checks each entry before it writes it, but it
// cannot sign one: the clients and the machines check the whole chain themselves.
package locks

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"

	"github.com/agentloops-dev/agent-loops/Go/internal/controlplane/store"
	"github.com/agentloops-dev/agent-loops/Go/internal/machinelock"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// Prefix is where every person's lock is in the store.
const Prefix = "v1/locks/"

// MostAdded bounds the entries one lock/add takes.
const MostAdded = 16

var (
	// ErrChanged is an entry another client put first: read the lock again.
	ErrChanged = errors.New("the lock changed elsewhere")
	// ErrInvalid is an entry that does not pass the checks, or a request with none.
	ErrInvalid = errors.New("invalid")
)

var personID = regexp.MustCompile(`^[A-Za-z0-9._-]{1,128}$`)

// Book is every person's lock in one store.
type Book struct {
	store store.Store
}

// New is a book over s.
func New(s store.Store) *Book { return &Book{store: s} }

func entriesPrefix(person string) string { return Prefix + person + "/" }

// entryKey is entry i's key: zero-padded, so the store lists them in order.
func entryKey(person string, i int) string {
	return fmt.Sprintf("%s%06d.json", entriesPrefix(person), i)
}

func checkPerson(person string) error {
	if !personID.MatchString(person) {
		return fmt.Errorf("%w: %q is not a person's id", ErrInvalid, person)
	}
	return nil
}

// Get is the person's lock, with no entries when there is none yet. It reads the entries
// in order and stops at the first place with none, so a lock is never read with a hole.
func (b *Book) Get(ctx context.Context, person string) (wire.Lock, error) {
	lock := wire.Lock{Person: person, Entries: []wire.LockEntry{}}
	if err := checkPerson(person); err != nil {
		return lock, err
	}
	keys, err := b.store.List(ctx, entriesPrefix(person))
	if err != nil {
		return lock, err
	}
	for i := range min(len(keys), machinelock.MostEntries) {
		o, err := b.store.Get(ctx, entryKey(person, i))
		if err != nil {
			return lock, err
		}
		if o == nil {
			break
		}
		var e wire.LockEntry
		if err := json.Unmarshal(o.Data, &e); err != nil {
			return lock, fmt.Errorf("%s does not read: %w", entryKey(person, i), err)
		}
		lock.Entries = append(lock.Entries, e)
	}
	return lock, nil
}

// Add puts entries on the end of the person's lock, in order, after it checks each one as
// a client will. The first entry of a person with no lock is the root, which must name
// that person. It answers where the lock stands after the last entry.
func (b *Book) Add(ctx context.Context, person string, entries []wire.LockEntry) (wire.LockHead, error) {
	if err := checkPerson(person); err != nil {
		return wire.LockHead{}, err
	}
	if len(entries) == 0 || len(entries) > MostAdded {
		return wire.LockHead{}, fmt.Errorf("%w: lock/add takes 1 to %d entries", ErrInvalid, MostAdded)
	}
	lock, err := b.Get(ctx, person)
	if err != nil {
		return wire.LockHead{}, err
	}
	state, err := machinelock.Check(lock.Entries)
	if err != nil {
		// A stored chain that does not check is not this caller's to grow.
		return wire.LockHead{}, fmt.Errorf("the lock kept for %s does not check: %w", person, err)
	}
	for _, e := range entries {
		if err := state.Add(e); err != nil {
			var check *machinelock.CheckError
			if errors.As(err, &check) && errors.Is(err, machinelock.ErrOutOfOrder) && check.Index > 0 {
				return wire.LockHead{}, fmt.Errorf("%w: %v", ErrChanged, err)
			}
			return wire.LockHead{}, fmt.Errorf("%w: %v", ErrInvalid, err)
		}
		if state.Person != person {
			return wire.LockHead{}, fmt.Errorf("%w: the root names %q, not the caller", ErrInvalid, state.Person)
		}
		data, err := json.Marshal(e)
		if err != nil {
			return wire.LockHead{}, err
		}
		if _, err := b.store.Put(ctx, entryKey(person, state.Count()-1), data, store.Absent); err != nil {
			if store.IsConflict(err) {
				return wire.LockHead{}, fmt.Errorf("%w: entry %d was put first", ErrChanged, state.Count()-1)
			}
			return wire.LockHead{}, err
		}
	}
	return HeadOf(state), nil
}

// Reset drops the person's lock, so the next client signs a new root (#3493, D4): the
// person lost every signer and the recovery key. It deletes the newest entry first, so a
// reader at the same moment reads a shorter chain, never one with a hole. Every client and
// machine that pinned the old lock refuses the new one until it joins again.
func (b *Book) Reset(ctx context.Context, person string) error {
	if err := checkPerson(person); err != nil {
		return err
	}
	keys, err := b.store.List(ctx, entriesPrefix(person))
	if err != nil {
		return err
	}
	for i := len(keys) - 1; i >= 0; i-- {
		if err := b.store.Delete(ctx, keys[i].Key); err != nil {
			return err
		}
	}
	return nil
}

// HeadOf is where a checked lock stands, as the wire says it.
func HeadOf(s *machinelock.State) wire.LockHead {
	h := s.Head()
	return wire.LockHead{Count: int64(s.Count()), Head: h[:]}
}

// Why is a book's error as words for a client, without the sentinel's own word.
func Why(err error) string {
	return strings.TrimPrefix(strings.TrimPrefix(err.Error(), ErrInvalid.Error()+": "), ErrChanged.Error()+": ")
}
