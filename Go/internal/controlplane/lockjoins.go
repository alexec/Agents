package controlplane

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/sha256"
	"encoding/json"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/controlplane/records"
	"github.com/agentloops-dev/agent-loops/Go/internal/controlplane/store"
	"github.com/agentloops-dev/agent-loops/Go/internal/machinelock"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// Adding a client to the machine lock (#3490, specs/3399-machine-lock D2). A client that is
// not in its person's lock asks with lock/join and a commitment; a signer sends its nonce
// (lock/joinAnswer); the new client then shows its own (lock/joinReveal), and both screens
// show six digits. The signer approves by putting the client's addClient on the lock with
// lock/add. The control plane only passes the request on: it signs nothing, and the digits
// are made on the two screens. Requests are kept in the store (v1/lockjoins/<id>.json) so
// any copy can take the next step, and each change is told to the person's clients at
// every copy.
//
// A machine that is not in the lock and has no invite asks the same way (#3491, D3), on its
// channel 0: machine/lockJoin and machine/lockJoinReveal, told how it goes with
// machine/lockJoinChanged. Its request names the machine, and a signer approves it with an
// addMachine whose key is the machine's.

const (
	lockJoinsPrefix = "v1/lockjoins/"
	// At most this many requests wait for one person, and for everyone.
	lockJoinsPerPerson = 5
	lockJoinsOpen      = 200
)

type lockJoinRecord struct {
	ID         string        `json:"id"`
	Person     string        `json:"person"`
	Client     string        `json:"client"`
	Machine    bool          `json:"machine,omitempty"`
	Name       string        `json:"name"`
	Kind       string        `json:"kind"`
	Key        []byte        `json:"key"`
	Commitment []byte        `json:"commitment"`
	Nonce      []byte        `json:"nonce,omitempty"`
	AnsweredBy string        `json:"answeredBy,omitempty"`
	Reveal     []byte        `json:"reveal,omitempty"`
	Created    records.Stamp `json:"created"`
	Expires    records.Stamp `json:"expires"`
	Result     string        `json:"result,omitempty"`
}

func lockJoinKey(id string) string { return lockJoinsPrefix + id + ".json" }

type lockJoins struct {
	s   *Service
	now func() time.Time
	mu  sync.Mutex
}

func newLockJoins(s *Service) *lockJoins { return &lockJoins{s: s, now: time.Now} }

func (j *lockJoins) open(r lockJoinRecord) bool {
	return r.Result == "" && j.now().Before(r.Expires.Time)
}

func (j *lockJoins) read(ctx context.Context, id string) (*lockJoinRecord, string, error) {
	if !isJoinID(id) {
		return nil, "", nil
	}
	object, err := j.s.cfg.Store.Get(ctx, lockJoinKey(id))
	if err != nil || object == nil {
		return nil, "", err
	}
	var r lockJoinRecord
	if json.Unmarshal(object.Data, &r) != nil || r.ID != id {
		return nil, "", nil
	}
	return &r, object.ETag, nil
}

// all is every request kept; ended ones older than joinKept are deleted on the way.
func (j *lockJoins) all(ctx context.Context) ([]lockJoinRecord, error) {
	listed, err := j.s.cfg.Store.List(ctx, lockJoinsPrefix)
	if err != nil {
		return nil, err
	}
	out := []lockJoinRecord{}
	for _, entry := range listed {
		r, _, err := j.read(ctx, strings.TrimSuffix(strings.TrimPrefix(entry.Key, lockJoinsPrefix), ".json"))
		if err != nil || r == nil {
			continue
		}
		if j.now().Sub(r.Expires.Time) > joinKept {
			j.s.cfg.Store.Delete(ctx, entry.Key)
			continue
		}
		out = append(out, *r)
	}
	sort.Slice(out, func(a, b int) bool { return out[a].Created.Before(out[b].Created.Time) })
	return out, nil
}

func (j *lockJoins) write(ctx context.Context, r lockJoinRecord, condition store.Condition) error {
	data, err := records.Encode(r)
	if err != nil {
		return err
	}
	if _, err := j.s.cfg.Store.Put(ctx, lockJoinKey(r.ID), data, condition); err != nil {
		if store.IsConflict(err) {
			return fail(changedElsewhere, "That request changed on another device at the same time. Try again.")
		}
		return err
	}
	return nil
}

func (j *lockJoins) row(r lockJoinRecord) wire.LockJoinRequest {
	row := wire.LockJoinRequest{Request: r.ID, Client: r.Client, Name: r.Name, Kind: wire.ClientKind(r.Kind), Key: r.Key,
		Commitment: r.Commitment, Expires: dateOf(r.Expires.Time), Nonce: r.Nonce, AnsweredBy: optional(r.AnsweredBy), Reveal: r.Reveal}
	if r.Machine {
		host := wire.MachineRef(r.Client)
		row.Machine = &host
	}
	return row
}

// tell is a request's change, to the person's clients here, and to the machine that asks
// when it is held here.
func (j *lockJoins) tell(r lockJoinRecord) {
	if r.Machine && r.Result == "" {
		j.s.router.Tell(r.Client, wire.NotifyMachineLockJoinChanged.Name, j.row(r))
	}
	if r.Result != "" {
		j.s.router.TellPerson(r.Person, wire.NotifyControlLockJoinDecided.Name, wire.LockJoinDecided{Request: r.ID, Result: r.Result})
		return
	}
	j.s.router.TellPerson(r.Person, wire.NotifyControlLockJoinRequested.Name, j.row(r))
}

// changed is a request written here: its person's clients here, and at every other copy.
func (j *lockJoins) changed(r lockJoinRecord, by string) {
	j.tell(r)
	j.s.announce("lockJoinChanged", r.ID, by)
}

// changedHere is a request another copy wrote.
func (j *lockJoins) changedHere(id string) {
	r, _, err := j.read(context.Background(), id)
	if err == nil && r != nil {
		j.tell(*r)
	}
}

// mine is an open request of the caller's person, read with its etag.
func (j *lockJoins) mine(ctx context.Context, id, person string) (*lockJoinRecord, string, error) {
	r, etag, err := j.read(ctx, id)
	if err != nil {
		return nil, "", fail(storeUnavailable, "The request could not be read.")
	}
	if r == nil || r.Person != person {
		return nil, "", fail(invalidParams, "There is no such request.")
	}
	if !j.open(*r) {
		return nil, "", fail(notPermitted, "That request has ended. The new device can ask again.")
	}
	return r, etag, nil
}

func (m *Methods) lockJoinMethod(ctx context.Context, method string, params json.RawMessage, from Caller) (any, error) {
	j := m.s.lockJoins
	person := m.callerPerson(from)
	switch method {
	case "lock/joinRequests":
		all, err := j.all(ctx)
		if err != nil {
			return nil, fail(storeUnavailable, "The requests could not be read: %v", err)
		}
		out := []wire.LockJoinRequest{}
		for _, r := range all {
			if j.open(r) && r.Person == person {
				out = append(out, j.row(r))
			}
		}
		return out, nil
	case "lock/join":
		request, err := require[wire.LockJoin](params, "LockJoin")
		if err != nil {
			return nil, err
		}
		return j.ask(ctx, person, from.Client, request)
	case "lock/joinAnswer", "lock/joinReveal":
		request, err := require[wire.LockJoinNonce](params, "LockJoinNonce")
		if err != nil {
			return nil, err
		}
		if err := j.nonce(ctx, person, from.Client, method == "lock/joinAnswer", request); err != nil {
			return nil, err
		}
		return wire.Empty{}, nil
	case "lock/joinDeny":
		request, err := require[wire.LockJoinEnd](params, "LockJoinEnd")
		if err != nil {
			return nil, err
		}
		j.mu.Lock()
		defer j.mu.Unlock()
		r, etag, err := j.mine(ctx, request.Request, person)
		if err != nil {
			return nil, err
		}
		r.Result = "denied"
		if err := j.write(ctx, *r, store.Matching(etag)); err != nil {
			return nil, err
		}
		j.changed(*r, from.Client)
		if r.Client == from.Client {
			m.s.log(r.Name + " stopped asking to join the lock")
		} else {
			m.s.log(r.Name + " was not added to the lock")
		}
		return wire.Empty{}, nil
	}
	return nil, fail(methodNotFound, "No method %s.", method)
}

// nonce is lock/joinAnswer (a signer's, answer) or lock/joinReveal and machine/lockJoinReveal
// (the asking client's or machine's own).
func (j *lockJoins) nonce(ctx context.Context, person, from string, answer bool, request wire.LockJoinNonce) error {
	if len(request.Nonce) != machinelock.NonceSize {
		return fail(invalidParams, "A nonce is %d bytes.", machinelock.NonceSize)
	}
	j.mu.Lock()
	defer j.mu.Unlock()
	r, etag, err := j.mine(ctx, request.Request, person)
	if err != nil {
		return err
	}
	if answer {
		if r.Client == from {
			return fail(notPermitted, "A device cannot approve itself.")
		}
		if len(r.Nonce) != 0 {
			return fail(notPermitted, "Another of your devices is comparing the digits already.")
		}
		r.Nonce, r.AnsweredBy = request.Nonce, from
	} else {
		if r.Client != from {
			return fail(invalidParams, "There is no such request.")
		}
		if len(r.Nonce) == 0 || len(r.Reveal) != 0 {
			return fail(notPermitted, "The request is not waiting for this device's digits.")
		}
		if !bytes.Equal(machinelock.Commitment(r.Key, request.Nonce), r.Commitment) {
			return fail(invalidParams, "That nonce is not the one the request named.")
		}
		r.Reveal = request.Nonce
	}
	if err := j.write(ctx, *r, store.Matching(etag)); err != nil {
		return err
	}
	j.changed(*r, from)
	return nil
}

// ask is lock/join: a new request, in place of any the same client still has open.
func (j *lockJoins) ask(ctx context.Context, person, client string, request wire.LockJoin) (any, error) {
	record := j.s.records.Client(client)
	if record == nil {
		return nil, fail(notPermitted, "This client is not paired.")
	}
	return j.open1(ctx, lockJoinRecord{Person: person, Client: client, Name: record.Name, Kind: record.Kind}, request)
}

// askMachine is machine/lockJoin: a machine of the person asks, as a client does (#3491).
func (j *lockJoins) askMachine(ctx context.Context, host string, request wire.LockJoin) (any, error) {
	record := j.s.records.Host(host)
	person := j.s.ownerOf(host)
	if record == nil || person == "" {
		return nil, fail(notPermitted, "This machine is not joined.")
	}
	if !bytes.Equal(record.PublicKey, request.Key) {
		// A machine asks with its own key, the one it joined with, and nothing else.
		return nil, fail(invalidParams, "That is not this machine's key.")
	}
	return j.open1(ctx, lockJoinRecord{Person: person, Client: host, Machine: true, Name: cmpOr(record.Name, host),
		Kind: string(wire.ClientKindUnknown)}, request)
}

// open1 opens a request of the client or machine in r, in place of any it still has open.
func (j *lockJoins) open1(ctx context.Context, asking lockJoinRecord, request wire.LockJoin) (any, error) {
	person, client := asking.Person, asking.Client
	if _, err := ecdh.P256().NewPublicKey(request.Key); err != nil {
		return nil, fail(invalidParams, "The key is not a P-256 key.")
	}
	if len(request.Commitment) != sha256.Size {
		return nil, fail(invalidParams, "The commitment is %d bytes.", sha256.Size)
	}
	lock, err := j.s.locks.Get(ctx, person)
	if err != nil {
		return nil, fail(storeUnavailable, "The lock could not be read.")
	}
	if len(lock.Entries) == 0 {
		return nil, fail(notPermitted, "There is no lock yet: this device makes it.")
	}
	if state, err := machinelock.Check(lock.Entries); err == nil {
		if member, ok := state.Member(request.Key); ok && member.Client() == !asking.Machine {
			return nil, fail(notPermitted, "This device is in the lock already.")
		}
	}
	j.mu.Lock()
	defer j.mu.Unlock()
	all, err := j.all(ctx)
	if err != nil {
		return nil, fail(storeUnavailable, "The requests could not be read.")
	}
	waiting, forPerson := 0, 0
	var ended []lockJoinRecord
	for _, r := range all {
		if !j.open(r) {
			continue
		}
		if r.Client == client {
			// Asking again ends the one before.
			if _, etag, err := j.read(ctx, r.ID); err == nil {
				r.Result = "expired"
				if j.write(ctx, r, store.Matching(etag)) == nil {
					ended = append(ended, r)
				}
			}
			continue
		}
		waiting++
		if r.Person == person {
			forPerson++
		}
	}
	for _, r := range ended {
		j.changed(r, client)
	}
	if waiting >= lockJoinsOpen || forPerson >= lockJoinsPerPerson {
		return nil, fail(notPermitted, "Too many devices are waiting to join. Try again in a few minutes.")
	}
	now := records.At(j.now())
	r := asking
	r.ID, r.Key, r.Commitment, r.Created, r.Expires = newJoinID(), request.Key, request.Commitment, now, records.At(now.Add(joinLifetime))
	if err := j.write(ctx, r, store.Absent); err != nil {
		return nil, err
	}
	j.changed(r, client)
	j.s.log(r.Name + " asks to join its person's lock (request " + r.ID[:8] + ")")
	return wire.LockJoinStarted{Request: r.ID, Expires: dateOf(r.Expires.Time)}, nil
}

// lockGrew is an entry put on a person's lock: each open request whose key is now a client
// of the lock is approved.
func (j *lockJoins) lockGrew(ctx context.Context, person string, by string) {
	lock, err := j.s.locks.Get(ctx, person)
	if err != nil {
		return
	}
	state, err := machinelock.Check(lock.Entries)
	if err != nil {
		return
	}
	j.mu.Lock()
	defer j.mu.Unlock()
	all, err := j.all(ctx)
	if err != nil {
		return
	}
	for _, r := range all {
		if r.Person != person || !j.open(r) {
			continue
		}
		if member, ok := state.Member(r.Key); !ok || member.Client() == r.Machine {
			continue
		}
		_, etag, err := j.read(ctx, r.ID)
		if err != nil {
			continue
		}
		r.Result = "approved"
		if j.write(ctx, r, store.Matching(etag)) == nil {
			j.changed(r, by)
			j.s.log(r.Name + " was added to the lock")
		}
	}
}
