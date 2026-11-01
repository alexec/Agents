package controlplane

import (
	"bytes"
	"context"
	"errors"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/records"
)

// Rotating the control key (#997, spec 736 FR-043). An admin's control/rotate makes a
// new key and keeps the old one as the previous key for previousKeyKept. The hello names
// both. A member that still trusts the previous key proves itself with it, and its ok
// gives it the new key with a proof only the previous key's holder can make
// (controllink.NewKeyProof), so nobody pairs again. Every member's connection is closed
// at the rotation, so each takes the new key at once. After previousKeyKept, a member
// not seen since pairs again.

// previousKeyKept is how long the key before a rotation is still accepted.
const previousKeyKept = 30 * 24 * time.Hour

// KeyKeeper keeps the control plane's key where it came from (kms.File, kms.Kept), so a
// rotation outlives a restart. A key handed in (AGENTS_CONTROL_KEY, --key-fd) has none,
// and is not rotated.
type KeyKeeper interface {
	// Rotate keeps next as the key and previous as the one before it.
	Rotate(ctx context.Context, previous, next []byte) error
	// Previous is the key before the last rotation, or nil.
	Previous(ctx context.Context) ([]byte, error)
	// DropPrevious forgets the key before the last rotation.
	DropPrevious(ctx context.Context) error
}

// controlKeys are the control plane's private and public keys, and the previous ones
// for previousKeyKept after a rotation.
type controlKeys struct {
	private, public                 []byte
	previousPrivate, previousPublic []byte
}

type keyBook struct {
	keysMu   sync.RWMutex
	keys     controlKeys
	rotating sync.Mutex
}

func (s *Service) currentKeys() controlKeys {
	s.keysMu.RLock()
	defer s.keysMu.RUnlock()
	return s.keys
}

func (s *Service) privateKey() []byte { return s.currentKeys().private }
func (s *Service) publicKey() []byte  { return s.currentKeys().public }

func (s *Service) setKeys(k controlKeys) {
	s.keysMu.Lock()
	s.keys = k
	s.keysMu.Unlock()
}

// takeUpPreviousKey settles the key at start: control.json may name the key before a
// rotation stopped between the keeper and control.json, and the previous key is taken
// up while it is still kept. It says the key control.json should name the previous one.
func (s *Service) takeUpPreviousKey(ctx context.Context, settings *records.Settings) (previous []byte, err error) {
	keys := s.currentKeys()
	stale := settings != nil && settings.ControlKey != nil && !bytes.Equal(settings.ControlKey, keys.public)
	if settings == nil || s.cfg.KeyKeeper == nil || (!stale && settings.PreviousKey == nil) {
		if stale {
			return nil, errors.New("this store belongs to a control plane with another key; give it that key, or another store")
		}
		return nil, nil
	}
	private, err := s.cfg.KeyKeeper.Previous(ctx)
	if err != nil {
		return nil, err
	}
	var public []byte
	if private != nil {
		public, _ = controllink.PublicKey(private)
	}
	want := settings.PreviousKey
	if stale {
		// Rotated, and stopped before control.json said so: its key is the previous one.
		want = settings.ControlKey
	}
	if public == nil || !bytes.Equal(public, want) {
		if stale {
			return nil, errors.New("this store belongs to a control plane with another key; give it that key, or another store")
		}
		return nil, nil // the previous key is gone: members still on it pair again
	}
	rotated := settings.RotatedAt
	if !stale && (rotated == nil || time.Since(rotated.Time) > previousKeyKept) {
		return nil, nil
	}
	keys.previousPrivate, keys.previousPublic = private, public
	s.setKeys(keys)
	return public, nil
}

// rotate is control/rotate.
func (s *Service) rotate(ctx context.Context, from Caller) error {
	if !s.isAdmin(s.actorFor(from.Client).User) {
		return fail(notPermitted, "Only an admin can rotate the control key.")
	}
	if s.cfg.KeyKeeper == nil {
		return fail(notSupported, "This control plane is given its key (AGENTS_CONTROL_KEY or --key-fd), so it cannot keep a new one.")
	}
	if s.mesh != nil {
		return fail(notSupported, "This control plane runs as several copies, which prove themselves to each other with its key. Rotate it while one copy runs.")
	}
	s.rotating.Lock()
	defer s.rotating.Unlock()
	old := s.currentKeys()
	next := controllink.NewPrivateKey()
	nextPublic, err := controllink.PublicKey(next)
	if err != nil {
		return err
	}
	// The keeper first: a stop before control.json is said is taken up at the next start.
	if err := s.cfg.KeyKeeper.Rotate(ctx, old.private, next); err != nil {
		return fail(storeUnavailable, "The new key could not be kept, so nothing changed: %v", err)
	}
	now := records.Now()
	if _, err := s.records.ChangeSettings(ctx, func(settings *records.Settings) {
		settings.ControlKey, settings.PreviousKey, settings.RotatedAt = nextPublic, old.public, &now
	}); err != nil {
		return err
	}
	s.setKeys(controlKeys{private: next, public: nextPublic, previousPrivate: old.private, previousPublic: old.public})
	s.log("the control key was rotated; the previous one is accepted for 30 days")
	// The backups' key, sealed with the new key, so the backups outlive the previous one.
	if err := s.backups.keepDataKey(ctx); err != nil {
		s.log("the backups' key could not be sealed with the new control key, and is at the next start: " + err.Error())
	}
	// The policy, signed with the new key, which each member is given as it connects again.
	s.resignPolicy(ctx)
	// Each member connects again, with the previous key, and is given the new one. After
	// a moment, so the admin's own answer goes first.
	go func() {
		select {
		case <-s.stop:
		case <-time.After(time.Second):
			s.router.CloseMembers()
		}
	}()
	return nil
}

// dropPreviousKey forgets the key before a rotation once previousKeyKept has passed.
func (s *Service) dropPreviousKey(ctx context.Context) {
	settings := s.records.Settings()
	if settings == nil || settings.PreviousKey == nil || settings.RotatedAt == nil ||
		time.Since(settings.RotatedAt.Time) <= previousKeyKept {
		return
	}
	s.rotating.Lock()
	defer s.rotating.Unlock()
	// Not while the backups' key is sealed only with the previous key: it would be lost.
	if err := s.backups.keepDataKey(ctx); err != nil {
		s.log("the previous control key is kept: the backups' key could not be sealed with this one: " + err.Error())
		return
	}
	if _, err := s.records.ChangeSettings(ctx, func(settings *records.Settings) { settings.PreviousKey = nil }); err != nil {
		s.log("could not forget the previous control key: " + err.Error())
		return
	}
	keys := s.currentKeys()
	keys.previousPrivate, keys.previousPublic = nil, nil
	s.setKeys(keys)
	if s.cfg.KeyKeeper != nil {
		if err := s.cfg.KeyKeeper.DropPrevious(ctx); err != nil {
			s.log("could not delete the previous control key: " + err.Error())
		}
	}
	s.log("the control key before the last rotation is no longer accepted")
}

// newKeyFor is what an ok gives a member that proved itself with the previous key.
func newKeyFor(shared, public []byte) *controllink.NewKeyOffer {
	return &controllink.NewKeyOffer{Key: controllink.B64URL(public),
		Proof: controllink.B64URL(controllink.NewKeyProof(shared, public))}
}
