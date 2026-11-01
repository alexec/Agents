package store

import (
	"context"
	"sort"
	"strings"
	"sync"
)

// Memory is MemoryStore: a store in memory, for tests and for copies in one process in
// the copies tests.
type Memory struct {
	mu      sync.Mutex
	objects map[string]Object
	down    bool
}

func NewMemory() *Memory { return &Memory{objects: map[string]Object{}} }

// SetDown makes every call fail as a store that cannot be reached.
func (m *Memory) SetDown(down bool) {
	m.mu.Lock()
	m.down = down
	m.mu.Unlock()
}

func (m *Memory) reachable() error {
	if m.down {
		return Unavailable("the test turned it off")
	}
	return nil
}

func (m *Memory) Get(_ context.Context, key string) (*Object, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.reachable(); err != nil {
		return nil, err
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
	if err := m.reachable(); err != nil {
		return "", err
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
	if err := m.reachable(); err != nil {
		return err
	}
	delete(m.objects, key)
	return nil
}

func (m *Memory) List(_ context.Context, prefix string) ([]Key, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.reachable(); err != nil {
		return nil, err
	}
	out := []Key{}
	for k, o := range m.objects {
		if strings.HasPrefix(k, prefix) {
			out = append(out, Key{k, o.ETag, int64(len(o.Data))})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Key < out[j].Key })
	return out, nil
}
