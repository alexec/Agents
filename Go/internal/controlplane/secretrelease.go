package controlplane

import (
	"context"
	"crypto/ecdh"
	"encoding/json"
	"errors"
	"regexp"
	"strings"
	"time"

	"github.com/agentloops-dev/agents/Go/internal/controlplane/kms"
	"github.com/agentloops-dev/agents/Go/internal/controlplane/store"
	"github.com/agentloops-dev/agents/Go/internal/machinelock"
	"github.com/agentloops-dev/agents/Go/internal/secretrelease"
	"github.com/agentloops-dev/agents/Go/wire"
)

// The release key of a Linux machine (#4058, the spike #4013): the machine seals each value
// with Ask before use to its own key and to this key, and only the control plane keeps the
// private half, sealed by the secrets keeper. It opens one value's layer only for an
// approval that a client of the machine's person's lock signed to that machine, in the last
// ten minutes, once; and it gives back only the key for that layer. It never has the
// machine's key, so it never opens the value (Principle 6).
//
//	v1/release-keys/<host>.json           the private half, sealed (kms.Sealed)
//	v1/release-keys/<host>/seen/<id>.json an approval taken, by machinelock.SignedID

const releaseKeysPrefix = "v1/release-keys/"

var releaseHost = regexp.MustCompile(`^[A-Za-z0-9._-]{1,128}$`)

func releaseKeyKey(host string) string     { return releaseKeysPrefix + host + ".json" }
func releaseSeenPrefix(host string) string { return releaseKeysPrefix + host + "/seen/" }

type releaseSeen struct {
	At int64 `json:"at"`
}

func (m *Methods) secretReleaseMethod(ctx context.Context, host, method string, params json.RawMessage) (any, error) {
	if !releaseHost.MatchString(host) || m.s.records.Host(host) == nil {
		return nil, fail(notPermitted, "This machine is not joined.")
	}
	if !m.s.users.Sealing() {
		return nil, fail(notSupported, "This control plane has no key to keep a release key with, so a Linux machine of it cannot keep a secret with Ask before use.")
	}
	switch method {
	case wire.CallMachineSecretKey.Name:
		private, err := m.s.releaseKey(ctx, host, true)
		if err != nil {
			return nil, err
		}
		return wire.SecretReleaseKey{PublicKey: private.PublicKey().Bytes()}, nil
	case wire.CallMachineSecretRelease.Name:
		request, err := require[wire.SecretRelease](params, "SecretRelease")
		if err != nil {
			return nil, err
		}
		key, err := m.s.releaseSecret(ctx, host, request, time.Now())
		if err != nil {
			return nil, err
		}
		return wire.SecretReleased{Key: key}, nil
	}
	return nil, fail(methodNotFound, "No method %s.", method)
}

// releaseKey is a machine's release key: made, sealed and kept the first time create is true.
func (s *Service) releaseKey(ctx context.Context, host string, create bool) (*ecdh.PrivateKey, error) {
	at := releaseKeyKey(host)
	for range 3 {
		o, err := s.cfg.Store.Get(ctx, at)
		if err != nil {
			return nil, err
		}
		if o != nil {
			var sealed kms.Sealed
			if err := json.Unmarshal(o.Data, &sealed); err != nil {
				return nil, errors.New("the release key does not read")
			}
			raw, err := s.users.OpenFor(ctx, &sealed, []byte(at))
			if err != nil {
				return nil, err
			}
			defer clear(raw)
			return ecdh.X25519().NewPrivateKey(raw)
		}
		if !create {
			return nil, fail(invalidParams, "This machine has no release key, so nothing of it was sealed to one.")
		}
		private, err := secretrelease.NewKey()
		if err != nil {
			return nil, err
		}
		sealed, err := s.users.SealFor(ctx, private.Bytes(), []byte(at))
		if err != nil {
			return nil, err
		}
		b, _ := json.Marshal(sealed)
		if _, err := s.cfg.Store.Put(ctx, at, b, store.Absent); err != nil {
			if store.IsConflict(err) {
				// Another copy made it first: read that one.
				continue
			}
			return nil, err
		}
		s.log("made a release key for " + host)
		return private, nil
	}
	return nil, errors.New("the release key changed elsewhere; ask again")
}

// releaseSecret checks the person's signed approval and gives the key for one value's layer.
func (s *Service) releaseSecret(ctx context.Context, host string, r wire.SecretRelease, now time.Time) ([]byte, error) {
	refuse := func(why string) error {
		s.log("refused a release for " + host + ": " + why)
		return fail(notPermitted, "Nothing was released: %s.", why)
	}
	person := s.ownerOf(host)
	if person == "" || s.locks == nil {
		return nil, refuse("this machine has no person")
	}
	lock, err := s.locks.Get(ctx, person)
	if err != nil {
		return nil, err
	}
	if len(lock.Entries) == 0 {
		return nil, refuse("its person has no lock, so no device can sign an approval")
	}
	state, err := machinelock.Check(lock.Entries)
	if err != nil {
		return nil, refuse("its person's lock does not check")
	}
	a, err := secretrelease.CheckApproval(state, host, r.Approval, now)
	if err != nil {
		return nil, refuse(strings.TrimSuffix(err.Error(), "."))
	}
	if a.Name != r.Name || a.Action == "deny" || a.Action == "" {
		return nil, refuse("the approval is for another use")
	}
	private, err := s.releaseKey(ctx, host, false)
	if err != nil {
		return nil, err
	}
	// Taken once: a second write of the same signature finds it there.
	seen, _ := json.Marshal(releaseSeen{At: r.Approval.Lock.At})
	if _, err := s.cfg.Store.Put(ctx, releaseSeenPrefix(host)+machinelock.SignedID(r.Approval.Lock)+".json", seen, store.Absent); err != nil {
		if store.IsConflict(err) {
			return nil, refuse("that approval was used before")
		}
		return nil, err
	}
	s.forgetOldReleases(ctx, host, now)
	key, err := secretrelease.Release(private, r.Name, r.Encapsulated)
	if err != nil {
		return nil, fail(invalidParams, "%s", err.Error())
	}
	s.log("released " + r.Name + " for " + host + " (" + a.Use + " at " + a.Place + ")")
	return key, nil
}

// forgetOldReleases bounds what a machine's seen approvals keep: one past its lifetime is
// refused as stale anyway.
func (s *Service) forgetOldReleases(ctx context.Context, host string, now time.Time) {
	keys, err := s.cfg.Store.List(ctx, releaseSeenPrefix(host))
	if err != nil {
		return
	}
	oldest := now.Add(-2 * secretrelease.ApprovalLifetime).Unix()
	for _, k := range keys {
		o, err := s.cfg.Store.Get(ctx, k.Key)
		if err != nil || o == nil {
			continue
		}
		var seen releaseSeen
		if json.Unmarshal(o.Data, &seen) == nil && seen.At < oldest {
			s.cfg.Store.Delete(ctx, k.Key)
		}
	}
}
