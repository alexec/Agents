package controlplane

import (
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
		return m.s.locks.Get(ctx, person)
	case "lock/add":
		request, err := require[wire.LockAdd](params, "LockAdd")
		if err != nil {
			return nil, err
		}
		head, err := m.s.locks.Add(ctx, person, request.Entries)
		if err != nil {
			return nil, lockFailure(err)
		}
		m.s.log(fmt.Sprintf("%d entries put on %s's lock, now %d", len(request.Entries), person, head.Count))
		m.s.announce("lockChanged", person, from.Client)
		m.s.lockChangedHere(person)
		// A request whose client is now in the lock is approved (#3490).
		m.s.lockJoins.lockGrew(ctx, person, from.Client)
		return head, nil
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
