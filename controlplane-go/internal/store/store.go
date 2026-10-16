// Package store is ControlStore.swift in Go (058, contracts/store.md): one object per
// record under v1/, in a folder or a bucket, every write that matters conditional, and
// forgetting done with a tombstone, because a bucket cannot be trusted to delete
// conditionally.
package store

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"sort"
	"strings"
	"sync"

	"crypto/sha256"
)

// Store is where the control plane remembers things.
type Store interface {
	// Get returns the object and its entity tag, or nil when there is none.
	Get(ctx context.Context, key string) (*Object, error)
	// Put writes data if the condition holds, and returns the new entity tag.
	Put(ctx context.Context, key string, data []byte, when Condition) (string, error)
	// Delete is unconditional: only for what a race cannot hurt.
	Delete(ctx context.Context, key string) error
	// List returns every key under prefix, with its entity tag, sorted.
	List(ctx context.Context, prefix string) ([]Key, error)
}

type Object struct {
	Data []byte
	ETag string
}

type Key struct {
	Key  string
	ETag string
}

// Condition is StoreCondition: Absent (If-None-Match: *), Matching(tag) (If-Match), or Always.
type Condition struct {
	kind int
	tag  string
}

var (
	Absent = Condition{kind: 1}
	Always = Condition{kind: 0}
)

func Matching(tag string) Condition { return Condition{kind: 2, tag: tag} }

func (c Condition) IsAbsent() bool          { return c.kind == 1 }
func (c Condition) IsAlways() bool          { return c.kind == 0 }
func (c Condition) Matching() (string, bool) { return c.tag, c.kind == 2 }

// ConflictError: the condition did not hold, and nothing was written.
type ConflictError struct{ Key string }

func (e *ConflictError) Error() string { return "conflict on " + e.Key }

// UnavailableError: the store could not be reached or said something not understood.
type UnavailableError struct{ Why string }

func (e *UnavailableError) Error() string { return "store unavailable: " + e.Why }

func IsConflict(err error) bool {
	var c *ConflictError
	return errors.As(err, &c)
}

func unavailable(format string, args ...any) error {
	return &UnavailableError{Why: fmt.Sprintf(format, args...)}
}

// Probe is the start-up check (rule 4): a store that ignores conditions would let two
// copies each believe they won, so a copy refuses to start on one.
func Probe(ctx context.Context, s Store, copy string) error {
	b := make([]byte, 8)
	rand.Read(b)
	key := "probe/" + copy + "-" + hex.EncodeToString(b)
	defer s.Delete(context.Background(), key)
	first, err := s.Put(ctx, key, []byte("probe"), Absent)
	if err != nil {
		return err
	}
	if _, err := s.Put(ctx, key, []byte("again"), Absent); !IsConflict(err) {
		if err != nil {
			return err
		}
		return unavailable("the store let a second create of %s through, so it ignores If-None-Match", key)
	}
	if _, err := s.Put(ctx, key, []byte("moved"), Matching(first)); err != nil {
		return err
	}
	if _, err := s.Put(ctx, key, []byte("stale"), Matching(first)); !IsConflict(err) {
		if err != nil {
			return err
		}
		return unavailable("the store let a write with a stale entity tag through, so it ignores If-Match")
	}
	return nil
}

// SHA256Tag is the folder and memory stores' entity tag: the same bytes, the same tag.
func SHA256Tag(data []byte) string {
	sum := sha256.Sum256(data)
	return `"` + hex.EncodeToString(sum[:]) + `"`
}

// Memory is a store in memory, for tests.
type Memory struct {
	mu      sync.Mutex
	objects map[string]Object
	Down    bool
}

func NewMemory() *Memory { return &Memory{objects: map[string]Object{}} }

func (m *Memory) Get(_ context.Context, key string) (*Object, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.Down {
		return nil, unavailable("the test turned it off")
	}
	o, ok := m.objects[key]
	if !ok {
		return nil, nil
	}
	return &Object{Data: append([]byte(nil), o.Data...), ETag: o.ETag}, nil
}

func (m *Memory) Put(_ context.Context, key string, data []byte, when Condition) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.Down {
		return "", unavailable("the test turned it off")
	}
	o, there := m.objects[key]
	if when.IsAbsent() && there {
		return "", &ConflictError{key}
	}
	if tag, ok := when.Matching(); ok && (!there || o.ETag != tag) {
		return "", &ConflictError{key}
	}
	tag := SHA256Tag(data)
	m.objects[key] = Object{Data: append([]byte(nil), data...), ETag: tag}
	return tag, nil
}

func (m *Memory) Delete(_ context.Context, key string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.Down {
		return unavailable("the test turned it off")
	}
	delete(m.objects, key)
	return nil
}

func (m *Memory) List(_ context.Context, prefix string) ([]Key, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.Down {
		return nil, unavailable("the test turned it off")
	}
	var out []Key
	for k, o := range m.objects {
		if strings.HasPrefix(k, prefix) {
			out = append(out, Key{k, o.ETag})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Key < out[j].Key })
	return out, nil
}
