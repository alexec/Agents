package controlplane

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"sync"

	"github.com/alexec/agents/Go/internal/controlplane/locks"
	"github.com/alexec/agents/Go/internal/machinelock"
	"github.com/alexec/agents/Go/wire"
)

// The machine lock (#3399, specs/3399-machine-lock): the control plane keeps each person's
// chain and sends it, but signs nothing. A client adds entries with lock/add; each machine
// that says host.lock/1 is sent the whole lock at each join and when it grows, and checks
// it against the head it pinned.

// toldLocks is the head each machine here was last sent, so a change resends only what
// differs.
type toldLocks struct {
	mu   sync.Mutex
	last map[string][sha256.Size]byte
}

func (m *Methods) lockMethod(ctx context.Context, method string, params json.RawMessage, from Caller) (any, error) {
	person := m.callerPerson(from)
	switch method {
	case "lock/get":
		var request wire.LockGet
		json.Unmarshal(params, &request)
		if other := deref(request.Person); other != "" && other != person {
			// Another person's lock, for an admin's client to check the machine keys it seals
			// an org route to (#3491, D7, D8). It holds only public keys and names.
			if !m.s.isAdmin(person) {
				return nil, fail(notPermitted, "Only an admin can read another person's lock.")
			}
			person = other
		}
		return m.s.locks.Get(ctx, person)
	case "lock/add":
		request, err := require[wire.LockAdd](params, "LockAdd")
		if err != nil {
			return nil, err
		}
		return m.s.addToLock(ctx, person, request.Entries, from.Client)
	}
	return nil, fail(methodNotFound, "No method %s.", method)
}

// addToLock puts a client's or a machine's entries on a person's lock, and tells everyone
// who keeps a copy.
func (s *Service) addToLock(ctx context.Context, person string, entries []wire.LockEntry, by string) (any, error) {
	head, err := s.locks.Add(ctx, person, entries)
	if err != nil {
		return nil, lockFailure(err)
	}
	s.log(fmt.Sprintf("%d entries put on %s's lock, now %d", len(entries), person, head.Count))
	s.announce("lockChanged", person, by)
	s.lockChangedHere(person)
	// A request whose client or machine is now in the lock is approved (#3490, #3491).
	s.lockJoins.lockGrew(ctx, person, by)
	return head, nil
}

// hostLockMethod is a machine joining its person's lock (#3491, D3), on its channel 0.
func (m *Methods) hostLockMethod(ctx context.Context, host, method string, params json.RawMessage) (any, error) {
	person := m.s.ownerOf(host)
	record := m.s.records.Host(host)
	if person == "" || record == nil {
		return nil, fail(notPermitted, "This machine is not joined.")
	}
	switch method {
	case "host/lockAdd":
		// Only the machine's own addMachine, signed with an invite: the lock checks the
		// invite, and this checks that the machine adds itself and nothing else.
		request, err := require[wire.LockAdd](params, "LockAdd")
		if err != nil {
			return nil, err
		}
		for _, e := range request.Entries {
			body, err := machinelock.Open(e)
			if err != nil || body.Kind != wire.LockEntryKindAddMachine || !bytes.Equal(body.Key, record.PublicKey) {
				return nil, fail(invalidParams, "A machine puts only its own addMachine on the lock.")
			}
		}
		return m.s.addToLock(ctx, person, request.Entries, host)
	case "host/lockJoin":
		request, err := require[wire.LockJoin](params, "LockJoin")
		if err != nil {
			return nil, err
		}
		return m.s.lockJoins.askMachine(ctx, host, request)
	case "host/lockJoinReveal":
		request, err := require[wire.LockJoinNonce](params, "LockJoinNonce")
		if err != nil {
			return nil, err
		}
		if err := m.s.lockJoins.nonce(ctx, person, host, false, request); err != nil {
			return nil, err
		}
		return wire.Empty{}, nil
	}
	return nil, fail(methodNotFound, "No method %s.", method)
}

// lockFailure is a lock book's error as words for the client.
func lockFailure(err error) error {
	switch {
	case errors.Is(err, locks.ErrChanged):
		return fail(changedElsewhere, "Another of your devices changed your lock at the same time (%s). Read it again.", locks.Why(err))
	case errors.Is(err, locks.ErrInvalid):
		return fail(invalidParams, "%s", locks.Why(err))
	}
	return err
}

// lockChangedHere is an entry put on a person's lock, here or at another copy: their
// clients here read it again, and their machines here are sent it.
func (s *Service) lockChangedHere(person string) {
	ctx, cancel := context.WithTimeout(context.Background(), userDeliveryTimeout)
	defer cancel()
	lock, err := s.locks.Get(ctx, person)
	if err != nil {
		s.log("the lock of " + person + " could not be read: " + err.Error())
		return
	}
	if state, err := machinelock.Check(lock.Entries); err == nil {
		s.router.TellPerson(person, wire.NotifyControlLockChanged.Name, locks.HeadOf(state))
	}
	for _, host := range s.router.HostsHeldHere() {
		if s.ownerOf(host) == person {
			go s.sendLock(host, false)
		}
	}
}

// takesLock says a machine checks host/lock.
func (s *Service) takesLock(host string) bool {
	h := s.records.Host(host)
	return h != nil && slices.Contains(hostCapabilities(*h), wire.CapHostLock1)
}

// sendLock sends a machine its person's whole lock, on its channel 0. always sends even
// what it was sent last (a join). A person with no lock yet sends nothing.
func (s *Service) sendLock(host string, always bool) {
	if s.locks == nil || !s.takesLock(host) {
		return
	}
	person := s.ownerOf(host)
	if person == "" {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), userDeliveryTimeout)
	defer cancel()
	lock, err := s.locks.Get(ctx, person)
	if err != nil {
		s.log("the lock for " + host + " could not be read: " + err.Error())
		return
	}
	if len(lock.Entries) == 0 {
		return
	}
	b, _ := json.Marshal(lock)
	sum := sha256.Sum256(b)
	s.toldLocks.mu.Lock()
	if s.toldLocks.last == nil {
		s.toldLocks.last = map[string][sha256.Size]byte{}
	}
	same := s.toldLocks.last[host] == sum
	s.toldLocks.mu.Unlock()
	if same && !always {
		return
	}
	if s.ownerOf(host) != person || !s.router.Tell(host, wire.NewMethodName(wire.NotifyHostLock.Name), lock) {
		s.toldLocks.mu.Lock()
		delete(s.toldLocks.last, host)
		s.toldLocks.mu.Unlock()
		return
	}
	s.toldLocks.mu.Lock()
	s.toldLocks.last[host] = sum
	s.toldLocks.mu.Unlock()
}
