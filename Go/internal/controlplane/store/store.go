// Package store is where the control plane remembers things (058, research R4,
// contracts/store.md), as ControlStore.swift has it: one object per record under
// <prefix>/v1/, in a folder or a bucket.
//
// Every write that matters is conditional, so several copies of the control plane can
// share one store: a write either applies to the version it read, or is refused with a
// ConflictError and changes nothing. There is no conditional delete (MinIO ignores
// If-Match on DELETE), so forgetting a record writes a tombstone instead.
//
// The folder store is the default and needs no account (#1134); a bucket is an option.
package store

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
)

// Store is ControlStore.
type Store interface {
	// Get returns the object and its entity tag, or nil when there is none.
	Get(ctx context.Context, key string) (*Object, error)
	// Put writes data if the condition holds, and returns the new entity tag.
	Put(ctx context.Context, key string, data []byte, when Condition) (string, error)
	// Delete deletes unconditionally. Only for what a race cannot hurt: spent and
	// expired codes, old events, old tombstones, a probe.
	Delete(ctx context.Context, key string) error
	// List returns every key under prefix, with its entity tag, sorted by key.
	List(ctx context.Context, prefix string) ([]Key, error)
}

// Object is StoredObject.
type Object struct {
	Data []byte
	ETag string
}

// Key is StoredKey.
type Key struct {
	Key  string
	ETag string
	// Size is the object's bytes, as the listing says them, so its size needs no read
	// (#3103); -1 when the store's listing does not say.
	Size int64
}

// Condition is StoreCondition: Absent (If-None-Match: *), Matching(tag) (If-Match, the
// tag sent exactly as it was given), or Always (only for a copy's own heartbeat, which
// nobody else writes).
type Condition struct {
	kind conditionKind
	tag  string
}

type conditionKind int

const (
	always conditionKind = iota
	absent
	matching
)

var (
	Absent = Condition{kind: absent}
	Always = Condition{kind: always}
)

// Matching is If-Match: tag.
func Matching(tag string) Condition { return Condition{kind: matching, tag: tag} }

func (c Condition) IsAbsent() bool { return c.kind == absent }
func (c Condition) IsAlways() bool { return c.kind == always }

// Matching returns the tag of an If-Match condition.
func (c Condition) Matching() (string, bool) { return c.tag, c.kind == matching }

// ConflictError is StoreError.conflict: the condition did not hold (412, 409, or 404 on
// an If-Match), or the key already exists (Absent). Nothing was written.
type ConflictError struct{ Key string }

func (e *ConflictError) Error() string { return "conflict on " + e.Key }

// UnavailableError is StoreError.unavailable: the store could not be reached or answered
// something not understood.
type UnavailableError struct{ Why string }

func (e *UnavailableError) Error() string { return "store unavailable: " + e.Why }

// IsConflict reports whether err is a ConflictError.
func IsConflict(err error) bool {
	var c *ConflictError
	return errors.As(err, &c)
}

// Unavailable makes an UnavailableError.
func Unavailable(format string, args ...any) error {
	return &UnavailableError{Why: fmt.Sprintf(format, args...)}
}

// Probe is the start-up probe (contracts/store.md rule 4): a store that ignores
// conditions would let two copies each believe they won, so a copy refuses to start on
// one.
func Probe(ctx context.Context, s Store, copy string) error {
	key := "probe/" + copy + "-" + randomHex(16)
	first, err := s.Put(ctx, key, []byte("probe"), Absent)
	if err != nil {
		return err
	}
	defer s.Delete(context.WithoutCancel(ctx), key)
	if _, err := s.Put(ctx, key, []byte("again"), Absent); !IsConflict(err) {
		if err != nil {
			return err
		}
		return Unavailable("the store let a second create of %s through, so it ignores If-None-Match", key)
	}
	if _, err := s.Put(ctx, key, []byte("moved"), Matching(first)); err != nil {
		return err
	}
	if _, err := s.Put(ctx, key, []byte("stale"), Matching(first)); !IsConflict(err) {
		if err != nil {
			return err
		}
		return Unavailable("the store let a write with a stale entity tag through, so it ignores If-Match")
	}
	return nil
}

// SHA256Tag is the folder and memory stores' entity tag, as Swift's: the quoted hex
// SHA-256 of the bytes. The same bytes have the same tag, as on S3 and MinIO.
func SHA256Tag(data []byte) string {
	sum := sha256.Sum256(data)
	return `"` + hex.EncodeToString(sum[:]) + `"`
}

func randomHex(n int) string {
	b := make([]byte, n)
	rand.Read(b)
	return hex.EncodeToString(b)
}
